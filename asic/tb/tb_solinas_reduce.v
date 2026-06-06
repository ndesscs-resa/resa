//-----------------------------------------------------------------------------
// Testbench: solinas_reduce - Solinas Prime Reduction
//-----------------------------------------------------------------------------
// Q = 2^51 - 2^17 + 1 = 0x7FFFFFFFE0001
// 4-stage pipeline, result valid 4 cycles after input
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_solinas_reduce;

    parameter K         = 51;
    parameter ACC_WIDTH = 118;
    localparam [K-1:0] Q = 51'h7FFFFFFFE0001;

    reg                    clk;
    reg                    rst_n;
    reg                    valid_in;
    reg  [ACC_WIDTH-1:0]  acc;
    wire                   valid_out;
    wire [K-1:0]           r;

    solinas_reduce #(
        .K         (K),
        .ACC_WIDTH (ACC_WIDTH),
        .Q         (Q)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .acc       (acc),
        .valid_out (valid_out),
        .r         (r)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer test_num = 0;

    task automatic drive(input [ACC_WIDTH-1:0] val);
    begin
        @(posedge clk);
        valid_in <= 1'b1;
        acc      <= val;
        @(posedge clk);
        valid_in <= 1'b0;
        acc      <= {ACC_WIDTH{1'b0}};
    end
    endtask

    task automatic check(input [K-1:0] expected, input [8*40-1:0] label);
    begin
        // 4-stage pipeline
        while (!valid_out) @(posedge clk);
        test_num = test_num + 1;
        if (r === expected) begin
            $display("PASS [%0d] %0s: r = 0x%0h", test_num, label, r);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] %0s: r = 0x%0h, expected = 0x%0h",
                     test_num, label, r, expected);
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
    end
    endtask

    initial begin
        $dumpfile("tb_solinas_reduce.vcd");
        $dumpvars(0, tb_solinas_reduce);

        rst_n    = 0;
        valid_in = 0;
        acc      = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        //---------------------------------------------------------------------
        // Test 1: input = 0 -> output = 0
        //---------------------------------------------------------------------
        drive({ACC_WIDTH{1'b0}});
        check({K{1'b0}}, "zero");

        //---------------------------------------------------------------------
        // Test 2: input = 1 -> output = 1
        //---------------------------------------------------------------------
        drive({{(ACC_WIDTH-1){1'b0}}, 1'b1});
        check({{(K-1){1'b0}}, 1'b1}, "one");

        //---------------------------------------------------------------------
        // Test 3: input = Q-1 -> output = Q-1
        //---------------------------------------------------------------------
        drive({{(ACC_WIDTH-K){1'b0}}, Q - 51'd1});
        check(Q - 51'd1, "Q-1");

        //---------------------------------------------------------------------
        // Test 4: input = Q -> output = 0
        //---------------------------------------------------------------------
        drive({{(ACC_WIDTH-K){1'b0}}, Q});
        check({K{1'b0}}, "Q->0");

        //---------------------------------------------------------------------
        // Test 5: input = 2*Q -> output = 0
        //---------------------------------------------------------------------
        drive({{(ACC_WIDTH-K-1){1'b0}}, Q, 1'b0});
        check({K{1'b0}}, "2Q->0");

        //---------------------------------------------------------------------
        // Test 6: input = Q+1 -> output = 1
        //---------------------------------------------------------------------
        drive({{(ACC_WIDTH-K){1'b0}}, Q} + {{(ACC_WIDTH-1){1'b0}}, 1'b1});
        check({{(K-1){1'b0}}, 1'b1}, "Q+1->1");

        //---------------------------------------------------------------------
        // Test 7: input = 3*Q -> output = 0
        //---------------------------------------------------------------------
        begin
            reg [ACC_WIDTH-1:0] threeQ;
            threeQ = {{(ACC_WIDTH-K){1'b0}}, Q} * 118'd3;
            drive(threeQ);
            check({K{1'b0}}, "3Q->0");
        end

        //---------------------------------------------------------------------
        // Test 8: input = 2^51 -> output = 2^17 - 1
        // Because 2^51 mod Q = 2^17 - 1 = 0x1FFFF
        //---------------------------------------------------------------------
        drive(118'h1 << 51);
        check(51'h1FFFF, "2^51->c");

        //---------------------------------------------------------------------
        // Test 9: input = 2^102 -> output = (2^17-1)^2 mod Q
        // 2^102 mod Q = (2^51)^2 mod Q = c^2 mod Q
        // c = 2^17-1 = 131071
        // c^2 = 17179738113 = 0x3FFFFFFC0001
        // c^2 mod Q: c^2 = 2^34 - 2^18 + 1
        // Need to check if < Q. Q = 2^51-2^17+1 >> 2^34, so c^2 < Q. Output = c^2.
        //---------------------------------------------------------------------
        drive(118'h1 << 102);
        check(51'h3FFFC0001, "2^102->c^2");

        //---------------------------------------------------------------------
        // Test 10: Small value in low 51 bits only (no reduction needed)
        // input = 42 -> output = 42
        //---------------------------------------------------------------------
        drive(118'd42);
        check(51'd42, "small_42");

        //---------------------------------------------------------------------
        // Test 11: Large 118-bit value
        // acc = 2^117 (all high bit set)
        // Need to compute 2^117 mod Q
        // 2^117 = 2^102 * 2^15
        // Decompose: acc_0 = 0, acc_1 = 0, acc_2 = 2^15 = 32768
        // term2 = 32768 * (2^34 - 2^18 + 1) = 2^49 - 2^33 + 2^15
        // sum = term2 = 2^49 - 2^33 + 32768
        // This is < 2^51 so result = 2^49 - 2^33 + 2^15
        //---------------------------------------------------------------------
        begin
            reg [K-1:0] exp11;
            exp11 = (51'h1 << 49) - (51'h1 << 33) + (51'h1 << 15);
            drive(118'h1 << 117);
            check(exp11, "2^117");
        end

        //---------------------------------------------------------------------
        // Test 12: Pipeline throughput - 3 consecutive inputs
        //---------------------------------------------------------------------
        begin
            reg [K-1:0] exp_a, exp_b, exp_c;
            exp_a = 51'd7;  // 7 mod Q = 7
            exp_b = 51'd0;  // Q mod Q = 0
            exp_c = 51'd42; // 42 mod Q = 42

            @(posedge clk);
            valid_in <= 1'b1;
            acc      <= 118'd7;
            @(posedge clk);
            acc      <= {{(ACC_WIDTH-K){1'b0}}, Q};
            @(posedge clk);
            acc      <= 118'd42;
            @(posedge clk);
            valid_in <= 1'b0;

            // Wait for first result
            while (!valid_out) @(posedge clk);
            test_num = test_num + 1;
            if (r === exp_a) begin
                $display("PASS [%0d] pipe_a: r = %0d", test_num, r);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] pipe_a: r = %0d, expected = %0d", test_num, r, exp_a);
                fail_cnt = fail_cnt + 1;
            end

            @(posedge clk);
            test_num = test_num + 1;
            if (r === exp_b) begin
                $display("PASS [%0d] pipe_b: r = %0d", test_num, r);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] pipe_b: r = 0x%0h, expected = 0x%0h", test_num, r, exp_b);
                fail_cnt = fail_cnt + 1;
            end

            @(posedge clk);
            test_num = test_num + 1;
            if (r === exp_c) begin
                $display("PASS [%0d] pipe_c: r = %0d", test_num, r);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] pipe_c: r = %0d, expected = %0d", test_num, r, exp_c);
                fail_cnt = fail_cnt + 1;
            end
        end

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        $display("============================================");
        $display("tb_solinas_reduce: %0d PASSED, %0d FAILED (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("SOME TESTS FAILED");
            $fatal(1, "tb_solinas_reduce failed");
        end
        $display("============================================");
        $finish;
    end

endmodule
