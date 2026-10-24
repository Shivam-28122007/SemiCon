`timescale 1ns/1ps
// SARCathon 2026 Phase 2 educational reference implementation.
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
module sarcathon_axi_pcie_bridge #(
    parameter integer DATA_WIDTH   = 64,
    parameter integer ADDR_WIDTH   = 32,
    parameter integer AXI_ID_WIDTH = 4,
    parameter integer MAX_BEATS    = 4,
    parameter integer TAG_COUNT    = 4,
    parameter integer W_FIFO_DEPTH = 16
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
    output reg                     tx_tlp_type, // 0=MemWr, 1=MemRd
    output reg [ADDR_WIDTH-1:0]     tx_tlp_addr,
    output reg [7:0]                tx_tlp_len,
    output reg [7:0]                tx_tlp_tag,
    output reg [DATA_WIDTH*MAX_BEATS-1:0] tx_tlp_data,

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

    // ---------------- Write-data FIFO ----------------
    reg [DATA_WIDTH-1:0] w_fifo_data [0:W_FIFO_DEPTH-1];
    reg [DATA_WIDTH/8-1:0] w_fifo_strb [0:W_FIFO_DEPTH-1];
    reg w_fifo_last [0:W_FIFO_DEPTH-1];
    reg [W_PTR_W-1:0] w_wr_ptr, w_rd_ptr;
    reg [W_CNT_W-1:0] w_count;

    reg wr_busy, wr_collecting, wr_packet_pending;
    wire w_push = s_axi_wvalid && s_axi_wready;
    wire w_pop;

    // AXI4 bursts must be naturally aligned and must not cross a 4-KiB
    // boundary. The implementation intentionally supports full-width beats.
    // These checks are applied at address acceptance; invalid reads are
    // completed locally with SLVERR and invalid writes are drained then
    // completed locally with SLVERR, without issuing a TLP.
    wire aw_misaligned = ((s_axi_awaddr % DATA_BYTES) != 0);
    wire ar_misaligned = ((s_axi_araddr % DATA_BYTES) != 0);
    wire aw_crosses_4k = (((s_axi_awaddr % 4096) +
                           (({1'b0, s_axi_awlen} + 9'd1) * DATA_BYTES)) > 4096);
    wire ar_crosses_4k = (((s_axi_araddr % 4096) +
                           (({1'b0, s_axi_arlen} + 9'd1) * DATA_BYTES)) > 4096);
    assign s_axi_wready = (w_count < W_FIFO_DEPTH);
    assign w_pop = wr_collecting && (w_count != 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_wr_ptr <= 0;
            w_rd_ptr <= 0;
            w_count  <= 0;
        end else begin
            if (w_push) begin
                w_fifo_data[w_wr_ptr] <= s_axi_wdata;
                w_fifo_strb[w_wr_ptr] <= s_axi_wstrb;
                w_fifo_last[w_wr_ptr] <= s_axi_wlast;
                w_wr_ptr <= (w_wr_ptr == W_FIFO_DEPTH-1) ? 0 : w_wr_ptr + 1'b1;
            end
            if (w_pop)
                w_rd_ptr <= (w_rd_ptr == W_FIFO_DEPTH-1) ? 0 : w_rd_ptr + 1'b1;
            case ({w_push, w_pop})
                2'b10: w_count <= w_count + 1'b1;
                2'b01: w_count <= w_count - 1'b1;
                default: w_count <= w_count;
            endcase
        end
    end

    // ---------------- Write burst collector ----------------
    reg [AXI_ID_WIDTH-1:0] wr_id;
    reg [ADDR_WIDTH-1:0] wr_addr;
    reg [8:0] wr_total_beats;
    reg [8:0] wr_collected;
    reg wr_error;
    reg [DATA_WIDTH*MAX_BEATS-1:0] wr_packet_data;
    reg [7:0] wr_packet_len;
    reg [ADDR_WIDTH-1:0] wr_packet_addr;
    reg [AXI_ID_WIDTH-1:0] wr_packet_id;

    assign s_axi_awready = !wr_busy;

    wire w_bad_strb = (w_fifo_strb[w_rd_ptr] != {DATA_WIDTH/8{1'b1}});
    wire w_bad_last = (w_fifo_last[w_rd_ptr] != (wr_collected == (wr_total_beats - 1'b1)));

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

    reg [7:0] resp_q [0:TAG_COUNT-1];
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
    assign s_axi_arready = free_found && (resp_count < TAG_COUNT);
    assign rx_cpl_ready = (rx_cpl_tag < TAG_COUNT) &&
                          tag_valid[rx_cpl_tag] &&
                          tag_sent[rx_cpl_tag] &&
                          !tag_done[rx_cpl_tag];

    wire r_head_valid = (resp_count != 0) && tag_done[resp_q[resp_rd_ptr]];
    wire [7:0] r_head_tag = resp_q[resp_rd_ptr];
    assign s_axi_rvalid = r_head_valid;
    assign s_axi_rid = r_head_valid ? tag_axi_id[r_head_tag] : {AXI_ID_WIDTH{1'b0}};
    assign s_axi_rdata = r_head_valid ?
        tag_data[r_head_tag][r_beat*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
    assign s_axi_rresp = r_head_valid ? tag_status[r_head_tag] : AXI_OKAY;
    assign s_axi_rlast = r_head_valid && (r_beat == (tag_beats[r_head_tag] - 1'b1));

    // ---------------- TX arbitration ----------------
    // Writes have priority. Read requests are selected from pending tags.
    reg tx_is_write;
    reg [7:0] tx_active_tag;
    reg read_pick_found;
    reg [TAG_IDX_W-1:0] read_pick_tag;
    integer j;
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

    // ---------------- Sequential control ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_busy <= 0;
            wr_collecting <= 0;
            wr_packet_pending <= 0;
            wr_id <= 0;
            wr_addr <= 0;
            wr_total_beats <= 0;
            wr_collected <= 0;
            wr_error <= 0;
            wr_packet_data <= 0;
            wr_packet_len <= 0;
            wr_packet_addr <= 0;
            wr_packet_id <= 0;
            s_axi_bid <= 0;
            s_axi_bresp <= AXI_OKAY;
            s_axi_bvalid <= 0;
            tx_tlp_valid <= 0;
            tx_tlp_type <= 0;
            tx_tlp_addr <= 0;
            tx_tlp_len <= 0;
            tx_tlp_tag <= 0;
            tx_tlp_data <= 0;
            tx_is_write <= 0;
            tx_active_tag <= 0;
            resp_wr_ptr <= 0;
            resp_rd_ptr <= 0;
            resp_count <= 0;
            r_beat <= 0;
            for (i = 0; i < TAG_COUNT; i = i + 1) begin
                tag_valid[i] <= 0;
                tag_pending_tx[i] <= 0;
                tag_sent[i] <= 0;
                tag_done[i] <= 0;
                tag_axi_id[i] <= 0;
                tag_addr[i] <= 0;
                tag_beats[i] <= 1;
                tag_data[i] <= 0;
                tag_status[i] <= AXI_OKAY;
                resp_q[i] <= 0;
            end
        end else begin
            // Accept write address. W beats can already be buffered.
            if (s_axi_awvalid && s_axi_awready) begin
                wr_busy <= 1;
                wr_collecting <= 1;
                wr_packet_pending <= 0;
                wr_id <= s_axi_awid;
                wr_addr <= s_axi_awaddr;
                wr_total_beats <= {1'b0, s_axi_awlen} + 1'b1;
                wr_collected <= 0;
                wr_packet_data <= 0;
                wr_error <= (s_axi_awsize != AXI_SIZE[2:0]) ||
                            (s_axi_awburst != BURST_INCR) ||
                            (({1'b0, s_axi_awlen} + 1'b1) > MAX_BEATS) ||
                            aw_misaligned || aw_crosses_4k;
            end

            // Collect one beat per cycle from the W FIFO.
            if (w_pop) begin
                if (wr_collected < MAX_BEATS)
                    wr_packet_data[wr_collected*DATA_WIDTH +: DATA_WIDTH] <= w_fifo_data[w_rd_ptr];
                if (w_bad_strb || w_bad_last)
                    wr_error <= 1'b1;
                if (wr_collected == (wr_total_beats - 1'b1)) begin
                    wr_collecting <= 0;
                    wr_packet_len <= wr_total_beats[7:0];
                    wr_packet_addr <= wr_addr;
                    wr_packet_id <= wr_id;
                    if (wr_error || w_bad_strb || w_bad_last ||
                        (wr_total_beats > MAX_BEATS)) begin
                        s_axi_bid <= wr_id;
                        s_axi_bresp <= AXI_SLVERR;
                        s_axi_bvalid <= 1;
                    end else begin
                        wr_packet_pending <= 1;
                    end
                end
                wr_collected <= wr_collected + 1'b1;
            end

            // Accept read address and allocate a tag/response-order slot.
            if (s_axi_arvalid && s_axi_arready) begin
                tag_valid[free_tag] <= 1;
                tag_axi_id[free_tag] <= s_axi_arid;
                tag_addr[free_tag] <= s_axi_araddr;
                resp_q[resp_wr_ptr] <= { {(8-TAG_IDX_W){1'b0}}, free_tag };
                resp_wr_ptr <= (resp_wr_ptr == TAG_COUNT-1) ? 0 : resp_wr_ptr + 1'b1;
                if ((s_axi_arsize != AXI_SIZE[2:0]) ||
                    (s_axi_arburst != BURST_INCR) ||
                    (({1'b0, s_axi_arlen} + 1'b1) > MAX_BEATS) ||
                    ar_misaligned || ar_crosses_4k) begin
                    // Local error policy: malformed read returns one SLVERR beat.
                    tag_beats[free_tag] <= 1;
                    tag_data[free_tag] <= 0;
                    tag_status[free_tag] <= AXI_SLVERR;
                    tag_done[free_tag] <= 1;
                    tag_sent[free_tag] <= 0;
                    tag_pending_tx[free_tag] <= 0;
                end else begin
                    tag_beats[free_tag] <= s_axi_arlen + 1'b1;
                    tag_status[free_tag] <= AXI_OKAY;
                    tag_done[free_tag] <= 0;
                    tag_sent[free_tag] <= 0;
                    tag_pending_tx[free_tag] <= 1;
                end
            end

            // Accept matching completion only after the corresponding request
            // has been accepted by the downstream TX interface.
            if (rx_cpl_valid && rx_cpl_ready) begin
                tag_data[rx_cpl_tag] <= rx_cpl_data;
                tag_status[rx_cpl_tag] <= (rx_cpl_status == 2'b00) ? AXI_OKAY : AXI_SLVERR;
                tag_done[rx_cpl_tag] <= 1;
            end

            // Consume AXI R beats. Responses are deliberately ordered by AR order.
            if (s_axi_rvalid && s_axi_rready) begin
                if (s_axi_rlast) begin
                    tag_valid[r_head_tag] <= 0;
                    tag_pending_tx[r_head_tag] <= 0;
                    tag_sent[r_head_tag] <= 0;
                    tag_done[r_head_tag] <= 0;
                    resp_rd_ptr <= (resp_rd_ptr == TAG_COUNT-1) ? 0 : resp_rd_ptr + 1'b1;
                    r_beat <= 0;
                end else begin
                    r_beat <= r_beat + 1'b1;
                end
            end

            // TX output remains registered and stable while READY is low.
            if (tx_tlp_valid && tx_tlp_ready) begin
                tx_tlp_valid <= 0;
                if (tx_is_write) begin
                    s_axi_bid <= wr_packet_id;
                    s_axi_bresp <= AXI_OKAY;
                    s_axi_bvalid <= 1;
                end else begin
                    tag_sent[tx_active_tag] <= 1;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 0;
                wr_busy <= 0;
            end

            // Launch a new TX packet only when the current packet has retired.
            if (!tx_tlp_valid || (tx_tlp_valid && tx_tlp_ready)) begin
                if (wr_packet_pending) begin
                    tx_tlp_valid <= 1;
                    tx_tlp_type <= 1'b0;
                    tx_tlp_addr <= wr_packet_addr;
                    tx_tlp_len <= wr_packet_len;
                    tx_tlp_tag <= 0;
                    tx_tlp_data <= wr_packet_data;
                    tx_is_write <= 1;
                    tx_active_tag <= 0;
                    wr_packet_pending <= 0;
                end else if (read_pick_found) begin
                    tx_tlp_valid <= 1;
                    tx_tlp_type <= 1'b1;
                    tx_tlp_addr <= tag_addr[read_pick_tag];
                    tx_tlp_len <= tag_beats[read_pick_tag];
                    tx_tlp_tag <= {{(8-TAG_IDX_W){1'b0}}, read_pick_tag};
                    tx_tlp_data <= 0;
                    tx_is_write <= 0;
                    tx_active_tag <= {{(8-TAG_IDX_W){1'b0}}, read_pick_tag};
                    tag_pending_tx[read_pick_tag] <= 0;
                end
            end

            // Update response queue occupancy for simultaneous AR acceptance
            // and final R beat consumption.
            case ({(s_axi_arvalid && s_axi_arready),
                   (s_axi_rvalid && s_axi_rready && s_axi_rlast)})
                2'b10: resp_count <= resp_count + 1'b1;
                2'b01: resp_count <= resp_count - 1'b1;
                default: resp_count <= resp_count;
            endcase
        end
    end

endmodule
