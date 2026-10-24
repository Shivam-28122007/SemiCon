`timescale 1ns/1ps
// Phase 3 regression for sarcathon_axi_pcie_bridge.
// Procedural assertions are used for broad Icarus Verilog compatibility.
// Compile: iverilog -g2012 -Wall -s tb_phase3_axi_pcie_bridge -o phase3_sim sarcathon_axi_pcie_bridge.v tb_phase3_axi_pcie_bridge.v
// Run: vvp phase3_sim
module tb_phase3_axi_pcie_bridge;
    localparam DATA_WIDTH=32;
    localparam ADDR_WIDTH=32;
    localparam ID_WIDTH=4;
    localparam MAX_BEATS=4;
    localparam TAG_COUNT=4;
    localparam W_FIFO_DEPTH=8;
    localparam [2:0] AXI_SIZE=3'd2;

    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;

    reg [ID_WIDTH-1:0] awid;
    reg [ADDR_WIDTH-1:0] awaddr;
    reg [7:0] awlen;
    reg [2:0] awsize;
    reg [1:0] awburst;
    reg awvalid;
    wire awready;
    reg [DATA_WIDTH-1:0] wdata;
    reg [DATA_WIDTH/8-1:0] wstrb;
    reg wlast, wvalid;
    wire wready;
    wire [ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    reg bready;

    reg [ID_WIDTH-1:0] arid;
    reg [ADDR_WIDTH-1:0] araddr;
    reg [7:0] arlen;
    reg [2:0] arsize;
    reg [1:0] arburst;
    reg arvalid;
    wire arready;
    wire [ID_WIDTH-1:0] rid;
    wire [DATA_WIDTH-1:0] rdata;
    wire [1:0] rresp;
    wire rlast, rvalid;
    reg rready;

    wire tx_valid;
    reg tx_ready;
    wire tx_type;
    wire [ADDR_WIDTH-1:0] tx_addr;
    wire [7:0] tx_len, tx_tag;
    wire [DATA_WIDTH*MAX_BEATS-1:0] tx_data;
    reg rx_valid;
    wire rx_ready;
    reg [7:0] rx_tag;
    reg [DATA_WIDTH*MAX_BEATS-1:0] rx_data;
    reg [1:0] rx_status;

    // -DGATE_LEVEL: the DUT is a synthesized netlist whose parameters were
    // fixed at synthesis (DATA_WIDTH=32, MAX_BEATS=4, TAG_COUNT=4,
    // W_FIFO_DEPTH=8), so no overrides are passed.
    sarcathon_axi_pcie_bridge
`ifndef GATE_LEVEL
    #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH), .MAX_BEATS(MAX_BEATS),
        .TAG_COUNT(TAG_COUNT), .W_FIFO_DEPTH(W_FIFO_DEPTH)
    )
`endif
    dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .tx_tlp_valid(tx_valid), .tx_tlp_ready(tx_ready), .tx_tlp_type(tx_type),
        .tx_tlp_addr(tx_addr), .tx_tlp_len(tx_len), .tx_tlp_tag(tx_tag), .tx_tlp_data(tx_data),
        .rx_cpl_valid(rx_valid), .rx_cpl_ready(rx_ready), .rx_cpl_tag(rx_tag),
        .rx_cpl_data(rx_data), .rx_cpl_status(rx_status)
    );

    integer checks=0, passes=0, failures=0;
    integer assertion_checks=0, assertion_failures=0;
    integer assert_x_checks=0, assert_fifo_checks=0;
    integer cov_len1=0, cov_len2=0, cov_len3=0, cov_len4=0;
    integer cov_wlen1=0, cov_wlen2=0, cov_wlen3=0, cov_wlen4=0;
    integer cov_tx_stall_cycles=0, cov_r_stall_cycles=0, cov_b_stall_cycles=0;
    integer cov_random_writes=0, cov_random_reads=0;
    integer cov_packet_profile=0, cov_ml_profile=0;
    integer cov_malformed=0, cov_reset_active=0, cov_out_of_order=0;
    integer cov_tag_exhaustion=0, cov_boundary_reject=0, cov_stale_cpl=0;
    integer cov_fifo_full_cycles=0, cov_wfirst_bursts=0, cov_mixed_bursts=0;
    integer cov_aw_while_b_pending=0, cov_late_wlast=0, cov_tag_reuse=0;
    integer seed=32'h13579bdf;
    integer start_seed;

    // Concurrent mixed-traffic scoreboard state.
    localparam integer NW_MIX=24, NR_MIX=24;
    reg [31:0] mw_addr [0:NW_MIX-1];
    reg [7:0] mw_len [0:NW_MIX-1];
    reg [3:0] mw_id [0:NW_MIX-1];
    reg [127:0] mw_data [0:NW_MIX-1];
    reg [31:0] mr_addr [0:NR_MIX-1];
    reg [7:0] mr_len [0:NR_MIX-1];
    reg [3:0] mr_id [0:NR_MIX-1];
    reg mr_matched [0:NR_MIX-1];
    reg [7:0] pend_tag [0:TAG_COUNT-1];
    reg [31:0] pend_addr [0:TAG_COUNT-1];
    reg [7:0] pend_len [0:TAG_COUNT-1];
    integer pend_cnt, mw_tlp_seen, mr_issued, mr_sent, cpl_sent;
    integer wn, wk, rn, rc, rk, bc, tn, cn, cidx, cdly, gap;
    reg found;
    reg [31:0] cap_addr;
    reg [7:0] cap_len, cap_tag, cpl_tag;
    reg cap_type;
    reg [127:0] cap_data, cpl_payload;

    // Deterministic endpoint memory model for read completions.
    function [31:0] mem_word;
        input [31:0] a;
        begin
            mem_word = a ^ 32'h5a5a_a5a5;
        end
    endfunction
    integer i,j,k,cycles, beats, n;
    reg [31:0] rand_word;
    reg [7:0] tags [0:TAG_COUNT-1];
    reg [3:0] ids [0:TAG_COUNT-1];
    reg [7:0] read_beats [0:TAG_COUNT-1];
    reg [127:0] read_payload [0:TAG_COUNT-1];
    reg [31:0] write_payload [0:MAX_BEATS-1];
    reg [127:0] expected_payload;
    reg [31:0] expected_word;
    reg [31:0] held_tx_data;
    reg [176:0] held_tx_payload;
    reg [31:0] held_rdata;
    reg [3:0] held_rid;
    reg [1:0] held_rresp;
    reg held_rlast;
    reg [3:0] held_bid;
    reg [1:0] held_bresp;
    reg prev_tx_stall, prev_r_stall, prev_b_stall;
    integer assertion_count_local;

    task check;
        input [8*112-1:0] name;
        input condition;
        begin
            checks=checks+1;
            if (condition) begin
                passes=passes+1;
                $display("PASS | %0s", name);
            end else begin
                failures=failures+1;
                $display("FAIL | %0s", name);
            end
        end
    endtask

    task defaults;
        begin
            awid=0; awaddr=0; awlen=0; awsize=AXI_SIZE; awburst=2'b01; awvalid=0;
            wdata=0; wstrb=4'hf; wlast=0; wvalid=0;
            bready=0;
            arid=0; araddr=0; arlen=0; arsize=AXI_SIZE; arburst=2'b01; arvalid=0;
            rready=0;
            tx_ready=0;
            rx_valid=0; rx_tag=0; rx_data=0; rx_status=0;
        end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    task send_aw;
        input [3:0] id;
        input [31:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        integer guard;
        begin
            @(negedge clk);
            awid=id; awaddr=addr; awlen=len; awsize=size; awburst=burst; awvalid=1;
            guard=0;
            while (1) begin
                @(posedge clk);
                if (awready) begin
                    @(negedge clk); awvalid=0;
                    disable send_aw;
                end
                guard=guard+1;
                if (guard>100) begin
                    check("AW handshake timeout", 0);
                    @(negedge clk); awvalid=0;
                    disable send_aw;
                end
            end
        end
    endtask

    task send_w;
        input [31:0] data;
        input [3:0] strb;
        input last;
        integer guard;
        begin
            @(negedge clk);
            wdata=data; wstrb=strb; wlast=last; wvalid=1;
            guard=0;
            while (1) begin
                @(posedge clk);
                if (wready) begin
                    @(negedge clk); wvalid=0;
                    disable send_w;
                end
                guard=guard+1;
                if (guard>100) begin
                    check("W handshake timeout", 0);
                    @(negedge clk); wvalid=0;
                    disable send_w;
                end
            end
        end
    endtask

    task send_ar;
        input [3:0] id;
        input [31:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        integer guard;
        begin
            @(negedge clk);
            arid=id; araddr=addr; arlen=len; arsize=size; arburst=burst; arvalid=1;
            guard=0;
            while (1) begin
                @(posedge clk);
                if (arready) begin
                    @(negedge clk); arvalid=0;
                    disable send_ar;
                end
                guard=guard+1;
                if (guard>100) begin
                    check("AR handshake timeout", 0);
                    @(negedge clk); arvalid=0;
                    disable send_ar;
                end
            end
        end
    endtask

    task wait_tx;
        output [7:0] got_tag;
        integer guard;
        begin
            guard=0;
            while (!tx_valid && guard<150) begin @(negedge clk); guard=guard+1; end
            got_tag=tx_tag;
            check("TX packet appears before timeout", tx_valid);
        end
    endtask

    task accept_tx;
        integer stall_cycles;
        integer stall_i;
        begin
            // Deterministic pseudo-random backpressure (0..3 cycles).
            stall_cycles = ($random(seed) & 32'h7fffffff) % 4;
            for (stall_i=0; stall_i<stall_cycles; stall_i=stall_i+1) tick;
            @(negedge clk); tx_ready=1;
            @(posedge clk); #1;
            @(negedge clk); tx_ready=0;
        end
    endtask

    task send_completion;
        input [7:0] tag;
        input [127:0] payload;
        input [1:0] status;
        integer guard;
        reg accepted;
        begin
            // Drive completion away from the active edge, then sample READY
            // only at rising edges. This avoids missing a one-cycle handshake
            // when READY rises after a TX handshake and falls after completion
            // acceptance in the same simulation timestep.
            @(negedge clk);
            rx_tag=tag;
            rx_data=payload;
            rx_status=status;
            rx_valid=1'b1;
            accepted=1'b0;
            guard=0;
            while (!accepted && guard<100) begin
                @(posedge clk);
                if (rx_ready === 1'b1)
                    accepted=1'b1;
                guard=guard+1;
            end
            check("completion tag becomes acceptable", accepted);
            @(negedge clk);
            rx_valid=1'b0;
        end
    endtask

    task consume_read_beat;
        input [3:0] exp_id;
        input [31:0] exp_data;
        input [1:0] exp_resp;
        input exp_last;
        integer guard;
        integer stall_cycles;
        integer stall_i;
        begin
            guard=0;
            while (!rvalid && guard<150) begin @(negedge clk); guard=guard+1; end
            check("R beat becomes valid", rvalid);
            if (rvalid) begin
                check("R ID/order correct", rid==exp_id);
                check("R data correct", rdata==exp_data);
                check("R response correct", rresp==exp_resp);
                check("RLAST correct", rlast==exp_last);
                // Randomly hold RREADY low to stress output stability.
                stall_cycles = ($random(seed) & 32'h7fffffff) % 4;
                for (stall_i=0; stall_i<stall_cycles; stall_i=stall_i+1) tick;
                @(negedge clk); rready=1;
                @(posedge clk); #1;
                @(negedge clk); rready=0;
            end
        end
    endtask

    task consume_write_response;
        input [3:0] exp_id;
        input [1:0] exp_resp;
        integer guard;
        integer stall_cycles;
        integer stall_i;
        begin
            guard=0;
            while (!bvalid && guard<150) begin @(negedge clk); guard=guard+1; end
            check("B response becomes valid", bvalid);
            if (bvalid) begin
                check("B ID correct", bid==exp_id);
                check("B response code correct", bresp==exp_resp);
                // Randomly hold BREADY low to stress response stability.
                stall_cycles = ($random(seed) & 32'h7fffffff) % 4;
                for (stall_i=0; stall_i<stall_cycles; stall_i=stall_i+1) tick;
                @(negedge clk); bready=1;
                @(posedge clk); #1;
                @(negedge clk); bready=0;
            end
        end
    endtask

    // Procedural assertions: payload/control must remain stable during stalls.
    // Checks sample values at each rising edge and are disabled during reset.
    always @(posedge clk) begin
        if (!rst_n) begin
            prev_tx_stall <= 0;
            prev_r_stall <= 0;
            prev_b_stall <= 0;
        end else begin
            if (prev_tx_stall) begin
                assertion_checks=assertion_checks+1;
                if (!(tx_valid && tx_addr==held_tx_payload[31:0] &&
                      tx_len==held_tx_payload[39:32] &&
                      tx_tag==held_tx_payload[47:40] &&
                      tx_type==held_tx_payload[48] &&
                      tx_data===held_tx_payload[176:49])) begin
                    assertion_failures=assertion_failures+1;
                    failures=failures+1;
                    $display("ASSERT FAIL | TX payload/control changed while stalled");
                end
            end
            if (prev_r_stall) begin
                assertion_checks=assertion_checks+1;
                if (!(rvalid && rid==held_rid && rdata===held_rdata &&
                      rresp==held_rresp && rlast==held_rlast)) begin
                    assertion_failures=assertion_failures+1;
                    failures=failures+1;
                    $display("ASSERT FAIL | AXI R payload/control changed while stalled");
                end
            end
            if (prev_b_stall) begin
                assertion_checks=assertion_checks+1;
                if (!(bvalid && bid==held_bid && bresp==held_bresp)) begin
                    assertion_failures=assertion_failures+1;
                    failures=failures+1;
                    $display("ASSERT FAIL | AXI B response changed while stalled");
                end
            end

            // No X may be visible on a channel while its VALID is high. This
            // matters because pure datapath registers in the DUT have no reset.
            if (tx_valid) begin
                assertion_checks=assertion_checks+1; assert_x_checks=assert_x_checks+1;
                if ((^{tx_addr,tx_len,tx_tag,tx_type,tx_data}) === 1'bx) begin
                    assertion_failures=assertion_failures+1;
                    failures=failures+1;
                    $display("ASSERT FAIL | TX VALID with X/Z payload");
                end
            end
            if (rvalid) begin
                assertion_checks=assertion_checks+1; assert_x_checks=assert_x_checks+1;
                if ((^{rid,rdata,rresp,rlast}) === 1'bx) begin
                    assertion_failures=assertion_failures+1;
                    failures=failures+1;
                    $display("ASSERT FAIL | AXI R VALID with X/Z payload");
                end
            end
            if (bvalid) begin
                assertion_checks=assertion_checks+1; assert_x_checks=assert_x_checks+1;
                if ((^{bid,bresp}) === 1'bx) begin
                    assertion_failures=assertion_failures+1;
                    failures=failures+1;
                    $display("ASSERT FAIL | AXI B VALID with X/Z payload");
                end
            end
            // White-box W FIFO checks: occupancy bound and WREADY == !full.
            // Not available on a gate-level netlist (-DGATE_LEVEL).
`ifndef GATE_LEVEL
            assertion_checks=assertion_checks+1; assert_fifo_checks=assert_fifo_checks+1;
            if (!(dut.w_count <= W_FIFO_DEPTH && (wready == (dut.w_count < W_FIFO_DEPTH)))) begin
                assertion_failures=assertion_failures+1;
                failures=failures+1;
                $display("ASSERT FAIL | W FIFO occupancy/WREADY inconsistent (count=%0d)", dut.w_count);
            end
`endif
            if (!wready) cov_fifo_full_cycles=cov_fifo_full_cycles+1;
            if (bvalid && !bready && awvalid && awready)
                cov_aw_while_b_pending=cov_aw_while_b_pending+1;

            prev_tx_stall <= tx_valid && !tx_ready;
            prev_r_stall <= rvalid && !rready;
            prev_b_stall <= bvalid && !bready;
            if (tx_valid && !tx_ready) begin
                cov_tx_stall_cycles=cov_tx_stall_cycles+1;
                held_tx_payload[31:0] <= tx_addr;
                held_tx_payload[39:32] <= tx_len;
                held_tx_payload[47:40] <= tx_tag;
                held_tx_payload[48] <= tx_type;
                held_tx_payload[176:49] <= tx_data;
            end
            if (rvalid && !rready) begin
                cov_r_stall_cycles=cov_r_stall_cycles+1;
                held_rid <= rid; held_rdata <= rdata;
                held_rresp <= rresp; held_rlast <= rlast;
            end
            if (bvalid && !bready) begin
                cov_b_stall_cycles=cov_b_stall_cycles+1;
                held_bid <= bid; held_bresp <= bresp;
            end
        end
    end

    // Test main
    initial begin
        defaults();
        prev_tx_stall=0; prev_r_stall=0; prev_b_stall=0;
        held_tx_payload=0; held_rid=0; held_rdata=0; held_rresp=0; held_rlast=0;
        held_bid=0; held_bresp=0;
        if ($value$plusargs("seed=%h", seed)) ;
        start_seed=seed;
        $display("==============================================================");
        $display("SARCathon Phase 3 Functional Verification Regression");
        $display("seed=0x%08h; deterministic constrained-random; DATA_WIDTH=32; MAX_BEATS=4; TAG_COUNT=4; W_FIFO_DEPTH=%0d",
                 start_seed, W_FIFO_DEPTH);
        $display("==============================================================");

        repeat(4) tick;
        rst_n=1;
        repeat(2) tick;
        check("reset clears TX VALID", !tx_valid);
        check("reset clears B VALID", !bvalid);
        check("reset clears R VALID", !rvalid);

        // Directed: random backpressure on a 4-beat write and TX stability.
        send_aw(4'h1, 32'h1000_0000, 8'd3, AXI_SIZE, 2'b01);
        expected_payload=0;
        for (j=0;j<MAX_BEATS;j=j+1) begin
            rand_word=$random(seed);
            write_payload[j]=rand_word;
            send_w(rand_word,4'hf,(j==MAX_BEATS-1));
            expected_payload[j*DATA_WIDTH +: DATA_WIDTH]=rand_word;
        end
        wait_tx(tags[0]);
        check("write burst coalesced into one TLP", tx_valid && tx_type==0 && tx_len==4);
        check("write TLP address correct", tx_addr==32'h1000_0000);
        check("write packet payload correct", tx_data===expected_payload);
        repeat(4) tick; // hold READY low; assertions check stable TX
        accept_tx();
        consume_write_response(4'h1,2'b00);
        cov_wlen4=cov_wlen4+1;

        // Malformed write: partial strobe -> SLVERR and no TLP.
        send_aw(4'h2,32'h1100_0000,8'd0,AXI_SIZE,2'b01);
        send_w(32'hdeaf_beef,4'b0011,1'b1);
        consume_write_response(4'h2,2'b10);
        check("malformed write did not leave TX packet", !tx_valid);
        cov_malformed=cov_malformed+1;

        // WLAST asserted early on beat 0 of a two-beat burst is malformed.
        // The bridge drains the declared burst and returns SLVERR, no TLP.
        send_aw(4'h4,32'h1100_1000,8'd1,AXI_SIZE,2'b01);
        send_w(32'h4444_0000,4'hf,1'b1);
        send_w(32'h4444_0001,4'hf,1'b1);
        consume_write_response(4'h4,2'b10);
        check("early WLAST burst rejected without TLP",!tx_valid);
        cov_malformed=cov_malformed+1;

        // Malformed burst type: FIXED reads are outside this bridge's contract.
        send_ar(4'hc,32'h1180_0000,8'd0,AXI_SIZE,2'b00);
        consume_read_beat(4'hc,32'h0,2'b10,1'b1);
        check("FIXED burst read is rejected locally",!tx_valid);
        cov_malformed=cov_malformed+1;

        // Oversized write burst (5 beats when MAX_BEATS=4) is drained and
        // rejected with SLVERR instead of emitting a truncated packet.
        send_aw(4'hb,32'h1190_0000,8'd4,AXI_SIZE,2'b01);
        for (j=0;j<5;j=j+1)
            send_w(32'hbad0_0000+j,4'hf,(j==4));
        consume_write_response(4'hb,2'b10);
        check("oversized write burst emits no TLP",!tx_valid);
        cov_malformed=cov_malformed+1;

        // AXI4 boundary rule: a two-beat 32-bit write at 0x...FFC crosses
        // the 4-KiB boundary and must be rejected without producing a TLP.
        send_aw(4'h9,32'h1000_0ffc,8'd1,AXI_SIZE,2'b01);
        send_w(32'h1111_1111,4'hf,1'b0);
        send_w(32'h2222_2222,4'hf,1'b1);
        consume_write_response(4'h9,2'b10);
        check("4-KiB-crossing write rejected without TLP",!tx_valid);
        cov_malformed=cov_malformed+1;
        cov_boundary_reject=cov_boundary_reject+1;

        // Randomized multi-outstanding reads; use deterministic pseudo-random
        // burst lengths/data and deliver completions in reverse order.
        for (i=0;i<TAG_COUNT;i=i+1) begin
            beats=1+($random(seed) & 32'h7fffffff)%MAX_BEATS;
            read_beats[i]=beats;
            ids[i]=i+3;
            araddr=32'h2000_0000 + i*32'h1000;
            for (j=0;j<MAX_BEATS;j=j+1) read_payload[i][j*32 +: 32]=0;
            for (j=0;j<beats;j=j+1) begin
                rand_word=$random(seed);
                read_payload[i][j*32 +: 32]=rand_word;
            end
            send_ar(ids[i],32'h2000_0000+i*32'h1000,beats-1,AXI_SIZE,2'b01);
            case (beats)
                1: cov_len1=cov_len1+1;
                2: cov_len2=cov_len2+1;
                3: cov_len3=cov_len3+1;
                4: cov_len4=cov_len4+1;
            endcase
        end
        check("ARREADY backpressures when all completion tags are allocated",!arready);
        cov_tag_exhaustion=cov_tag_exhaustion+1;

        for (i=0;i<TAG_COUNT;i=i+1) begin
            wait_tx(tags[i]);
            check("read request is MemRd",tx_valid && tx_type==1);
            check("read TLP length matches AXI burst",tx_len==read_beats[i]);
            check("read TLP address matches request",tx_addr==(32'h2000_0000+i*32'h1000));
            for (j=0;j<i;j=j+1)
                check("allocated read tags are unique",tags[i]!=tags[j]);
            accept_tx();
        end

        // Unknown tag must be rejected; does not count as a completion.
        @(negedge clk); rx_valid=1; rx_tag=8'hfe; rx_data=0; rx_status=0;
        #1; check("unknown completion tag is rejected",!rx_ready);
        @(negedge clk); rx_valid=0;

        // Reverse order simulates out-of-order completions.
        for (i=TAG_COUNT-1;i>=0;i=i-1) begin
            send_completion(tags[i],read_payload[i],2'b00);
            if (i==TAG_COUNT-1) cov_out_of_order=cov_out_of_order+1;
        end

        // AXI R responses must still be in original AR acceptance order.
        for (i=0;i<TAG_COUNT;i=i+1) begin
            for (j=0;j<read_beats[i];j=j+1) begin
                consume_read_beat(ids[i],read_payload[i][j*32 +: 32],2'b00,(j==read_beats[i]-1));
            end
            cov_random_reads=cov_random_reads+1;
        end

        // Malformed read size: local policy is one zero-data SLVERR beat.
        send_ar(4'hd,32'h3000_0000,8'd0,3'd1,2'b01);
        consume_read_beat(4'hd,32'h0,2'b10,1'b1);
        check("malformed read generated no TX request",!tx_valid);
        cov_malformed=cov_malformed+1;

        // Misaligned full-width address is rejected locally.
        send_ar(4'h8,32'h3000_0002,8'd0,AXI_SIZE,2'b01);
        consume_read_beat(4'h8,32'h0,2'b10,1'b1);
        check("misaligned read rejected without TLP",!tx_valid);
        cov_malformed=cov_malformed+1;

        // A two-beat read at 0x...FFC crosses 4 KiB and is rejected locally.
        send_ar(4'h7,32'h3000_0ffc,8'd1,AXI_SIZE,2'b01);
        consume_read_beat(4'h7,32'h0,2'b10,1'b1);
        check("4-KiB-crossing read rejected without TLP",!tx_valid);
        cov_malformed=cov_malformed+1;
        cov_boundary_reject=cov_boundary_reject+1;

        // Completion error maps to AXI SLVERR.
        send_ar(4'he,32'h3100_0000,8'd0,AXI_SIZE,2'b01);
        wait_tx(tags[0]);
        accept_tx();
        expected_payload=0; expected_payload[31:0]=32'hface_cafe;
        send_completion(tags[0],expected_payload,2'b01);
        consume_read_beat(4'he,32'hface_cafe,2'b10,1'b1);
        // A duplicate/stale completion after retirement must not be accepted.
        @(negedge clk); rx_valid=1; rx_tag=tags[0]; rx_data=expected_payload; rx_status=0;
        #1; check("duplicate/stale completion rejected after retirement",!rx_ready);
        cov_stale_cpl=cov_stale_cpl+1;
        @(negedge clk); rx_valid=0;

        // Packet-processing profile: many small, sequential write packets.
        for (i=0;i<6;i=i+1) begin
            beats=1+(i%2);
            send_aw((i+1)%16,32'h4000_0000+i*32,beats-1,AXI_SIZE,2'b01);
            expected_payload=0;
            for (j=0;j<beats;j=j+1) begin
                rand_word=$random(seed);
                expected_payload[j*32 +: 32]=rand_word;
                send_w(rand_word,4'hf,(j==beats-1));
            end
            wait_tx(tags[0]);
            check("packet profile emits coalesced write",tx_valid && tx_type==0 && tx_len==beats);
            check("packet profile payload matches",tx_data===expected_payload);
            accept_tx();
            consume_write_response((i+1)%16,2'b00);
            if (beats==1) cov_wlen1=cov_wlen1+1; else cov_wlen2=cov_wlen2+1;
            cov_packet_profile=cov_packet_profile+1;
            cov_random_writes=cov_random_writes+1;
        end

        // ML-inference profile: four 4-beat feature-vector reads outstanding.
        for (i=0;i<TAG_COUNT;i=i+1) begin
            ids[i]=i+1;
            read_beats[i]=4;
            read_payload[i]=0;
            for (j=0;j<4;j=j+1) begin
                // Deterministic feature-vector-like payload; each transaction
                // represents a chunk of input activations/weights.
                read_payload[i][j*32 +: 32]=32'h0100_0000 | (i<<16) | (j*4) | 32'h1;
            end
            send_ar(ids[i],32'h5000_0000+i*32'h100,8'd3,AXI_SIZE,2'b01);
        end
        for (i=0;i<TAG_COUNT;i=i+1) begin
            wait_tx(tags[i]);
            check("ML profile request is 4-beat read",tx_valid && tx_type==1 && tx_len==4);
            accept_tx();
        end
        for (i=TAG_COUNT-1;i>=0;i=i-1) send_completion(tags[i],read_payload[i],2'b00);
        for (i=0;i<TAG_COUNT;i=i+1)
            for (j=0;j<4;j=j+1)
                consume_read_beat(ids[i],read_payload[i][j*32 +: 32],2'b00,(j==3));
        cov_ml_profile=cov_ml_profile+1;

        // Reset during a stalled TX request: reset should clear valid outputs.
        send_ar(4'hf,32'h6000_0000,8'd0,AXI_SIZE,2'b01);
        wait_tx(tags[0]);
        check("TX is stalled before reset test",tx_valid && !tx_ready);
        @(negedge clk); rst_n=0;
        repeat(2) tick;
        check("reset clears stalled TX VALID",!tx_valid);
        check("reset clears response VALID signals",!bvalid && !rvalid);
        cov_reset_active=cov_reset_active+1;
        @(negedge clk); rst_n=1;
        repeat(3) tick;
        check("bridge returns idle after reset",!tx_valid && !bvalid && !rvalid);

        // Reset with a read request already accepted downstream but not yet
        // completed. The tag must be invalidated and a late completion ignored.
        send_ar(4'h6,32'h6100_0000,8'd0,AXI_SIZE,2'b01);
        wait_tx(tags[0]);
        accept_tx();
        @(negedge clk); rst_n=0;
        repeat(2) tick;
        check("reset clears accepted outstanding read",!tx_valid && !rvalid);
        @(negedge clk); rx_valid=1; rx_tag=tags[0]; rx_data=0; rx_status=0;
        #1; check("late completion after reset rejected",!rx_ready);
        cov_stale_cpl=cov_stale_cpl+1;
        @(negedge clk); rx_valid=0; rst_n=1;
        repeat(3) tick;
        check("bridge recovers after outstanding-read reset",!tx_valid && !bvalid && !rvalid);
        cov_reset_active=cov_reset_active+1;

        // Reset while a write burst is only partially collected. The buffered
        // beat and partial transaction must be discarded, then a fresh write
        // must work after reset.
        send_aw(4'h5,32'h6200_0000,8'd1,AXI_SIZE,2'b01);
        send_w(32'h5555_aaaa,4'hf,1'b0);
        repeat(2) tick;
        @(negedge clk); rst_n=0;
        repeat(2) tick;
        check("reset clears partial write collection",!tx_valid && !bvalid);
        @(negedge clk); rst_n=1;
        repeat(2) tick;
        send_aw(4'h5,32'h6200_1000,8'd0,AXI_SIZE,2'b01);
        send_w(32'hcafef00d,4'hf,1'b1);
        wait_tx(tags[0]);
        check("fresh write succeeds after partial-write reset",tx_valid && tx_type==0 && tx_len==1 && tx_addr==32'h6200_1000);
        accept_tx();
        consume_write_response(4'h5,2'b00);
        cov_reset_active=cov_reset_active+1;

        // ---------------------------------------------------------------
        // Late/missing WLAST: two-beat burst with WLAST never asserted is
        // drained, rejected with SLVERR, and leaves no stale beat behind.
        send_aw(4'h3,32'h1200_0000,8'd1,AXI_SIZE,2'b01);
        send_w(32'h3333_0000,4'hf,1'b0);
        send_w(32'h3333_0001,4'hf,1'b0);
        consume_write_response(4'h3,2'b10);
        check("missing/late WLAST burst rejected without TLP",!tx_valid);
        send_aw(4'h3,32'h1200_0040,8'd0,AXI_SIZE,2'b01);
        send_w(32'h3333_0002,4'hf,1'b1);
        wait_tx(tags[0]);
        check("write after late-WLAST reject is clean",
              tx_valid && tx_type==0 && tx_len==1 && tx_data[31:0]==32'h3333_0002);
        accept_tx();
        consume_write_response(4'h3,2'b00);
        cov_malformed=cov_malformed+1;
        cov_late_wlast=cov_late_wlast+1;

        // ---------------------------------------------------------------
        // W-before-AW FIFO-full stress: two complete 4-beat bursts are
        // buffered before any AW. WREADY must drop when the FIFO is full.
        for (k=0;k<W_FIFO_DEPTH;k=k+1) begin
            write_payload[k%MAX_BEATS]=$random(seed);
            if (k<MAX_BEATS) expected_payload[k*32 +: 32]=write_payload[k%MAX_BEATS];
            else read_payload[0][(k-MAX_BEATS)*32 +: 32]=write_payload[k%MAX_BEATS];
            send_w(write_payload[k%MAX_BEATS],4'hf,(k%MAX_BEATS)==MAX_BEATS-1);
        end
        @(negedge clk);
`ifdef GATE_LEVEL
        check("W FIFO full deasserts WREADY",!wready);
`else
        check("W FIFO full deasserts WREADY",!wready && dut.w_count==W_FIFO_DEPTH);
`endif
        send_aw(4'h1,32'h1300_0000,8'd3,AXI_SIZE,2'b01);
        wait_tx(tags[0]);
        check("FIFO-buffered burst 0 payload correct",
              tx_valid && tx_type==0 && tx_len==4 && tx_data===expected_payload);
        accept_tx();
        // B for burst 0 is now pending; the next AW must still be accepted.
        @(negedge clk);
        check("B response pending before pipelined AW",bvalid);
        send_aw(4'h2,32'h1300_0100,8'd3,AXI_SIZE,2'b01);
        check("AW accepted while previous B is pending",bvalid);
        consume_write_response(4'h1,2'b00);
        wait_tx(tags[0]);
        check("FIFO-buffered burst 1 payload correct",
              tx_valid && tx_type==0 && tx_len==4 && tx_data===read_payload[0]);
        accept_tx();
        consume_write_response(4'h2,2'b00);
`ifdef GATE_LEVEL
        check("W FIFO drained and WREADY restored",wready);
`else
        check("W FIFO drained and WREADY restored",wready && dut.w_count==0);
`endif
        cov_wfirst_bursts=cov_wfirst_bursts+2;
        cov_wlen4=cov_wlen4+2;

        // ---------------------------------------------------------------
        // Reset while an AXI B response is stalled by BREADY=0.
        send_aw(4'ha,32'h6300_0000,8'd0,AXI_SIZE,2'b01);
        send_w(32'haaaa_0001,4'hf,1'b1);
        wait_tx(tags[0]);
        accept_tx();
        cycles=0;
        while (!bvalid && cycles<50) begin @(negedge clk); cycles=cycles+1; end
        repeat(3) tick;
        check("B stalled before reset",bvalid && !bready);
        @(negedge clk); rst_n=0;
        repeat(2) tick;
        check("reset clears stalled B response",!bvalid && !tx_valid);
        @(negedge clk); rst_n=1;
        repeat(2) tick;
        send_aw(4'ha,32'h6300_0040,8'd0,AXI_SIZE,2'b01);
        send_w(32'haaaa_0002,4'hf,1'b1);
        wait_tx(tags[0]);
        check("write recovers after B-stall reset",tx_valid && tx_type==0 && tx_data[31:0]==32'haaaa_0002);
        accept_tx();
        consume_write_response(4'ha,2'b00);
        cov_reset_active=cov_reset_active+1;

        // Reset while an AXI R burst is stalled mid-burst by RREADY=0.
        send_ar(4'hb,32'h6400_0000,8'd1,AXI_SIZE,2'b01);
        wait_tx(tags[0]);
        accept_tx();
        expected_payload=0;
        expected_payload[31:0]=32'hbbbb_0000; expected_payload[63:32]=32'hbbbb_0001;
        send_completion(tags[0],expected_payload,2'b00);
        consume_read_beat(4'hb,32'hbbbb_0000,2'b00,1'b0);
        repeat(3) tick;
        check("R stalled mid-burst before reset",rvalid && !rready);
        @(negedge clk); rst_n=0;
        repeat(2) tick;
        check("reset clears stalled R response",!rvalid && !tx_valid);
        @(negedge clk); rst_n=1;
        repeat(2) tick;
        send_ar(4'hb,32'h6400_0040,8'd0,AXI_SIZE,2'b01);
        wait_tx(tags[0]);
        accept_tx();
        expected_payload=0; expected_payload[31:0]=32'hbbbb_0002;
        send_completion(tags[0],expected_payload,2'b00);
        consume_read_beat(4'hb,32'hbbbb_0002,2'b00,1'b1);
        cov_reset_active=cov_reset_active+1;

        // ---------------------------------------------------------------
        // Concurrent mixed read/write traffic. Independent threads drive AW/W,
        // AR, accept TX with random stalls, return completions out of order
        // with random delays, and consume R/B with random stalls. Scoreboards
        // check MemWr order/payload, MemRd address/length, R data/ID order and
        // B ID order. NR_MIX > TAG_COUNT forces tag reuse.
        for (wn=0;wn<NW_MIX;wn=wn+1) begin
            mw_len[wn]=1+($random(seed) & 32'h7fffffff)%MAX_BEATS;
            mw_id[wn]=wn%16;
            mw_addr[wn]=32'h7000_0000 + wn*32'h40;
            mw_data[wn]=0;
            for (wk=0;wk<mw_len[wn];wk=wk+1) mw_data[wn][wk*32 +: 32]=$random(seed);
        end
        for (rn=0;rn<NR_MIX;rn=rn+1) begin
            mr_len[rn]=1+($random(seed) & 32'h7fffffff)%MAX_BEATS;
            mr_id[rn]=(rn+5)%16;
            mr_addr[rn]=32'h8000_0000 + rn*32'h40;
            mr_matched[rn]=0;
        end
        pend_cnt=0; mw_tlp_seen=0; mr_issued=0; mr_sent=0; cpl_sent=0;
        fork
            // AW/W producer: random AW-vs-W skew, W sometimes fully first.
            begin
                for (wn=0;wn<NW_MIX;wn=wn+1) begin
                    gap=($random(seed) & 32'h7fffffff)%3;
                    fork
                        begin
                            repeat(gap) tick;
                            send_aw(mw_id[wn],mw_addr[wn],mw_len[wn]-1,AXI_SIZE,2'b01);
                        end
                        begin
                            for (wk=0;wk<mw_len[wn];wk=wk+1)
                                send_w(mw_data[wn][wk*32 +: 32],4'hf,(wk==mw_len[wn]-1));
                        end
                    join
                    if (gap!=0) cov_wfirst_bursts=cov_wfirst_bursts+1;
                    case (mw_len[wn])
                        1: cov_wlen1=cov_wlen1+1;
                        2: cov_wlen2=cov_wlen2+1;
                        3: cov_wlen3=cov_wlen3+1;
                        4: cov_wlen4=cov_wlen4+1;
                    endcase
                end
            end
            // AR producer.
            begin
                for (rn=0;rn<NR_MIX;rn=rn+1) begin
                    repeat(($random(seed) & 32'h7fffffff)%3) tick;
                    send_ar(mr_id[rn],mr_addr[rn],mr_len[rn]-1,AXI_SIZE,2'b01);
                    mr_issued=rn+1;
                    case (mr_len[rn])
                        1: cov_len1=cov_len1+1;
                        2: cov_len2=cov_len2+1;
                        3: cov_len3=cov_len3+1;
                        4: cov_len4=cov_len4+1;
                    endcase
                end
            end
            // TX endpoint: random READY stalls, MemWr/MemRd scoreboards.
            begin
                while (!(mw_tlp_seen==NW_MIX && mr_sent==NR_MIX)) begin
                    @(negedge clk);
                    if (tx_valid) begin
                        cap_type=tx_type; cap_addr=tx_addr; cap_len=tx_len;
                        cap_tag=tx_tag; cap_data=tx_data;
                        accept_tx();
                        if (cap_type==1'b0) begin
                            check("mixed: MemWr in AW order with correct addr/len/data",
                                  mw_tlp_seen<NW_MIX &&
                                  cap_addr==mw_addr[mw_tlp_seen] &&
                                  cap_len==mw_len[mw_tlp_seen] &&
                                  cap_data===mw_data[mw_tlp_seen]);
                            mw_tlp_seen=mw_tlp_seen+1;
                        end else begin
                            found=0;
                            for (tn=0;tn<NR_MIX;tn=tn+1)
                                if (!found && !mr_matched[tn] && tn<mr_issued &&
                                    mr_addr[tn]==cap_addr && mr_len[tn]==cap_len) begin
                                    found=1; mr_matched[tn]=1;
                                end
                            check("mixed: MemRd matches an issued AR (addr/len)",found);
                            pend_tag[pend_cnt]=cap_tag;
                            pend_addr[pend_cnt]=cap_addr;
                            pend_len[pend_cnt]=cap_len;
                            pend_cnt=pend_cnt+1;
                            mr_sent=mr_sent+1;
                        end
                    end
                end
            end
            // Completion endpoint: random delay, random (out-of-order) pick.
            begin
                while (cpl_sent<NR_MIX) begin
                    @(negedge clk);
                    if (pend_cnt>0) begin
                        // Endpoint latency of 0..11 cycles lets several
                        // requests accumulate so reordering is exercised.
                        cdly=($random(seed) & 32'h7fffffff)%12;
                        repeat(cdly) tick;
                        // pend_* is kept oldest-first; index 0 is in order.
                        cidx=($random(seed) & 32'h7fffffff)%pend_cnt;
                        if (cidx!=0) cov_out_of_order=cov_out_of_order+1;
                        cpl_payload=0;
                        for (cn=0;cn<pend_len[cidx];cn=cn+1)
                            cpl_payload[cn*32 +: 32]=mem_word(pend_addr[cidx]+cn*4);
                        // cpl_tag is private to this thread: the TX thread
                        // owns cap_* across its accept_tx() delay.
                        cpl_tag=pend_tag[cidx];
                        for (cn=cidx;cn<pend_cnt-1;cn=cn+1) begin
                            pend_tag[cn]=pend_tag[cn+1];
                            pend_addr[cn]=pend_addr[cn+1];
                            pend_len[cn]=pend_len[cn+1];
                        end
                        pend_cnt=pend_cnt-1;
                        send_completion(cpl_tag,cpl_payload,2'b00);
                        cpl_sent=cpl_sent+1;
                    end
                end
            end
            // R consumer: data/ID/RLAST must follow AR order.
            begin
                for (rc=0;rc<NR_MIX;rc=rc+1) begin
                    while (mr_issued<=rc) @(negedge clk);
                    for (rk=0;rk<mr_len[rc];rk=rk+1)
                        consume_read_beat(mr_id[rc],mem_word(mr_addr[rc]+rk*4),2'b00,(rk==mr_len[rc]-1));
                    cov_random_reads=cov_random_reads+1;
                    cov_mixed_bursts=cov_mixed_bursts+1;
                    if (rc>=TAG_COUNT) cov_tag_reuse=cov_tag_reuse+1;
                end
            end
            // B consumer: IDs must follow AW order.
            begin
                for (bc=0;bc<NW_MIX;bc=bc+1) begin
                    consume_write_response(mw_id[bc],2'b00);
                    cov_random_writes=cov_random_writes+1;
                    cov_mixed_bursts=cov_mixed_bursts+1;
                end
            end
        join
        check("mixed: every MemWr observed",mw_tlp_seen==NW_MIX);
        check("mixed: every MemRd observed and completed",mr_sent==NR_MIX && cpl_sent==NR_MIX);
        repeat(4) tick;
        check("mixed: bridge idle after concurrent traffic",
              !tx_valid && !bvalid && !rvalid && awready && arready);

        $display("");
        $display("================ FUNCTIONAL COVERAGE ================");
        $display("Read  burst length 1/2/3/4 : %0d / %0d / %0d / %0d",cov_len1,cov_len2,cov_len3,cov_len4);
        $display("Write burst length 1/2/3/4 : %0d / %0d / %0d / %0d",cov_wlen1,cov_wlen2,cov_wlen3,cov_wlen4);
        $display("W-before-AW bursts   : %0d",cov_wfirst_bursts);
        $display("W FIFO full cycles   : %0d",cov_fifo_full_cycles);
        $display("AW while B pending   : %0d",cov_aw_while_b_pending);
        $display("Late-WLAST rejects   : %0d",cov_late_wlast);
        $display("Mixed concurrent bursts: %0d",cov_mixed_bursts);
        $display("Tag-reuse read bursts: %0d",cov_tag_reuse);
        $display("TX stall cycles      : %0d",cov_tx_stall_cycles);
        $display("R stall cycles       : %0d",cov_r_stall_cycles);
        $display("B stall cycles       : %0d",cov_b_stall_cycles);
        $display("Random read bursts   : %0d",cov_random_reads);
        $display("Random write bursts  : %0d",cov_random_writes);
        $display("Packet profile bursts: %0d",cov_packet_profile);
        $display("ML profile batches   : %0d",cov_ml_profile);
        $display("Malformed tests      : %0d",cov_malformed);
        $display("Reset-during-activity: %0d",cov_reset_active);
        $display("Out-of-order completions: %0d",cov_out_of_order);
        $display("Tag-exhaustion tests  : %0d",cov_tag_exhaustion);
        $display("Boundary rejects     : %0d",cov_boundary_reject);
        $display("Stale completion tests: %0d",cov_stale_cpl);
        $display("=====================================================");
        $display("Assertion checks=%0d assertion failures=%0d (X-on-VALID=%0d, W-FIFO=%0d, stall-stability=%0d)",
                 assertion_checks,assertion_failures,assert_x_checks,assert_fifo_checks,
                 assertion_checks-assert_x_checks-assert_fifo_checks);
        $display("Seed: 0x%08h",start_seed);
        $display("REGRESSION SUMMARY: checks=%0d passed=%0d failed=%0d",checks,passes,failures);
        if (failures==0 && assertion_failures==0)
            $display("RESULT: ALL PHASE 3 CHECKS PASSED");
        else
            $display("RESULT: PHASE 3 REGRESSION FAILED");
        $display("Coverage counters are scenario counters, not a formal coverage percentage.");
        $display("Traffic profiles are abstract workload models, not PCIe/ML application compliance.");
        $display("=====================================================");
        $finish;
    end

    initial begin
        #500000;
        failures=failures+1;
        $display("FAIL | GLOBAL SIMULATION TIMEOUT");
        $display("REGRESSION SUMMARY AT TIMEOUT: checks=%0d passed=%0d failed=%0d",checks,passes,failures);
        $display("RESULT: PHASE 3 REGRESSION FAILED");
        $finish;
    end
endmodule
