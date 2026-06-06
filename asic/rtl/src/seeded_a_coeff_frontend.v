//-----------------------------------------------------------------------------
// Seeded-a coefficient frontend: AXI-1024 stored-b stream + ChaCha20 generated-a.
//
// This module is the input side of the b8+a8 accelerator configuration. It
// extracts 8 stored-b coefficients per cycle from a 1024-bit AXI-Stream and
// regenerates 8 public-a coefficients per cycle from a 512-bit/cycle ChaCha20
// stream. Downstream MAC/SRAM/reduction logic should consume 16 coefficients
// per cycle, with b coefficients occupying lanes [0..7] and a coefficients
// lanes [8..15].
//-----------------------------------------------------------------------------

`default_nettype none

module seeded_a_coeff_frontend #(
    parameter K = 51,
    parameter B_PES = 8,
    parameter A_PES = 8,
    parameter AXIS_W = 1024
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush,

    input  wire                         seed_valid,
    input  wire [255:0]                 seed_key,
    input  wire [95:0]                  seed_nonce,
    input  wire [31:0]                  seed_counter,
    output wire                         seed_ready,

    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    input  wire [AXIS_W-1:0]            s_axis_tdata,

    output wire                         coeff_valid,
    input  wire                         coeff_ready,
    output wire [(B_PES+A_PES)*K-1:0]   coeff_data
);

    wire                     b_valid;
    wire                     b_ready;
    wire [B_PES*K-1:0]       b_data;
    wire [12:0]              b_coeff_count;
    wire                     b_ctxt_boundary;

    wire                     a_valid;
    wire                     a_ready;
    wire [A_PES*K-1:0]       a_data;

    assign coeff_valid = b_valid && a_valid;
    assign b_ready = coeff_ready && a_valid;
    assign a_ready = coeff_ready && b_valid;
    assign coeff_data = {a_data, b_data};

    continuous_unpack #(
        .K        (K),
        .NUM_PE   (B_PES),
        .IN_WIDTH (AXIS_W)
    ) u_b_unpack (
        .clk           (clk),
        .rst_n         (rst_n),
        .flush         (flush),
        .s_valid       (s_axis_tvalid),
        .s_ready       (s_axis_tready),
        .s_data        (s_axis_tdata),
        .out_valid     (b_valid),
        .out_ready     (b_ready),
        .out_data      (b_data),
        .coeff_count   (b_coeff_count),
        .ctxt_boundary (b_ctxt_boundary)
    );

    a_seed_expander_chacha20 #(
        .K     (K),
        .A_PES (A_PES)
    ) u_a_expand (
        .clk          (clk),
        .rst_n        (rst_n),
        .seed_valid   (seed_valid),
        .seed_key     (seed_key),
        .seed_nonce   (seed_nonce),
        .seed_counter (seed_counter),
        .seed_ready   (seed_ready),
        // Keep the external a/b coefficient streams aligned. The PRG may fill
        // its internal FIFO ahead of b, but a groups are popped only with a
        // matched b group and a downstream accept.
        .coeff_ready  (a_ready),
        .coeff_data   (a_data),
        .coeff_valid  (a_valid)
    );

    `ifdef SIMULATION
    always @(posedge clk) begin
        if (rst_n && !flush && b_ctxt_boundary) begin
            $display("seeded_a_coeff_frontend: b ciphertext boundary at coeff_count=%0d",
                     b_coeff_count);
        end
    end
    `endif

endmodule

`default_nettype wire
