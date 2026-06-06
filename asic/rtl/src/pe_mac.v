//-----------------------------------------------------------------------------
// Stateless Multiply-Add Processing Element
//-----------------------------------------------------------------------------
// Computes: acc_out = acc_in + coeff * scalar
//
// The accumulator lives in external SRAM rather than inside the PE. The PE
// performs one multiply-add step per invocation.
//
// Operation:
//   product  = coeff * scalar          (K-bit x K-bit = 2K-bit)
//   acc_out  = acc_in + product        (ACC_W-bit result)
//
// Overflow Analysis:
//   - product max: (2^K - 1)^2 < 2^(2K) = 2^102
//   - ACC_W = 118 supports up to 2^(118-102) = 2^16 = 65536 accumulations
//     of maximum-value products without overflow
//
// Pipeline (2-stage):
//   Stage 1: Register inputs, compute product = coeff * scalar (102 bits)
//   Stage 2: acc_out = acc_in_delayed + zero-extended product
//
// Total latency: 2 cycles
// Throughput: 1 input/cycle
//
// Note: acc_in arrives from SRAM with 1-cycle read latency. The top-level
// module is responsible for aligning acc_in to arrive at the PE at the
// same cycle as the stage 1 output (i.e., acc_in is valid at stage 2).
//-----------------------------------------------------------------------------

module pe_mac #(
    parameter K     = 51,    // Coefficient bit width
    parameter ACC_W = 118    // Accumulator width
)(
    input  wire             clk,
    input  wire             rst_n,

    //-------------------------------------------------------------------------
    // Input (stage 0)
    //-------------------------------------------------------------------------
    input  wire             valid_in,
    input  wire [K-1:0]     coeff,      // Ciphertext coefficient
    input  wire [K-1:0]     scalar,     // Query scalar (broadcast)
    input  wire [ACC_W-1:0] acc_in,     // Current accumulator from SRAM

    //-------------------------------------------------------------------------
    // Output (stage 2, 2-cycle latency)
    //-------------------------------------------------------------------------
    output reg              valid_out,
    output reg  [ACC_W-1:0] acc_out     // Updated accumulator -> write back to SRAM
);

    //-------------------------------------------------------------------------
    // Stage 1: Input registration and multiplication
    //-------------------------------------------------------------------------
    // Register coeff and scalar, compute 102-bit product.
    // acc_in is NOT registered here; it will be registered in stage 2
    // after the SRAM read latency has been absorbed by the top module.

    reg                     s1_valid;
    reg  [2*K-1:0]          s1_product;   // 102-bit product
    reg  [ACC_W-1:0]        s1_acc_in;    // Delay acc_in to align with product

    wire [2*K-1:0]          mult_result = coeff * scalar;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid   <= 1'b0;
            s1_product <= {(2*K){1'b0}};
            s1_acc_in  <= {ACC_W{1'b0}};
        end else begin
            s1_valid   <= valid_in;
            s1_product <= mult_result;
            s1_acc_in  <= acc_in;
        end
    end

    //-------------------------------------------------------------------------
    // Stage 2: Accumulate - acc_out = acc_in_delayed + product
    //-------------------------------------------------------------------------
    // Zero-extend the 102-bit product to ACC_W bits before addition.
    // No overflow: ACC_W = 118 guarantees headroom for 65536 accumulations.

    wire [ACC_W-1:0]        product_ext = {{(ACC_W-2*K){1'b0}}, s1_product};
    wire [ACC_W-1:0]        sum         = s1_acc_in + product_ext;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            acc_out   <= {ACC_W{1'b0}};
        end else begin
            valid_out <= s1_valid;
            acc_out   <= sum;
        end
    end

    //-------------------------------------------------------------------------
    // Simulation Assertions
    //-------------------------------------------------------------------------
    `ifdef SIMULATION

    // Check that acc_out did not overflow (MSB should not wrap around)
    // If acc_in + product < acc_in, overflow occurred
    always @(posedge clk) begin
        if (rst_n && s1_valid) begin
            if (sum < s1_acc_in && s1_product != {(2*K){1'b0}}) begin
                $display("ERROR [pe_mac]: Accumulator overflow detected at time %0t", $time);
                $display("  acc_in  = %0h", s1_acc_in);
                $display("  product = %0h", s1_product);
                $display("  sum     = %0h", sum);
            end
        end
    end

    `endif

endmodule
