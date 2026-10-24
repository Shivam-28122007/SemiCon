`timescale 1ns/1ps
module tb_sarcathon_axi_pcie_bridge;
    localparam DATA_WIDTH=32;
    localparam ADDR_WIDTH=32;
    localparam ID_WIDTH=4;
    localparam MAX_BEATS=4;
    localparam TAG_COUNT=4;
    localparam W_FIFO_DEPTH=8;

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

    sarcathon_axi_pcie_bridge #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH), .MAX_BEATS(MAX_BEATS),
        .TAG_COUNT(TAG_COUNT), .W_FIFO_DEPTH(W_FIFO_DEPTH)
    ) dut (
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

    integer tests=0, passed=0, failed=0;
    integer cycles;
    reg [7:0] tag0, tag1;
    reg [DATA_WIDTH*MAX_BEATS-1:0] expected_payload;

    task report;
        input [8*100-1:0] name;
        input condition;
        begin
            tests=tests+1;
            if (condition) begin
                passed=passed+1;
                $display("PASS | %0s", name);
            end else begin
                failed=failed+1;
                $display("FAIL | %0s", name);
            end
        end
    endtask

    task defaults;
        begin
            awid=0; awaddr=0; awlen=0; awsize=2; awburst=1; awvalid=0;
            wdata=0; wstrb=4'hf; wlast=0; wvalid=0;
            bready=0;
            arid=0; araddr=0; arlen=0; arsize=2; arburst=1; arvalid=0;
            rready=0;
            tx_ready=0;
            rx_valid=0; rx_tag=0; rx_data=0; rx_status=0;
        end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    task send_aw;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        begin
            @(negedge clk);
            awid=id; awaddr=addr; awlen=len; awsize=size; awburst=burst; awvalid=1;
            cycles=0;
            while (!awready && cycles<30) begin tick; cycles=cycles+1; end
            if (awready) tick;
            @(negedge clk); awvalid=0;
        end
    endtask

    task send_w;
        input [DATA_WIDTH-1:0] data;
        input [DATA_WIDTH/8-1:0] strb;
        input last;
        begin
            @(negedge clk);
            wdata=data; wstrb=strb; wlast=last; wvalid=1;
            cycles=0;
            while (!wready && cycles<30) begin tick; cycles=cycles+1; end
            if (wready) tick;
            @(negedge clk); wvalid=0;
        end
    endtask

    task send_ar;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        begin
            @(negedge clk);
            arid=id; araddr=addr; arlen=len; arsize=size; arburst=burst; arvalid=1;
            cycles=0;
            while (!arready && cycles<30) begin tick; cycles=cycles+1; end
            if (arready) tick;
            @(negedge clk); arvalid=0;
        end
    endtask

    task wait_tx;
        output [7:0] got_tag;
        begin
            cycles=0;
            while (!tx_valid && cycles<60) begin tick; cycles=cycles+1; end
            got_tag=tx_tag;
        end
    endtask

    task accept_tx;
        begin
            @(negedge clk); tx_ready=1;
            tick;
            @(negedge clk); tx_ready=0;
        end
    endtask

    task send_completion;
        input [7:0] tag;
        input [DATA_WIDTH*MAX_BEATS-1:0] data;
        input [1:0] status;
        begin
            @(negedge clk); rx_tag=tag; rx_data=data; rx_status=status; rx_valid=1;
            cycles=0;
            while (!rx_ready && cycles<30) begin tick; cycles=cycles+1; end
            if (rx_ready) tick;
            @(negedge clk); rx_valid=0;
        end
    endtask

    task wait_bresp;
        input [ID_WIDTH-1:0] exp_id;
        input [1:0] exp_resp;
        begin
            cycles=0;
            while (!bvalid && cycles<80) begin tick; cycles=cycles+1; end
            report("write response arrives", bvalid);
            if (bvalid) begin
                report("write response ID matches", bid==exp_id);
                report("write response code matches", bresp==exp_resp);
                @(negedge clk); bready=1; tick;
                @(negedge clk); bready=0;
            end
        end
    endtask

    task read_beat;
        input [ID_WIDTH-1:0] exp_id;
        input [DATA_WIDTH-1:0] exp_data;
        input [1:0] exp_resp;
        input exp_last;
        begin
            cycles=0;
            while (!rvalid && cycles<80) begin tick; cycles=cycles+1; end
            report("read beat becomes valid", rvalid);
            if (rvalid) begin
                report("read ID matches expected", rid==exp_id);
                report("read data matches expected", rdata==exp_data);
                report("read response matches expected", rresp==exp_resp);
                report("RLAST matches expected", rlast==exp_last);
                @(negedge clk); rready=1; tick;
                @(negedge clk); rready=0;
            end
        end
    endtask

    initial begin
        $display("==============================================================");
        $display("SARCathon Phase 2 AXI4-to-PCIe Bridge Self-Checking Testbench");
        $display("==============================================================");
        defaults();
        repeat(3) tick;
        rst_n=1;
        tick;
        report("reset releases with no TX packet", !tx_valid);
        report("reset releases with no B response", !bvalid);
        report("reset releases with no R response", !rvalid);

        // Test 1: three-beat write burst is coalesced into one TLP.
        send_aw(4'h3, 32'h1000_0000, 8'd2, 3'd2, 2'b01);
        send_w(32'h1122_3344, 4'hf, 0);
        send_w(32'h5566_7788, 4'hf, 0);
        send_w(32'h99aa_bbcc, 4'hf, 1);
        wait_tx(tag0);
        report("write burst emits TLP", tx_valid);
        report("write TLP type is MemWr", tx_type==0);
        report("write TLP address matches", tx_addr==32'h1000_0000);
        report("three beats coalesced into one TLP", tx_len==3);
        expected_payload=0;
        expected_payload[31:0]=32'h1122_3344;
        expected_payload[63:32]=32'h5566_7788;
        expected_payload[95:64]=32'h99aa_bbcc;
        report("coalesced write payload matches", tx_data==expected_payload);

        // Hold downstream READY low and verify packet fields remain stable.
        repeat(3) begin
            tick;
            report("TX VALID held under backpressure", tx_valid);
            report("TX payload stable under backpressure",
                   tx_addr==32'h1000_0000 && tx_len==3 && tx_data==expected_payload);
        end
        accept_tx();
        wait_bresp(4'h3, 2'b00);

        // Test 2: partial strobe is rejected and produces no write TLP.
        send_aw(4'h4, 32'h2000_0000, 8'd0, 3'd2, 2'b01);
        send_w(32'hdead_beef, 4'b0011, 1);
        cycles=0;
        while (!bvalid && cycles<50) begin tick; cycles=cycles+1; end
        report("partial WSTRB returns B response", bvalid);
        report("partial WSTRB returns SLVERR", bresp==2'b10);
        report("invalid write does not issue TLP", !tx_valid);
        if (bvalid) begin @(negedge clk); bready=1; tick; @(negedge clk); bready=0; end

        // Test 2b: W data can arrive before AW and is retained by the W FIFO.
        send_w(32'h1234_abcd, 4'hf, 1);
        send_aw(4'h2, 32'h2800_0000, 8'd0, 3'd2, 2'b01);
        wait_tx(tag0);
        report("W-before-AW data is buffered", tx_valid && tx_type==0);
        report("buffered W data reaches coalesced packet",
               tx_data[31:0]==32'h1234_abcd && tx_len==1);
        accept_tx();
        wait_bresp(4'h2, 2'b00);

        // Test 3: two outstanding reads; completions arrive out of order.
        send_ar(4'h5, 32'h3000_0000, 8'd1, 3'd2, 2'b01);
        send_ar(4'h6, 32'h4000_0000, 8'd0, 3'd2, 2'b01);

        wait_tx(tag0);
        report("first read request emits TLP", tx_valid && tx_type==1);
        report("first read burst length is two", tx_len==2);
        report("first read address matches", tx_addr==32'h3000_0000);
        accept_tx();

        wait_tx(tag1);
        report("second read request emits TLP", tx_valid && tx_type==1);
        report("second read address matches", tx_addr==32'h4000_0000);
        report("outstanding reads use distinct tags", tag0!=tag1);
        accept_tx();

        // Wrong/stale tag must not be accepted.
        @(negedge clk); rx_tag=8'hfe; rx_data=0; rx_status=0; rx_valid=1;
        #1;
        report("unknown completion tag is rejected", !rx_ready);
        @(negedge clk); rx_valid=0;

        // Complete second request first. AXI responses remain in AR order.
        expected_payload=0;
        expected_payload[31:0]=32'hbbbb_0002;
        send_completion(tag1, expected_payload, 2'b00);
        expected_payload=0;
        expected_payload[31:0]=32'haaaa_0001;
        expected_payload[63:32]=32'haaaa_0002;
        send_completion(tag0, expected_payload, 2'b00);

        read_beat(4'h5, 32'haaaa_0001, 2'b00, 0);
        read_beat(4'h5, 32'haaaa_0002, 2'b00, 1);
        read_beat(4'h6, 32'hbbbb_0002, 2'b00, 1);

        // Test 4: invalid read burst/size follows local one-beat SLVERR policy.
        send_ar(4'h7, 32'h5000_0000, 8'd0, 3'd1, 2'b01);
        read_beat(4'h7, 32'h0000_0000, 2'b10, 1);
        report("malformed read emits no PCIe request", !tx_valid);

        // Test 5: AXI R backpressure must preserve data and control.
        send_ar(4'h8, 32'h6000_0000, 8'd0, 3'd2, 2'b01);
        wait_tx(tag0);
        accept_tx();
        expected_payload=0;
        expected_payload[31:0]=32'hcafe_f00d;
        send_completion(tag0, expected_payload, 2'b00);
        cycles=0;
        while (!rvalid && cycles<50) begin tick; cycles=cycles+1; end
        report("R channel becomes valid for backpressure test", rvalid);
        if (rvalid) begin
            repeat(3) begin
                tick;
                report("R VALID held while RREADY low", rvalid);
                report("R payload stable while stalled",
                       rid==4'h8 && rdata==32'hcafe_f00d && rlast);
            end
            @(negedge clk); rready=1; tick; @(negedge clk); rready=0;
        end

        // Test 6: non-OK completion status maps to AXI SLVERR.
        send_ar(4'h9, 32'h7000_0000, 8'd0, 3'd2, 2'b01);
        wait_tx(tag0);
        report("error-status read request emits TLP", tx_valid && tx_type==1);
        accept_tx();
        expected_payload=0;
        expected_payload[31:0]=32'hface_1234;
        send_completion(tag0, expected_payload, 2'b01);
        read_beat(4'h9, 32'hface_1234, 2'b10, 1);

        $display("--------------------------------------------------------------");
        $display("TEST SUMMARY: total=%0d passed=%0d failed=%0d", tests, passed, failed);
        if (failed==0) $display("RESULT: ALL TESTS PASSED");
        else $display("RESULT: TESTS FAILED");
        $display("NOTE: Simulation is only a functional regression; it is not formal");
        $display("verification, PCIe compliance validation, or physical sign-off.");
        $display("==============================================================");
        $finish;
    end

    initial begin
        #200000;
        $display("FATAL: global simulation timeout");
        $display("TEST SUMMARY AT TIMEOUT: total=%0d passed=%0d failed=%0d", tests, passed, failed);
        $finish;
    end
endmodule
