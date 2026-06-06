`timescale 1ns/1ps

module tb_seeded_a_coeff_frontend;
    localparam K = 51;
    localparam B_PES = 8;
    localparam A_PES = 8;
    localparam AXIS_W = 1024;
    localparam OUT_GROUPS = 64;
    localparam TOTAL_B_COEFFS = OUT_GROUPS * B_PES;
    localparam TOTAL_BITS = TOTAL_B_COEFFS * K;
    localparam TOTAL_WORDS = (TOTAL_BITS + AXIS_W - 1) / AXIS_W;

    reg clk;
    reg rst_n;
    reg flush;
    reg seed_valid;
    wire seed_ready;
    reg [255:0] seed_key;
    reg [95:0] seed_nonce;
    reg [31:0] seed_counter;
    reg s_axis_tvalid;
    wire s_axis_tready;
    reg [AXIS_W-1:0] s_axis_tdata;
    wire coeff_valid;
    reg coeff_ready;
    wire [(B_PES+A_PES)*K-1:0] coeff_data;

    reg [AXIS_W-1:0] packed_mem [0:TOTAL_WORDS-1];
    integer errors;
    integer out_idx;
    integer word_idx;
    integer cycle_count;
    reg word_fire;
    reg coeff_fire;

    seeded_a_coeff_frontend #(
        .K(K),
        .B_PES(B_PES),
        .A_PES(A_PES),
        .AXIS_W(AXIS_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush(flush),
        .seed_valid(seed_valid),
        .seed_key(seed_key),
        .seed_nonce(seed_nonce),
        .seed_counter(seed_counter),
        .seed_ready(seed_ready),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),
        .coeff_valid(coeff_valid),
        .coeff_ready(coeff_ready),
        .coeff_data(coeff_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function [31:0] rotl32;
        input [31:0] x;
        input [4:0] n;
        begin
            rotl32 = (x << n) | (x >> (32 - n));
        end
    endfunction

    function [127:0] quarter_round;
        input [31:0] a_in;
        input [31:0] b_in;
        input [31:0] c_in;
        input [31:0] d_in;
        reg [31:0] a;
        reg [31:0] b;
        reg [31:0] c;
        reg [31:0] d;
        begin
            a = a_in; b = b_in; c = c_in; d = d_in;
            a = a + b; d = rotl32(d ^ a, 5'd16);
            c = c + d; b = rotl32(b ^ c, 5'd12);
            a = a + b; d = rotl32(d ^ a, 5'd8);
            c = c + d; b = rotl32(b ^ c, 5'd7);
            quarter_round = {d, c, b, a};
        end
    endfunction

    function [511:0] double_round;
        input [511:0] s;
        reg [31:0] x0; reg [31:0] x1; reg [31:0] x2; reg [31:0] x3;
        reg [31:0] x4; reg [31:0] x5; reg [31:0] x6; reg [31:0] x7;
        reg [31:0] x8; reg [31:0] x9; reg [31:0] x10; reg [31:0] x11;
        reg [31:0] x12; reg [31:0] x13; reg [31:0] x14; reg [31:0] x15;
        reg [127:0] qr;
        begin
            {x15, x14, x13, x12, x11, x10, x9, x8,
             x7, x6, x5, x4, x3, x2, x1, x0} = s;
            qr = quarter_round(x0, x4, x8, x12); {x12, x8, x4, x0} = qr;
            qr = quarter_round(x1, x5, x9, x13); {x13, x9, x5, x1} = qr;
            qr = quarter_round(x2, x6, x10, x14); {x14, x10, x6, x2} = qr;
            qr = quarter_round(x3, x7, x11, x15); {x15, x11, x7, x3} = qr;
            qr = quarter_round(x0, x5, x10, x15); {x15, x10, x5, x0} = qr;
            qr = quarter_round(x1, x6, x11, x12); {x12, x11, x6, x1} = qr;
            qr = quarter_round(x2, x7, x8, x13); {x13, x8, x7, x2} = qr;
            qr = quarter_round(x3, x4, x9, x14); {x14, x9, x4, x3} = qr;
            double_round = {x15, x14, x13, x12, x11, x10, x9, x8,
                            x7, x6, x5, x4, x3, x2, x1, x0};
        end
    endfunction

    function [511:0] add_state_words;
        input [511:0] a;
        input [511:0] b;
        integer wi;
        reg [511:0] tmp;
        begin
            tmp = 512'd0;
            for (wi = 0; wi < 16; wi = wi + 1)
                tmp[wi*32 +: 32] = a[wi*32 +: 32] + b[wi*32 +: 32];
            add_state_words = tmp;
        end
    endfunction

    function [511:0] chacha_block;
        input [255:0] key;
        input [31:0] counter;
        input [95:0] nonce;
        integer ri;
        reg [511:0] init;
        reg [511:0] s;
        begin
            init = {nonce[95:64], nonce[63:32], nonce[31:0], counter,
                    key[255:224], key[223:192], key[191:160], key[159:128],
                    key[127:96], key[95:64], key[63:32], key[31:0],
                    32'h6b206574, 32'h79622d32, 32'h3320646e, 32'h61707865};
            s = init;
            for (ri = 0; ri < 10; ri = ri + 1)
                s = double_round(s);
            chacha_block = add_state_words(s, init);
        end
    endfunction

    task pack_b_coefficients;
        integer ci;
        integer bit_pos;
        integer wi;
        integer bi;
        reg [K-1:0] coeff;
        begin
            for (wi = 0; wi < TOTAL_WORDS; wi = wi + 1)
                packed_mem[wi] = {AXIS_W{1'b0}};
            for (ci = 0; ci < TOTAL_B_COEFFS; ci = ci + 1) begin
                coeff = ci;
                for (bi = 0; bi < K; bi = bi + 1) begin
                    bit_pos = ci * K + bi;
                    packed_mem[bit_pos / AXIS_W][bit_pos % AXIS_W] = coeff[bi];
                end
            end
        end
    endtask

    task check_output_group;
        integer p;
        reg [K-1:0] got_b;
        reg [K-1:0] exp_b;
        reg [A_PES*K-1:0] got_a;
        reg [A_PES*K-1:0] exp_a;
        reg [511:0] exp_block;
        begin
            for (p = 0; p < B_PES; p = p + 1) begin
                got_b = coeff_data[p*K +: K];
                exp_b = (out_idx * B_PES + p);
                if (got_b !== exp_b) begin
                    $display("FAIL b[%0d]: got=%0h expected=%0h", out_idx * B_PES + p, got_b, exp_b);
                    errors = errors + 1;
                end
            end
            got_a = coeff_data[(B_PES+A_PES)*K-1 -: A_PES*K];
            exp_block = chacha_block(seed_key, seed_counter + out_idx, seed_nonce);
            exp_a = exp_block[A_PES*K-1:0];
            if (got_a !== exp_a) begin
                $display("FAIL a group %0d: got=%0h expected=%0h", out_idx, got_a, exp_a);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_seeded_a_coeff_frontend.vcd");
        $dumpvars(0, tb_seeded_a_coeff_frontend);
        rst_n = 1'b0;
        flush = 1'b0;
        seed_valid = 1'b0;
        seed_key = {
            32'h1f1e1d1c, 32'h1b1a1918, 32'h17161514, 32'h13121110,
            32'h0f0e0d0c, 32'h0b0a0908, 32'h07060504, 32'h03020100
        };
        seed_nonce = {32'h00000000, 32'h4a000000, 32'h09000000};
        seed_counter = 32'h00000001;
        s_axis_tvalid = 1'b0;
        s_axis_tdata = {AXIS_W{1'b0}};
        coeff_ready = 1'b0;
        errors = 0;
        out_idx = 0;
        word_idx = 0;
        cycle_count = 0;
        word_fire = 1'b0;
        coeff_fire = 1'b0;
        pack_b_coefficients;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        seed_valid = 1'b1;
        while (!seed_ready) @(posedge clk);
        @(posedge clk);
        seed_valid = 1'b0;
        coeff_ready = 1'b1;

        while (out_idx < OUT_GROUPS && cycle_count < 10000) begin
            @(negedge clk);
            coeff_ready = (cycle_count % 7 != 3) && (cycle_count % 11 != 5);
            // Deliberately starve the stored-b stream after the a FIFO has
            // filled. This catches a/b skew bugs where generated-a is popped
            // on downstream ready even when no matching b group is available.
            s_axis_tvalid = (word_idx < TOTAL_WORDS) &&
                            ((cycle_count < 4) || (cycle_count % 5 == 0) ||
                             (out_idx > 48));
            if (word_idx < TOTAL_WORDS)
                s_axis_tdata = packed_mem[word_idx];
            #1;
            word_fire = s_axis_tvalid && s_axis_tready;
            coeff_fire = coeff_valid && coeff_ready;

            if (coeff_fire) begin
                check_output_group;
            end

            @(posedge clk);
            cycle_count = cycle_count + 1;

            if (word_fire) begin
                word_idx = word_idx + 1;
            end

            if (coeff_fire) begin
                out_idx = out_idx + 1;
            end
        end

        if (out_idx != OUT_GROUPS) begin
            $display("FAIL: only observed %0d/%0d output groups", out_idx, OUT_GROUPS);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_seeded_a_coeff_frontend: ALL TESTS PASSED");
        end else begin
            $display("tb_seeded_a_coeff_frontend: %0d FAILED", errors);
            $fatal(1, "tb_seeded_a_coeff_frontend failed");
        end
        $finish;
    end
endmodule
