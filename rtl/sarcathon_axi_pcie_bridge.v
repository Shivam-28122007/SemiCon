`timescale 1ns/1ps
// SARCathon 2026 Phase 2/4 educational reference implementation.
// AXI4 slave -> packet-oriented abstract PCIe TLP interface.
// Synthesizable RTL; compile with Icarus: iverilog -g2012 ...
//
// Contract / deliberate scope:
// * Full-width AXI beats only; INCR bursts only; burst length <= MAX_BEATS.
// * Writes are coalesced into one TLP per AXI burst.
// * Reads are coalesced into one TLP per AXI burst.
// * Multiple reads may be outstanding; completion tags identify the request.
// * AXI R responses are returned in AR acceptance order, even if completions
//   arrive out of order.
// * W data is buffered in a FIFO; one write-address transaction is collected
//   at a time. The abstract TLP data bus holds MAX_BEATS beats.
// * This is not a PCIe 6.0 link/FLIT/CRC/FEC/PHY implementation.
//
// Phase 4 PPA revision (functionally equivalent at the ports, see
// PHASE4_SYNTHESIS_PPA.md; the Phase 2 version is frozen under
// phase4/rtl_reference/):
// * Write pipeline: the next AW is accepted as soon as the previous write TLP
//   is accepted downstream, instead of waiting for the AXI B handshake.
// * tx_tlp_data is driven from the write collection register instead of a
//   second 256-bit copy; tx_tlp_type/tag reuse existing state.
// * The W FIFO stores one "strobe is all ones" bit instead of the full WSTRB.
// * Pure datapath registers have no reset; every control/valid flop keeps its
//   asynchronous reset, so no X reaches a VALID output.
// * Locally rejected reads return zero data by masking, not by clearing the
//   tag data registers.
module sarcathon_axi_pcie_bridge #(
    parameter integer DATA_WIDTH   = 64,
    parameter integer ADDR_WIDTH   = 32,
    parameter integer AXI_ID_WIDTH = 4,
    parameter integer MAX_BEATS    = 4,
    parameter integer TAG_COUNT    = 4,
    parameter integer W_FIFO_DEPTH = 2 * MAX_BEATS
) (
    input  wire clk,
    input  wire rst_n,

    // AXI4 write address channel
    input  wire [AXI_ID_WIDTH-1:0] s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire [7:0]              s_axi_awlen,   // beats - 1
    input  wire [2:0]              s_axi_awsize,
    input  wire [1:0]              s_axi_awburst,
    input  wire                    s_axi_awvalid,
    output wire                    s_axi_awready,

    // AXI4 write data channel
    input  wire [DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                    s_axi_wlast,
    input  wire                    s_axi_wvalid,
    output wire                    s_axi_wready,

    // AXI4 write response channel
    output reg  [AXI_ID_WIDTH-1:0] s_axi_bid,
    output reg  [1:0]              s_axi_bresp,
    output reg                     s_axi_bvalid,
    input  wire                    s_axi_bready,

    // AXI4 read address channel
    input  wire [AXI_ID_WIDTH-1:0] s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire [7:0]              s_axi_arlen,
    input  wire [2:0]              s_axi_arsize,
    input  wire [1:0]              s_axi_arburst,
    input  wire                    s_axi_arvalid,
    output wire                    s_axi_arready,

    // AXI4 read data channel
    output wire [AXI_ID_WIDTH-1:0] s_axi_rid,
    output wire [DATA_WIDTH-1:0]   s_axi_rdata,
    output wire [1:0]              s_axi_rresp,
    output wire                    s_axi_rlast,
    output wire                    s_axi_rvalid,
    input  wire                    s_axi_rready,

    // Abstract packet/TLP transmit interface.
    // tx_tlp_data[DATA_WIDTH-1:0] is beat 0, next slice is beat 1, etc.
    // tx_tlp_len is in AXI beats (not PCIe DWs).
    output reg                     tx_tlp_valid,
    input  wire                    tx_tlp_ready,
    output wire                    tx_tlp_type, // 0=MemWr, 1=MemRd
    output reg [ADDR_WIDTH-1:0]     tx_tlp_addr,
    output reg [7:0]                tx_tlp_len,
    output reg [7:0]                tx_tlp_tag,
    output wire [DATA_WIDTH*MAX_BEATS-1:0] tx_tlp_data,

    // Abstract completion interface: one completion contains the entire
    // coalesced read burst. Beat 0 occupies the least-significant slice.
    input  wire                     rx_cpl_valid,
    output wire                     rx_cpl_ready,
    input  wire [7:0]               rx_cpl_tag,
    input  wire [DATA_WIDTH*MAX_BEATS-1:0] rx_cpl_data,
    input  wire [1:0]                rx_cpl_status
);

    localparam [1:0] AXI_OKAY   = 2'b00;
    localparam [1:0] AXI_SLVERR = 2'b10;
    localparam [1:0] BURST_INCR = 2'b01;
    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer AXI_SIZE = $clog2(DATA_BYTES);
    localparam integer W_PTR_W = (W_FIFO_DEPTH <= 2) ? 1 : $clog2(W_FIFO_DEPTH);
    localparam integer W_CNT_W = $clog2(W_FIFO_DEPTH + 1);
    localparam integer TAG_IDX_W = (TAG_COUNT <= 2) ? 1 : $clog2(TAG_COUNT);
    localparam integer TAG_CNT_W = $clog2(TAG_COUNT + 1);
    localparam integer BEAT_IDX_W = (MAX_BEATS <= 2) ? 1 : $clog2(MAX_BEATS);
    // Explicitly sized copies of the integer parameters keep every compare
    // width-exact (Verilator -Wall clean).
    localparam integer W_LAST_I   = W_FIFO_DEPTH - 1;
    localparam integer TAG_LAST_I = TAG_COUNT - 1;
    localparam [W_CNT_W-1:0]   W_DEPTH_C   = W_FIFO_DEPTH[W_CNT_W-1:0];
    localparam [W_PTR_W-1:0]   W_LAST_C    = W_LAST_I[W_PTR_W-1:0];
    localparam [TAG_CNT_W-1:0] TAG_COUNT_C = TAG_COUNT[TAG_CNT_W-1:0];
    localparam [TAG_IDX_W-1:0] TAG_LAST_C  = TAG_LAST_I[TAG_IDX_W-1:0];
    localparam [8:0]           TAG_COUNT_9 = TAG_COUNT[8:0];
    localparam [8:0]           MAX_BEATS_9 = MAX_BEATS[8:0];
    localparam [15:0]          PAGE_BYTES  = 16'd4096;

    // ---------------- Write-data FIFO ----------------
    // Only "all strobes set" is stored; partial strobes are an error anyway.
    reg [DATA_WIDTH-1:0] w_fifo_data [0:W_FIFO_DEPTH-1];
    reg w_fifo_strb_ok [0:W_FIFO_DEPTH-1];
    reg w_fifo_last [0:W_FIFO_DEPTH-1];
    reg [W_PTR_W-1:0] w_wr_ptr, w_rd_ptr;
    reg [W_CNT_W-1:0] w_count;

    wire w_push = s_axi_wvalid && s_axi_wready;
    wire w_pop;

    // AXI4 bursts must be naturally aligned and must not cross a 4-KiB
    // boundary. The implementation intentionally supports full-width beats.
    // These checks are applied at address acceptance; invalid reads are
    // completed locally with SLVERR and invalid writes are drained then
    // completed locally with SLVERR, without issuing a TLP.
    // Full-width alignment = low AXI_SIZE address bits are zero
    // (DATA_WIDTH >= 16, so AXI_SIZE >= 1).
    wire aw_misaligned = |s_axi_awaddr[AXI_SIZE-1:0];
    wire ar_misaligned = |s_axi_araddr[AXI_SIZE-1:0];
    // Burst span in bytes = (len + 1) << AXI_SIZE; 16 bits covers 256 beats
    // of up to 128 bytes. Requires ADDR_WIDTH >= 12.
    wire [15:0] aw_span = ({8'd0, s_axi_awlen} + 16'd1) << AXI_SIZE;
    wire [15:0] ar_span = ({8'd0, s_axi_arlen} + 16'd1) << AXI_SIZE;
    wire aw_crosses_4k = (({4'd0, s_axi_awaddr[11:0]} + aw_span) > PAGE_BYTES);
    wire ar_crosses_4k = (({4'd0, s_axi_araddr[11:0]} + ar_span) > PAGE_BYTES);
    wire [8:0] aw_beats = {1'b0, s_axi_awlen} + 9'd1;
    wire [8:0] ar_beats = {1'b0, s_axi_arlen} + 9'd1;
    assign s_axi_wready = (w_count < W_DEPTH_C);

    always @(posedge clk) begin
        if (w_push) begin
            w_fifo_data[w_wr_ptr] <= s_axi_wdata;
            w_fifo_strb_ok[w_wr_ptr] <= &s_axi_wstrb;
            w_fifo_last[w_wr_ptr] <= s_axi_wlast;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_wr_ptr <= 0;
            w_rd_ptr <= 0;
            w_count  <= 0;
        end else begin
            if (w_push)
                w_wr_ptr <= (w_wr_ptr == W_LAST_C) ? 0 : w_wr_ptr + 1'b1;
            if (w_pop)
                w_rd_ptr <= (w_rd_ptr == W_LAST_C) ? 0 : w_rd_ptr + 1'b1;
            case ({w_push, w_pop})
                2'b10: w_count <= w_count + 1'b1;
                2'b01: w_count <= w_count - 1'b1;
                default: w_count <= w_count;
            endcase
        end
    end

    // ---------------- Write burst collector ----------------
    // wr_busy covers AW acceptance through downstream acceptance of the write
    // TLP (or local SLVERR). wr_id/wr_addr/wr_last_beat/wr_packet_data stay
    // stable for that whole window and directly source the TX packet.
    reg wr_busy, wr_collecting, wr_packet_pending;
    reg [AXI_ID_WIDTH-1:0] wr_id;
    reg [ADDR_WIDTH-1:0] wr_addr;
    reg [7:0] wr_last_beat;   // AWLEN: index of the final beat
    reg [8:0] wr_collected;
    reg w_final;              // registered: next popped beat is the final one
    reg wr_error;             // includes oversize, flagged at AW acceptance
    reg [DATA_WIDTH*MAX_BEATS-1:0] wr_packet_data;

    assign s_axi_awready = !wr_busy;

    // Phase 4 timing fix: w_final used to be a subtract-and-compare on the
    // w_pop -> wr_packet_data write-enable path (ABC critical path). It is now
    // a flop, so w_pop is a shallow AND of registered state.
    wire w_bad_strb = !w_fifo_strb_ok[w_rd_ptr];
    wire w_bad_last = (w_fifo_last[w_rd_ptr] != w_final);
    // The final beat produces a B response (directly on error, or after the
    // TLP is accepted), so it waits until the single B slot is free.
    assign w_pop = wr_collecting && (w_count != 0) && !(w_final && s_axi_bvalid);
    wire wr_burst_bad = wr_error || w_bad_strb || w_bad_last;

    // ---------------- Multiple-outstanding read tracking ----------------
    reg tag_valid [0:TAG_COUNT-1];
    reg tag_pending_tx [0:TAG_COUNT-1];
    reg tag_sent [0:TAG_COUNT-1];
    reg tag_done [0:TAG_COUNT-1];
    reg [AXI_ID_WIDTH-1:0] tag_axi_id [0:TAG_COUNT-1];
    reg [ADDR_WIDTH-1:0] tag_addr [0:TAG_COUNT-1];
    reg [7:0] tag_beats [0:TAG_COUNT-1];
    reg [DATA_WIDTH*MAX_BEATS-1:0] tag_data [0:TAG_COUNT-1];
    reg [1:0] tag_status [0:TAG_COUNT-1];

    reg [TAG_IDX_W-1:0] resp_q [0:TAG_COUNT-1];
    reg [TAG_IDX_W-1:0] resp_wr_ptr, resp_rd_ptr;
    reg [TAG_CNT_W-1:0] resp_count;
    reg [BEAT_IDX_W-1:0] r_beat;

    integer i;
    reg free_found;
    reg [TAG_IDX_W-1:0] free_tag;
    always @* begin
        free_found = 1'b0;
        free_tag = 0;
        for (integer k = 0; k < TAG_COUNT; k = k + 1) begin
            if (!free_found && !tag_valid[k]) begin
                free_found = 1'b1;
                free_tag = k[TAG_IDX_W-1:0];
            end
        end
    end
    assign s_axi_arready = free_found && (resp_count < TAG_COUNT_C);
    // Out-of-range tags are rejected before the truncated index is used.
    wire cpl_tag_in_range = ({1'b0, rx_cpl_tag} < TAG_COUNT_9);
    wire [TAG_IDX_W-1:0] cpl_idx = rx_cpl_tag[TAG_IDX_W-1:0];
    assign rx_cpl_ready = cpl_tag_in_range &&
                          tag_valid[cpl_idx] &&
                          tag_sent[cpl_idx] &&
                          !tag_done[cpl_idx];

    wire ar_bad = (s_axi_arsize != AXI_SIZE[2:0]) ||
                  (s_axi_arburst != BURST_INCR) ||
                  (ar_beats > MAX_BEATS_9) ||
                  ar_misaligned || ar_crosses_4k;

    // A completed tag that was never sent downstream is a local SLVERR and
    // returns zero data without touching tag_data.
    wire [TAG_IDX_W-1:0] r_head_tag = resp_q[resp_rd_ptr];
    wire r_head_valid = (resp_count != 0) && tag_done[r_head_tag];
    wire r_head_local = !tag_sent[r_head_tag];
    assign s_axi_rvalid = r_head_valid;
    assign s_axi_rid = r_head_valid ? tag_axi_id[r_head_tag] : {AXI_ID_WIDTH{1'b0}};
    assign s_axi_rdata = (r_head_valid && !r_head_local) ?
        tag_data[r_head_tag][r_beat*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
    assign s_axi_rresp = r_head_valid ? tag_status[r_head_tag] : AXI_OKAY;
    assign s_axi_rlast = r_head_valid &&
        ({{(8-BEAT_IDX_W){1'b0}}, r_beat} == (tag_beats[r_head_tag] - 8'd1));

    // ---------------- TX arbitration ----------------
    // Writes have priority. A write is launched only while the B slot is
    // free, so its downstream acceptance can always post the B response.
    // Reads are not blocked by a stalled B channel.
    reg tx_is_write;
    reg read_pick_found;
    reg [TAG_IDX_W-1:0] read_pick_tag;
    always @* begin
        read_pick_found = 1'b0;
        read_pick_tag = 0;
        for (integer m = 0; m < TAG_COUNT; m = m + 1) begin
            if (!read_pick_found && tag_pending_tx[m]) begin
                read_pick_found = 1'b1;
                read_pick_tag = m[TAG_IDX_W-1:0];
            end
        end
    end

    wire aw_fire  = s_axi_awvalid && s_axi_awready;
    wire ar_fire  = s_axi_arvalid && s_axi_arready;
    wire cpl_fire = rx_cpl_valid && rx_cpl_ready;
    wire r_fire   = s_axi_rvalid && s_axi_rready;
    wire tx_fire  = tx_tlp_valid && tx_tlp_ready;
    wire tx_slot_free = !tx_tlp_valid || tx_tlp_ready;
    wire launch_wr = tx_slot_free && wr_packet_pending && !s_axi_bvalid;
    wire launch_rd = tx_slot_free && !launch_wr && read_pick_found;

    assign tx_tlp_type = !tx_is_write;
    assign tx_tlp_data = tx_is_write ? wr_packet_data : {DATA_WIDTH*MAX_BEATS{1'b0}};

    // ---------------- Datapath registers (no reset) ----------------
    // Every register here is written before any VALID output can expose it.
    always @(posedge clk) begin
        if (aw_fire) begin
            wr_id <= s_axi_awid;
            wr_addr <= s_axi_awaddr;
            wr_last_beat <= s_axi_awlen;
            wr_packet_data <= 0;
        end
        if (w_pop && (wr_collected < MAX_BEATS_9))
            wr_packet_data[wr_collected*DATA_WIDTH +: DATA_WIDTH] <= w_fifo_data[w_rd_ptr];

        if (ar_fire) begin
            tag_axi_id[free_tag] <= s_axi_arid;
            tag_addr[free_tag] <= s_axi_araddr;
            tag_beats[free_tag] <= ar_bad ? 8'd1 : s_axi_arlen + 1'b1;
            tag_status[free_tag] <= ar_bad ? AXI_SLVERR : AXI_OKAY;
            resp_q[resp_wr_ptr] <= free_tag;
        end
        if (cpl_fire) begin
            tag_data[cpl_idx] <= rx_cpl_data;
            tag_status[cpl_idx] <= (rx_cpl_status == 2'b00) ? AXI_OKAY : AXI_SLVERR;
        end

        if (launch_wr) begin
            tx_tlp_addr <= wr_addr;
            tx_tlp_len <= wr_last_beat + 8'd1;
            tx_tlp_tag <= 0;
        end else if (launch_rd) begin
            tx_tlp_addr <= tag_addr[read_pick_tag];
            tx_tlp_len <= tag_beats[read_pick_tag];
            tx_tlp_tag <= {{(8-TAG_IDX_W){1'b0}}, read_pick_tag};
        end
    end

    // ---------------- Control registers (asynchronous reset) ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_busy <= 0;
            wr_collecting <= 0;
            wr_packet_pending <= 0;
            wr_collected <= 0;
            w_final <= 0;
            wr_error <= 0;
            s_axi_bid <= 0;
            s_axi_bresp <= AXI_OKAY;
            s_axi_bvalid <= 0;
            tx_tlp_valid <= 0;
            tx_is_write <= 0;
            resp_wr_ptr <= 0;
            resp_rd_ptr <= 0;
            resp_count <= 0;
            r_beat <= 0;
            for (i = 0; i < TAG_COUNT; i = i + 1) begin
                tag_valid[i] <= 0;
                tag_pending_tx[i] <= 0;
                tag_sent[i] <= 0;
                tag_done[i] <= 0;
            end
        end else begin
            // Accept write address. W beats can already be buffered.
            if (aw_fire) begin
                wr_busy <= 1;
                wr_collecting <= 1;
                wr_collected <= 0;
                w_final <= (s_axi_awlen == 8'd0);
                wr_error <= (s_axi_awsize != AXI_SIZE[2:0]) ||
                            (s_axi_awburst != BURST_INCR) ||
                            (aw_beats > MAX_BEATS_9) ||
                            aw_misaligned || aw_crosses_4k;
            end

            // Collect one beat per cycle from the W FIFO.
            if (w_pop) begin
                if (w_bad_strb || w_bad_last)
                    wr_error <= 1'b1;
                if (w_final) begin
                    wr_collecting <= 0;
                    if (wr_burst_bad) begin
                        s_axi_bid <= wr_id;
                        s_axi_bresp <= AXI_SLVERR;
                        s_axi_bvalid <= 1;
                        wr_busy <= 0;
                    end else begin
                        wr_packet_pending <= 1;
                    end
                end
                wr_collected <= wr_collected + 1'b1;
                w_final <= (wr_collected[7:0] + 8'd1 == wr_last_beat) && !wr_collected[8];
            end

            // Accept read address and allocate a tag/response-order slot.
            if (ar_fire) begin
                tag_valid[free_tag] <= 1;
                resp_wr_ptr <= (resp_wr_ptr == TAG_LAST_C) ? 0 : resp_wr_ptr + 1'b1;
                // Local error policy: malformed read returns one SLVERR beat.
                tag_done[free_tag] <= ar_bad;
                tag_sent[free_tag] <= 0;
                tag_pending_tx[free_tag] <= !ar_bad;
            end

            // Accept matching completion only after the corresponding request
            // has been accepted by the downstream TX interface.
            if (cpl_fire)
                tag_done[cpl_idx] <= 1;

            // Consume AXI R beats. Responses are deliberately ordered by AR order.
            if (r_fire) begin
                if (s_axi_rlast) begin
                    tag_valid[r_head_tag] <= 0;
                    tag_pending_tx[r_head_tag] <= 0;
                    tag_sent[r_head_tag] <= 0;
                    tag_done[r_head_tag] <= 0;
                    resp_rd_ptr <= (resp_rd_ptr == TAG_LAST_C) ? 0 : resp_rd_ptr + 1'b1;
                    r_beat <= 0;
                end else begin
                    r_beat <= r_beat + 1'b1;
                end
            end

            // TX output remains registered and stable while READY is low.
            if (tx_fire) begin
                tx_tlp_valid <= 0;
                if (tx_is_write) begin
                    s_axi_bid <= wr_id;
                    s_axi_bresp <= AXI_OKAY;
                    s_axi_bvalid <= 1;
                    wr_busy <= 0;
                end else begin
                    tag_sent[tx_tlp_tag[TAG_IDX_W-1:0]] <= 1;
                end
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 0;

            // Launch a new TX packet only when the current packet has retired.
            if (launch_wr) begin
                tx_tlp_valid <= 1;
                tx_is_write <= 1;
                wr_packet_pending <= 0;
            end else if (launch_rd) begin
                tx_tlp_valid <= 1;
                tx_is_write <= 0;
                tag_pending_tx[read_pick_tag] <= 0;
            end

            // Update response queue occupancy for simultaneous AR acceptance
            // and final R beat consumption.
            case ({ar_fire, (r_fire && s_axi_rlast)})
                2'b10: resp_count <= resp_count + 1'b1;
                2'b01: resp_count <= resp_count - 1'b1;
                default: resp_count <= resp_count;
            endcase
        end
    end

endmodule
