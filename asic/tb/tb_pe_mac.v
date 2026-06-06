//-----------------------------------------------------------------------------
// Testbench: pe_mac - Stateless Multiply-Add Processing Element
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_pe_mac;

    parameter K     = 51;
    parameter ACC_W = 118;

    reg              clk;
    reg              rst_n;
    reg              valid_in;
    reg  [K-1:0]     coeff;
    reg  [K-1:0]     scalar;
    reg  [ACC_W-1:0] acc_in;
    wire             valid_out;
    wire [ACC_W-1:0] acc_out;

    pe_mac #(.K(K), .ACC_W(ACC_W)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .coeff     (coeff),
        .scalar    (scalar),
        .acc_in    (acc_in),
        .valid_out (valid_out),
        .acc_out   (acc_out)
    );

    // Clock: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer test_num = 0;

    // Q = 2^51 - 2^17 + 1
    localparam [K-1:0] Q = 51'h7FFFFFFFE0001;

    task automatic drive(
        input [K-1:0]     t_coeff,
        input [K-1:0]     t_scalar,
        input [ACC_W-1:0] t_acc_in
    );
    begin
        @(posedge clk);
        valid_in <= 1'b1;
        coeff    <= t_coeff;
        scalar   <= t_scalar;
        acc_in   <= t_acc_in;
        @(posedge clk);
        valid_in <= 1'b0;
        coeff    <= {K{1'b0}};
        scalar   <= {K{1'b0}};
        acc_in   <= {ACC_W{1'b0}};
    end
    endtask

    task automatic check(
        input [ACC_W-1:0] expected,
        input [8*40-1:0]  label
    );
    begin
        // Wait for valid_out (2-cycle pipeline)
        @(posedge clk);
        while (!valid_out) @(posedge clk);
        test_num = test_num + 1;
        if (acc_out === expected) begin
            $display("PASS [%0d] %0s: acc_out = 0x%0h", test_num, label, acc_out);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] %0s: acc_out = 0x%0h, expected = 0x%0h",
                     test_num, label, acc_out, expected);
            fail_cnt = fail_cnt + 1;
        end
    end
    endtask

    // Expected product computation helper:
    // For 51-bit values, product fits in 102 bits. ACC_W=118 holds acc_in+product.

    initial begin
        $dumpfile("tb_pe_mac.vcd");
        $dumpvars(0, tb_pe_mac);

        rst_n    = 0;
        valid_in = 0;
        coeff    = 0;
        scalar   = 0;
        acc_in   = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        //---------------------------------------------------------------------
        // Test A: 0 * 0 + 0 = 0
        //---------------------------------------------------------------------
        drive({K{1'b0}}, {K{1'b0}}, {ACC_W{1'b0}});
        check({ACC_W{1'b0}}, "0*0+0");

        //---------------------------------------------------------------------
        // Test B: 1 * 1 + 0 = 1
        //---------------------------------------------------------------------
        drive({{(K-1){1'b0}}, 1'b1}, {{(K-1){1'b0}}, 1'b1}, {ACC_W{1'b0}});
        check({{(ACC_W-1){1'b0}}, 1'b1}, "1*1+0");

        //---------------------------------------------------------------------
        // Test C: 5 * 7 + 100 = 135
        //---------------------------------------------------------------------
        drive(51'd5, 51'd7, 118'd100);
        check(118'd135, "5*7+100");

        //---------------------------------------------------------------------
        // Test D: (Q-1) * (Q-1) + 0 = (Q-1)^2
        // Q-1 = 0x7FFFFFFFE0000
        // (Q-1)^2 = Q^2 - 2Q + 1
        // We just compute numerically: (2^51-2^17)^2 = 2^102 - 2^68 + 2^34
        //---------------------------------------------------------------------
        begin
            reg [ACC_W-1:0] expected_d;
            // (Q-1) = 2^51 - 2^17 = 0x7FFFFFFFE0000
            // (Q-1)^2 = 2^102 - 2*2^51*2^17 + 2^34
            //         = 2^102 - 2^69 + 2^34
            // (Q-1)^2 < Q^2 < 2^102, so the product fits in ACC_W=118.
            // (2^51-2^17)^2 = 2^102 - 2^69 + 2^34
            // But 2^102 requires bit 102, which is within 118-bit ACC_W.
            // In hex: 2^102 = 0x40000000000000000000000000
            //         2^69  = 0x200000000000000000
            //         2^34  = 0x400000000
            // result = 2^102 - 2^69 + 2^34
            // = 0x3FFFFFFFE00000000400000000
            expected_d = (118'h1 << 102) - (118'h1 << 69) + (118'h1 << 34);
            drive(Q - 51'd1, Q - 51'd1, {ACC_W{1'b0}});
            check(expected_d, "(Q-1)^2");
        end

        //---------------------------------------------------------------------
        // Test E: Accumulation chain: 3*4+0=12, then 2*5+12=22
        //---------------------------------------------------------------------
        drive(51'd3, 51'd4, 118'd0);
        check(118'd12, "3*4+0");

        drive(51'd2, 51'd5, 118'd12);
        check(118'd22, "2*5+12");

        //---------------------------------------------------------------------
        // Test F: Pipeline timing - two consecutive inputs
        //---------------------------------------------------------------------
        begin
            reg [ACC_W-1:0] exp1, exp2;
            exp1 = 118'd10 * 118'd20 + 118'd5;  // 205
            exp2 = 118'd3  * 118'd7  + 118'd100; // 121

            @(posedge clk);
            valid_in <= 1'b1;
            coeff    <= 51'd10;
            scalar   <= 51'd20;
            acc_in   <= 118'd5;
            @(posedge clk);
            coeff    <= 51'd3;
            scalar   <= 51'd7;
            acc_in   <= 118'd100;
            @(posedge clk);
            valid_in <= 1'b0;

            // First result after 2 cycles from first input
            @(posedge clk); // wait for pipeline
            while (!valid_out) @(posedge clk);
            test_num = test_num + 1;
            if (acc_out === exp1) begin
                $display("PASS [%0d] pipeline_first: acc_out = %0d", test_num, acc_out);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] pipeline_first: acc_out = %0d, expected = %0d",
                         test_num, acc_out, exp1);
                fail_cnt = fail_cnt + 1;
            end

            @(posedge clk);
            test_num = test_num + 1;
            if (valid_out && acc_out === exp2) begin
                $display("PASS [%0d] pipeline_second: acc_out = %0d", test_num, acc_out);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] pipeline_second: acc_out = %0d, expected = %0d, valid=%0b",
                         test_num, acc_out, exp2, valid_out);
                fail_cnt = fail_cnt + 1;
            end
        end

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        $display("============================================");
        $display("tb_pe_mac: %0d PASSED, %0d FAILED (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("SOME TESTS FAILED");
            $fatal(1, "tb_pe_mac failed");
        end
        $display("============================================");
        $finish;
    end

endmodule
