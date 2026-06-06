//-----------------------------------------------------------------------------
// Scalar Buffer for Inner Product Query
//-----------------------------------------------------------------------------
// Stores query scalars for inner product computation with configurable active
// dimensions up to MAX_DIMS.
//
// Key Features:
//   - 4096 x 51-bit = ~26 KB storage
//   - Variable active dimension support
//   - Single-cycle write latency
//   - Single-cycle read latency (registered output)
//
// Memory Organization:
//   - Linear addressing: addr 0..active_dims-1
//   - Beyond active_dims: undefined (not accessed)
//
// Timing:
//   - Write: wr_valid -> wr_ready (combinational)
//   - Read:  rd_addr -> rd_data (1 cycle latency), rd_valid asserted
//
// Interface:
//   - Write port: Host/DMA loads query scalars
//   - Read port: MAC units read scalars for inner product
//
// Artifact boundary:
//   - This behavioral memory is used by RTL simulation and control-path checks.
//   - ASIC SRAM macro area/power is accounted separately with the PCACTI inputs
//     under asic/sram/ and asic/power/.
//   - No explicit reset of memory contents (overwritten each query)
//-----------------------------------------------------------------------------

module scalar_buffer #(
    parameter K        = 51,                    // Coefficient bit-width
    parameter MAX_DIMS = 4096                   // Maximum supported dimension
)(
    input  wire                           clk,
    input  wire                           rst_n,

    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    input  wire [$clog2(MAX_DIMS+1)-1:0]  active_dims,  // Actual dimension, including MAX_DIMS

    //-------------------------------------------------------------------------
    // Write Interface (from Host/DMA)
    //-------------------------------------------------------------------------
    input  wire                           wr_valid,
    input  wire [K-1:0]                   wr_data,
    input  wire [$clog2(MAX_DIMS)-1:0]    wr_addr,
    output wire                           wr_ready,

    //-------------------------------------------------------------------------
    // Read Interface (to MAC Units)
    //-------------------------------------------------------------------------
    input  wire [$clog2(MAX_DIMS)-1:0]    rd_addr,
    output reg  [K-1:0]                   rd_data,
    output reg                            rd_valid
);

    //-------------------------------------------------------------------------
    // Local Parameters
    //-------------------------------------------------------------------------

    localparam ADDR_WIDTH = $clog2(MAX_DIMS);     // 12 bits for 4096
    localparam DIMS_WIDTH = $clog2(MAX_DIMS + 1); // 13 bits for active_dims=4096

    //-------------------------------------------------------------------------
    // Memory Declaration
    //-------------------------------------------------------------------------
    // Simple dual-port RAM: one write port, one read port.
    // The ASIC synthesis flow blackboxes this memory and accounts for the SRAM
    // macro separately; FPGA/simulation tools may infer a block RAM.

    (* ram_style = "block" *)
    reg [K-1:0] mem [0:MAX_DIMS-1];

    //-------------------------------------------------------------------------
    // Write Logic
    //-------------------------------------------------------------------------
    // Single-cycle write, always ready (no contention in dual-port)

    always @(posedge clk) begin
        if (wr_valid && wr_ready) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // Always ready to accept writes
    assign wr_ready = 1'b1;

    //-------------------------------------------------------------------------
    // Read Logic
    //-------------------------------------------------------------------------
    // Registered read for BRAM compatibility
    // 1 cycle latency: rd_addr -> rd_data

    // Registered read output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data  <= {K{1'b0}};
            rd_valid <= 1'b0;
        end else begin
            rd_data  <= mem[rd_addr];
            rd_valid <= 1'b1;  // Valid 1 cycle after address presented
        end
    end

    //-------------------------------------------------------------------------
    // Optional: Address Range Checking (Simulation Only)
    //-------------------------------------------------------------------------
    `ifdef SIMULATION

    always @(posedge clk) begin
        if (wr_valid && active_dims != 0 &&
            {{(DIMS_WIDTH-ADDR_WIDTH){1'b0}}, wr_addr} >= active_dims) begin
            $display("[%0t] SCALAR_BUFFER WARNING: Write addr %0d exceeds active_dims %0d",
                     $time, wr_addr, active_dims);
        end
        // The read port has no explicit read-enable; outside ST_LOAD_SCALAR the
        // top module may present a don't-care address. Only writes are checked.
    end

    `endif

endmodule
