//-----------------------------------------------------------------------------
// Testbench: acc_sram_bank - Accumulator SRAM Bank
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_acc_sram_bank;

    parameter DEPTH = 1024;
    parameter WIDTH = 118;
    localparam ADDR_W = $clog2(DEPTH);

    reg                    clk;
    reg                    rst_n;
    reg                    wr_en;
    reg  [ADDR_W-1:0]     wr_addr;
    reg  [WIDTH-1:0]      wr_data;
    reg                    rd_en;
    reg  [ADDR_W-1:0]     rd_addr;
    wire [WIDTH-1:0]      rd_data;
    wire                   rd_valid;

    acc_sram_bank #(.DEPTH(DEPTH), .WIDTH(WIDTH)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data),
        .rd_valid(rd_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer test_num = 0;
    integer i;

    task automatic write_mem(input [ADDR_W-1:0] addr, input [WIDTH-1:0] data);
    begin
        @(posedge clk);
        wr_en   <= 1'b1;
        wr_addr <= addr;
        wr_data <= data;
        @(posedge clk);
        wr_en   <= 1'b0;
    end
    endtask

    task automatic read_check(input [ADDR_W-1:0] addr, input [WIDTH-1:0] expected, input [8*40-1:0] label);
    begin
        @(posedge clk);
        rd_en   <= 1'b1;
        rd_addr <= addr;
        @(posedge clk);
        // 1-cycle read latency: rd_valid and rd_data update at this posedge
        // Sample after delta delay to see registered outputs
        #1;
        rd_en   <= 1'b0;
        test_num = test_num + 1;
        if (rd_valid && rd_data === expected) begin
            $display("PASS [%0d] %0s: addr=%0d, data=0x%0h", test_num, label, addr, rd_data);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] %0s: addr=%0d, data=0x%0h, expected=0x%0h, valid=%0b",
                     test_num, label, addr, rd_data, expected, rd_valid);
            fail_cnt = fail_cnt + 1;
        end
    end
    endtask

    initial begin
        $dumpfile("tb_acc_sram_bank.vcd");
        $dumpvars(0, tb_acc_sram_bank);

        rst_n   = 0;
        wr_en   = 0;
        wr_addr = 0;
        wr_data = 0;
        rd_en   = 0;
        rd_addr = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        //---------------------------------------------------------------------
        // Test 1: Basic write-then-read at a few addresses
        //---------------------------------------------------------------------
        write_mem(0,         118'hDEAD_BEEF_CAFE);
        write_mem(1,         118'h1234_5678_9ABC);
        write_mem(DEPTH - 1, 118'hFFFF_FFFF_FFFF);

        read_check(0,         118'hDEAD_BEEF_CAFE, "basic_addr0");
        read_check(1,         118'h1234_5678_9ABC, "basic_addr1");
        read_check(DEPTH - 1, 118'hFFFF_FFFF_FFFF, "basic_last_addr");

        //---------------------------------------------------------------------
        // Test 2: Write-first forwarding (simultaneous R/W same address)
        //---------------------------------------------------------------------
        @(posedge clk);
        wr_en   <= 1'b1;
        wr_addr <= 42;
        wr_data <= 118'hAAAA_BBBB_CCCC;
        rd_en   <= 1'b1;
        rd_addr <= 42;
        @(posedge clk);
        // 1-cycle latency: rd_valid and rd_data valid at this posedge
        #1;
        wr_en   <= 1'b0;
        rd_en   <= 1'b0;
        test_num = test_num + 1;
        if (rd_valid && rd_data === 118'hAAAA_BBBB_CCCC) begin
            $display("PASS [%0d] write_first_fwd: data=0x%0h", test_num, rd_data);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] write_first_fwd: data=0x%0h, expected=0xAAAABBBBCCCC, valid=%0b",
                     test_num, rd_data, rd_valid);
            fail_cnt = fail_cnt + 1;
        end

        //---------------------------------------------------------------------
        // Test 3: Write all entries, read all back
        //---------------------------------------------------------------------
        // Write phase
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            wr_en   <= 1'b1;
            wr_addr <= i[ADDR_W-1:0];
            // Pattern: addr * 7 + 13 (unique per address)
            wr_data <= ({118'b0} | i) * 118'd7 + 118'd13;
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // Read-back phase: issue reads sequentially, check with 1-cycle latency
        begin
            reg [WIDTH-1:0] exp;
            reg all_ok;
            integer err_count;
            integer check_addr;
            all_ok = 1;
            err_count = 0;

            // Issue first read
            @(posedge clk);
            rd_en   <= 1'b1;
            rd_addr <= 0;

            for (i = 1; i <= DEPTH; i = i + 1) begin
                @(posedge clk); #1;
                // Issue next read (or deassert on last iteration)
                if (i < DEPTH) begin
                    rd_addr <= i[ADDR_W-1:0];
                end else begin
                    rd_en <= 1'b0;
                end
                // After 1-cycle latency, check previous read result
                // rd_valid and rd_data are now valid for address (i-1)
                check_addr = i - 1;
                exp = ({118'b0} | check_addr) * 118'd7 + 118'd13;
                if (!(rd_valid && rd_data === exp)) begin
                    if (err_count < 10)
                        $display("  FAIL at addr %0d: got 0x%0h, expected 0x%0h, valid=%b", check_addr, rd_data, exp, rd_valid);
                    all_ok = 0;
                    err_count = err_count + 1;
                end
            end

            test_num = test_num + 1;
            if (all_ok) begin
                $display("PASS [%0d] full_depth_readback: all entries match", test_num);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] full_depth_readback: %0d errors", test_num, err_count);
                fail_cnt = fail_cnt + 1;
            end
        end

        //---------------------------------------------------------------------
        // Test 4: Overwrite and verify
        //---------------------------------------------------------------------
        write_mem(100, 118'd999);
        read_check(100, 118'd999, "overwrite");

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        $display("============================================");
        $display("tb_acc_sram_bank: %0d PASSED, %0d FAILED (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("SOME TESTS FAILED");
            $fatal(1, "tb_acc_sram_bank failed");
        end
        $display("============================================");
        $finish;
    end

endmodule
