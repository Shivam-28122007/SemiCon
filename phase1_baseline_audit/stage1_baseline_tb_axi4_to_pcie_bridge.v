`timescale 1ns/1ps

// ============================================================================
// Self-checking Stage-1 testbench for axi4_to_pcie_bridge
// Covers:
//   1. Reset
//   2. Single-beat AXI write
//   3. AXI write with independent AW/W timing
//   4. AXI write burst (one PCIe TLP per beat)
//   5. Partial WSTRB -> SLVERR
//   6. Single-beat AXI read + successful CplD
//   7. Read TX backpressure
//   8. Read burst with multiple completions
//   9. Completion error -> AXI SLVERR
//  10. Wrong completion tag is not consumed
// ============================================================================

module tb_axi4_to_pcie_bridge;

    parameter DATA_WIDTH = 64;
    parameter ADDR_WIDTH = 32;
    parameter ID_WIDTH   = 4;

    reg clk;
    reg rst_n;

    reg [ID_WIDTH-1:0] s_axi_awid;
    reg [ADDR_WIDTH-1:0] s_axi_awaddr;
    reg [7:0] s_axi_awlen;
    reg [2:0] s_axi_awsize;
    reg [1:0] s_axi_awburst;
    reg s_axi_awvalid;
    wire s_axi_awready;

    reg [DATA_WIDTH-1:0] s_axi_wdata;
    reg [(DATA_WIDTH/8)-1:0] s_axi_wstrb;
    reg s_axi_wlast;
    reg s_axi_wvalid;
    wire s_axi_wready;

    wire [ID_WIDTH-1:0] s_axi_bid;
    wire [1:0] s_axi_bresp;
    wire s_axi_bvalid;
    reg s_axi_bready;

    reg [ID_WIDTH-1:0] s_axi_arid;
    reg [ADDR_WIDTH-1:0] s_axi_araddr;
    reg [7:0] s_axi_arlen;
    reg [2:0] s_axi_arsize;
    reg [1:0] s_axi_arburst;
    reg s_axi_arvalid;
    wire s_axi_arready;

    wire [ID_WIDTH-1:0] s_axi_rid;
    wire [DATA_WIDTH-1:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rlast;
    wire s_axi_rvalid;
    reg s_axi_rready;

    wire tx_tlp_valid;
    reg tx_tlp_ready;
    wire [4:0] tx_tlp_type;
    wire [ADDR_WIDTH-1:0] tx_tlp_addr;
    wire [9:0] tx_tlp_length;
    wire [7:0] tx_tlp_tag;
    wire [DATA_WIDTH-1:0] tx_tlp_data;
    wire tx_tlp_sop;
    wire tx_tlp_eop;

    reg rx_cpl_valid;
    wire rx_cpl_ready;
    reg [7:0] rx_cpl_tag;
    reg [DATA_WIDTH-1:0] rx_cpl_data;
    reg [1:0] rx_cpl_status;
    reg rx_cpl_eop;

    integer errors;
    integer pass_count;

    localparam [4:0] TLP_MEM_WR = 5'b00000;
    localparam [4:0] TLP_MEM_RD = 5'b00001;

    axi4_to_pcie_bridge #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .tx_tlp_valid(tx_tlp_valid), .tx_tlp_ready(tx_tlp_ready),
        .tx_tlp_type(tx_tlp_type), .tx_tlp_addr(tx_tlp_addr),
        .tx_tlp_length(tx_tlp_length), .tx_tlp_tag(tx_tlp_tag),
        .tx_tlp_data(tx_tlp_data), .tx_tlp_sop(tx_tlp_sop),
        .tx_tlp_eop(tx_tlp_eop),
        .rx_cpl_valid(rx_cpl_valid), .rx_cpl_ready(rx_cpl_ready),
        .rx_cpl_tag(rx_cpl_tag), .rx_cpl_data(rx_cpl_data),
        .rx_cpl_status(rx_cpl_status), .rx_cpl_eop(rx_cpl_eop)
    );

    always #5 clk = ~clk;

    task fail;
        input [8*100-1:0] msg;
        begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    task pass;
        input [8*100-1:0] msg;
        begin
            pass_count = pass_count + 1;
            $display("PASS: %0s", msg);
        end
    endtask

    task drive_defaults;
        begin
            s_axi_awid = 0; s_axi_awaddr = 0; s_axi_awlen = 0;
            s_axi_awsize = 3'b011; s_axi_awburst = 2'b01; s_axi_awvalid = 0;
            s_axi_wdata = 0; s_axi_wstrb = 8'hFF; s_axi_wlast = 0; s_axi_wvalid = 0;
            s_axi_bready = 0;
            s_axi_arid = 0; s_axi_araddr = 0; s_axi_arlen = 0;
            s_axi_arsize = 3'b011; s_axi_arburst = 2'b01; s_axi_arvalid = 0;
            s_axi_rready = 0;
            tx_tlp_ready = 0;
            rx_cpl_valid = 0; rx_cpl_tag = 0; rx_cpl_data = 0;
            rx_cpl_status = 0; rx_cpl_eop = 0;
        end
    endtask

    task reset_dut;
        begin
            rst_n = 0;
            repeat (3) @(posedge clk);
            if (s_axi_bvalid || s_axi_rvalid || tx_tlp_valid)
                fail("Reset did not clear valid outputs");
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    // Drive a complete AXI write address + data transaction. The task waits
    // for the actual AXI handshakes, not merely for READY to become high.
    task axi_write_single;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input [DATA_WIDTH/8-1:0] strb;
        begin
            @(negedge clk);
            s_axi_awid = id; s_axi_awaddr = addr; s_axi_awlen = 0;
            s_axi_awsize = 3'b011; s_axi_awburst = 2'b01; s_axi_awvalid = 1;
            s_axi_wdata = data; s_axi_wstrb = strb; s_axi_wlast = 1; s_axi_wvalid = 1;
            while (!(s_axi_awready && s_axi_wready)) @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 0;
            s_axi_wvalid = 0;
            s_axi_wlast = 0;
        end
    endtask

    task check_write_tlp;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            wait (tx_tlp_valid);
            if (tx_tlp_type !== TLP_MEM_WR) fail("Write TLP type incorrect");
            else pass("Write TLP type = MemWr");
            if (tx_tlp_addr !== addr) fail("Write TLP address incorrect");
            else pass("Write TLP address correct");
            if (tx_tlp_length !== 10'd2) fail("Write TLP length incorrect");
            else pass("Write TLP length = 2 DW");
            if (tx_tlp_tag !== {4'b0,id}) fail("Write TLP tag incorrect");
            else pass("Write TLP tag correct");
            if (tx_tlp_data !== data) fail("Write TLP payload incorrect");
            else pass("Write TLP payload correct");
            if (!(tx_tlp_sop && tx_tlp_eop)) fail("Write TLP SOP/EOP incorrect");
            else pass("Write TLP SOP/EOP correct");
        end
    endtask

    task complete_write;
        input [ID_WIDTH-1:0] id;
        input [1:0] expected_resp;
        begin
            @(negedge clk);
            tx_tlp_ready = 1;
            wait (s_axi_bvalid);
            if (s_axi_bid !== id) fail("BID incorrect");
            if (s_axi_bresp !== expected_resp) fail("BRESP incorrect");
            else pass("AXI write response correct");
            @(negedge clk);
            s_axi_bready = 1;
            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 0;
            tx_tlp_ready = 0;
        end
    endtask

    task axi_read_single;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        begin
            @(negedge clk);
            s_axi_arid = id; s_axi_araddr = addr; s_axi_arlen = 0;
            s_axi_arsize = 3'b011; s_axi_arburst = 2'b01; s_axi_arvalid = 1;
            while (!s_axi_arready) @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_arvalid = 0;
        end
    endtask

    task check_read_tlp;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        begin
            wait (tx_tlp_valid);
            if (tx_tlp_type !== TLP_MEM_RD) fail("Read TLP type incorrect");
            else pass("Read TLP type = MemRd");
            if (tx_tlp_addr !== addr) fail("Read TLP address incorrect");
            else pass("Read TLP address correct");
            if (tx_tlp_length !== 10'd2) fail("Read TLP length incorrect");
            else pass("Read TLP length = 2 DW");
            if (tx_tlp_tag !== {4'b0,id}) fail("Read TLP tag incorrect");
            else pass("Read TLP tag correct");
            if (!(tx_tlp_sop && tx_tlp_eop)) fail("Read TLP SOP/EOP incorrect");
            else pass("Read TLP SOP/EOP correct");
        end
    endtask

    task send_completion;
        input [7:0] tag;
        input [DATA_WIDTH-1:0] data;
        input [1:0] status;
        input eop;
        begin
            @(negedge clk);
            rx_cpl_tag = tag;
            rx_cpl_data = data;
            rx_cpl_status = status;
            rx_cpl_eop = eop;
            rx_cpl_valid = 1;
            while (!rx_cpl_ready) @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            rx_cpl_valid = 0;
        end
    endtask

    initial begin
        $dumpfile("bridge_stage1.vcd");
        $dumpvars(0, tb_axi4_to_pcie_bridge);

        clk = 0;
        errors = 0;
        pass_count = 0;
        drive_defaults;

        // TEST 1 -----------------------------------------------------------
        $display("\n=== TEST 1: Reset ===");
        reset_dut;
        pass("Reset sequence completed");

        // TEST 2 -----------------------------------------------------------
        $display("\n=== TEST 2: Single-beat AXI Write ===");
        axi_write_single(4'h1, 32'hA000_1000, 64'hDEAD_BEEF_CAFE_0001, 8'hFF);
        check_write_tlp(4'h1, 32'hA000_1000, 64'hDEAD_BEEF_CAFE_0001);
        complete_write(4'h1, 2'b00);

        // TEST 3 -----------------------------------------------------------
        $display("\n=== TEST 3: Independent AW/W Timing ===");
        @(negedge clk);
        s_axi_awid = 4'h2; s_axi_awaddr = 32'hA000_2000; s_axi_awlen = 0;
        s_axi_awsize = 3'b011; s_axi_awburst = 2'b01; s_axi_awvalid = 1;
        while (!s_axi_awready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        s_axi_awvalid = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        s_axi_wdata = 64'h1111_2222_3333_4444; s_axi_wstrb = 8'hFF;
        s_axi_wlast = 1; s_axi_wvalid = 1;
        while (!s_axi_wready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        s_axi_wvalid = 0; s_axi_wlast = 0;
        check_write_tlp(4'h2, 32'hA000_2000, 64'h1111_2222_3333_4444);
        complete_write(4'h2, 2'b00);
        pass("AW and W accepted independently");

        // TEST 4 -----------------------------------------------------------
        $display("\n=== TEST 4: 3-beat AXI Write Burst ===");
        @(negedge clk);
        s_axi_awid = 4'h3; s_axi_awaddr = 32'hA000_3000; s_axi_awlen = 2;
        s_axi_awsize = 3'b011; s_axi_awburst = 2'b01; s_axi_awvalid = 1;
        while (!s_axi_awready) @(posedge clk);
        @(posedge clk);
        @(negedge clk); s_axi_awvalid = 0;

        // Beat 0
        s_axi_wdata = 64'h0000_0000_0000_0001; s_axi_wstrb = 8'hFF;
        s_axi_wlast = 0; s_axi_wvalid = 1;
        while (!s_axi_wready) @(posedge clk);
        @(posedge clk); @(negedge clk); s_axi_wvalid = 0;
        check_write_tlp(4'h3, 32'hA000_3000, 64'h1);
        @(negedge clk); tx_tlp_ready = 1;
        wait (tx_tlp_valid); @(posedge clk); @(negedge clk); tx_tlp_ready = 0;

        // Beat 1
        s_axi_wdata = 64'h0000_0000_0000_0002; s_axi_wstrb = 8'hFF;
        s_axi_wlast = 0; s_axi_wvalid = 1;
        while (!s_axi_wready) @(posedge clk);
        @(posedge clk); @(negedge clk); s_axi_wvalid = 0;
        check_write_tlp(4'h3, 32'hA000_3008, 64'h2);
        @(negedge clk); tx_tlp_ready = 1;
        wait (tx_tlp_valid); @(posedge clk); @(negedge clk); tx_tlp_ready = 0;

        // Beat 2
        s_axi_wdata = 64'h0000_0000_0000_0003; s_axi_wstrb = 8'hFF;
        s_axi_wlast = 1; s_axi_wvalid = 1;
        while (!s_axi_wready) @(posedge clk);
        @(posedge clk); @(negedge clk); s_axi_wvalid = 0; s_axi_wlast = 0;
        check_write_tlp(4'h3, 32'hA000_3010, 64'h3);
        complete_write(4'h3, 2'b00);
        pass("3-beat AXI INCR burst converted to 3 MemWr TLPs");

        // TEST 5 -----------------------------------------------------------
        $display("\n=== TEST 5: Partial WSTRB Error ===");
        axi_write_single(4'h4, 32'hA000_4000, 64'hAAAA_BBBB_CCCC_DDDD, 8'h0F);
        wait (s_axi_bvalid);
        if (tx_tlp_valid) fail("Partial WSTRB incorrectly generated a PCIe TLP");
        if (s_axi_bresp !== 2'b10) fail("Partial WSTRB did not return SLVERR");
        else pass("Partial WSTRB correctly rejected with SLVERR");
        @(negedge clk); s_axi_bready = 1; @(posedge clk); @(negedge clk); s_axi_bready = 0;

        // TEST 6 -----------------------------------------------------------
        $display("\n=== TEST 6: Single-beat AXI Read + Successful CplD ===");
        axi_read_single(4'h5, 32'hB000_2000);
        check_read_tlp(4'h5, 32'hB000_2000);

        // Backpressure: TX must remain valid until READY.
        if (!tx_tlp_valid) fail("Read TLP valid not asserted");
        @(negedge clk); tx_tlp_ready = 0;
        repeat (2) @(posedge clk);
        if (!tx_tlp_valid) fail("TX valid was not held under backpressure");
        else pass("TX valid held under backpressure");
        @(negedge clk); tx_tlp_ready = 1;
        @(posedge clk); @(negedge clk); tx_tlp_ready = 0;

        send_completion(8'h05, 64'h1234_5678_9ABC_DEF0, 2'b00, 1'b1);
        wait (s_axi_rvalid);
        if (s_axi_rid !== 4'h5) fail("RID incorrect for successful CplD");
        if (s_axi_rdata !== 64'h1234_5678_9ABC_DEF0) fail("RDATA incorrect for successful CplD");
        if (s_axi_rresp !== 2'b00) fail("RRESP should be OKAY");
        if (!s_axi_rlast) fail("RLAST should be asserted for single-beat read");
        else pass("Successful CplD correctly returned on AXI R channel");
        @(negedge clk); s_axi_rready = 1; @(posedge clk); @(negedge clk); s_axi_rready = 0;

        // TEST 7 -----------------------------------------------------------
        $display("\n=== TEST 7: Read Burst with Multiple Completions ===");
        @(negedge clk);
        s_axi_arid = 4'h6; s_axi_araddr = 32'hB000_3000; s_axi_arlen = 1;
        s_axi_arsize = 3'b011; s_axi_arburst = 2'b01; s_axi_arvalid = 1;
        while (!s_axi_arready) @(posedge clk);
        @(posedge clk); @(negedge clk); s_axi_arvalid = 0;
        check_read_tlp(4'h6, 32'hB000_3000);
        @(negedge clk); tx_tlp_ready = 1; @(posedge clk); @(negedge clk); tx_tlp_ready = 0;

        send_completion(8'h06, 64'hAAAA_0000_0000_0001, 2'b00, 1'b0);
        wait (s_axi_rvalid);
        if (s_axi_rlast) fail("First beat of read burst incorrectly marked RLAST");
        if (s_axi_rdata !== 64'hAAAA_0000_0000_0001) fail("Read burst beat 0 data mismatch");
        else pass("Read burst beat 0 received correctly");
        @(negedge clk); s_axi_rready = 1; @(posedge clk); @(negedge clk); s_axi_rready = 0;

        check_read_tlp(4'h6, 32'hB000_3008);
        @(negedge clk); tx_tlp_ready = 1; @(posedge clk); @(negedge clk); tx_tlp_ready = 0;
        send_completion(8'h06, 64'hBBBB_0000_0000_0002, 2'b00, 1'b1);
        wait (s_axi_rvalid);
        if (!s_axi_rlast) fail("Last beat of read burst did not assert RLAST");
        if (s_axi_rdata !== 64'hBBBB_0000_0000_0002) fail("Read burst beat 1 data mismatch");
        else pass("Read burst final beat received correctly");
        @(negedge clk); s_axi_rready = 1; @(posedge clk); @(negedge clk); s_axi_rready = 0;

        // TEST 8 -----------------------------------------------------------
        $display("\n=== TEST 8: Completion Error -> AXI SLVERR ===");
        axi_read_single(4'h7, 32'hB000_4000);
        check_read_tlp(4'h7, 32'hB000_4000);
        @(negedge clk); tx_tlp_ready = 1; @(posedge clk); @(negedge clk); tx_tlp_ready = 0;
        send_completion(8'h07, 64'h0, 2'b01, 1'b1);
        wait (s_axi_rvalid);
        if (s_axi_rresp !== 2'b10) fail("PCIe error status was not mapped to AXI SLVERR");
        else pass("PCIe completion error mapped to AXI SLVERR");
        @(negedge clk); s_axi_rready = 1; @(posedge clk); @(negedge clk); s_axi_rready = 0;

        // TEST 9 -----------------------------------------------------------
        $display("\n=== TEST 9: Wrong Completion Tag Rejection ===");
        axi_read_single(4'h8, 32'hB000_5000);
        check_read_tlp(4'h8, 32'hB000_5000);
        @(negedge clk); tx_tlp_ready = 1; @(posedge clk); @(negedge clk); tx_tlp_ready = 0;

        @(negedge clk);
        rx_cpl_tag = 8'h09;
        rx_cpl_data = 64'h9999_9999_9999_9999;
        rx_cpl_status = 2'b00;
        rx_cpl_eop = 1'b1;
        rx_cpl_valid = 1'b1;
        repeat (2) @(posedge clk);
        if (rx_cpl_ready) fail("Bridge accepted a completion with the wrong tag");
        if (s_axi_rvalid) fail("Wrong-tag completion reached AXI R channel");
        else pass("Wrong completion tag correctly rejected");
        @(negedge clk); rx_cpl_valid = 0;

        // Correct completion after wrong-tag attempt.
        send_completion(8'h08, 64'h8888_7777_6666_5555, 2'b00, 1'b1);
        wait (s_axi_rvalid);
        if (s_axi_rdata !== 64'h8888_7777_6666_5555) fail("Correct completion was not accepted");
        else pass("Correct completion accepted after wrong-tag attempt");
        @(negedge clk); s_axi_rready = 1; @(posedge clk); @(negedge clk); s_axi_rready = 0;

        // Final result -----------------------------------------------------
        $display("\n============================================================");
        $display("Stage-1 Verification Summary");
        $display("PASS checks : %0d", pass_count);
        $display("FAIL checks : %0d", errors);
        if (errors == 0)
            $display("RESULT      : ALL TESTS PASSED");
        else
            $display("RESULT      : TESTS FAILED");
        $display("============================================================\n");

        $finish;
    end

endmodule
