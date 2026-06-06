//-----------------------------------------------------------------------------
// Fully-pipelined ChaCha20 block function.
//
// The module accepts one counter block per cycle and emits one 512-bit ChaCha20
// block per cycle after 10 double-round pipeline stages. This shape is useful
// for seeded-a expansion: one 512-bit PRG block covers the 8 x 51 = 408 bits
// required by the generated-a lane each cycle.
//-----------------------------------------------------------------------------

`default_nettype none

module chacha20_block_stream (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         flush,

    input  wire         in_valid,
    input  wire [255:0] key,
    input  wire [31:0]  counter,
    input  wire [95:0]  nonce,

    output wire         out_valid,
    output wire [511:0] out_block
);

    localparam [31:0] C0 = 32'h61707865;
    localparam [31:0] C1 = 32'h3320646e;
    localparam [31:0] C2 = 32'h79622d32;
    localparam [31:0] C3 = 32'h6b206574;

    reg [511:0] state_pipe [0:10];
    reg [511:0] init_pipe  [0:10];
    reg [10:0]  valid_pipe;
    wire [511:0] round_out [0:9];

    wire [511:0] init_state = {
        nonce[95:64], nonce[63:32], nonce[31:0], counter,
        key[255:224], key[223:192], key[191:160], key[159:128],
        key[127:96], key[95:64], key[63:32], key[31:0],
        C3, C2, C1, C0
    };

    function [31:0] rotl32;
        input [31:0] x;
        input [4:0] n;
        begin
            rotl32 = (x << n) | (x >> (32 - n));
        end
    endfunction

    function [127:0] quarter_round;
        input [31:0] a_in;
        input [31:0] b_in;
        input [31:0] c_in;
        input [31:0] d_in;
        reg [31:0] a;
        reg [31:0] b;
        reg [31:0] c;
        reg [31:0] d;
        begin
            a = a_in;
            b = b_in;
            c = c_in;
            d = d_in;
            a = a + b; d = rotl32(d ^ a, 5'd16);
            c = c + d; b = rotl32(b ^ c, 5'd12);
            a = a + b; d = rotl32(d ^ a, 5'd8);
            c = c + d; b = rotl32(b ^ c, 5'd7);
            quarter_round = {d, c, b, a};
        end
    endfunction

    function [511:0] double_round;
        input [511:0] s;
        reg [31:0] x0;
        reg [31:0] x1;
        reg [31:0] x2;
        reg [31:0] x3;
        reg [31:0] x4;
        reg [31:0] x5;
        reg [31:0] x6;
        reg [31:0] x7;
        reg [31:0] x8;
        reg [31:0] x9;
        reg [31:0] x10;
        reg [31:0] x11;
        reg [31:0] x12;
        reg [31:0] x13;
        reg [31:0] x14;
        reg [31:0] x15;
        reg [127:0] qr;
        begin
            {x15, x14, x13, x12, x11, x10, x9, x8,
             x7, x6, x5, x4, x3, x2, x1, x0} = s;

            qr = quarter_round(x0, x4, x8, x12);
            {x12, x8, x4, x0} = qr;
            qr = quarter_round(x1, x5, x9, x13);
            {x13, x9, x5, x1} = qr;
            qr = quarter_round(x2, x6, x10, x14);
            {x14, x10, x6, x2} = qr;
            qr = quarter_round(x3, x7, x11, x15);
            {x15, x11, x7, x3} = qr;

            qr = quarter_round(x0, x5, x10, x15);
            {x15, x10, x5, x0} = qr;
            qr = quarter_round(x1, x6, x11, x12);
            {x12, x11, x6, x1} = qr;
            qr = quarter_round(x2, x7, x8, x13);
            {x13, x8, x7, x2} = qr;
            qr = quarter_round(x3, x4, x9, x14);
            {x14, x9, x4, x3} = qr;

            double_round = {x15, x14, x13, x12, x11, x10, x9, x8,
                            x7, x6, x5, x4, x3, x2, x1, x0};
        end
    endfunction

    function [511:0] add_state_words;
        input [511:0] a;
        input [511:0] b;
        integer wi;
        reg [511:0] tmp;
        begin
            tmp = 512'd0;
            for (wi = 0; wi < 16; wi = wi + 1) begin
                tmp[wi*32 +: 32] = a[wi*32 +: 32] + b[wi*32 +: 32];
            end
            add_state_words = tmp;
        end
    endfunction

    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : gen_round_wire
            assign round_out[gi] = double_round(state_pipe[gi]);
        end
    endgenerate

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= 11'd0;
            for (i = 0; i <= 10; i = i + 1) begin
                state_pipe[i] <= 512'd0;
                init_pipe[i] <= 512'd0;
            end
        end else if (flush) begin
            valid_pipe <= 11'd0;
            for (i = 0; i <= 10; i = i + 1) begin
                state_pipe[i] <= 512'd0;
                init_pipe[i] <= 512'd0;
            end
        end else begin
            valid_pipe <= {valid_pipe[9:0], in_valid};
            state_pipe[0] <= init_state;
            init_pipe[0] <= init_state;
            for (i = 0; i < 10; i = i + 1) begin
                state_pipe[i + 1] <= round_out[i];
                init_pipe[i + 1] <= init_pipe[i];
            end
        end
    end

    assign out_valid = valid_pipe[10];
    assign out_block = add_state_words(state_pipe[10], init_pipe[10]);

endmodule

`default_nettype wire
