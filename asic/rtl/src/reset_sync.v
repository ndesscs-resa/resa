//-----------------------------------------------------------------------------
// Reset Synchronizer Module
//-----------------------------------------------------------------------------
// Synchronizes asynchronous reset deassertion to the clock domain.
//
// Features:
//   - Asynchronous reset assertion (immediate)
//   - Synchronous reset deassertion (reduces reset-release metastability risk)
//   - Configurable number of synchronizer stages (default: 2)
//
// Usage:
//   - Connect rst_n_async to external asynchronous reset
//   - Use rst_n_sync for all internal synchronous logic
//
// Timing:
//   - Reset assertion: Immediate (asynchronous)
//   - Reset deassertion: STAGES clock cycles after rst_n_async goes high
//
//-----------------------------------------------------------------------------

module reset_sync #(
    parameter STAGES = 2   // Number of synchronizer flip-flop stages
)(
    input  wire clk,           // Clock signal
    input  wire rst_n_async,   // Asynchronous reset (active low)
    output wire rst_n_sync     // Synchronized reset (active low)
);

    // Synchronizer register chain
    // All bits reset to 0 asynchronously, then shift in 1s on clock edges
    reg [STAGES-1:0] sync_reg;

    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) begin
            // Asynchronous reset: all stages go to 0
            sync_reg <= {STAGES{1'b0}};
        end else begin
            // Shift in 1 from LSB, propagate through chain
            sync_reg <= {sync_reg[STAGES-2:0], 1'b1};
        end
    end

    // Output is the last stage of the synchronizer chain
    assign rst_n_sync = sync_reg[STAGES-1];

endmodule
