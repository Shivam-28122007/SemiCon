`timescale 1ns/1ps

// ============================================================================
// SARCATHON 2026 - Stage 1 RTL Prototype
// Simplified AXI4 Slave -> PCIe TLP Bridge
//
// Scope:
//   * 64-bit AXI4 data path by default
//   * One outstanding AXI transaction at a time
//   * AXI INCR/FIXED bursts are converted to one PCIe TLP per AXI beat
//   * Full-byte-write strobes only; partial WSTRB is returned as SLVERR
//   * PCIe MemWr / MemRd request abstraction
//   * PCIe Completion with Data -> AXI R channel
//   * PCIe completion status -> AXI RRESP
//   * No claim of complete PCIe 6.0 PHY/link implementation
//
// The external PCIe interface is an abstract TLP interface intended for
// Stage-1 RTL verification. It is not a physical PCIe PIPE/PHY interface.
// ============================================================================

module axi4_to_pcie_bridge #(
    parameter integer DATA_WIDTH = 64,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH   = 4
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ------------------------- AXI4 Slave -------------------------------
    input  wire [ID_WIDTH-1:0]        s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]      s_axi_awaddr,
    input  wire [7:0]                 s_axi_awlen,
    input  wire [2:0]                 s_axi_awsize,
    input  wire [1:0]                 s_axi_awburst,
    input  wire                       s_axi_awvalid,
    output reg                        s_axi_awready,

    input  wire [DATA_WIDTH-1:0]      s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0]  s_axi_wstrb,
    input  wire                       s_axi_wlast,
    input  wire                       s_axi_wvalid,
    output reg                        s_axi_wready,

    output reg  [ID_WIDTH-1:0]        s_axi_bid,
    output reg  [1:0]                 s_axi_bresp,
    output reg                        s_axi_bvalid,
    input  wire                       s_axi_bready,

    input  wire [ID_WIDTH-1:0]        s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]      s_axi_araddr,
    input  wire [7:0]                 s_axi_arlen,
    input  wire [2:0]                 s_axi_arsize,
    input  wire [1:0]                 s_axi_arburst,
    input  wire                       s_axi_arvalid,
    output reg                        s_axi_arready,

    output reg  [ID_WIDTH-1:0]        s_axi_rid,
    output reg  [DATA_WIDTH-1:0]      s_axi_rdata,
    output reg  [1:0]                 s_axi_rresp,
    output reg                        s_axi_rlast,
    output reg                        s_axi_rvalid,
    input  wire                       s_axi_rready,

    // --------------------- Abstract PCIe TX TLP --------------------------
    output reg                        tx_tlp_valid,
    input  wire                       tx_tlp_ready,
    output reg  [4:0]                 tx_tlp_type,
    output reg  [ADDR_WIDTH-1:0]      tx_tlp_addr,
    output reg  [9:0]                 tx_tlp_length,
    output reg  [7:0]                 tx_tlp_tag,
    output reg  [DATA_WIDTH-1:0]      tx_tlp_data,
    output reg                        tx_tlp_sop,
    output reg                        tx_tlp_eop,

    // --------------------- Abstract PCIe RX CplD -------------------------
    input  wire                       rx_cpl_valid,
    output reg                        rx_cpl_ready,
    input  wire [7:0]                 rx_cpl_tag,
    input  wire [DATA_WIDTH-1:0]      rx_cpl_data,
    input  wire [1:0]                 rx_cpl_status,
    input  wire                       rx_cpl_eop
);

    localparam [4:0] TLP_MEM_WR = 5'b00000;
    localparam [4:0] TLP_MEM_RD = 5'b00001;

    localparam [1:0] AXI_OKAY   = 2'b00;
    localparam [1:0] AXI_SLVERR = 2'b10;

    localparam [1:0] AXI_BURST_FIXED = 2'b00;
    localparam [1:0] AXI_BURST_INCR  = 2'b01;

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer DATA_DW    = DATA_WIDTH / 32;
    localparam [2:0]  AXI_SIZE    = $clog2(DATA_BYTES);

    // One outstanding transaction. Write and read channels are mutually
    // exclusive while a transaction is active.
    localparam [3:0]
        ST_IDLE       = 4'd0,
        ST_WR_TX      = 4'd1,
        ST_WR_RESP    = 4'd2,
        ST_RD_TX      = 4'd3,
        ST_RD_CPL     = 4'd4,
        ST_RD_RESP    = 4'd5;

    reg [3:0] state;

    // AXI write holding registers. AW and W may arrive independently.
    reg                         aw_hold;
    reg                         w_hold;
    reg [ID_WIDTH-1:0]          wr_id;
    reg [ADDR_WIDTH-1:0]        wr_addr;
    reg [7:0]                   wr_beats_left;
    reg [1:0]                   wr_burst;
    reg [2:0]                   wr_size;
    reg [DATA_WIDTH-1:0]        wr_data;
    reg [(DATA_WIDTH/8)-1:0]    wr_strb;
    reg                         wr_last;

    // AXI read transaction registers.
    reg [ID_WIDTH-1:0]          rd_id;
    reg [ADDR_WIDTH-1:0]        rd_addr;
    reg [7:0]                   rd_beats_left;
    reg [1:0]                   rd_burst;
    reg [2:0]                   rd_size;

    // ---------------------------------------------------------------------
    // Ready signals are combinational so they are available before the
    // corresponding AXI handshake edge.
    // ---------------------------------------------------------------------
    always @* begin
        s_axi_awready = 1'b0;
        s_axi_wready  = 1'b0;
        s_axi_arready = 1'b0;
        rx_cpl_ready  = 1'b0;

        if (state == ST_IDLE) begin
            // AW and W are independently buffered. This supports legal AXI
            // cases where AW and W do not arrive in the same cycle.
            s_axi_awready = !aw_hold;
            s_axi_wready  = !w_hold;

            // Write traffic has priority if a write is already pending or
            // presented in this cycle.
            if (!aw_hold && !w_hold && !s_axi_awvalid && !s_axi_wvalid &&
                s_axi_arvalid) begin
                s_axi_arready = 1'b1;
            end
        end

        // A completion is accepted only for the currently outstanding read
        // tag. This prevents an unrelated/stale completion from being
        // consumed by the AXI R channel.
        if ((state == ST_RD_CPL) &&
            (rx_cpl_tag == {{(8-ID_WIDTH){1'b0}}, rd_id})) begin
            rx_cpl_ready = 1'b1;
        end
    end

    // ---------------------------------------------------------------------
    // Main bridge FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            aw_hold        <= 1'b0;
            w_hold         <= 1'b0;

            wr_id          <= {ID_WIDTH{1'b0}};
            wr_addr        <= {ADDR_WIDTH{1'b0}};
            wr_beats_left  <= 8'd0;
            wr_burst       <= AXI_BURST_INCR;
            wr_size        <= AXI_SIZE;
            wr_data        <= {DATA_WIDTH{1'b0}};
            wr_strb        <= {(DATA_WIDTH/8){1'b0}};
            wr_last        <= 1'b0;

            rd_id          <= {ID_WIDTH{1'b0}};
            rd_addr        <= {ADDR_WIDTH{1'b0}};
            rd_beats_left  <= 8'd0;
            rd_burst       <= AXI_BURST_INCR;
            rd_size        <= AXI_SIZE;

            s_axi_bvalid   <= 1'b0;
            s_axi_bid      <= {ID_WIDTH{1'b0}};
            s_axi_bresp    <= AXI_OKAY;

            s_axi_rvalid   <= 1'b0;
            s_axi_rid      <= {ID_WIDTH{1'b0}};
            s_axi_rdata    <= {DATA_WIDTH{1'b0}};
            s_axi_rresp    <= AXI_OKAY;
            s_axi_rlast    <= 1'b0;

            tx_tlp_valid   <= 1'b0;
            tx_tlp_type    <= 5'd0;
            tx_tlp_addr    <= {ADDR_WIDTH{1'b0}};
            tx_tlp_length  <= 10'd0;
            tx_tlp_tag     <= 8'd0;
            tx_tlp_data    <= {DATA_WIDTH{1'b0}};
            tx_tlp_sop     <= 1'b0;
            tx_tlp_eop     <= 1'b0;
        end else begin
            case (state)

                // ---------------------------------------------------------
                // IDLE / AXI request capture
                // ---------------------------------------------------------
                ST_IDLE: begin
                    tx_tlp_valid <= 1'b0;
                    s_axi_bvalid <= 1'b0;

                    // Capture AW independently.
                    if (s_axi_awvalid && s_axi_awready) begin
                        aw_hold       <= 1'b1;
                        wr_id         <= s_axi_awid;
                        wr_addr       <= s_axi_awaddr;
                        wr_beats_left <= s_axi_awlen + 8'd1;
                        wr_burst      <= s_axi_awburst;
                        wr_size       <= s_axi_awsize;
                    end

                    // Capture W independently.
                    if (s_axi_wvalid && s_axi_wready) begin
                        w_hold <= 1'b1;
                        wr_data <= s_axi_wdata;
                        wr_strb <= s_axi_wstrb;
                        wr_last <= s_axi_wlast;
                    end

                    // Once both write channels have been captured, validate
                    // the transaction and prepare exactly one PCIe MemWr TLP
                    // for the current AXI beat.
                    if (aw_hold && w_hold) begin
                        if ((wr_size != AXI_SIZE) ||
                            ((wr_burst != AXI_BURST_FIXED) &&
                             (wr_burst != AXI_BURST_INCR)) ||
                            (wr_strb != {(DATA_WIDTH/8){1'b1}}) ||
                            (wr_last != (wr_beats_left == 8'd1))) begin

                            // Unsupported AXI attributes or malformed WLAST.
                            s_axi_bid    <= wr_id;
                            s_axi_bresp  <= AXI_SLVERR;
                            s_axi_bvalid <= 1'b1;
                            aw_hold      <= 1'b0;
                            w_hold       <= 1'b0;
                            state        <= ST_WR_RESP;
                        end else begin
                            tx_tlp_valid  <= 1'b1;
                            tx_tlp_type   <= TLP_MEM_WR;
                            tx_tlp_addr   <= wr_addr;
                            tx_tlp_length <= DATA_DW;
                            tx_tlp_tag    <= {{(8-ID_WIDTH){1'b0}}, wr_id};
                            tx_tlp_data   <= wr_data;
                            tx_tlp_sop    <= 1'b1;
                            tx_tlp_eop    <= 1'b1;
                            state         <= ST_WR_TX;
                        end
                    end
                    // Read can only be accepted when there is no pending
                    // write channel activity.
                    else if (s_axi_arvalid && s_axi_arready) begin
                        rd_id         <= s_axi_arid;
                        rd_addr       <= s_axi_araddr;
                        rd_beats_left <= s_axi_arlen + 8'd1;
                        rd_burst      <= s_axi_arburst;
                        rd_size       <= s_axi_arsize;

                        if ((s_axi_arsize != AXI_SIZE) ||
                            ((s_axi_arburst != AXI_BURST_FIXED) &&
                             (s_axi_arburst != AXI_BURST_INCR))) begin
                            // Invalid AXI read request: return SLVERR without
                            // generating a PCIe request.
                            s_axi_rid    <= s_axi_arid;
                            s_axi_rdata  <= {DATA_WIDTH{1'b0}};
                            s_axi_rresp  <= AXI_SLVERR;
                            s_axi_rlast  <= 1'b1;
                            s_axi_rvalid <= 1'b1;
                            state        <= ST_RD_RESP;
                        end else begin
                            tx_tlp_valid  <= 1'b1;
                            tx_tlp_type   <= TLP_MEM_RD;
                            tx_tlp_addr   <= s_axi_araddr;
                            tx_tlp_length <= DATA_DW;
                            tx_tlp_tag    <= {{(8-ID_WIDTH){1'b0}}, s_axi_arid};
                            tx_tlp_data   <= {DATA_WIDTH{1'b0}};
                            tx_tlp_sop    <= 1'b1;
                            tx_tlp_eop    <= 1'b1;
                            state         <= ST_RD_TX;
                        end
                    end
                end

                // ---------------------------------------------------------
                // PCIe Memory Write TLP: hold valid until ready.
                // ---------------------------------------------------------
                ST_WR_TX: begin
                    if (tx_tlp_valid && tx_tlp_ready) begin
                        tx_tlp_valid <= 1'b0;
                        w_hold       <= 1'b0;

                        if (wr_beats_left == 8'd1) begin
                            aw_hold      <= 1'b0;
                            s_axi_bid    <= wr_id;
                            s_axi_bresp  <= AXI_OKAY;
                            s_axi_bvalid <= 1'b1;
                            state        <= ST_WR_RESP;
                        end else begin
                            wr_beats_left <= wr_beats_left - 8'd1;
                            if (wr_burst == AXI_BURST_INCR)
                                wr_addr <= wr_addr + DATA_BYTES;
                            state <= ST_IDLE;
                        end
                    end
                end

                // ---------------------------------------------------------
                // AXI Write Response: hold until BREADY.
                // ---------------------------------------------------------
                ST_WR_RESP: begin
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // PCIe Memory Read TLP: hold valid until ready.
                // ---------------------------------------------------------
                ST_RD_TX: begin
                    if (tx_tlp_valid && tx_tlp_ready) begin
                        tx_tlp_valid <= 1'b0;
                        state        <= ST_RD_CPL;
                    end
                end

                // ---------------------------------------------------------
                // Wait for matching PCIe Completion with Data.
                // ---------------------------------------------------------
                ST_RD_CPL: begin
                    if (rx_cpl_valid && rx_cpl_ready) begin
                        s_axi_rid    <= rd_id;
                        s_axi_rdata  <= rx_cpl_data;
                        s_axi_rresp  <= (rx_cpl_status == 2'b00) ?
                                        AXI_OKAY : AXI_SLVERR;
                        s_axi_rlast  <= (rd_beats_left == 8'd1);

                        // In this Stage-1 abstraction each AXI beat maps to
                        // one CplD. Therefore EOP must match the expected
                        // AXI beat boundary.
                        if (rx_cpl_eop != (rd_beats_left == 8'd1))
                            s_axi_rresp <= AXI_SLVERR;

                        s_axi_rvalid <= 1'b1;
                        state        <= ST_RD_RESP;
                    end
                end

                // ---------------------------------------------------------
                // AXI R response: hold until RREADY. For bursts, issue the
                // next PCIe read only after the current AXI beat is consumed.
                // This intentionally keeps one outstanding read at a time.
                // ---------------------------------------------------------
                ST_RD_RESP: begin
                    if (s_axi_rvalid && s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;

                        if ((rd_beats_left > 8'd1) &&
                            (s_axi_rresp == AXI_OKAY)) begin
                            rd_beats_left <= rd_beats_left - 8'd1;

                            if (rd_burst == AXI_BURST_INCR)
                                rd_addr <= rd_addr + DATA_BYTES;

                            tx_tlp_valid  <= 1'b1;
                            tx_tlp_type   <= TLP_MEM_RD;
                            tx_tlp_addr   <= (rd_burst == AXI_BURST_INCR) ?
                                             (rd_addr + DATA_BYTES) : rd_addr;
                            tx_tlp_length <= DATA_DW;
                            tx_tlp_tag    <= {{(8-ID_WIDTH){1'b0}}, rd_id};
                            tx_tlp_data   <= {DATA_WIDTH{1'b0}};
                            tx_tlp_sop    <= 1'b1;
                            tx_tlp_eop    <= 1'b1;
                            state         <= ST_RD_TX;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
