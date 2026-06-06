//-----------------------------------------------------------------------------
// ChaCha20 seed expander for seeded-a storage.
//
// One fully-pipelined ChaCha20 block stream produces 512 pseudorandom bits per
// cycle after pipeline fill, enough for an A_PES=8 generated-a lane
// (8 x 51 = 408 bits/cycle). The lower A_PES*K bits are consumed as packed
// residues. Enrollment must use the same PRG-to-residue mapping so stored
// ciphertexts and regenerated a-polynomials agree; sampling is handled by the
// enrollment path, while this scoring datapath regenerates the stored stream.
//-----------------------------------------------------------------------------

`default_nettype none

module a_seed_expander_chacha20 #(
    parameter K = 51,
    parameter A_PES = 8,
    parameter FIFO_DEPTH = 16
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   seed_valid,
    input  wire [255:0]           seed_key,
    input  wire [95:0]            seed_nonce,
    input  wire [31:0]            seed_counter,
    output wire                   seed_ready,

    input  wire                   coeff_ready,
    output wire [A_PES*K-1:0]     coeff_data,
    output wire                   coeff_valid
);

    localparam OUT_W = A_PES * K;
    localparam FIFO_ADDR_W = $clog2(FIFO_DEPTH);
    localparam CREDIT_W = FIFO_ADDR_W + 2;

    reg [255:0] key_reg;
    reg [95:0]  nonce_reg;
    reg [31:0]  counter_reg;
    reg         active_reg;
    reg [10:0]  issue_pipe;
    reg [OUT_W-1:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_ADDR_W-1:0] fifo_wr_ptr;
    reg [FIFO_ADDR_W-1:0] fifo_rd_ptr;
    reg [FIFO_ADDR_W:0]   fifo_count;

    wire [511:0] prg_block;
    wire         prg_valid;
    wire         seed_accept = seed_valid && seed_ready;
    wire         pop_fifo = coeff_valid && coeff_ready;
    wire [FIFO_ADDR_W:0] inflight_count;
    wire [CREDIT_W-1:0] fifo_count_ext =
        {{(CREDIT_W-(FIFO_ADDR_W+1)){1'b0}}, fifo_count};
    wire [CREDIT_W-1:0] inflight_count_ext =
        {{(CREDIT_W-(FIFO_ADDR_W+1)){1'b0}}, inflight_count};
    wire [CREDIT_W-1:0] fifo_depth_ext = FIFO_DEPTH[CREDIT_W-1:0];
    wire         fifo_has_credit = (fifo_count_ext + inflight_count_ext) < fifo_depth_ext;
    wire         issue_block = active_reg && fifo_has_credit && !seed_accept;

    assign seed_ready = (!active_reg || (fifo_count == 0 && inflight_count == 0));
    assign coeff_data = fifo_mem[fifo_rd_ptr];
    assign coeff_valid = (fifo_count != 0);

    function [FIFO_ADDR_W:0] popcount11;
        input [10:0] bits;
        integer bi;
        begin
            popcount11 = {(FIFO_ADDR_W+1){1'b0}};
            for (bi = 0; bi < 11; bi = bi + 1) begin
                popcount11 = popcount11 + {{FIFO_ADDR_W{1'b0}}, bits[bi]};
            end
        end
    endfunction

    assign inflight_count = popcount11(issue_pipe);

    chacha20_block_stream u_chacha (
        .clk       (clk),
        .rst_n     (rst_n),
        .flush     (seed_accept),
        .in_valid  (issue_block),
        .key       (key_reg),
        .counter   (counter_reg),
        .nonce     (nonce_reg),
        .out_valid (prg_valid),
        .out_block (prg_block)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_reg <= 256'd0;
            nonce_reg <= 96'd0;
            counter_reg <= 32'd0;
            active_reg <= 1'b0;
            issue_pipe <= 11'd0;
            fifo_wr_ptr <= {FIFO_ADDR_W{1'b0}};
            fifo_rd_ptr <= {FIFO_ADDR_W{1'b0}};
            fifo_count <= {(FIFO_ADDR_W+1){1'b0}};
        end else begin
            if (seed_accept) begin
                key_reg <= seed_key;
                nonce_reg <= seed_nonce;
                counter_reg <= seed_counter;
                active_reg <= 1'b1;
                issue_pipe <= 11'd0;
                fifo_wr_ptr <= {FIFO_ADDR_W{1'b0}};
                fifo_rd_ptr <= {FIFO_ADDR_W{1'b0}};
                fifo_count <= {(FIFO_ADDR_W+1){1'b0}};
            end else if (issue_block) begin
                counter_reg <= counter_reg + 32'd1;
            end

            if (!seed_accept) begin
                issue_pipe <= {issue_pipe[9:0], issue_block};

                if (prg_valid) begin
                    fifo_mem[fifo_wr_ptr] <= prg_block[OUT_W-1:0];
                    fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
                end

                if (pop_fifo) begin
                    fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
                end

                case ({prg_valid, pop_fifo})
                    2'b10: fifo_count <= fifo_count + {{FIFO_ADDR_W{1'b0}}, 1'b1};
                    2'b01: fifo_count <= fifo_count - {{FIFO_ADDR_W{1'b0}}, 1'b1};
                    default: fifo_count <= fifo_count;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
