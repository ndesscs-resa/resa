//-----------------------------------------------------------------------------
// Accumulator SRAM Bank - Single-PE Accumulator Storage
//-----------------------------------------------------------------------------
// Simple dual-port RAM (1 read port, 1 write port) for storing one PE's
// accumulator values. Each entry holds an ACC_W-bit accumulator for one
// output position.
//
// Port Configuration:
//   - Write port: Synchronous write for accumulate writeback and clear
//   - Read port: Synchronous read with 1-cycle latency (registered output)
//
// Timing:
//   Cycle T:   rd_en asserted with rd_addr
//   Cycle T+1: rd_data valid, rd_valid asserted
//
// Concurrent Access:
//   - Normal operation: read addr t, write addr t-2 (due to PE pipeline)
//   - Same-address read/write: write-first behavior (read returns new data)
//   - Different-address read/write: fully concurrent, no hazard
//
// Artifact boundary:
//   - This behavioral memory is used by RTL simulation and control-path checks.
//   - SRAM macro area/power is accounted separately with the PCACTI inputs under
//     asic/sram/ and asic/power/.
//   - DEPTH is supplied by the top-level lane configuration.
//   - The current b8+a8 seeded-a top uses 16 banks x 512 entries, covering the
//     8192 result coefficients for the two ciphertext polynomials.
//-----------------------------------------------------------------------------

module acc_sram_bank #(
    parameter DEPTH = 1024,  // Entries per bank; top-level b8+a8 overrides to 512
    parameter WIDTH = 118    // Accumulator bit width
)(
    input  wire                        clk,
    input  wire                        rst_n,

    //-------------------------------------------------------------------------
    // Write Port (accumulate writeback and clear)
    //-------------------------------------------------------------------------
    input  wire                        wr_en,
    input  wire [$clog2(DEPTH)-1:0]    wr_addr,
    input  wire [WIDTH-1:0]            wr_data,

    //-------------------------------------------------------------------------
    // Read Port (1-cycle latency)
    //-------------------------------------------------------------------------
    input  wire                        rd_en,
    input  wire [$clog2(DEPTH)-1:0]    rd_addr,
    output reg  [WIDTH-1:0]            rd_data,
    output reg                         rd_valid
);

    localparam ADDR_W = $clog2(DEPTH);

    //-------------------------------------------------------------------------
    // Memory Array
    //-------------------------------------------------------------------------
    // Write-first behavior: if read and write target the same address in the
    // same cycle, the read returns the newly written data.

    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    //-------------------------------------------------------------------------
    // Write Port - Synchronous Write
    //-------------------------------------------------------------------------

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    //-------------------------------------------------------------------------
    // Read Port - 1-Cycle Latency (Registered Output)
    //-------------------------------------------------------------------------
    // Write-first: when rd_addr == wr_addr and both enabled, forward wr_data.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data  <= {WIDTH{1'b0}};
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                if (wr_en && (rd_addr == wr_addr)) begin
                    // Write-first: forward new write data
                    rd_data <= wr_data;
                end else begin
                    rd_data <= mem[rd_addr];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation Assertions
    //-------------------------------------------------------------------------
    `ifdef SIMULATION

    // Address bounds checking
    // Note: When DEPTH is a power of 2 and ADDR_W = $clog2(DEPTH), the address
    // can never exceed DEPTH-1, so these checks are compile-time tautologies.
    // Kept for safety with non-power-of-2 DEPTH configurations.
    /* verilator lint_off UNSIGNED */
    /* verilator lint_off CMPCONST */
    always @(posedge clk) begin
        if (rst_n && wr_en) begin
            if ({{1'b0}, wr_addr} >= DEPTH) begin
                $display("ERROR [acc_sram_bank]: Write address out of bounds at time %0t", $time);
                $display("  wr_addr = %0d, DEPTH = %0d", wr_addr, DEPTH);
            end
        end
        if (rst_n && rd_en) begin
            if ({{1'b0}, rd_addr} >= DEPTH) begin
                $display("ERROR [acc_sram_bank]: Read address out of bounds at time %0t", $time);
                $display("  rd_addr = %0d, DEPTH = %0d", rd_addr, DEPTH);
            end
        end
    end
    /* verilator lint_on CMPCONST */
    /* verilator lint_on UNSIGNED */

    `endif

endmodule
