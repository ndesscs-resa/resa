// Blackbox declaration for scalar_buffer (SRAM area estimated separately via PCACTI)
(* blackbox *)
module scalar_buffer #(
    parameter K        = 51,
    parameter MAX_DIMS = 4096
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire [$clog2(MAX_DIMS+1)-1:0]  active_dims,
    input  wire                           wr_valid,
    input  wire [K-1:0]                   wr_data,
    input  wire [$clog2(MAX_DIMS)-1:0]    wr_addr,
    output wire                           wr_ready,
    input  wire [$clog2(MAX_DIMS)-1:0]    rd_addr,
    output wire [K-1:0]                   rd_data,
    output wire                           rd_valid
);
endmodule
