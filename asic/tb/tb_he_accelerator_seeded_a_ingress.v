//-----------------------------------------------------------------------------
// Compact-ingress end-to-end oracle test for he_accelerator_seeded_a_ingress.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_he_accelerator_seeded_a_ingress;
    localparam N          = 512;
    localparam K          = 51;
    localparam ACC_W      = 118;
    localparam NUM_PE     = 16;
    localparam B_PES      = 8;
    localparam A_PES      = 8;
    localparam MAX_DIMS   = 64;
    localparam SRAM_DEPTH = 64;
    localparam AXIS_W     = 1024;
    localparam TB_DIM     = 1;
    localparam TB_GROUPS  = 1;

    localparam TOTAL_COEFFS = 2 * N;
    localparam SCALAR_ADDR_W = $clog2(MAX_DIMS);
    localparam TOTAL_B_COEFFS = SRAM_DEPTH * B_PES;
    localparam TOTAL_B_BITS = TOTAL_B_COEFFS * K;
    localparam TOTAL_OUT_BITS = TOTAL_COEFFS * K;
    localparam COMPACT_BITS = 256 + TOTAL_B_BITS;
    localparam COMPACT_WORDS = (COMPACT_BITS + AXIS_W - 1) / AXIS_W;
    localparam OUT_WORDS = (TOTAL_OUT_BITS + AXIS_W - 1) / AXIS_W;
    localparam [50:0] MOD_Q = 51'h7FFFFFFFE0001;

    reg clk;
    reg rst_n;
    reg start;
    wire done;
    wire busy;
    wire [3:0] state_out;
    reg [15:0] num_groups;
    reg [15:0] embed_dim;
    reg [95:0] seed_nonce_base;
    reg [31:0] seed_counter_base;

    reg wr_scalar_valid;
    reg [K-1:0] wr_scalar_data;
    reg [SCALAR_ADDR_W-1:0] wr_scalar_addr;

    reg s_axis_tvalid;
    wire s_axis_tready;
    reg [AXIS_W-1:0] s_axis_tdata;

    wire m_axis_tvalid;
    reg m_axis_tready;
    wire [AXIS_W-1:0] m_axis_tdata;
    wire m_axis_tlast;

    reg [K-1:0] query_scalar;
    reg [AXIS_W-1:0] compact_mem [0:COMPACT_WORDS-1];
    reg [TOTAL_OUT_BITS-1:0] output_bits;
    integer input_word_idx;
    integer output_word_idx;
    integer ready_cycle;
    integer errors;
    reg drive_stream;

    localparam [3:0] ST_IDLE       = 4'd0;

    localparam [255:0] GROUP_SEED = {
        32'h1f1e1d1c, 32'h1b1a1918, 32'h17161514, 32'h13121110,
        32'h0f0e0d0c, 32'h0b0a0908, 32'h07060504, 32'h03020100
    };

    he_accelerator_seeded_a_ingress #(
        .N          (N),
        .K          (K),
        .ACC_W      (ACC_W),
        .NUM_PE     (NUM_PE),
        .B_PES      (B_PES),
        .A_PES      (A_PES),
        .MAX_DIMS   (MAX_DIMS),
        .SRAM_DEPTH (SRAM_DEPTH),
        .AXIS_W     (AXIS_W)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .done             (done),
        .busy             (busy),
        .state_out        (state_out),
        .num_groups       (num_groups),
        .embed_dim        (embed_dim),
        .seed_nonce_base  (seed_nonce_base),
        .seed_counter_base(seed_counter_base),
        .wr_scalar_valid  (wr_scalar_valid),
        .wr_scalar_data   (wr_scalar_data),
        .wr_scalar_addr   (wr_scalar_addr),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tdata     (s_axis_tdata),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tlast     (m_axis_tlast)
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

    function [K-1:0] b_coeff_at;
        input integer idx;
        begin
            b_coeff_at = ((idx * 17) + 5) & {K{1'b1}};
        end
    endfunction

    function [K-1:0] expected_coeff_at;
        input integer coeff_idx;
        integer addr;
        integer lane;
        integer b_idx;
        integer a_lane;
        reg [K-1:0] raw_coeff;
        reg [511:0] block;
        reg [2*K-1:0] product;
        reg [95:0] nonce;
        begin
            addr = coeff_idx / NUM_PE;
            lane = coeff_idx % NUM_PE;
            if (lane < B_PES) begin
                b_idx = addr * B_PES + lane;
                raw_coeff = b_coeff_at(b_idx);
            end else begin
                a_lane = lane - B_PES;
                nonce = seed_nonce_base ^ {32'h48454442, 16'd0, 16'd0, 32'h00000000};
                block = chacha_block(GROUP_SEED, seed_counter_base + addr, nonce);
                raw_coeff = block[a_lane*K +: K];
            end
            product = raw_coeff * query_scalar;
            expected_coeff_at = product % MOD_Q;
        end
    endfunction

    task set_compact_bit;
        input integer bit_pos;
        input value;
        begin
            compact_mem[bit_pos / AXIS_W][bit_pos % AXIS_W] = value;
        end
    endtask

    task build_compact_stream;
        integer wi;
        integer bi;
        integer ci;
        integer bit_pos;
        reg [K-1:0] coeff;
        begin
            for (wi = 0; wi < COMPACT_WORDS; wi = wi + 1)
                compact_mem[wi] = {AXIS_W{1'b0}};
            bit_pos = 0;
            for (bi = 0; bi < 256; bi = bi + 1) begin
                set_compact_bit(bit_pos, GROUP_SEED[bi]);
                bit_pos = bit_pos + 1;
            end
            for (ci = 0; ci < TOTAL_B_COEFFS; ci = ci + 1) begin
                coeff = b_coeff_at(ci);
                for (bi = 0; bi < K; bi = bi + 1) begin
                    set_compact_bit(bit_pos, coeff[bi]);
                    bit_pos = bit_pos + 1;
                end
            end
        end
    endtask

    task write_scalar;
        input [SCALAR_ADDR_W-1:0] addr;
        input [K-1:0] data;
        begin
            @(posedge clk);
            wr_scalar_valid <= 1'b1;
            wr_scalar_addr <= addr;
            wr_scalar_data <= data;
            @(posedge clk);
            wr_scalar_valid <= 1'b0;
        end
    endtask

    task check_output;
        integer ci;
        reg [K-1:0] got;
        reg [K-1:0] exp;
        integer local_errors;
        begin
            local_errors = 0;
            for (ci = 0; ci < TOTAL_COEFFS; ci = ci + 1) begin
                got = output_bits[ci*K +: K];
                exp = expected_coeff_at(ci);
                if (got !== exp) begin
                    if (local_errors < 20)
                        $display("FAIL coeff[%0d]: got=%0h expected=%0h", ci, got, exp);
                    local_errors = local_errors + 1;
                end
            end
            if (local_errors != 0)
                errors = errors + local_errors;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_word_idx <= 0;
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= {AXIS_W{1'b0}};
        end else if (drive_stream) begin
            integer next_word_idx;
            next_word_idx = input_word_idx;
            if (s_axis_tvalid && s_axis_tready)
                next_word_idx = input_word_idx + 1;
            input_word_idx <= next_word_idx;
            if (next_word_idx < COMPACT_WORDS) begin
                s_axis_tvalid <= 1'b1;
                s_axis_tdata <= compact_mem[next_word_idx];
            end else begin
                s_axis_tvalid <= 1'b0;
                s_axis_tdata <= {AXIS_W{1'b0}};
            end
        end else begin
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= {AXIS_W{1'b0}};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_word_idx <= 0;
            output_bits <= {TOTAL_OUT_BITS{1'b0}};
        end else if (m_axis_tvalid && m_axis_tready) begin
            if (output_word_idx * AXIS_W < TOTAL_OUT_BITS)
                output_bits[output_word_idx * AXIS_W +: AXIS_W] <= m_axis_tdata;
            output_word_idx <= output_word_idx + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tready <= 1'b1;
            ready_cycle <= 0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            m_axis_tready <= ((ready_cycle % 11) != 3) &&
                             ((ready_cycle % 17) != 8);
        end
    end

    initial begin
        $dumpfile("tb_he_accelerator_seeded_a_ingress.vcd");
        $dumpvars(0, tb_he_accelerator_seeded_a_ingress);

        rst_n = 1'b0;
        start = 1'b0;
        num_groups = TB_GROUPS;
        embed_dim = TB_DIM;
        seed_nonce_base = 96'h00112233445566778899aabb;
        seed_counter_base = 32'h00000001;
        wr_scalar_valid = 1'b0;
        wr_scalar_data = {K{1'b0}};
        wr_scalar_addr = {SCALAR_ADDR_W{1'b0}};
        drive_stream = 1'b0;
        query_scalar = 51'd17;
        errors = 0;
        build_compact_stream;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        write_scalar({SCALAR_ADDR_W{1'b0}}, query_scalar);

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        drive_stream <= 1'b1;

        begin
            integer timeout;
            timeout = 0;
            while (!done && timeout < 200000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 200000) begin
                $display("FAIL timeout waiting for done, state=%0d", state_out);
                errors = errors + 1;
            end
        end

        @(posedge clk);
        drive_stream <= 1'b0;

        if (busy !== 1'b0 && state_out !== ST_IDLE) begin
            repeat (4) @(posedge clk);
        end
        if (output_word_idx != OUT_WORDS) begin
            $display("FAIL output beat count: got=%0d expected=%0d", output_word_idx, OUT_WORDS);
            errors = errors + 1;
        end

        check_output;

        if (errors == 0) begin
            $display("tb_he_accelerator_seeded_a_ingress: ALL TESTS PASSED");
        end else begin
            $display("tb_he_accelerator_seeded_a_ingress: %0d FAILED", errors);
            $fatal(1, "tb_he_accelerator_seeded_a_ingress failed");
        end
        $finish;
    end

endmodule
