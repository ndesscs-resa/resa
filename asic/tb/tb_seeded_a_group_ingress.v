`timescale 1ns/1ps

module tb_seeded_a_group_ingress;
    localparam N = 40;
    localparam K = 8;
    localparam AXIS_W = 128;
    localparam DIM = 3;
    localparam GROUPS = 2;
    localparam SEED_W = 256;
    localparam B_BITS = N * K;
    localparam B_WORDS = (B_BITS + AXIS_W - 1) / AXIS_W;
    localparam TOTAL_RECORDS = GROUPS * DIM;
    localparam TOTAL_BITS = GROUPS * (SEED_W + DIM * B_BITS);
    localparam TOTAL_WORDS = (TOTAL_BITS + AXIS_W - 1) / AXIS_W;

    reg clk;
    reg rst_n;
    reg flush;
    reg [15:0] embed_dim;
    reg s_axis_tvalid;
    wire s_axis_tready;
    reg [AXIS_W-1:0] s_axis_tdata;
    reg [95:0] seed_nonce_base;
    reg [31:0] seed_counter_base;
    wire seed_valid;
    reg seed_ready;
    wire [255:0] seed_key;
    wire [95:0] seed_nonce;
    wire [31:0] seed_counter;
    wire b_axis_tvalid;
    reg b_axis_tready;
    wire [AXIS_W-1:0] b_axis_tdata;
    wire [15:0] group_idx_debug;
    wire [15:0] dim_idx_debug;

    reg [AXIS_W-1:0] stream_words [0:TOTAL_WORDS-1];
    integer word_idx;
    integer seed_seen;
    integer b_word_seen;
    integer cycle_count;
    integer errors;

    seeded_a_group_ingress #(
        .N(N),
        .K(K),
        .AXIS_W(AXIS_W),
        .BUFFER_BEATS(3)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush(flush),
        .embed_dim(embed_dim),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),
        .seed_nonce_base(seed_nonce_base),
        .seed_counter_base(seed_counter_base),
        .seed_valid(seed_valid),
        .seed_ready(seed_ready),
        .seed_key(seed_key),
        .seed_nonce(seed_nonce),
        .seed_counter(seed_counter),
        .b_axis_tvalid(b_axis_tvalid),
        .b_axis_tready(b_axis_tready),
        .b_axis_tdata(b_axis_tdata),
        .group_idx_debug(group_idx_debug),
        .dim_idx_debug(dim_idx_debug)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function payload_bit;
        input integer group;
        input integer dim;
        input integer bit_idx;
        begin
            payload_bit = ((group * 17 + dim * 11 + bit_idx * 5 + (bit_idx / 7)) & 1);
        end
    endfunction

    function [255:0] make_seed;
        input integer group;
        integer bi;
        begin
            make_seed = 256'd0;
            for (bi = 0; bi < 256; bi = bi + 1)
                make_seed[bi] = ((group * 23 + bi * 3 + (bi / 5)) & 1);
        end
    endfunction

    function [AXIS_W-1:0] expected_b_word;
        input integer group;
        input integer dim;
        input integer word;
        integer bi;
        integer payload_idx;
        begin
            expected_b_word = {AXIS_W{1'b0}};
            for (bi = 0; bi < AXIS_W; bi = bi + 1) begin
                payload_idx = word * AXIS_W + bi;
                if (payload_idx < B_BITS)
                    expected_b_word[bi] = payload_bit(group, dim, payload_idx);
            end
        end
    endfunction

    task set_stream_bit;
        input integer bit_pos;
        input value;
        begin
            stream_words[bit_pos / AXIS_W][bit_pos % AXIS_W] = value;
        end
    endtask

    task build_stream;
        integer wi;
        integer group;
        integer dim;
        integer bi;
        integer bit_pos;
        reg [255:0] seed;
        begin
            for (wi = 0; wi < TOTAL_WORDS; wi = wi + 1)
                stream_words[wi] = {AXIS_W{1'b0}};

            bit_pos = 0;
            for (group = 0; group < GROUPS; group = group + 1) begin
                seed = make_seed(group);
                for (bi = 0; bi < SEED_W; bi = bi + 1) begin
                    set_stream_bit(bit_pos, seed[bi]);
                    bit_pos = bit_pos + 1;
                end
                for (dim = 0; dim < DIM; dim = dim + 1) begin
                    for (bi = 0; bi < B_BITS; bi = bi + 1) begin
                        set_stream_bit(bit_pos, payload_bit(group, dim, bi));
                        bit_pos = bit_pos + 1;
                    end
                end
            end
        end
    endtask

    task check_seed;
        integer exp_group;
        integer exp_dim;
        reg [255:0] exp_key;
        reg [95:0] exp_nonce;
        begin
            exp_group = seed_seen / DIM;
            exp_dim = seed_seen % DIM;
            exp_key = make_seed(exp_group);
            exp_nonce = seed_nonce_base ^ {32'h48454442, exp_group[15:0], exp_dim[15:0], 32'h00000000};
            if (seed_key !== exp_key) begin
                $display("FAIL seed key record %0d: got=%0h expected=%0h", seed_seen, seed_key, exp_key);
                errors = errors + 1;
            end
            if (seed_nonce !== exp_nonce) begin
                $display("FAIL seed nonce record %0d: got=%0h expected=%0h", seed_seen, seed_nonce, exp_nonce);
                errors = errors + 1;
            end
            if (seed_counter !== seed_counter_base) begin
                $display("FAIL seed counter record %0d: got=%0h expected=%0h", seed_seen, seed_counter, seed_counter_base);
                errors = errors + 1;
            end
        end
    endtask

    task check_b_word;
        integer exp_record;
        integer exp_group;
        integer exp_dim;
        integer exp_word;
        reg [AXIS_W-1:0] exp_data;
        begin
            exp_record = b_word_seen / B_WORDS;
            exp_group = exp_record / DIM;
            exp_dim = exp_record % DIM;
            exp_word = b_word_seen % B_WORDS;
            exp_data = expected_b_word(exp_group, exp_dim, exp_word);
            if (b_axis_tdata !== exp_data) begin
                $display("FAIL b word %0d (g=%0d dim=%0d word=%0d): got=%0h expected=%0h",
                         b_word_seen, exp_group, exp_dim, exp_word, b_axis_tdata, exp_data);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_seeded_a_group_ingress.vcd");
        $dumpvars(0, tb_seeded_a_group_ingress);

        rst_n = 1'b0;
        flush = 1'b0;
        embed_dim = DIM[15:0];
        s_axis_tvalid = 1'b0;
        s_axis_tdata = {AXIS_W{1'b0}};
        seed_nonce_base = 96'h00112233445566778899aabb;
        seed_counter_base = 32'h00000001;
        seed_ready = 1'b0;
        b_axis_tready = 1'b0;
        word_idx = 0;
        seed_seen = 0;
        b_word_seen = 0;
        cycle_count = 0;
        errors = 0;
        build_stream;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;

        while ((seed_seen < TOTAL_RECORDS || b_word_seen < TOTAL_RECORDS * B_WORDS) &&
               cycle_count < 5000) begin
            @(negedge clk);
            seed_ready = (cycle_count % 5 != 2);
            b_axis_tready = (cycle_count % 7 != 3) && (cycle_count % 11 != 6);
            s_axis_tvalid = (word_idx < TOTAL_WORDS) &&
                            (cycle_count < 3 || (cycle_count % 6 != 4));
            if (word_idx < TOTAL_WORDS)
                s_axis_tdata = stream_words[word_idx];
            else
                s_axis_tdata = {AXIS_W{1'b0}};

            #1;
            if (seed_valid && seed_ready) begin
                check_seed;
                seed_seen = seed_seen + 1;
            end
            if (b_axis_tvalid && b_axis_tready) begin
                check_b_word;
                b_word_seen = b_word_seen + 1;
            end
            if (s_axis_tvalid && s_axis_tready)
                word_idx = word_idx + 1;

            @(posedge clk);
            cycle_count = cycle_count + 1;
        end

        s_axis_tvalid = 1'b0;
        seed_ready = 1'b0;
        b_axis_tready = 1'b0;

        if (cycle_count >= 5000) begin
            $display("FAIL timeout: seeds=%0d/%0d b_words=%0d/%0d words=%0d/%0d",
                     seed_seen, TOTAL_RECORDS, b_word_seen, TOTAL_RECORDS * B_WORDS,
                     word_idx, TOTAL_WORDS);
            errors = errors + 1;
        end
        if (seed_seen != TOTAL_RECORDS) begin
            $display("FAIL seed count: got=%0d expected=%0d", seed_seen, TOTAL_RECORDS);
            errors = errors + 1;
        end
        if (b_word_seen != TOTAL_RECORDS * B_WORDS) begin
            $display("FAIL b word count: got=%0d expected=%0d",
                     b_word_seen, TOTAL_RECORDS * B_WORDS);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_seeded_a_group_ingress: ALL TESTS PASSED");
        end else begin
            $display("tb_seeded_a_group_ingress: %0d FAILED", errors);
            $fatal(1, "tb_seeded_a_group_ingress failed");
        end
        $finish;
    end
endmodule
