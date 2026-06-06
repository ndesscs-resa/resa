`timescale 1ns/1ps

module tb_chacha20_block_stream;
    reg clk;
    reg rst_n;
    reg flush;
    reg in_valid;
    reg [255:0] key;
    reg [31:0] counter;
    reg [95:0] nonce;
    wire out_valid;
    wire [511:0] out_block;

    integer cycles;
    integer errors;
    integer out_idx;
    integer kat_idx;

    localparam integer KAT_COUNT = 7;
    reg [255:0] kat_key [0:KAT_COUNT-1];
    reg [31:0]  kat_counter [0:KAT_COUNT-1];
    reg [95:0]  kat_nonce [0:KAT_COUNT-1];
    reg [511:0] kat_expected [0:KAT_COUNT-1];

    chacha20_block_stream dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush(flush),
        .in_valid(in_valid),
        .key(key),
        .counter(counter),
        .nonce(nonce),
        .out_valid(out_valid),
        .out_block(out_block)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task run_single_kat;
        input integer idx;
        begin
            key = kat_key[idx];
            counter = kat_counter[idx];
            nonce = kat_nonce[idx];
            @(posedge clk);
            in_valid = 1'b1;
            @(posedge clk);
            in_valid = 1'b0;

            cycles = 0;
            while (!out_valid && cycles < 20) begin
                cycles = cycles + 1;
                @(posedge clk);
            end

            if (!out_valid) begin
                $display("FAIL: KAT %0d produced no output", idx);
                errors = errors + 1;
            end else if (out_block !== kat_expected[idx]) begin
                $display("FAIL: KAT %0d full block mismatch", idx);
                $display("  expected %0128x", kat_expected[idx]);
                $display("  got      %0128x", out_block);
                errors = errors + 1;
            end

            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_chacha20_block_stream.vcd");
        $dumpvars(0, tb_chacha20_block_stream);

        kat_key[0] = 256'h1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100;
        kat_counter[0] = 32'h00000001;
        kat_nonce[0] = 96'h000000004a00000009000000;
        kat_expected[0] = 512'h4e3c50a2_e883d0cb_b94e16de_d19c12b5_a2028bd9_05d7c214_09aa9f07_466482d2_4e6cd4c3_9aaa2204_0368c033_c7f4d1c7_c47120a3_1fdd0f50_15593bd1_e4e7f110;

        kat_key[1] = 256'h1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100;
        kat_counter[1] = 32'h00000002;
        kat_nonce[1] = 96'h000000004a00000009000000;
        kat_expected[1] = 512'h3baf864c_37ca065b_00265586_27faf25c_9c4f3d68_9c6721bf_86c4f955_92f821e7_e89f2e0a_9f45bfa5_fd1d35aa_94c3569d_d6b92bea_b0acccf8_4ebfd739_7783880a;

        kat_key[2] = 256'h1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100;
        kat_counter[2] = 32'h00000003;
        kat_nonce[2] = 96'h000000004a00000009000000;
        kat_expected[2] = 512'h0ea01b5d_e9fea953_511e4e4b_1b94c63a_4527cdac_8b59769a_12eb3acc_931e868a_18271cf5_9752e26b_159aca6d_da926a1d_24435aae_0ec2d52e_8665be83_cbbdbfdc;

        kat_key[3] = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        kat_counter[3] = 32'h00000000;
        kat_nonce[3] = 96'h000000000000000000000000;
        kat_expected[3] = 512'h8665eeb2_69b687c3_1ca11815_f4b8436a_374ad8b8_3fe02477_8d485751_7c5941da_c70d778b_ccef36a8_1aed8da0_b819d2bd_28bd8653_e56a5d40_903df1a0_ade0b876;

        kat_key[4] = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        kat_counter[4] = 32'h00000001;
        kat_nonce[4] = 96'h000000000000000000000000;
        kat_expected[4] = 512'h6f4d794b_1f0ae1ac_45fb0a51_281fed31_d539d874_b03371d5_434ee69c_7621b729_ed7aee32_3e53c612_6965e348_a0290fcb_0d082d73_7c97ba98_7a385155_bee7079f;

        kat_key[5] = 256'hdcd5cec7c0b9b2aba49d968f88817a736c655e575049423b342d261f18110a03;
        kat_counter[5] = 32'h01020304;
        kat_nonce[5] = 96'h7e73685d52473c31261b1005;
        kat_expected[5] = 512'hc52b4a05_4fb726c7_952f7303_e3c79433_377ef22b_3ec1a068_593f637d_6cea000f_84c11696_419d1425_1f55f30a_692dd89c_ca9d263a_50511110_4f2b5a31_20559cc9;

        kat_key[6] = 256'h00000000000000000000000000000000ffffffffffffffffffffffffffffffff;
        kat_counter[6] = 32'hf0e1d2c3;
        kat_nonce[6] = 96'hbbaa99887766554433221100;
        kat_expected[6] = 512'h6ea297a6_6e33f54b_af1a6570_8c6a045a_ec5f20a8_5db06a04_6ee8b647_2da4767e_1010dbe1_7cb31edc_c8d14d98_2a0c33ee_3036491b_e2c42809_56fdd577_13b6e5c7;

        rst_n = 1'b0;
        flush = 1'b0;
        in_valid = 1'b0;
        key = 256'd0;
        counter = 32'd0;
        nonce = 96'd0;
        errors = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // Full-block known-answer tests. KAT 0 is RFC 8439; KAT 3 is the
        // all-zero public vector; the rest cover counter, key, and nonce order.
        for (kat_idx = 0; kat_idx < KAT_COUNT; kat_idx = kat_idx + 1) begin
            run_single_kat(kat_idx);
        end

        // A flush must cancel an accepted input before it reaches the output.
        key = kat_key[1];
        counter = kat_counter[1];
        nonce = kat_nonce[1];
        @(posedge clk);
        in_valid = 1'b1;
        @(posedge clk);
        in_valid = 1'b0;
        flush = 1'b1;
        @(posedge clk);
        flush = 1'b0;
        repeat (12) begin
            @(posedge clk);
            if (out_valid) begin
                $display("FAIL: flush did not cancel pending block");
                errors = errors + 1;
            end
        end

        // Back-to-back counters must preserve one-block-per-cycle throughput.
        key = kat_key[0];
        counter = kat_counter[0];
        nonce = kat_nonce[0];
        @(posedge clk);
        in_valid = 1'b1;
        @(posedge clk);
        counter = kat_counter[1];
        @(posedge clk);
        counter = kat_counter[2];
        @(posedge clk);
        in_valid = 1'b0;

        out_idx = 0;
        cycles = 0;
        while (out_idx < 3 && cycles < 30) begin
            cycles = cycles + 1;
            @(posedge clk);
            if (out_valid) begin
                if (out_block !== kat_expected[out_idx]) begin
                    $display("FAIL: back-to-back block %0d mismatch", out_idx);
                    $display("  expected %0128x", kat_expected[out_idx]);
                    $display("  got      %0128x", out_block);
                    errors = errors + 1;
                end
                out_idx = out_idx + 1;
            end
        end
        if (out_idx != 3) begin
            $display("FAIL: expected 3 back-to-back outputs, got %0d", out_idx);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_chacha20_block_stream: ALL TESTS PASSED");
        end else begin
            $display("tb_chacha20_block_stream: %0d FAILED", errors);
            $fatal(1, "tb_chacha20_block_stream failed");
        end

        $finish;
    end
endmodule
