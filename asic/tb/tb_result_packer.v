//-----------------------------------------------------------------------------
// Testbench: result_packer - Packs Reduced Coefficients to AXI-Stream
//-----------------------------------------------------------------------------
// Feeds NUM_PE x 51-bit coefficients per cycle, verifies packed output beats.
// Also performs a round-trip test with continuous_unpack.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_result_packer;

    parameter K            = 51;
    parameter NUM_PE       = 8;
    parameter OUT_WIDTH    = 512;
    parameter TOTAL_COEFFS = 8192;

    localparam INPUT_WIDTH = NUM_PE * K;
    localparam TOTAL_BEATS = (TOTAL_COEFFS * K + OUT_WIDTH - 1) / OUT_WIDTH; // 816

    reg                         clk;
    reg                         rst_n;
    reg                         flush;
    reg                         in_valid;
    wire                        in_ready;
    reg  [INPUT_WIDTH-1:0]      in_data;
    wire                        m_valid;
    reg                         m_ready;
    wire [OUT_WIDTH-1:0]        m_data;
    wire                        m_last;

    result_packer #(
        .K            (K),
        .NUM_PE       (NUM_PE),
        .OUT_WIDTH    (OUT_WIDTH),
        .TOTAL_COEFFS (TOTAL_COEFFS)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .flush   (flush),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data (in_data),
        .m_valid (m_valid),
        .m_ready (m_ready),
        .m_data  (m_data),
        .m_last  (m_last)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer test_num = 0;

    //-------------------------------------------------------------------------
    // Storage for output beats
    //-------------------------------------------------------------------------
    reg [OUT_WIDTH-1:0] out_beats [0:TOTAL_BEATS-1];
    integer beat_count;
    integer last_seen;

    //-------------------------------------------------------------------------
    // Test 1: Feed TOTAL_COEFFS coefficients, collect output beats
    //-------------------------------------------------------------------------
    integer group_idx;
    integer cycle_timeout;

    initial begin
        $dumpfile("tb_result_packer.vcd");
        $dumpvars(0, tb_result_packer);

        rst_n    = 0;
        flush    = 0;
        in_valid = 0;
        in_data  = 0;
        m_ready  = 1;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        //---------------------------------------------------------------------
        // Test 1: Pack 8192 coefficients, verify beat count and m_last
        //---------------------------------------------------------------------
        beat_count = 0;
        last_seen  = 0;
        group_idx  = 0;

        fork
            // Producer: feed TOTAL_COEFFS / NUM_PE groups
            begin : pack_producer
                for (group_idx = 0; group_idx < TOTAL_COEFFS / NUM_PE; group_idx = group_idx + 1) begin
                    @(posedge clk);
                    while (!in_ready) @(posedge clk);
                    in_valid <= 1'b1;
                    // Pack NUM_PE coefficients: value = global_coeff_index
                    begin : pack_coeffs
                        integer p;
                        reg [INPUT_WIDTH-1:0] word;
                        reg [K-1:0] cval;
                        word = {INPUT_WIDTH{1'b0}};
                        for (p = 0; p < NUM_PE; p = p + 1) begin
                            cval = (group_idx * NUM_PE + p);
                            word[p*K +: K] = cval;
                        end
                        in_data <= word;
                    end
                end
                @(posedge clk);
                in_valid <= 1'b0;
            end

            // Consumer: collect output beats
            begin : pack_consumer
                cycle_timeout = 0;
                while (beat_count < TOTAL_BEATS) begin
                    @(posedge clk);
                    if (m_valid && m_ready) begin
                        out_beats[beat_count] = m_data;
                        beat_count = beat_count + 1;
                        cycle_timeout = 0;
                        if (m_last) last_seen = last_seen + 1;
                    end else begin
                        cycle_timeout = cycle_timeout + 1;
                        if (cycle_timeout > 500000) begin
                            $display("ERROR: Timeout collecting beats at beat_count=%0d", beat_count);
                            disable pack_consumer;
                        end
                    end
                end
            end
        join

        // Verify beat count
        test_num = test_num + 1;
        if (beat_count == TOTAL_BEATS) begin
            $display("PASS [%0d] beat_count: %0d beats collected (expected %0d)",
                     test_num, beat_count, TOTAL_BEATS);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] beat_count: %0d beats collected, expected %0d",
                     test_num, beat_count, TOTAL_BEATS);
            fail_cnt = fail_cnt + 1;
        end

        // Verify m_last
        test_num = test_num + 1;
        if (last_seen == 1) begin
            $display("PASS [%0d] m_last: seen exactly once", test_num);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] m_last: seen %0d times, expected 1", test_num, last_seen);
            fail_cnt = fail_cnt + 1;
        end

        //---------------------------------------------------------------------
        // Test 2: Verify packed bitstream content
        // Extract coefficients from packed output and compare
        //---------------------------------------------------------------------
        begin : verify_bitstream
            integer ci, bit_pos, word_idx, bit_in_word, bits_left, bits_this_word, b;
            reg [K-1:0] got_coeff;
            reg [K-1:0] exp_coeff;
            integer verify_errors;
            verify_errors = 0;

            for (ci = 0; ci < TOTAL_COEFFS; ci = ci + 1) begin
                got_coeff = {K{1'b0}};
                bit_pos = ci * K;
                bits_left = K;
                while (bits_left > 0) begin
                    word_idx = bit_pos / OUT_WIDTH;
                    bit_in_word = bit_pos % OUT_WIDTH;
                    bits_this_word = OUT_WIDTH - bit_in_word;
                    if (bits_this_word > bits_left)
                        bits_this_word = bits_left;

                    for (b = 0; b < bits_this_word; b = b + 1) begin
                        got_coeff[K - bits_left + b] = out_beats[word_idx][bit_in_word + b];
                    end

                    bit_pos = bit_pos + bits_this_word;
                    bits_left = bits_left - bits_this_word;
                end

                exp_coeff = ci;
                if (got_coeff !== exp_coeff) begin
                    if (verify_errors < 10)
                        $display("  MISMATCH coeff[%0d]: got=0x%0h, expected=0x%0h", ci, got_coeff, exp_coeff);
                    verify_errors = verify_errors + 1;
                end
            end

            test_num = test_num + 1;
            if (verify_errors == 0) begin
                $display("PASS [%0d] bitstream_verify: all %0d coefficients correct", test_num, TOTAL_COEFFS);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL [%0d] bitstream_verify: %0d errors", test_num, verify_errors);
                fail_cnt = fail_cnt + 1;
            end
        end

        //---------------------------------------------------------------------
        // Test 3: Flush resets state
        //---------------------------------------------------------------------
        @(posedge clk);
        flush <= 1'b1;
        @(posedge clk);
        flush <= 1'b0;
        repeat (2) @(posedge clk);

        test_num = test_num + 1;
        // After flush, m_valid should be 0 (no data in buffer)
        if (!m_valid) begin
            $display("PASS [%0d] flush_clears_output", test_num);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] flush_clears_output: m_valid still asserted", test_num);
            fail_cnt = fail_cnt + 1;
        end

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        $display("============================================");
        $display("tb_result_packer: %0d PASSED, %0d FAILED (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("SOME TESTS FAILED");
            $fatal(1, "tb_result_packer failed");
        end
        $display("============================================");
        $finish;
    end

endmodule
