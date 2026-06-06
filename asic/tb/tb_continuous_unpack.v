//-----------------------------------------------------------------------------
// Testbench: continuous_unpack - Bitstream Unpacker
//-----------------------------------------------------------------------------
// Packs known 51-bit coefficients into 512-bit AXI-Stream words, feeds them
// to the DUT, and verifies correct extraction order and ciphertext boundary.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_continuous_unpack;

    parameter K        = 51;
    parameter NUM_PE   = 8;
    parameter IN_WIDTH = 512;

    localparam EXTRACT_WIDTH = NUM_PE * K;
    localparam COEFFS_PER_CT = 8192;

    reg                         clk;
    reg                         rst_n;
    reg                         flush;
    reg                         s_valid;
    wire                        s_ready;
    reg  [IN_WIDTH-1:0]         s_data;
    wire                        out_valid;
    reg                         out_ready;
    wire [NUM_PE*K-1:0]         out_data;
    wire [12:0]                 coeff_count;
    wire                        ctxt_boundary;

    continuous_unpack #(
        .K        (K),
        .NUM_PE   (NUM_PE),
        .IN_WIDTH (IN_WIDTH)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .flush        (flush),
        .s_valid      (s_valid),
        .s_ready      (s_ready),
        .s_data       (s_data),
        .out_valid    (out_valid),
        .out_ready    (out_ready),
        .out_data     (out_data),
        .coeff_count  (coeff_count),
        .ctxt_boundary(ctxt_boundary)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer test_num = 0;

    //-------------------------------------------------------------------------
    // Helper: Pack coefficients into a bitstream, stored in a large memory
    //-------------------------------------------------------------------------
    // Total bits for 8192 coefficients: 8192 * 51 = 417792 bits
    // Total 512-bit words: ceil(417792/512) = 816 words
    localparam TOTAL_WORDS = 816;

    reg [IN_WIDTH-1:0] packed_mem [0:TOTAL_WORDS-1];

    // Pack coefficients 0..8191 with value = (index & ((1<<51)-1))
    // into the bitstream. Coefficient i occupies bits [i*51 +: 51].
    // We need to distribute these across 512-bit words.
    task automatic pack_coefficients;
        integer ci;
        integer bit_pos;
        integer word_idx;
        integer bit_in_word;
        integer bits_left;
        integer bits_this_word;
        reg [K-1:0] coeff_val;
    begin
        // Clear all memory
        for (ci = 0; ci < TOTAL_WORDS; ci = ci + 1)
            packed_mem[ci] = {IN_WIDTH{1'b0}};

        // Pack each coefficient
        bit_pos = 0;
        for (ci = 0; ci < COEFFS_PER_CT; ci = ci + 1) begin
            // Coefficient value = ci (mod 2^51)
            coeff_val = ci;  // integer auto-extends with 0 for unsigned

            // Place 51 bits starting at global bit_pos
            bits_left = K;
            while (bits_left > 0) begin
                word_idx = bit_pos / IN_WIDTH;
                bit_in_word = bit_pos % IN_WIDTH;
                bits_this_word = IN_WIDTH - bit_in_word;
                if (bits_this_word > bits_left)
                    bits_this_word = bits_left;

                // Place bits_this_word bits of coeff_val into packed_mem[word_idx]
                // Starting at bit_in_word
                begin : place_bits_block
                    integer b;
                    for (b = 0; b < bits_this_word; b = b + 1) begin
                        packed_mem[word_idx][bit_in_word + b] = coeff_val[K - bits_left + b];
                    end
                end

                bit_pos   = bit_pos + bits_this_word;
                bits_left = bits_left - bits_this_word;
            end
        end
    end
    endtask

    //-------------------------------------------------------------------------
    // Test: Feed packed bitstream, verify output coefficients
    //-------------------------------------------------------------------------
    integer coeff_idx;
    integer word_ptr;
    integer extract_count;
    integer boundary_seen;
    integer cycle_timeout;
    integer errors;

    initial begin
        $dumpfile("tb_continuous_unpack.vcd");
        $dumpvars(0, tb_continuous_unpack);

        rst_n     = 0;
        flush     = 0;
        s_valid   = 0;
        s_data    = 0;
        out_ready = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Pack coefficients
        pack_coefficients;

        //---------------------------------------------------------------------
        // Test 1: Unpack all 8192 coefficients, verify order & values
        //---------------------------------------------------------------------
        out_ready = 1;
        coeff_idx = 0;
        word_ptr  = 0;
        extract_count = 0;
        boundary_seen = 0;
        errors = 0;

        // Drive input and check output simultaneously
        fork
            // Producer: feed 512-bit words when s_ready
            begin : producer
                while (word_ptr < TOTAL_WORDS) begin
                    @(posedge clk);
                    if (s_ready || !s_valid) begin
                        s_valid <= 1'b1;
                        s_data  <= packed_mem[word_ptr];
                        word_ptr = word_ptr + 1;
                    end
                end
                // Wait for s_ready to consume last word
                @(posedge clk);
                while (!s_ready) @(posedge clk);
                @(posedge clk);
                s_valid <= 1'b0;
            end

            // Consumer: check output coefficients
            begin : consumer
                cycle_timeout = 0;
                while (extract_count < COEFFS_PER_CT / NUM_PE) begin
                    @(posedge clk);
                    if (out_valid && out_ready) begin
                        cycle_timeout = 0;
                        // Check NUM_PE coefficients
                        begin : check_coeffs
                            integer p;
                            reg [K-1:0] got;
                            reg [K-1:0] expected;
                            for (p = 0; p < NUM_PE; p = p + 1) begin
                                got = out_data[p*K +: K];
                                expected = (coeff_idx + p);
                                if (got !== expected) begin
                                    if (errors < 10)
                                        $display("  MISMATCH coeff[%0d]: got=0x%0h, expected=0x%0h",
                                                 coeff_idx + p, got, expected[K-1:0]);
                                    errors = errors + 1;
                                end
                            end
                        end
                        coeff_idx = coeff_idx + NUM_PE;
                        extract_count = extract_count + 1;

                        // Check boundary
                        if (ctxt_boundary) begin
                            boundary_seen = boundary_seen + 1;
                        end
                    end else begin
                        cycle_timeout = cycle_timeout + 1;
                        if (cycle_timeout > 10000) begin
                            $display("ERROR: Timeout waiting for output at extract_count=%0d", extract_count);
                            errors = errors + 1;
                            disable consumer;
                        end
                    end
                end
            end
        join

        // Check results
        test_num = test_num + 1;
        if (errors == 0) begin
            $display("PASS [%0d] unpack_8192_coeffs: all %0d coefficients correct", test_num, coeff_idx);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] unpack_8192_coeffs: %0d errors out of %0d coefficients", test_num, errors, coeff_idx);
            fail_cnt = fail_cnt + 1;
        end

        // Check boundary signal
        test_num = test_num + 1;
        if (boundary_seen >= 1) begin
            $display("PASS [%0d] ctxt_boundary: seen %0d times", test_num, boundary_seen);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] ctxt_boundary: expected at least 1, seen %0d", test_num, boundary_seen);
            fail_cnt = fail_cnt + 1;
        end

        //---------------------------------------------------------------------
        // Test 2: Flush resets state
        //---------------------------------------------------------------------
        @(posedge clk);
        flush <= 1'b1;
        @(posedge clk);
        flush <= 1'b0;
        @(posedge clk);

        test_num = test_num + 1;
        // After flush, coeff_count should be 0
        if (coeff_count === 13'd0) begin
            $display("PASS [%0d] flush_resets_count", test_num);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL [%0d] flush_resets_count: coeff_count=%0d", test_num, coeff_count);
            fail_cnt = fail_cnt + 1;
        end

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        $display("============================================");
        $display("tb_continuous_unpack: %0d PASSED, %0d FAILED (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("SOME TESTS FAILED");
            $fatal(1, "tb_continuous_unpack failed");
        end
        $display("============================================");
        $finish;
    end

endmodule
