//-----------------------------------------------------------------------------
// Result Packer - Packs Reduced Coefficients to AXI-Stream Output
//-----------------------------------------------------------------------------
// Accepts NUM_PE x K-bit reduced coefficients per cycle and packs them into
// OUT_WIDTH-bit AXI-Stream output beats. Since 51-bit coefficients don't
// align to 512-bit boundaries, a shift-register accumulator is used.
//
// Architecture:
//   - Input: NUM_PE (8) x K (51) = 408 bits per cycle from Solinas reduce
//   - Output: OUT_WIDTH (512) bits per AXI-Stream beat
//   - Internal: Parameterized shift-register accumulator
//
// Operation:
//   1. Accept NUM_PE x K bits of reduced coefficients per input valid cycle
//   2. Accumulate into shift buffer at current bit position
//   3. When buffer has >= OUT_WIDTH bits, emit one output beat
//   4. Track total coefficients packed; assert tlast at ciphertext boundary
//
// Ciphertext Packing:
//   Total coefficients per ciphertext: 2*N = 8192 (c0 and c1 concatenated)
//   Total bits: 8192 * 51 = 417792 bits
//   Total output beats: ceil(417792 / 512) = 816 beats
//   Last beat has 417792 mod 512 = 0 bits => exactly 816 beats (!)
//   (8192 * 51 = 417792 = 816 * 512, perfect alignment)
//
// Pipeline:
//   - 1-cycle latency from valid input to buffer update
//   - Output available when buffer has >= OUT_WIDTH valid bits
//
// Timing:
//   - Input: Sustained 1 input/cycle from solinas_reduce pipeline
//   - In the seeded-a top, READY_MARGIN_INPUTS reserves enough buffer headroom
//     for reduction-pipeline outputs already in flight when output backpressure
//     deasserts in_ready.
//
// System boundary:
//   - The AXI-Stream output is the encrypted score-ciphertext stream.
//   - The surrounding SSD controller performs host-memory DMA for that stream.
//-----------------------------------------------------------------------------

module result_packer #(
    parameter K         = 51,       // Coefficient bit width
    parameter NUM_PE    = 8,        // Parallel inputs per cycle
    parameter OUT_WIDTH = 512,      // AXI-Stream output width
    parameter TOTAL_COEFFS = 8192,  // Coefficients per result (2*N for both polys)
    parameter BUFFER_BEATS = 3,     // Internal shift-buffer capacity in output beats
    parameter READY_MARGIN_INPUTS = 0 // Extra input groups reserved after in_ready drops
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush,          // Reset state

    // Input: reduced coefficients from solinas_reduce array
    input  wire                         in_valid,
    output wire                         in_ready,
    input  wire [NUM_PE*K-1:0]          in_data,

    // AXI-Stream Master output
    output wire                         m_valid,
    input  wire                         m_ready,
    output wire [OUT_WIDTH-1:0]         m_data,
    output wire                         m_last          // Last beat of ciphertext
);

    //-------------------------------------------------------------------------
    // Derived Parameters
    //-------------------------------------------------------------------------
    localparam INPUT_WIDTH  = NUM_PE * K;
    localparam BUF_WIDTH    = BUFFER_BEATS * OUT_WIDTH;
    localparam BITS_CNT_W   = $clog2(BUF_WIDTH + INPUT_WIDTH + 1);
    localparam TOTAL_BITS   = TOTAL_COEFFS * K;         // 417792
    localparam TOTAL_BEATS  = (TOTAL_BITS + OUT_WIDTH - 1) / OUT_WIDTH; // 816
    localparam READY_BITS    = (READY_MARGIN_INPUTS + 1) * INPUT_WIDTH;

    //-------------------------------------------------------------------------
    // Internal Registers
    //-------------------------------------------------------------------------
    reg  [BUF_WIDTH-1:0]       shift_buf;               // Pack accumulator
    reg  [BITS_CNT_W-1:0]      valid_bits;              // Valid bits in buffer
    reg  [13:0]                coeff_cnt;               // Coefficient counter (14b for >= 8192 compare)
    reg  [9:0]                 beat_cnt;                // Output beat counter

    //-------------------------------------------------------------------------
    // Emit and Accept Conditions
    //-------------------------------------------------------------------------
    // Emit: enough bits in buffer for one output beat AND downstream ready
    wire can_emit = (valid_bits >= OUT_WIDTH[BITS_CNT_W-1:0]) && m_ready;

    // After potential emission, compute remaining valid bits
    wire [BITS_CNT_W-1:0] post_emit_valid = can_emit ?
        (valid_bits - OUT_WIDTH[BITS_CNT_W-1:0]) : valid_bits;

    // Accept: room for input data after potential emission
    wire has_accept_room =
        ((post_emit_valid + INPUT_WIDTH[BITS_CNT_W-1:0]) <= BUF_WIDTH[BITS_CNT_W-1:0]);
    wire has_ready_headroom =
        ((post_emit_valid + READY_BITS[BITS_CNT_W-1:0]) <= BUF_WIDTH[BITS_CNT_W-1:0]);
    wire can_accept = in_valid && has_accept_room;

    //-------------------------------------------------------------------------
    // Output Assignments
    //-------------------------------------------------------------------------
    // Extract the bottom OUT_WIDTH bits as output
    assign m_data  = shift_buf[OUT_WIDTH-1:0];
    assign m_valid = (valid_bits >= OUT_WIDTH[BITS_CNT_W-1:0]);
    assign m_last  = m_valid && m_ready && (beat_cnt == TOTAL_BEATS[9:0] - 10'd1);

    // Accept input when buffer has room
    assign in_ready = has_ready_headroom;

    //-------------------------------------------------------------------------
    // Buffer Update Logic (combinational)
    //-------------------------------------------------------------------------
    // Step 1: After emit - shift down by OUT_WIDTH
    wire [BUF_WIDTH-1:0] buf_after_emit = can_emit ?
        (shift_buf >> OUT_WIDTH) : shift_buf;

    // Clear stale bits above the remaining valid window before OR-ing in the
    // next reduced-coefficient group. This matters when INPUT_WIDTH and
    // OUT_WIDTH are not aligned, including the seeded-a 16x51 -> AXI-1024 path.
    wire [BUF_WIDTH-1:0] post_emit_mask =
        (post_emit_valid == {BITS_CNT_W{1'b0}}) ? {BUF_WIDTH{1'b0}} :
        ({BUF_WIDTH{1'b1}} >> (BUF_WIDTH[BITS_CNT_W-1:0] - post_emit_valid));
    wire [BUF_WIDTH-1:0] buf_after_emit_clean = buf_after_emit & post_emit_mask;

    // Step 2: After accept - insert input data at post_emit_valid position
    wire [BUF_WIDTH-1:0] input_shifted =
        {{(BUF_WIDTH-INPUT_WIDTH){1'b0}}, in_data} << post_emit_valid;

    wire [BUF_WIDTH-1:0] buf_after_accept = can_accept ?
        (buf_after_emit_clean | input_shifted) : buf_after_emit_clean;

    //-------------------------------------------------------------------------
    // Sequential State Update
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_buf  <= {BUF_WIDTH{1'b0}};
            valid_bits <= {BITS_CNT_W{1'b0}};
            coeff_cnt  <= 14'b0;
            beat_cnt   <= 10'b0;
        end else if (flush) begin
            shift_buf  <= {BUF_WIDTH{1'b0}};
            valid_bits <= {BITS_CNT_W{1'b0}};
            coeff_cnt  <= 14'b0;
            beat_cnt   <= 10'b0;
        end else begin
            // Update buffer
            shift_buf <= buf_after_accept;

            // Update valid_bits
            if (can_emit && can_accept) begin
                valid_bits <= valid_bits - OUT_WIDTH[BITS_CNT_W-1:0]
                            + INPUT_WIDTH[BITS_CNT_W-1:0];
            end else if (can_emit) begin
                valid_bits <= valid_bits - OUT_WIDTH[BITS_CNT_W-1:0];
            end else if (can_accept) begin
                valid_bits <= valid_bits + INPUT_WIDTH[BITS_CNT_W-1:0];
            end

            // Update coefficient counter
            if (can_accept) begin
                if (coeff_cnt + NUM_PE[13:0] >= TOTAL_COEFFS[13:0]) begin
                    coeff_cnt <= 14'b0;
                end else begin
                    coeff_cnt <= coeff_cnt + NUM_PE[13:0];
                end
            end

            // Update beat counter
            if (can_emit) begin
                if (beat_cnt == TOTAL_BEATS[9:0] - 10'd1) begin
                    beat_cnt <= 10'b0;
                end else begin
                    beat_cnt <= beat_cnt + 10'd1;
                end
            end
        end
    end

    //=========================================================================
    // Simulation-Only Assertions
    //=========================================================================
    `ifdef SIMULATION

    always @(posedge clk) begin
        if (rst_n && !flush) begin
            if (valid_bits > BUF_WIDTH[BITS_CNT_W-1:0]) begin
                $display("ERROR [result_packer @ %0t]: valid_bits=%0d exceeds BUF_WIDTH=%0d",
                         $time, valid_bits, BUF_WIDTH);
                $stop;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && !flush && can_accept) begin
            if (post_emit_valid + INPUT_WIDTH[BITS_CNT_W-1:0] > BUF_WIDTH[BITS_CNT_W-1:0]) begin
                $display("ERROR [result_packer @ %0t]: accept would overflow buffer",
                         $time);
                $stop;
            end
        end
    end

    `endif

endmodule
