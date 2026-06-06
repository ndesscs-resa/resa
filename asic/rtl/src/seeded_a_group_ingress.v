//-----------------------------------------------------------------------------
// Seeded-a group ingress parser.
//-----------------------------------------------------------------------------
// Compact input stream format:
//
//   group_record = group_seed_key || b_payload[dim 0] || ... || b_payload[dim d-1]
//
// The 256-bit group seed is secret-independent PRG seed material for the public
// a component. The parser reuses that key within the group only with a distinct
// public nonce for each dimension, so the generated a-polynomials are distinct.
// Stored b payloads are forwarded as a continuous AXI stream to the existing
// seeded-a datapath.
//-----------------------------------------------------------------------------

`default_nettype none

module seeded_a_group_ingress #(
    parameter N = 4096,
    parameter K = 51,
    parameter AXIS_W = 1024,
    parameter BUFFER_BEATS = 4
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 flush,

    input  wire [15:0]          embed_dim,

    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire [AXIS_W-1:0]    s_axis_tdata,

    input  wire [95:0]          seed_nonce_base,
    input  wire [31:0]          seed_counter_base,

    output wire                 seed_valid,
    input  wire                 seed_ready,
    output wire [255:0]         seed_key,
    output wire [95:0]          seed_nonce,
    output wire [31:0]          seed_counter,

    output wire                 b_axis_tvalid,
    input  wire                 b_axis_tready,
    output wire [AXIS_W-1:0]    b_axis_tdata,

    output wire [15:0]          group_idx_debug,
    output wire [15:0]          dim_idx_debug
);

    localparam SEED_W = 256;
    localparam B_BITS = N * K;
    localparam BUF_WIDTH = (BUFFER_BEATS + 1) * AXIS_W + SEED_W;
    localparam BITS_CNT_W = $clog2(BUF_WIDTH + 1);
    localparam DIM_BITS_W = $clog2(((B_BITS > BUF_WIDTH) ? B_BITS : BUF_WIDTH) + 1);

    localparam [0:0] ST_READ_GROUP_SEED = 1'b0;
    localparam [0:0] ST_DIM_STREAM      = 1'b1;

    localparam [BITS_CNT_W-1:0] SEED_W_C = SEED_W;
    localparam [BITS_CNT_W-1:0] AXIS_W_C = AXIS_W;
    localparam [BITS_CNT_W-1:0] BUF_WIDTH_C = BUF_WIDTH;
    localparam [DIM_BITS_W-1:0] B_BITS_C = B_BITS;
    localparam [DIM_BITS_W-1:0] AXIS_W_DIM_C = AXIS_W;

    reg                         state;
    reg [BUF_WIDTH-1:0]         shift_buf;
    reg [BITS_CNT_W-1:0]        valid_bits;
    reg [255:0]                 group_seed_key;
    reg [15:0]                  group_idx;
    reg [15:0]                  dim_idx;
    reg [15:0]                  embed_dim_r;
    reg [DIM_BITS_W-1:0]        dim_bits_remaining;
    reg                         seed_sent;

    wire [DIM_BITS_W-1:0] b_emit_bits =
        (dim_bits_remaining > AXIS_W_DIM_C) ? AXIS_W_DIM_C : dim_bits_remaining;
    wire [BITS_CNT_W-1:0] b_emit_bits_count = b_emit_bits[BITS_CNT_W-1:0];

    wire seed_load_fire =
        (state == ST_READ_GROUP_SEED) && (valid_bits >= SEED_W_C);
    wire b_can_emit =
        (state == ST_DIM_STREAM) &&
        (dim_bits_remaining != {DIM_BITS_W{1'b0}}) &&
        (valid_bits >= b_emit_bits_count);
    wire b_fire = !flush && b_can_emit && b_axis_tready;
    wire seed_fire = !flush && (state == ST_DIM_STREAM) && !seed_sent && seed_ready;

    reg [BITS_CNT_W-1:0] pop_bits;
    reg [BUF_WIDTH-1:0]  buf_after_pop_clean;
    reg [BITS_CNT_W-1:0] bits_after_pop;
    reg [DIM_BITS_W-1:0] dim_bits_remaining_next;
    reg                  seed_sent_next;
    reg                  dim_done_next;

    wire [BITS_CNT_W:0] room_after_pop =
        {1'b0, bits_after_pop} + {1'b0, AXIS_W_C};
    wire has_load_room = (room_after_pop <= {1'b0, BUF_WIDTH_C});
    wire input_fire = s_axis_tvalid && !flush && has_load_room;
    wire [BUF_WIDTH-1:0] input_shifted =
        {{(BUF_WIDTH-AXIS_W){1'b0}}, s_axis_tdata} << bits_after_pop;
    wire [BUF_WIDTH-1:0] buf_after_load =
        input_fire ? (buf_after_pop_clean | input_shifted) : buf_after_pop_clean;
    wire [BITS_CNT_W-1:0] valid_bits_after_load =
        input_fire ? (bits_after_pop + AXIS_W_C) : bits_after_pop;

    assign s_axis_tready = !flush && has_load_room;

    assign seed_valid = !flush && (state == ST_DIM_STREAM) && !seed_sent;
    assign seed_key = group_seed_key;
    assign seed_nonce = seed_nonce_base ^ {32'h48454442, group_idx, dim_idx, 32'h00000000};
    assign seed_counter = seed_counter_base;

    assign b_axis_tvalid = !flush && b_can_emit;
    assign b_axis_tdata = shift_buf[AXIS_W-1:0] & axis_low_mask(b_emit_bits);

    assign group_idx_debug = group_idx;
    assign dim_idx_debug = dim_idx;

    function [BUF_WIDTH-1:0] valid_low_mask;
        input [BITS_CNT_W-1:0] nbits;
        begin
            if (nbits == {BITS_CNT_W{1'b0}}) begin
                valid_low_mask = {BUF_WIDTH{1'b0}};
            end else if (nbits >= BUF_WIDTH_C) begin
                valid_low_mask = {BUF_WIDTH{1'b1}};
            end else begin
                valid_low_mask = {BUF_WIDTH{1'b1}} >> (BUF_WIDTH_C - nbits);
            end
        end
    endfunction

    function [AXIS_W-1:0] axis_low_mask;
        input [DIM_BITS_W-1:0] nbits;
        begin
            if (nbits == {DIM_BITS_W{1'b0}}) begin
                axis_low_mask = {AXIS_W{1'b0}};
            end else if (nbits >= AXIS_W_DIM_C) begin
                axis_low_mask = {AXIS_W{1'b1}};
            end else begin
                axis_low_mask = {AXIS_W{1'b1}} >> (AXIS_W_DIM_C - nbits);
            end
        end
    endfunction

    always @(*) begin
        if (seed_load_fire) begin
            pop_bits = SEED_W_C;
        end else if (b_fire) begin
            pop_bits = b_emit_bits_count;
        end else begin
            pop_bits = {BITS_CNT_W{1'b0}};
        end

        bits_after_pop = valid_bits - pop_bits;
        buf_after_pop_clean = (shift_buf >> pop_bits) & valid_low_mask(bits_after_pop);

        dim_bits_remaining_next = dim_bits_remaining;
        seed_sent_next = seed_sent;
        if (state == ST_DIM_STREAM) begin
            if (seed_fire) begin
                seed_sent_next = 1'b1;
            end
            if (b_fire) begin
                dim_bits_remaining_next = dim_bits_remaining - b_emit_bits;
            end
        end
        dim_done_next = (state == ST_DIM_STREAM) &&
                        (dim_bits_remaining_next == {DIM_BITS_W{1'b0}}) &&
                        seed_sent_next;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_READ_GROUP_SEED;
            shift_buf <= {BUF_WIDTH{1'b0}};
            valid_bits <= {BITS_CNT_W{1'b0}};
            group_seed_key <= 256'd0;
            group_idx <= 16'd0;
            dim_idx <= 16'd0;
            embed_dim_r <= 16'd0;
            dim_bits_remaining <= B_BITS_C;
            seed_sent <= 1'b0;
        end else if (flush) begin
            state <= ST_READ_GROUP_SEED;
            shift_buf <= {BUF_WIDTH{1'b0}};
            valid_bits <= {BITS_CNT_W{1'b0}};
            group_seed_key <= 256'd0;
            group_idx <= 16'd0;
            dim_idx <= 16'd0;
            embed_dim_r <= embed_dim;
            dim_bits_remaining <= B_BITS_C;
            seed_sent <= 1'b0;
        end else begin
            shift_buf <= buf_after_load;
            valid_bits <= valid_bits_after_load;

            if (seed_load_fire) begin
                group_seed_key <= shift_buf[SEED_W-1:0];
                state <= ST_DIM_STREAM;
                dim_bits_remaining <= B_BITS_C;
                seed_sent <= 1'b0;
            end else if (state == ST_DIM_STREAM) begin
                if (dim_done_next) begin
                    dim_bits_remaining <= B_BITS_C;
                    seed_sent <= 1'b0;
                    if (dim_idx + 16'd1 >= embed_dim_r) begin
                        dim_idx <= 16'd0;
                        group_idx <= group_idx + 16'd1;
                        state <= ST_READ_GROUP_SEED;
                    end else begin
                        dim_idx <= dim_idx + 16'd1;
                    end
                end else begin
                    dim_bits_remaining <= dim_bits_remaining_next;
                    seed_sent <= seed_sent_next;
                end
            end
        end
    end

    `ifdef SIMULATION
    /* verilator lint_off SYNCASYNCNET */
    always @(posedge clk) begin
        if (rst_n && !flush && valid_bits > BUF_WIDTH_C) begin
            $display("ERROR [seeded_a_group_ingress @ %0t]: valid_bits=%0d exceeds buffer width=%0d",
                     $time, valid_bits, BUF_WIDTH);
            $stop;
        end
    end
    /* verilator lint_on SYNCASYNCNET */
    `endif

endmodule

`default_nettype wire
