// Blackbox declaration for acc_sram_bank (SRAM area estimated separately via PCACTI)
(* blackbox *)
module acc_sram_bank #(
    parameter DEPTH = 1024,
    parameter WIDTH = 118
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        wr_en,
    input  wire [$clog2(DEPTH)-1:0]    wr_addr,
    input  wire [WIDTH-1:0]            wr_data,
    input  wire                        rd_en,
    input  wire [$clog2(DEPTH)-1:0]    rd_addr,
    output wire [WIDTH-1:0]            rd_data,
    output wire                        rd_valid
);
endmodule
