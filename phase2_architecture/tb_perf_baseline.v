`timescale 1ns/1ps
// Phase 2 throughput measurement for the frozen Stage 1 axi4_to_pcie_bridge.
// Same AXI workload as tb_perf_enhanced.v: NB write bursts then NB read
// bursts of BEATS beats, AXI master and endpoint always ready, read
// completions returned LAT cycles after the MemRd TLP is accepted.
// The Stage 1 bridge issues one TLP and expects one completion per AXI beat;
// rx_cpl_eop marks the completion for the final beat of the burst.
// Compile: iverilog -g2012 -s tb_perf_baseline -o perf_base stage1_baseline_axi4_to_pcie_bridge.v tb_perf_baseline.v
module tb_perf_baseline;
    localparam DATA_WIDTH=64, ADDR_WIDTH=32, ID_WIDTH=4;
    localparam integer NB=16, BEATS=4;
    localparam [2:0] AXI_SIZE=3'd3;

    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;

    reg [ID_WIDTH-1:0] awid=0; reg [ADDR_WIDTH-1:0] awaddr=0; reg [7:0] awlen=BEATS-1;
    reg awvalid=0; wire awready;
    reg [DATA_WIDTH-1:0] wdata=0; reg wlast=0, wvalid=0; wire wready;
    wire [ID_WIDTH-1:0] bid; wire [1:0] bresp; wire bvalid; reg bready=1;
    reg [ID_WIDTH-1:0] arid=0; reg [ADDR_WIDTH-1:0] araddr=0; reg [7:0] arlen=BEATS-1;
    reg arvalid=0; wire arready;
    wire [ID_WIDTH-1:0] rid; wire [DATA_WIDTH-1:0] rdata; wire [1:0] rresp; wire rlast, rvalid;
    reg rready=1;
    wire tx_valid; reg tx_ready=1; wire [4:0] tx_type;
    wire [ADDR_WIDTH-1:0] tx_addr; wire [9:0] tx_len; wire [7:0] tx_tag;
    wire [DATA_WIDTH-1:0] tx_data; wire tx_sop, tx_eop;
    reg rx_valid=0; wire rx_ready; reg [7:0] rx_tag=0;
    reg [DATA_WIDTH-1:0] rx_data=0; reg [1:0] rx_status=0; reg rx_eop=0;

    axi4_to_pcie_bridge #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(AXI_SIZE), .s_axi_awburst(2'b01),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb({DATA_WIDTH/8{1'b1}}), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(AXI_SIZE), .s_axi_arburst(2'b01),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .tx_tlp_valid(tx_valid), .tx_tlp_ready(tx_ready), .tx_tlp_type(tx_type),
        .tx_tlp_addr(tx_addr), .tx_tlp_length(tx_len), .tx_tlp_tag(tx_tag),
        .tx_tlp_data(tx_data), .tx_tlp_sop(tx_sop), .tx_tlp_eop(tx_eop),
        .rx_cpl_valid(rx_valid), .rx_cpl_ready(rx_ready), .rx_cpl_tag(rx_tag),
        .rx_cpl_data(rx_data), .rx_cpl_status(rx_status), .rx_cpl_eop(rx_eop)
    );

    function [DATA_WIDTH-1:0] mem_word;
        input [31:0] a;
        begin mem_word = {a, ~a}; end
    endfunction

    integer cyc=0, lat=8;
    integer aw_sent, w_sent, b_got, ar_sent, r_beats, r_bursts, tlps, rd_tlps, errors=0;
    integer t_start, t_end;
    reg run_w=0, run_r=0;

    reg [7:0] q_tag [0:63]; reg [31:0] q_addr [0:63]; reg q_eop [0:63]; integer q_due [0:63];
    integer q_wr, q_rd;

    always @(posedge clk) cyc <= cyc + 1;

    always @(posedge clk) begin
        if (run_w) begin
            if (awvalid && awready) begin
                aw_sent = aw_sent + 1;
                awaddr <= 32'h1000_0000 + aw_sent*BEATS*(DATA_WIDTH/8);
                awid <= aw_sent;
            end
            awvalid <= (aw_sent < NB);
            if (wvalid && wready) w_sent = w_sent + 1;
            wvalid <= (w_sent < NB*BEATS);
            wdata <= w_sent;
            wlast <= ((w_sent % BEATS) == BEATS-1);
            if (bvalid && bready) begin
                b_got = b_got + 1;
                if (bresp != 2'b00) errors = errors + 1;
            end
        end else begin
            awvalid <= 0; wvalid <= 0;
        end

        if (run_r) begin
            if (arvalid && arready) begin
                ar_sent = ar_sent + 1;
                araddr <= 32'h2000_0000 + ar_sent*BEATS*(DATA_WIDTH/8);
                arid <= ar_sent;
            end
            arvalid <= (ar_sent < NB);
            if (rvalid && rready) begin
                if (rdata !== mem_word(32'h2000_0000 + r_beats*(DATA_WIDTH/8))) errors = errors + 1;
                r_beats = r_beats + 1;
                if (rlast) r_bursts = r_bursts + 1;
            end
        end else begin
            arvalid <= 0;
        end

        if (tx_valid && tx_ready) begin
            tlps = tlps + 1;
            if (tx_type == 5'b00001) begin
                q_tag[q_wr % 64] = tx_tag; q_addr[q_wr % 64] = tx_addr;
                q_eop[q_wr % 64] = ((rd_tlps % BEATS) == BEATS-1);
                q_due[q_wr % 64] = cyc + lat; q_wr = q_wr + 1;
                rd_tlps = rd_tlps + 1;
            end
        end
        if (rx_valid && rx_ready) begin
            rx_valid <= 0;
            q_rd = q_rd + 1;
        end else if (!rx_valid && q_rd < q_wr && cyc >= q_due[q_rd % 64]) begin
            rx_valid <= 1;
            rx_tag <= q_tag[q_rd % 64];
            rx_eop <= q_eop[q_rd % 64];
            rx_data <= mem_word(q_addr[q_rd % 64]);
        end
    end

    task reset_bridge;
        begin
            run_w=0; run_r=0; rst_n=0;
            aw_sent=0; w_sent=0; b_got=0; ar_sent=0; r_beats=0; r_bursts=0; tlps=0; rd_tlps=0;
            q_wr=0; q_rd=0; rx_valid=0;
            awaddr=32'h1000_0000; awid=0; araddr=32'h2000_0000; arid=0;
            wdata=0; wlast=(BEATS==1);
            repeat(3) @(posedge clk);
            rst_n=1;
            repeat(2) @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        if ($value$plusargs("lat=%d", lat)) ;
        $display("PERF design=stage1_baseline lat=%0d NB=%0d BEATS=%0d DATA_WIDTH=%0d", lat, NB, BEATS, DATA_WIDTH);

        reset_bridge();
        t_start = cyc; run_w = 1;
        while (b_got < NB) @(negedge clk);
        t_end = cyc; run_w = 0;
        $display("PERF design=stage1_baseline scenario=write lat=%0d cycles=%0d beats=%0d tlps=%0d beats_per_cycle=%0.3f",
                 lat, t_end-t_start, NB*BEATS, tlps, (NB*BEATS*1.0)/(t_end-t_start));

        reset_bridge();
        t_start = cyc; run_r = 1;
        while (r_bursts < NB) @(negedge clk);
        t_end = cyc; run_r = 0;
        $display("PERF design=stage1_baseline scenario=read lat=%0d cycles=%0d beats=%0d tlps=%0d beats_per_cycle=%0.3f",
                 lat, t_end-t_start, NB*BEATS, tlps, (NB*BEATS*1.0)/(t_end-t_start));
        $display("PERF design=stage1_baseline data_errors=%0d", errors);
        $finish;
    end

    initial begin #2000000; $display("PERF TIMEOUT"); $finish; end
endmodule
