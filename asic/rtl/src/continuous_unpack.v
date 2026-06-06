//-----------------------------------------------------------------------------
// Continuous Bitstream Unpacker
//-----------------------------------------------------------------------------
// Extracts NUM_PE x K-bit coefficients per cycle from a continuous packed
// bitstream without assuming page padding between ciphertexts.
//
// Architecture:
//   - Input: AXI-Stream of packed data (IN_WIDTH bits per beat, default 512)
//   - Output: NUM_PE x K bits per extraction (8 x 51 = 408 bits by default)
//   - Internal: 1536-bit shift register (extraction window + input staging)
//
// The buffer is organized as a shift register. New data enters at the top
// (high bit positions); extraction always takes from the bottom (low bits).
//
// Operation per cycle (priority: extract > load):
//   1. If valid_bits >= EXTRACT_WIDTH and output ready:
//      - Extract bottom EXTRACT_WIDTH bits as NUM_PE coefficients
//      - Shift buffer down by EXTRACT_WIDTH
//      - Decrement valid_bits by EXTRACT_WIDTH
//      - Increment coeff_cnt by NUM_PE
//   2. If valid_bits + IN_WIDTH <= BUF_WIDTH and input valid:
//      - Accept input word, place at bit position [valid_bits +: IN_WIDTH]
//      - Increment valid_bits by IN_WIDTH
//   3. Both can happen simultaneously (extract first, then load)
//
// Ciphertext Boundary:
//   When coeff_cnt reaches COEFFS_PER_CT (8192) after incrementing,
//   ctxt_boundary pulses for one cycle and coeff_cnt resets to 0.
//
// Timing:
//   - Combinational extraction (registered output)
//   - 1-cycle latency from valid input data to first output
//   - Sustained throughput: 1 extraction/cycle when data available
//
// Synthesis Notes:
//   - The variable-position insertion uses a barrel shifter (input_word <<
//     post_extract_valid) which maps to efficient MUX trees.
//   - Buffer width 1536 = 3 x 512, enough to absorb stream alignment.
//   - EXTRACT_WIDTH (408) and IN_WIDTH (512) are not generally aligned, so valid_bits
//     takes many distinct values; the barrel shifter must handle general
//     offsets.
//-----------------------------------------------------------------------------

module continuous_unpack #(
    parameter K         = 51,       // Coefficient bit width
    parameter NUM_PE    = 8,        // Parallel extractions
    parameter IN_WIDTH  = 512       // AXI-Stream input width
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush,          // Reset state (at group boundary)

    // AXI-Stream input (packed data from device-local stream)
    input  wire                         s_valid,
    output wire                         s_ready,
    input  wire [IN_WIDTH-1:0]          s_data,

    // Output: extracted coefficients
    output wire                         out_valid,
    input  wire                         out_ready,
    output wire [NUM_PE*K-1:0]          out_data,

    // Ciphertext boundary detection
    output wire [12:0]                  coeff_count,    // Current count within ciphertext
    output wire                         ctxt_boundary   // Pulse at ciphertext boundary (8192)
);

    //-------------------------------------------------------------------------
    // Derived Parameters
    //-------------------------------------------------------------------------
    localparam EXTRACT_WIDTH  = NUM_PE * K;
    localparam BUF_WIDTH      = 3 * IN_WIDTH;           // 1536 bits at IN_WIDTH=512
    localparam BITS_CNT_WIDTH = $clog2(BUF_WIDTH + 1);
    localparam ROOM_CNT_WIDTH = BITS_CNT_WIDTH + 1;
    localparam COEFFS_PER_CT  = 14'd8192;              // Coefficients per ciphertext

    //-------------------------------------------------------------------------
    // Internal Registers
    //-------------------------------------------------------------------------
    reg  [BUF_WIDTH-1:0]        shift_buf;              // Main shift buffer
    reg  [BITS_CNT_WIDTH-1:0]   valid_bits;             // Valid bit count (0..1536)
    reg  [13:0]                 coeff_cnt;              // Coefficient counter within ciphertext

    //-------------------------------------------------------------------------
    // Extract and Load Condition Logic
    //-------------------------------------------------------------------------
    // Extract: enough bits in buffer AND downstream ready
    wire can_extract = (valid_bits >= EXTRACT_WIDTH[BITS_CNT_WIDTH-1:0]) && out_ready;

    // After a potential extraction, compute remaining valid bits
    wire [BITS_CNT_WIDTH-1:0] post_extract_valid = can_extract ?
        (valid_bits - EXTRACT_WIDTH[BITS_CNT_WIDTH-1:0]) : valid_bits;

    // Load: room for new input word AND upstream valid
    // Check room after potential extraction
    wire [ROOM_CNT_WIDTH-1:0] post_extract_valid_ext = {{(ROOM_CNT_WIDTH-BITS_CNT_WIDTH){1'b0}}, post_extract_valid};
    wire [ROOM_CNT_WIDTH-1:0] input_width_ext = IN_WIDTH[ROOM_CNT_WIDTH-1:0];
    wire [ROOM_CNT_WIDTH-1:0] buf_width_ext = BUF_WIDTH[ROOM_CNT_WIDTH-1:0];
    wire [ROOM_CNT_WIDTH-1:0] load_bits_after = post_extract_valid_ext + input_width_ext;
    wire                     has_load_room = (load_bits_after <= buf_width_ext);
    wire can_load = s_valid && has_load_room;

    //-------------------------------------------------------------------------
    // Output Assignments
    //-------------------------------------------------------------------------
    // Extract the bottom EXTRACT_WIDTH bits as output
    assign out_data  = shift_buf[EXTRACT_WIDTH-1:0];
    assign out_valid = can_extract;

    // Accept input when we can load (possibly after extraction makes room)
    assign s_ready = has_load_room;

    //-------------------------------------------------------------------------
    // Ciphertext Boundary
    //-------------------------------------------------------------------------
    // Next coeff count after extraction
    wire [13:0] coeff_cnt_next = coeff_cnt + NUM_PE[13:0];
    assign coeff_count    = coeff_cnt[12:0];
    assign ctxt_boundary  = can_extract && (coeff_cnt_next >= COEFFS_PER_CT);

    //-------------------------------------------------------------------------
    // Buffer Update Logic
    //-------------------------------------------------------------------------
    // Compute the buffer state after extract, then after load.
    // This is purely combinational; the registered version is in the
    // sequential block below.

    // Step 1: After extraction - shift down by EXTRACT_WIDTH
    wire [BUF_WIDTH-1:0] buf_after_extract = can_extract ?
        (shift_buf >> EXTRACT_WIDTH) : shift_buf;

    // Clear stale bits above the remaining valid window before OR-ing in the
    // next AXI word. Without this mask, previously extracted bits can pollute
    // the high bits of later coefficients when EXTRACT_WIDTH and IN_WIDTH are
    // not aligned.
    wire [BUF_WIDTH-1:0] post_extract_mask =
        (post_extract_valid == {BITS_CNT_WIDTH{1'b0}}) ? {BUF_WIDTH{1'b0}} :
        ({BUF_WIDTH{1'b1}} >> (BUF_WIDTH[BITS_CNT_WIDTH-1:0] - post_extract_valid));
    wire [BUF_WIDTH-1:0] buf_after_extract_clean = buf_after_extract & post_extract_mask;

    // Step 2: After load - insert input word at post_extract_valid position
    // Barrel-shift the input word to the correct position
    wire [BUF_WIDTH-1:0] input_shifted = {{(BUF_WIDTH-IN_WIDTH){1'b0}}, s_data} << post_extract_valid;

    wire [BUF_WIDTH-1:0] buf_after_load = can_load ?
        (buf_after_extract_clean | input_shifted) : buf_after_extract_clean;

    //-------------------------------------------------------------------------
    // Sequential State Update
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_buf  <= {BUF_WIDTH{1'b0}};
            valid_bits <= {BITS_CNT_WIDTH{1'b0}};
            coeff_cnt  <= 14'b0;
        end else if (flush) begin
            shift_buf  <= {BUF_WIDTH{1'b0}};
            valid_bits <= {BITS_CNT_WIDTH{1'b0}};
            coeff_cnt  <= 14'b0;
        end else begin
            // Update buffer
            shift_buf <= buf_after_load;

            // Update valid_bits: subtract if extract, add if load
            if (can_extract && can_load) begin
                valid_bits <= valid_bits - EXTRACT_WIDTH[BITS_CNT_WIDTH-1:0]
                            + IN_WIDTH[BITS_CNT_WIDTH-1:0];
            end else if (can_extract) begin
                valid_bits <= valid_bits - EXTRACT_WIDTH[BITS_CNT_WIDTH-1:0];
            end else if (can_load) begin
                valid_bits <= valid_bits + IN_WIDTH[BITS_CNT_WIDTH-1:0];
            end

            // Update coefficient counter
            if (can_extract) begin
                if (coeff_cnt_next >= COEFFS_PER_CT) begin
                    coeff_cnt <= coeff_cnt_next - COEFFS_PER_CT;
                end else begin
                    coeff_cnt <= coeff_cnt_next;
                end
            end
        end
    end

    //=========================================================================
    // Simulation-Only Assertions
    //=========================================================================
    `ifdef SIMULATION

    // valid_bits must never exceed buffer width
    always @(posedge clk) begin
        if (rst_n && !flush) begin
            if (valid_bits > BUF_WIDTH[BITS_CNT_WIDTH-1:0]) begin
                $display("ERROR [continuous_unpack @ %0t]: valid_bits=%0d exceeds BUF_WIDTH=%0d",
                         $time, valid_bits, BUF_WIDTH);
                $stop;
            end
        end
    end

    // Extraction must not occur with insufficient bits
    always @(posedge clk) begin
        if (rst_n && !flush && can_extract) begin
            if (valid_bits < EXTRACT_WIDTH[BITS_CNT_WIDTH-1:0]) begin
                $display("ERROR [continuous_unpack @ %0t]: extracting with only %0d valid bits (need %0d)",
                         $time, valid_bits, EXTRACT_WIDTH);
                $stop;
            end
        end
    end

    // Loading must not overflow the buffer
    always @(posedge clk) begin
        if (rst_n && !flush && can_load) begin
            if (load_bits_after > buf_width_ext) begin
                $display("ERROR [continuous_unpack @ %0t]: load would overflow buffer (post_extract=%0d, IN_WIDTH=%0d, BUF_WIDTH=%0d)",
                         $time, post_extract_valid, IN_WIDTH, BUF_WIDTH);
                $stop;
            end
        end
    end

    // coeff_cnt must stay within ciphertext bounds
    always @(posedge clk) begin
        if (rst_n && !flush) begin
            if (coeff_cnt >= COEFFS_PER_CT) begin
                $display("ERROR [continuous_unpack @ %0t]: coeff_cnt=%0d >= COEFFS_PER_CT=%0d",
                         $time, coeff_cnt, COEFFS_PER_CT);
                $stop;
            end
        end
    end

    `endif

endmodule
