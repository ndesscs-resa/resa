//-----------------------------------------------------------------------------
// Seeded-a accelerator with compact group ingress.
//-----------------------------------------------------------------------------
// This wrapper is the submission CSD input boundary. A single AXI stream
// carries one 256-bit group seed followed by the stored b payload for each
// dimension in that group. This wrapper binds compact storage records to the
// seed sideband consumed by the seeded-a accelerator core.
//
// The output is an encrypted score-ciphertext AXI-Stream. In the system model,
// the surrounding SSD controller consumes this stream and DMA-writes it to the
// host result buffer; the DMA engine is outside this synthesized Resa RTL.
//-----------------------------------------------------------------------------

`default_nettype none

module he_accelerator_seeded_a_ingress #(
    parameter N          = 4096,
    parameter K          = 51,
    parameter ACC_W      = 118,
    parameter NUM_PE     = 16,
    parameter B_PES      = 8,
    parameter A_PES      = 8,
    parameter MAX_DIMS   = 4096,
    parameter SRAM_DEPTH = 512,
    parameter AXIS_W     = 1024
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start,
    output wire                         done,
    output wire                         busy,
    output wire [3:0]                   state_out,

    input  wire [15:0]                  num_groups,
    input  wire [15:0]                  embed_dim,
    input  wire [95:0]                  seed_nonce_base,
    input  wire [31:0]                  seed_counter_base,

    input  wire                         wr_scalar_valid,
    input  wire [K-1:0]                 wr_scalar_data,
    input  wire [$clog2(MAX_DIMS)-1:0]  wr_scalar_addr,

    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    input  wire [AXIS_W-1:0]            s_axis_tdata,

    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready,
    output wire [AXIS_W-1:0]            m_axis_tdata,
    output wire                         m_axis_tlast
);

    wire                 core_seed_valid;
    wire                 core_seed_ready;
    wire [255:0]         core_seed_key;
    wire [95:0]          core_seed_nonce;
    wire [31:0]          core_seed_counter;
    wire                 core_b_valid;
    wire                 core_b_ready;
    wire [AXIS_W-1:0]    core_b_data;

    seeded_a_group_ingress #(
        .N      (N),
        .K      (K),
        .AXIS_W (AXIS_W)
    ) u_ingress (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (start),
        .embed_dim        (embed_dim),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tdata     (s_axis_tdata),
        .seed_nonce_base  (seed_nonce_base),
        .seed_counter_base(seed_counter_base),
        .seed_valid       (core_seed_valid),
        .seed_ready       (core_seed_ready),
        .seed_key         (core_seed_key),
        .seed_nonce       (core_seed_nonce),
        .seed_counter     (core_seed_counter),
        .b_axis_tvalid    (core_b_valid),
        .b_axis_tready    (core_b_ready),
        .b_axis_tdata     (core_b_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .group_idx_debug  (),
        .dim_idx_debug    ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    he_accelerator_seeded_a #(
        .N          (N),
        .K          (K),
        .ACC_W      (ACC_W),
        .NUM_PE     (NUM_PE),
        .B_PES      (B_PES),
        .A_PES      (A_PES),
        .MAX_DIMS   (MAX_DIMS),
        .SRAM_DEPTH (SRAM_DEPTH),
        .AXIS_W     (AXIS_W)
    ) u_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .done            (done),
        .busy            (busy),
        .state_out       (state_out),
        .num_groups      (num_groups),
        .embed_dim       (embed_dim),
        .wr_scalar_valid (wr_scalar_valid),
        .wr_scalar_data  (wr_scalar_data),
        .wr_scalar_addr  (wr_scalar_addr),
        .s_seed_valid    (core_seed_valid),
        .s_seed_ready    (core_seed_ready),
        .s_seed_key      (core_seed_key),
        .s_seed_nonce    (core_seed_nonce),
        .s_seed_counter  (core_seed_counter),
        .s_axis_tvalid   (core_b_valid),
        .s_axis_tready   (core_b_ready),
        .s_axis_tdata    (core_b_data),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tready   (m_axis_tready),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tlast    (m_axis_tlast)
    );

endmodule

`default_nettype wire
