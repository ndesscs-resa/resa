//-----------------------------------------------------------------------------
// Top-Level Integration Testbench: he_accelerator_seeded_a
//-----------------------------------------------------------------------------
// Tests the complete FSM flow of the Resa PCMV engine and checks the packed
// output against an exact software oracle for a nonzero query scalar.
//
// Test Coverage:
//   1. Reset and initialization
//   2. Query vector loading
//   3. Single group processing (INIT_GROUP -> WAIT_BUF -> LOAD_SCALAR -> PROCESS -> ...)
//   4. Result output verification against exact b/a seeded-a oracle
//   5. Optional multi-group sequential processing when TB_NUM_GROUPS > 1
//
// Parameters overridden for faster simulation:
//   - TB_DIM = 1 (instead of the paper-scale embedding dimension)
//   - SRAM_DEPTH = 64 (instead of 512)
//   - TB_NUM_GROUPS = 1 (instead of 245)
//
// Run: iverilog -g2012 -o tb_he_accelerator_seeded_a.vvp tb_he_accelerator_seeded_a.v <sources>
//      vvp tb_he_accelerator_seeded_a.vvp
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_he_accelerator_seeded_a;

    //=========================================================================
    // Testbench Parameters (smaller values for fast simulation)
    //=========================================================================
    // Match DUT parameters but scaled down
    // N must be multiple of 512 for perfect 1024-bit output alignment:
    //   2*N*51 must be divisible by 1024
    //   GCD(51,1024)=1, so 2*N must be multiple of 1024.
    localparam N          = 512;        // Minimum aligned value for AXI-1024 output
    localparam K          = 51;         // Coefficient bit width (unchanged)
    localparam ACC_W      = 118;        // Accumulator width (unchanged)
    localparam NUM_PE     = 16;          // Parallel PEs
    localparam B_PES      = 8;
    localparam A_PES      = 8;
    localparam MAX_DIMS   = 64;         // Reduced from 4096
    localparam SRAM_DEPTH = 64;         // N/8 = 512/8 = 64
    localparam AXIS_W     = 1024;        // AXI-Stream width

    // Test configuration
    localparam TB_DIM       = 1;        // Embedding dimensions to test
    localparam TB_NUM_GROUPS = 1;       // Number of vector groups to test

    // Derived
    localparam TOTAL_COEFFS = 2 * N;    // 1024 coefficients per ciphertext
    localparam SCALAR_ADDR_W = $clog2(MAX_DIMS);
    localparam TOTAL_B_COEFFS = SRAM_DEPTH * B_PES;
    localparam TOTAL_B_BITS = TOTAL_B_COEFFS * K;
    localparam TOTAL_B_WORDS = (TOTAL_B_BITS + AXIS_W - 1) / AXIS_W;
    localparam TOTAL_OUT_BITS = TOTAL_COEFFS * K;

    //=========================================================================
    // DUT Signals
    //=========================================================================
    reg                         clk;
    reg                         rst_n;
    reg                         start;
    wire                        done;
    wire                        busy;
    wire [3:0]                  state_out;
    reg  [15:0]                 num_groups;
    reg  [15:0]                 embed_dim;

    // Scalar write port
    reg                         wr_scalar_valid;
    reg  [K-1:0]                wr_scalar_data;
    reg  [SCALAR_ADDR_W-1:0]    wr_scalar_addr;

    // Seed sideband
    reg                         s_seed_valid;
    wire                        s_seed_ready;
    reg  [255:0]                s_seed_key;
    reg  [95:0]                 s_seed_nonce;
    reg  [31:0]                 s_seed_counter;

    // AXI-Stream Slave (ciphertext input)
    reg                         s_axis_tvalid;
    wire                        s_axis_tready;
    reg  [AXIS_W-1:0]           s_axis_tdata;

    // AXI-Stream Master (result output)
    wire                        m_axis_tvalid;
    reg                         m_axis_tready;
    wire [AXIS_W-1:0]           m_axis_tdata;
    wire                        m_axis_tlast;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    he_accelerator_seeded_a #(
        .N          (N),
        .K          (K),
        .ACC_W      (ACC_W),
        .NUM_PE     (NUM_PE),
        .MAX_DIMS   (MAX_DIMS),
        .SRAM_DEPTH (SRAM_DEPTH),
        .AXIS_W     (AXIS_W)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .done           (done),
        .busy           (busy),
        .state_out      (state_out),
        .num_groups     (num_groups),
        .embed_dim      (embed_dim),
        .wr_scalar_valid(wr_scalar_valid),
        .wr_scalar_data (wr_scalar_data),
        .wr_scalar_addr (wr_scalar_addr),
        .s_seed_valid   (s_seed_valid),
        .s_seed_ready   (s_seed_ready),
        .s_seed_key     (s_seed_key),
        .s_seed_nonce   (s_seed_nonce),
        .s_seed_counter (s_seed_counter),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tlast   (m_axis_tlast)
    );

    //=========================================================================
    // Clock Generation (10ns period = 100MHz)
    //=========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    //=========================================================================
    // Timeout Watchdog
    //=========================================================================
    initial begin
        #20000000;  // 20ms testbench timeout
        $display("TIMEOUT: Test did not complete within 20ms");
        $finish;
    end

    //=========================================================================
    // Test Counters
    //=========================================================================
    integer errors = 0;
    integer test_num = 0;
    integer i, j, k;
    integer input_word_idx;

    //=========================================================================
    // FSM State Decoding (for debug)
    //=========================================================================
    localparam [3:0]
        ST_IDLE       = 4'd0,
        ST_INIT_GROUP = 4'd1,
        ST_WAIT_BUF   = 4'd2,
        ST_LOAD_SCALAR= 4'd3,
        ST_PROCESS    = 4'd4,
        ST_NEXT_DIM   = 4'd5,
        ST_REDUCE     = 4'd6,
        ST_WRITEBACK  = 4'd7,
        ST_NEXT_GROUP = 4'd8,
        ST_DONE       = 4'd9;

    reg [12*8-1:0] state_name;
    always @(*) begin
        case (state_out)
            ST_IDLE:        state_name = "IDLE        ";
            ST_INIT_GROUP:  state_name = "INIT_GROUP  ";
            ST_WAIT_BUF:    state_name = "WAIT_BUF    ";
            ST_LOAD_SCALAR: state_name = "LOAD_SCALAR ";
            ST_PROCESS:     state_name = "PROCESS     ";
            ST_NEXT_DIM:    state_name = "NEXT_DIM    ";
            ST_REDUCE:      state_name = "REDUCE      ";
            ST_WRITEBACK:   state_name = "WRITEBACK   ";
            ST_NEXT_GROUP:  state_name = "NEXT_GROUP  ";
            ST_DONE:        state_name = "DONE        ";
            default:        state_name = "UNKNOWN     ";
        endcase
    end

    //=========================================================================
    // Test Data Storage
    //=========================================================================
    // Query scalars: q[d]
    reg [K-1:0] query_scalars [0:MAX_DIMS-1];

    // Track output beats for verification
    integer output_beat_count;
    integer output_ready_cycle;
    integer group_done_count;
    reg [TOTAL_OUT_BITS-1:0] output_bits;
    reg [AXIS_W-1:0] packed_b_mem [0:TOTAL_B_WORDS-1];
    reg drive_b_stream;

    always @(posedge clk) begin
        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            if (output_beat_count * AXIS_W < TOTAL_OUT_BITS)
                output_bits[output_beat_count * AXIS_W +: AXIS_W] = m_axis_tdata;
            output_beat_count = output_beat_count + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_word_idx <= 0;
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= {AXIS_W{1'b0}};
        end else if (drive_b_stream) begin
            integer next_word_idx;
            next_word_idx = input_word_idx;
            if (s_axis_tvalid && s_axis_tready)
                next_word_idx = input_word_idx + 1;
            input_word_idx <= next_word_idx;
            if (next_word_idx < TOTAL_B_WORDS) begin
                s_axis_tvalid <= 1'b1;
                s_axis_tdata <= packed_b_mem[next_word_idx];
            end else begin
                s_axis_tvalid <= 1'b0;
                s_axis_tdata <= {AXIS_W{1'b0}};
            end
        end else begin
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= {AXIS_W{1'b0}};
        end
    end

    //=========================================================================
    // Helper Tasks
    //=========================================================================

    // Wait for specific FSM state
    task wait_for_state(input [3:0] target_state, input integer max_cycles);
        integer cnt;
        begin
            cnt = 0;
            while (state_out != target_state && cnt < max_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
            if (cnt >= max_cycles) begin
                $display("ERROR: Timeout waiting for state %0d, stuck in %0d", target_state, state_out);
                errors = errors + 1;
            end
        end
    endtask

    // Write query scalar
    task write_scalar(input [SCALAR_ADDR_W-1:0] addr, input [K-1:0] data);
        begin
            @(posedge clk);
            wr_scalar_valid <= 1'b1;
            wr_scalar_addr  <= addr;
            wr_scalar_data  <= data;
            @(posedge clk);
            wr_scalar_valid <= 1'b0;
        end
    endtask

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
            a = a_in; b = b_in; c = c_in; d = d_in;
            a = a + b; d = rotl32(d ^ a, 5'd16);
            c = c + d; b = rotl32(b ^ c, 5'd12);
            a = a + b; d = rotl32(d ^ a, 5'd8);
            c = c + d; b = rotl32(b ^ c, 5'd7);
            quarter_round = {d, c, b, a};
        end
    endfunction

    function [511:0] double_round;
        input [511:0] s;
        reg [31:0] x0; reg [31:0] x1; reg [31:0] x2; reg [31:0] x3;
        reg [31:0] x4; reg [31:0] x5; reg [31:0] x6; reg [31:0] x7;
        reg [31:0] x8; reg [31:0] x9; reg [31:0] x10; reg [31:0] x11;
        reg [31:0] x12; reg [31:0] x13; reg [31:0] x14; reg [31:0] x15;
        reg [127:0] qr;
        begin
            {x15, x14, x13, x12, x11, x10, x9, x8,
             x7, x6, x5, x4, x3, x2, x1, x0} = s;
            qr = quarter_round(x0, x4, x8, x12); {x12, x8, x4, x0} = qr;
            qr = quarter_round(x1, x5, x9, x13); {x13, x9, x5, x1} = qr;
            qr = quarter_round(x2, x6, x10, x14); {x14, x10, x6, x2} = qr;
            qr = quarter_round(x3, x7, x11, x15); {x15, x11, x7, x3} = qr;
            qr = quarter_round(x0, x5, x10, x15); {x15, x10, x5, x0} = qr;
            qr = quarter_round(x1, x6, x11, x12); {x12, x11, x6, x1} = qr;
            qr = quarter_round(x2, x7, x8, x13); {x13, x8, x7, x2} = qr;
            qr = quarter_round(x3, x4, x9, x14); {x14, x9, x4, x3} = qr;
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
            for (wi = 0; wi < 16; wi = wi + 1)
                tmp[wi*32 +: 32] = a[wi*32 +: 32] + b[wi*32 +: 32];
            add_state_words = tmp;
        end
    endfunction

    function [511:0] chacha_block;
        input [255:0] key;
        input [31:0] counter;
        input [95:0] nonce;
        integer ri;
        reg [511:0] init;
        reg [511:0] s;
        begin
            init = {nonce[95:64], nonce[63:32], nonce[31:0], counter,
                    key[255:224], key[223:192], key[191:160], key[159:128],
                    key[127:96], key[95:64], key[63:32], key[31:0],
                    32'h6b206574, 32'h79622d32, 32'h3320646e, 32'h61707865};
            s = init;
            for (ri = 0; ri < 10; ri = ri + 1)
                s = double_round(s);
            chacha_block = add_state_words(s, init);
        end
    endfunction

    function [K-1:0] b_coeff_at;
        input integer idx;
        begin
            b_coeff_at = ((idx * 17) + 5) & {K{1'b1}};
        end
    endfunction

    function [K-1:0] expected_coeff_at;
        input integer coeff_idx;
        integer addr;
        integer lane;
        integer b_idx;
        integer a_lane;
        reg [K-1:0] raw_coeff;
        reg [511:0] block;
        reg [2*K-1:0] product;
        begin
            addr = coeff_idx / NUM_PE;
            lane = coeff_idx % NUM_PE;
            if (lane < B_PES) begin
                b_idx = addr * B_PES + lane;
                raw_coeff = b_coeff_at(b_idx);
            end else begin
                a_lane = lane - B_PES;
                block = chacha_block(s_seed_key, 32'h00000001 + addr, s_seed_nonce);
                raw_coeff = block[a_lane*K +: K];
            end
            product = raw_coeff * query_scalars[0];
            expected_coeff_at = product % 51'h7FFFFFFFE0001;
        end
    endfunction

    task pack_b_coefficients;
        integer ci;
        integer bit_pos;
        integer wi;
        integer bi;
        reg [K-1:0] coeff;
        begin
            for (wi = 0; wi < TOTAL_B_WORDS; wi = wi + 1)
                packed_b_mem[wi] = {AXIS_W{1'b0}};
            for (ci = 0; ci < TOTAL_B_COEFFS; ci = ci + 1) begin
                coeff = b_coeff_at(ci);
                for (bi = 0; bi < K; bi = bi + 1) begin
                    bit_pos = ci * K + bi;
                    packed_b_mem[bit_pos / AXIS_W][bit_pos % AXIS_W] = coeff[bi];
                end
            end
        end
    endtask

    task check_output_coefficients;
        integer ci;
        reg [K-1:0] got;
        reg [K-1:0] exp;
        integer local_errors;
        begin
            local_errors = 0;
            for (ci = 0; ci < TOTAL_COEFFS; ci = ci + 1) begin
                got = output_bits[ci*K +: K];
                exp = expected_coeff_at(ci);
                if (got !== exp) begin
                    if (local_errors < 40)
                        $display("  FAIL coeff[%0d]: got=0x%0h expected=0x%0h", ci, got, exp);
                    local_errors = local_errors + 1;
                end
            end
            if (local_errors == 0) begin
                $display("  PASS: all %0d packed output coefficients match oracle", TOTAL_COEFFS);
            end else begin
                $display("  FAIL: %0d packed output coefficient mismatches", local_errors);
                errors = errors + local_errors;
            end
        end
    endtask

    //=========================================================================
    // Main Test Sequence
    //=========================================================================
    initial begin
        $dumpfile("tb_he_accelerator_seeded_a.vcd");
        $dumpvars(0, tb_he_accelerator_seeded_a);

        // Initialize signals
        rst_n           = 0;
        start           = 0;
        num_groups      = 0;
        embed_dim       = 0;
        wr_scalar_valid = 0;
        wr_scalar_data  = 0;
        wr_scalar_addr  = 0;
        s_seed_valid    = 0;
        s_seed_key      = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
        s_seed_nonce    = 96'h000000090000004a00000000;
        s_seed_counter  = 32'h00000001;
        s_axis_tvalid   = 0;
        s_axis_tdata    = 0;
        drive_b_stream  = 0;
        m_axis_tready   = 1;
        output_ready_cycle = 0;
        output_beat_count = 0;
        group_done_count = 0;
        output_bits = {TOTAL_OUT_BITS{1'b0}};
        pack_b_coefficients;

        $display("");
        $display("========================================");
        $display("tb_he_accelerator_seeded_a: Integration Test");
        $display("========================================");
        $display("Parameters:");
        $display("  N          = %0d (ring dimension)", N);
        $display("  K          = %0d (coeff bits)", K);
        $display("  NUM_PE     = %0d", NUM_PE);
        $display("  SRAM_DEPTH = %0d", SRAM_DEPTH);
        $display("  TB_DIM     = %0d (embedding dims)", TB_DIM);
        $display("  TB_NUM_GROUPS = %0d", TB_NUM_GROUPS);
        $display("");

        //---------------------------------------------------------------------
        // Test 1: Reset and Initial State
        //---------------------------------------------------------------------
        test_num = 1;
        $display("[Test %0d] Reset and Initial State", test_num);

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        if (state_out !== ST_IDLE) begin
            $display("  FAIL: FSM not in IDLE after reset (state=%0d)", state_out);
            errors = errors + 1;
        end else begin
            $display("  PASS: FSM in IDLE state");
        end

        if (busy !== 1'b0) begin
            $display("  FAIL: busy should be 0 after reset");
            errors = errors + 1;
        end else begin
            $display("  PASS: busy=0 after reset");
        end

        if (done !== 1'b0) begin
            $display("  FAIL: done should be 0 after reset");
            errors = errors + 1;
        end else begin
            $display("  PASS: done=0 after reset");
        end

        //---------------------------------------------------------------------
        // Test 2: Query Scalar Loading
        //---------------------------------------------------------------------
        test_num = 2;
        $display("");
        $display("[Test %0d] Query Scalar Loading", test_num);

        // Load deterministic nonzero query scalars so the packed output can be
        // checked against an exact software oracle.
        for (i = 0; i < TB_DIM; i = i + 1) begin
            query_scalars[i] = 51'd17;
            write_scalar(i[SCALAR_ADDR_W-1:0], query_scalars[i]);
        end

        $display("  Loaded %0d nonzero query scalars", TB_DIM);
        $display("  PASS: Query scalars loaded");

        //---------------------------------------------------------------------
        // Test 3: Start Processing and FSM Transitions
        //---------------------------------------------------------------------
        test_num = 3;
        $display("");
        $display("[Test %0d] Start Processing - FSM Transitions", test_num);

        // Configure
        num_groups = TB_NUM_GROUPS;
        embed_dim  = TB_DIM;
        input_word_idx = 0;
        drive_b_stream = 1'b1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Check immediate transition to INIT_GROUP
        repeat (3) @(posedge clk);  // Allow reset_sync + state transition

        if (busy !== 1'b1) begin
            $display("  FAIL: busy should be 1 after start");
            errors = errors + 1;
        end else begin
            $display("  PASS: busy=1 after start");
        end

        // Wait for INIT_GROUP
        wait_for_state(ST_INIT_GROUP, 20);
        if (state_out == ST_INIT_GROUP) begin
            $display("  PASS: Entered INIT_GROUP state");
        end

        // INIT_GROUP takes SRAM_DEPTH cycles.
        wait_for_state(ST_WAIT_BUF, 4 * SRAM_DEPTH);
        if (state_out == ST_WAIT_BUF) begin
            $display("  PASS: Transitioned to WAIT_BUF");
        end

        //---------------------------------------------------------------------
        // Test 4: Single Group Processing Flow
        //---------------------------------------------------------------------
        test_num = 4;
        $display("");
        $display("[Test %0d] Single Group Processing", test_num);

        // In WAIT_BUF, need to provide data
        // Provide s_axis_tvalid to trigger LOAD_SCALAR transition

        // Process all dimensions for first group
        for (i = 0; i < TB_DIM; i = i + 1) begin
            // Wait for WAIT_BUF or LOAD_SCALAR
            while (state_out != ST_WAIT_BUF && state_out != ST_LOAD_SCALAR && state_out != ST_PROCESS) begin
                @(posedge clk);
            end

            if (state_out == ST_WAIT_BUF) begin
                // The background AXI driver is already holding the first real
                // stored-b word valid; this triggers LOAD_SCALAR and later
                // handshakes only when the DUT enters PROCESS.
                while (dut.state != ST_PROCESS) @(posedge clk);
            end

            // Wait for PROCESS
            wait_for_state(ST_PROCESS, 100);
            if (state_out == ST_PROCESS && i == 0) begin
                $display("  PASS: Entered PROCESS state");
            end

            // Feed ciphertext data during PROCESS
            // Need PROCESS_LAST + 1 extractions (0 to PROCESS_LAST inclusive)
            // PROCESS_LAST = SRAM_DEPTH - 1 + 2 = SRAM_DEPTH + 1
            // So we need SRAM_DEPTH + 2 extractions
            // Each extraction: NUM_PE * 51 bits
            // Beats needed: ceil((SRAM_DEPTH + 2) * NUM_PE * 51 / 512)
            begin
                integer cycles_in_process;
                integer seed_sent;

                cycles_in_process = 0;
                seed_sent = 0;

                while (state_out == ST_PROCESS && cycles_in_process < 2000) begin
                    if (!seed_sent) begin
                        s_seed_valid <= 1'b1;
                        s_seed_counter <= 32'h00000001 + i;
                        if (s_seed_valid && s_seed_ready) begin
                            seed_sent = 1;
                        end
                    end else begin
                        s_seed_valid <= 1'b0;
                    end

                    @(posedge clk);
                    cycles_in_process = cycles_in_process + 1;
                end
                s_seed_valid <= 1'b0;
            end

            // Wait for NEXT_DIM
            wait_for_state(ST_NEXT_DIM, 1000);
            if (state_out == ST_NEXT_DIM && i == 0) begin
                $display("  PASS: Entered NEXT_DIM");
            end

            // Let FSM decide next state
            @(posedge clk);
        end

        // After all dims, should go to REDUCE
        wait_for_state(ST_REDUCE, 1000);
        if (state_out == ST_REDUCE) begin
            $display("  PASS: Entered REDUCE state");
        end

        //---------------------------------------------------------------------
        // Test 5: Result Output (REDUCE + WRITEBACK)
        //---------------------------------------------------------------------
        test_num = 5;
        $display("");
        $display("[Test %0d] Result Output", test_num);

        // Count output beats
        begin
            integer beats_before;
            integer timeout_cnt;
            beats_before = output_beat_count;

            // REDUCE takes SRAM_DEPTH + solinas_reduce_latency cycles.
            // The packer emits most beats during REDUCE and completes at WRITEBACK.

            timeout_cnt = 0;

            while (state_out == ST_REDUCE && timeout_cnt < 4 * SRAM_DEPTH) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            if (state_out == ST_WRITEBACK) begin
                $display("  PASS: Entered WRITEBACK state");
            end else if (timeout_cnt >= 4 * SRAM_DEPTH) begin
                $display("  FAIL: Timeout in REDUCE state");
                errors = errors + 1;
            end

            // Wait until the FSM leaves WRITEBACK/NEXT_GROUP path for this group.
            begin
                integer wb_timeout;
                wb_timeout = 0;

                while ((state_out == ST_WRITEBACK || state_out == ST_REDUCE) && wb_timeout < 200000) begin
                    if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                        $display("  Received tlast at total beat %0d", output_beat_count);
                    end
                    @(posedge clk);
                    wb_timeout = wb_timeout + 1;
                end
            end

        if (output_beat_count - beats_before > 0) begin
            $display("  PASS: Received %0d output beats for group 0", output_beat_count - beats_before);
            end else begin
                $display("  FAIL: No output beats received for group 0");
                errors = errors + 1;
            end
        end

        // Should transition to NEXT_GROUP
        wait_for_state(ST_NEXT_GROUP, 1000);
        if (state_out == ST_NEXT_GROUP) begin
            $display("  PASS: Entered NEXT_GROUP state");
            group_done_count = group_done_count + 1;
        end

        if (TB_NUM_GROUPS > 1) begin
        //---------------------------------------------------------------------
        // Test 6: Multi-Group Processing (Group 1)
        //---------------------------------------------------------------------
        test_num = 6;
        $display("");
        $display("[Test %0d] Multi-Group Processing (Group 1)", test_num);

        @(posedge clk);  // Let FSM advance

        // Should go back to INIT_GROUP for group 1
        wait_for_state(ST_INIT_GROUP, 1000);
        if (state_out == ST_INIT_GROUP) begin
            $display("  PASS: Started INIT_GROUP for group 1");
        end

        // Process group 1 (same flow as group 0)
        wait_for_state(ST_WAIT_BUF, 4 * SRAM_DEPTH);

        // Process all dimensions for group 1
        for (i = 0; i < TB_DIM; i = i + 1) begin
            while (state_out != ST_WAIT_BUF && state_out != ST_LOAD_SCALAR && state_out != ST_PROCESS) begin
                @(posedge clk);
            end

            if (state_out == ST_WAIT_BUF) begin
                @(posedge clk);
                s_axis_tvalid <= 1'b1;
                s_axis_tdata  <= {AXIS_W{1'b0}};
                while (state_out == ST_WAIT_BUF) @(posedge clk);
                s_axis_tvalid <= 1'b0;
            end

            wait_for_state(ST_LOAD_SCALAR, 100);
            wait_for_state(ST_PROCESS, 100);

            // Feed ciphertext data
            begin
                integer beat;
                integer cycles_in_process;
                integer seed_sent;

                beat = 0;
                cycles_in_process = 0;
                seed_sent = 0;

                while (state_out == ST_PROCESS && cycles_in_process < 2000) begin
                    if (!seed_sent) begin
                        s_seed_valid <= 1'b1;
                        s_seed_counter <= 32'h00000100 + i;
                        if (s_seed_valid && s_seed_ready) begin
                            seed_sent = 1;
                        end
                    end else begin
                        s_seed_valid <= 1'b0;
                    end

                    if (s_axis_tready) begin
                        s_axis_tvalid <= 1'b1;
                        s_axis_tdata <= (beat + 1) * 200;  // Different pattern for group 1
                        beat = beat + 1;
                    end else begin
                        // Deassert when done feeding or when not ready
                        s_axis_tvalid <= 1'b0;
                    end

                    @(posedge clk);
                    cycles_in_process = cycles_in_process + 1;
                end
                s_axis_tvalid <= 1'b0;
                s_seed_valid <= 1'b0;
            end

            wait_for_state(ST_NEXT_DIM, 1000);
            @(posedge clk);
        end

        // Wait for REDUCE and WRITEBACK
        wait_for_state(ST_REDUCE, 1000);
        $display("  PASS: Entered REDUCE for group 1");

        // Collect output
        begin
            integer beat_cnt;
            integer timeout;
            beat_cnt = output_beat_count;
            timeout = 0;

            while ((state_out == ST_REDUCE || state_out == ST_WRITEBACK) && timeout < 200000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            $display("  Received %0d output beats for group 1", output_beat_count - beat_cnt);
        end

        // Should go to NEXT_GROUP then DONE
        wait_for_state(ST_NEXT_GROUP, 1000);
        if (state_out == ST_NEXT_GROUP) begin
            group_done_count = group_done_count + 1;
        end

        @(posedge clk);

        // After the configured final group, the FSM should go to DONE.
        wait_for_state(ST_DONE, 1000);
        if (state_out == ST_DONE) begin
            $display("  PASS: Entered DONE state");
        end
        end else begin
            @(posedge clk);
            wait_for_state(ST_DONE, 1000);
            if (state_out == ST_DONE) begin
                $display("  PASS: Entered DONE state");
            end
        end

        //---------------------------------------------------------------------
        // Test 7: Completion Signals
        //---------------------------------------------------------------------
        test_num = 7;
        $display("");
        $display("[Test %0d] Completion Signals", test_num);

        // Check done pulse
        if (done !== 1'b1) begin
            // Wait one more cycle
            @(posedge clk);
        end

        if (done === 1'b1) begin
            $display("  PASS: done signal asserted");
        end else begin
            $display("  FAIL: done signal not asserted");
            errors = errors + 1;
        end

        // After DONE, should return to IDLE
        wait_for_state(ST_IDLE, 20);

        if (state_out == ST_IDLE) begin
            $display("  PASS: Returned to IDLE");
        end else begin
            $display("  FAIL: Did not return to IDLE");
            errors = errors + 1;
        end

        if (busy === 1'b0) begin
            $display("  PASS: busy=0 after completion");
        end else begin
            $display("  FAIL: busy still asserted after completion");
            errors = errors + 1;
        end

        check_output_coefficients;

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        repeat (10) @(posedge clk);

        $display("");
        $display("========================================");
        $display("Test Summary");
        $display("========================================");
        $display("  Groups processed: %0d/%0d", group_done_count, TB_NUM_GROUPS);
        $display("  Output beats received: %0d", output_beat_count);
        $display("  Errors: %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("TEST PASSED: tb_he_accelerator_seeded_a");
        end else begin
            $display("TEST FAILED: %0d errors", errors);
            $fatal(1, "tb_he_accelerator_seeded_a failed");
        end
        $display("========================================");

        $finish;
    end

    // Exercise bounded AXI output backpressure during result emission. The
    // local DMA sink is usually ready, but the top-level RTL must not drop
    // reduced coefficients if ready deasserts for a few cycles.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tready <= 1'b1;
            output_ready_cycle <= 0;
        end else if (state_out == ST_REDUCE || state_out == ST_WRITEBACK) begin
            output_ready_cycle <= output_ready_cycle + 1;
            m_axis_tready <= ((output_ready_cycle % 11) != 3) &&
                             ((output_ready_cycle % 11) != 4) &&
                             ((output_ready_cycle % 17) != 8);
        end else begin
            output_ready_cycle <= 0;
            m_axis_tready <= 1'b1;
        end
    end

    //=========================================================================
    // Monitor: Track State Transitions
    //=========================================================================
    reg [3:0] prev_state;
    always @(posedge clk) begin
        if (rst_n) begin
            prev_state <= state_out;
            if (state_out != prev_state) begin
                $display("[%0t] State: %0s -> %0s", $time,
                    (prev_state == ST_IDLE)        ? "IDLE" :
                    (prev_state == ST_INIT_GROUP)  ? "INIT_GROUP" :
                    (prev_state == ST_WAIT_BUF)    ? "WAIT_BUF" :
                    (prev_state == ST_LOAD_SCALAR) ? "LOAD_SCALAR" :
                    (prev_state == ST_PROCESS)     ? "PROCESS" :
                    (prev_state == ST_NEXT_DIM)    ? "NEXT_DIM" :
                    (prev_state == ST_REDUCE)      ? "REDUCE" :
                    (prev_state == ST_WRITEBACK)   ? "WRITEBACK" :
                    (prev_state == ST_NEXT_GROUP)  ? "NEXT_GROUP" :
                    (prev_state == ST_DONE)        ? "DONE" : "???",
                    (state_out == ST_IDLE)        ? "IDLE" :
                    (state_out == ST_INIT_GROUP)  ? "INIT_GROUP" :
                    (state_out == ST_WAIT_BUF)    ? "WAIT_BUF" :
                    (state_out == ST_LOAD_SCALAR) ? "LOAD_SCALAR" :
                    (state_out == ST_PROCESS)     ? "PROCESS" :
                    (state_out == ST_NEXT_DIM)    ? "NEXT_DIM" :
                    (state_out == ST_REDUCE)      ? "REDUCE" :
                    (state_out == ST_WRITEBACK)   ? "WRITEBACK" :
                    (state_out == ST_NEXT_GROUP)  ? "NEXT_GROUP" :
                    (state_out == ST_DONE)        ? "DONE" : "???");
            end
        end
    end

endmodule
