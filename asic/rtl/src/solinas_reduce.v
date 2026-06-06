//-----------------------------------------------------------------------------
// Solinas Reduction Unit
//-----------------------------------------------------------------------------
// Computes: r = acc mod Q where Q = 2^51 - 2^17 + 1 (Solinas prime)
//
// Key Insight:
//   Since 2^51 == 2^17 - 1 (mod Q), we can reduce without multipliers:
//
//   acc = acc_2 * 2^102 + acc_1 * 2^51 + acc_0
//
//   2^51  mod Q = 2^17 - 1
//   2^102 mod Q = (2^17 - 1)^2 = 2^34 - 2^18 + 1
//
//   Therefore:
//   acc mod Q = acc_0
//             + acc_1 * (2^17 - 1)
//             + acc_2 * (2^34 - 2^18 + 1)
//             (mod Q)
//
// Input: Variable-width accumulator (from lazy MAC operations)
// Output: 51-bit reduced result
//
// acc_2 Width Calculation:
//   acc_2 = acc[ACC_WIDTH-1:102], so ACC2_WIDTH = ACC_WIDTH - 102
//   For ACC_WIDTH=114: ACC2_WIDTH=12, max acc_2 = 4095
//   For ACC_WIDTH=118: ACC2_WIDTH=16, max acc_2 = 65535
//
// Pipeline Stages:
//   Stage 1: Compute term1 and term2 (shift operations)
//   Stage 2: Sum all terms
//   Stage 3: First conditional subtraction (if sum >= 2Q)
//   Stage 4: Final correction (if result >= Q)
//
// Total latency: 4 cycles
// Throughput: 1 result/cycle
//-----------------------------------------------------------------------------

module solinas_reduce #(
    parameter K = 51,                              // Bit-width of modulus
    parameter ACC_WIDTH = 118,                     // Accumulator width (default for MAX_DIMS=65536)
    // Q = 2^51 - 2^17 + 1 = 0x7FFFFFFFE0001
    parameter [K-1:0] Q = 51'h7FFFFFFFE0001
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire [ACC_WIDTH-1:0]    acc,            // Variable-width input accumulator
    output reg                     valid_out,
    output reg  [K-1:0]            r               // 51-bit output
);

    //-------------------------------------------------------------------------
    // Derived Parameters for Variable ACC_WIDTH
    //-------------------------------------------------------------------------
    // acc_2 width depends on ACC_WIDTH: acc_2 = acc[ACC_WIDTH-1:102]
    localparam ACC2_WIDTH = ACC_WIDTH - 102;       // Variable: 12 for 114, 16 for 118, 26 for 128
    // term2 max bits: acc_2 * (2^34) < 2^(ACC2_WIDTH+34)
    localparam TERM2_WIDTH = ACC2_WIDTH + 34;      // 46 for 114, 50 for 118, 60 for 128

    //-------------------------------------------------------------------------
    // Constants derived from Q = 2^51 - 2^17 + 1
    //-------------------------------------------------------------------------
    // c = 2^51 mod Q = 2^17 - 1 = 0x1FFFF (17 bits)
    // c^2 = 2^102 mod Q = 2^34 - 2^18 + 1 (35 bits max value)

    //-------------------------------------------------------------------------
    // Stage 1: Extract fields and compute shifted terms
    //-------------------------------------------------------------------------
    // acc_0 = acc[50:0]           (51 bits)
    // acc_1 = acc[101:51]         (51 bits)
    // acc_2 = acc[ACC_WIDTH-1:102] (variable: ACC2_WIDTH bits)

    reg                         s1_valid;
    reg  [50:0]                 s1_acc_0;
    reg  [67:0]                 s1_term1;         // acc_1 * (2^17 - 1), max 68 bits
    reg  [TERM2_WIDTH-1:0]      s1_term2;         // acc_2 * (2^34 - 2^18 + 1), variable width

    wire [50:0]                 acc_0 = acc[50:0];
    wire [50:0]                 acc_1 = acc[101:51];
    wire [ACC2_WIDTH-1:0]       acc_2 = acc[ACC_WIDTH-1:102];    // Variable width extraction

    // term1 = acc_1 * (2^17 - 1) = (acc_1 << 17) - acc_1
    // Max value: (2^51 - 1) * (2^17 - 1) < 2^68
    wire [67:0]                 term1_shifted = {acc_1, 17'b0};      // acc_1 << 17
    wire [67:0]                 term1_calc = term1_shifted - {17'b0, acc_1};

    // term2 = acc_2 * (2^34 - 2^18 + 1)
    //       = (acc_2 << 34) - (acc_2 << 18) + acc_2
    // Max value: (2^ACC2_WIDTH - 1) * (2^34 - 2^18 + 1) < 2^TERM2_WIDTH
    // Note: TERM2_WIDTH = ACC2_WIDTH + 34, so term2_high needs no padding
    wire [TERM2_WIDTH-1:0]      term2_high = {acc_2, 34'b0};                                          // acc_2 << 34
    wire [ACC2_WIDTH+17:0]      term2_mid  = {acc_2, 18'b0};                                          // acc_2 << 18
    // Padding for subtraction: term2_mid is (ACC2_WIDTH+18) bits, need to extend to TERM2_WIDTH
    // TERM2_WIDTH - (ACC2_WIDTH + 18) = ACC2_WIDTH + 34 - ACC2_WIDTH - 18 = 16 bits
    wire [TERM2_WIDTH-1:0]      term2_calc = term2_high
                                           - {{16{1'b0}}, term2_mid}
                                           + {{34{1'b0}}, acc_2};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid  <= 1'b0;
            s1_acc_0  <= 51'b0;
            s1_term1  <= 68'b0;
            s1_term2  <= {TERM2_WIDTH{1'b0}};
        end else begin
            s1_valid  <= valid_in;
            s1_acc_0  <= acc_0;
            s1_term1  <= term1_calc;
            s1_term2  <= term2_calc;
        end
    end

    //-------------------------------------------------------------------------
    // Stage 2: Sum all terms
    //-------------------------------------------------------------------------
    // sum = acc_0 + term1 + term2
    // Max value < 2^51 + 2^68 + 2^TERM2_WIDTH
    // For ACC_WIDTH <= 128: max < 2^69, so 69-bit sum is sufficient

    reg                     s2_valid;
    reg  [68:0]             s2_sum;       // 69-bit sum (sufficient for all supported ACC_WIDTH)

    // Extend all terms to 69 bits for summation
    wire [68:0]             sum_raw = {18'b0, s1_acc_0}
                                    + {1'b0, s1_term1}
                                    + {{(69-TERM2_WIDTH){1'b0}}, s1_term2};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_sum   <= 69'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_sum   <= sum_raw;
        end
    end

    //-------------------------------------------------------------------------
    // Stage 3: Recursive reduction - apply the same formula to high bits
    //-------------------------------------------------------------------------
    // If sum >= 2^51, we need to reduce again
    // sum = sum_hi * 2^51 + sum_lo
    // sum mod Q = sum_lo + sum_hi * (2^17 - 1) (mod Q)
    //
    // sum_lo = sum[50:0] (51 bits)
    // sum_hi = sum[68:51] (18 bits)
    // term = sum_hi * (2^17 - 1) < 2^18 * 2^17 = 2^35

    reg                     s3_valid;
    reg  [52:0]             s3_result;    // 53-bit intermediate

    wire [50:0]             sum_lo = s2_sum[50:0];
    wire [17:0]             sum_hi = s2_sum[68:51];

    // sum_hi * (2^17 - 1) = (sum_hi << 17) - sum_hi
    wire [34:0]             reduce_term = {sum_hi, 17'b0} - {17'b0, sum_hi};

    // Add to lower portion: result = sum_lo + reduce_term
    // Max: (2^51 - 1) + (2^35 - 1) < 2^52
    wire [52:0]             reduced_sum = {2'b0, sum_lo} + {18'b0, reduce_term};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid  <= 1'b0;
            s3_result <= 53'b0;
        end else begin
            s3_valid  <= s2_valid;
            s3_result <= reduced_sum;
        end
    end

    //-------------------------------------------------------------------------
    // Stage 4: Final conditional subtractions
    //-------------------------------------------------------------------------
    // After stage 3, result < 2^52
    // We may need up to 3 subtractions of Q to get result < Q. The
    // intermediate bound is below 2^52 for the supported accumulator widths,
    // so the prioritized 3Q/2Q/Q correction is conservative.

    // Use 54-bit arithmetic: 3Q ~ 2^52.58 exceeds 53 bits, so 53-bit
    // subtraction cannot reliably detect borrow. Widening to 54 bits
    // ensures MSB is a correct borrow/sign indicator.
    wire [53:0]             q_ext   = {3'b0, Q};
    wire [53:0]             q_2x    = {2'b0, Q, 1'b0};   // Q << 1 = 2Q
    wire [53:0]             q_3x    = q_2x + q_ext;      // 3Q

    /* verilator lint_off UNUSED */
    wire [53:0]             r_minus_Q   = {1'b0, s3_result} - q_ext;
    wire [53:0]             r_minus_2Q  = {1'b0, s3_result} - q_2x;
    wire [53:0]             r_minus_3Q  = {1'b0, s3_result} - q_3x;
    /* verilator lint_on UNUSED */

    wire                    ge_3Q = ~r_minus_3Q[53];     // result >= 3Q
    wire                    ge_2Q = ~r_minus_2Q[53];     // result >= 2Q
    wire                    ge_Q  = ~r_minus_Q[53];      // result >= Q

    wire [50:0]             r_final = ge_3Q ? r_minus_3Q[50:0] :
                                      ge_2Q ? r_minus_2Q[50:0] :
                                      ge_Q  ? r_minus_Q[50:0]  :
                                              s3_result[50:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            r         <= {K{1'b0}};
        end else begin
            valid_out <= s3_valid;
            r         <= r_final;
        end
    end

endmodule
