//-----------------------------------------------------------------------------
// HE Accelerator Seeded-a Top Module -- b8+a8 PCMV Engine
//-----------------------------------------------------------------------------
// Seeded-a end-to-end system with AXI-1024 stored-b input and ChaCha20 generated-a.
// Uses 8 stored-b lanes plus 8 generated-a lanes, external accumulator SRAM
// banks, and stateless multiply-add PEs.
//
// Implemented blocks:
//   1. 16 PEs split across 8 stored-b lanes and 8 generated-a lanes
//   2. 16 acc_sram_bank instances with the accumulator state outside the PEs
//   3. Seeded-a frontend: AXI-1024 stored-b stream plus ChaCha20 a expansion
//   4. result_packer output path for reduced 51-bit coefficients
//   5. Explicit group-level iteration over vector groups and dimensions
//   6. Pipeline-overlap REDUCE + WRITEBACK phases
//
// Datapath Overview:
//   AXI-S b -> seeded_a_coeff_frontend -> 16 PEs -> 16 acc SRAM banks
//   seed  a -> ChaCha20 expansion --------^             |
//                                         scalar_buffer  v
//                                                   solinas_reduce[16]
//                                                          |
//                                                          v
//                                                    result_packer -> AXI-S out
//                                                             (to SSD-controller
//                                                              DMA writeback)
//
// FSM: IDLE -> INIT_GROUP -> WAIT_BUF -> LOAD_SCALAR -> PROCESS
//        ^         ^                                       |
//        |         |                      NEXT_DIM <-------+
//        |         |                         |
//        |    NEXT_GROUP <-- WRITEBACK <-- REDUCE
//        |                                   |
//        +------ DONE <----------------------+
//
// Parameters:
//   N = 4096 (ring dimension), K = 51 (Solinas prime bit width)
//   16 parallel PEs, 512-entry acc SRAM banks (N / B_PES)
//   ACC_W = 118 bits (supports up to 65536 accumulations)
//-----------------------------------------------------------------------------

module he_accelerator_seeded_a #(
    parameter N          = 4096,        // Ring dimension
    parameter K          = 51,          // Coefficient bit width
    parameter ACC_W      = 118,         // Accumulator width
    parameter NUM_PE     = 16,          // Parallel PEs (8 stored-b + 8 generated-a)
    parameter B_PES      = 8,           // Stored-b coefficients per cycle
    parameter A_PES      = 8,           // Generated-a coefficients per cycle
    parameter MAX_DIMS   = 4096,        // Max embedding dimension
    parameter SRAM_DEPTH = 512,         // Entries per acc SRAM bank (N/B_PES)
    parameter AXIS_W     = 1024         // AXI-Stream data width
)(
    input  wire                     clk,
    input  wire                     rst_n,

    //-------------------------------------------------------------------------
    // Control
    //-------------------------------------------------------------------------
    input  wire                     start,
    output reg                      done,
    output reg                      busy,
    output reg  [3:0]               state_out,      // Current FSM state for debug

    //-------------------------------------------------------------------------
    // Configuration (set before start)
    //-------------------------------------------------------------------------
    input  wire [15:0]              num_groups,      // Total vector groups (e.g., 24,415)
    input  wire [15:0]              embed_dim,       // Embedding dimension d (e.g., 768)

    //-------------------------------------------------------------------------
    // Query scalar write port (host loads query before start)
    //-------------------------------------------------------------------------
    input  wire                     wr_scalar_valid,
    input  wire [K-1:0]             wr_scalar_data,
    input  wire [$clog2(MAX_DIMS)-1:0] wr_scalar_addr,

    //-------------------------------------------------------------------------
    // Per-dimension seed metadata for regenerating public a on device
    //-------------------------------------------------------------------------
    input  wire                     s_seed_valid,
    output wire                     s_seed_ready,
    input  wire [255:0]             s_seed_key,
    input  wire [95:0]              s_seed_nonce,
    input  wire [31:0]              s_seed_counter,

    //-------------------------------------------------------------------------
    // AXI-Stream Slave: ciphertext data from device-local stream buffer
    //-------------------------------------------------------------------------
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    input  wire [AXIS_W-1:0]        s_axis_tdata,

    //-------------------------------------------------------------------------
    // AXI-Stream Master: compact result stream
    //-------------------------------------------------------------------------
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,
    output wire [AXIS_W-1:0]        m_axis_tdata,
    output wire                     m_axis_tlast
);

    //=========================================================================
    // FSM State Encoding
    //=========================================================================
    localparam [3:0]
        ST_IDLE       = 4'd0,   // Wait for start
        ST_INIT_GROUP = 4'd1,   // Clear acc SRAM: write 0 to all entries
        ST_WAIT_BUF   = 4'd2,   // Wait for input data valid from triple buffer
        ST_LOAD_SCALAR= 4'd3,   // Read scalar_buffer[dim_idx], broadcast to PEs
        ST_PROCESS    = 4'd4,   // Stream 8192 coefficients: NUM_PE/cycle
        ST_NEXT_DIM   = 4'd5,   // dim_idx < d? -> ST_LOAD_SCALAR : ST_REDUCE
        ST_REDUCE     = 4'd6,   // Read acc SRAM -> Solinas reduce
        ST_WRITEBACK  = 4'd7,   // Pack result for downstream DMA sink
        ST_NEXT_GROUP = 4'd8,   // group_idx < num_groups? -> ST_INIT_GROUP : ST_DONE
        ST_DONE       = 4'd9;   // Signal completion

    reg [3:0] state, next_state;

    //=========================================================================
    // Derived Parameters
    //=========================================================================
    localparam SRAM_ADDR_W  = $clog2(SRAM_DEPTH);
    localparam SCALAR_ADDR_W = $clog2(MAX_DIMS);            // 12 bits
    localparam SCALAR_DIMS_W = $clog2(MAX_DIMS + 1);        // 13 bits for 4096
    localparam CNT_W        = $clog2(SRAM_DEPTH + 5);
    localparam [CNT_W-1:0] SRAM_DEPTH_C = SRAM_DEPTH[CNT_W-1:0];
    localparam [CNT_W-1:0] PROCESS_LAST = SRAM_DEPTH_C - {{(CNT_W-1){1'b0}}, 1'b1}
                                         + {{(CNT_W-2){1'b0}}, 2'd2};
    localparam [CNT_W-1:0] REDUCE_LAST  = SRAM_DEPTH_C + {{(CNT_W-3){1'b0}}, 3'd4};

    //=========================================================================
    // Reset Synchronizer
    //=========================================================================
    /* verilator lint_off SYNCASYNCNET */
    wire rst_n_int;
    /* verilator lint_on SYNCASYNCNET */

    reset_sync u_rst (
        .clk         (clk),
        .rst_n_async (rst_n),
        .rst_n_sync  (rst_n_int)
    );

    //=========================================================================
    // Control Registers
    //=========================================================================
    reg [15:0] group_idx;       // Current vector group [0, num_groups)
    reg [15:0] dim_idx;         // Current dimension [0, embed_dim)
    reg  [CNT_W-1:0] cycle_cnt;       // Cycle within init/process phase
    reg  [CNT_W-1:0] reduce_cnt;      // Counter for reduce phase
    reg [15:0] num_groups_r;    // Registered num_groups
    reg [15:0] embed_dim_r;     // Registered embed_dim

    //=========================================================================
    // Scalar Buffer
    //=========================================================================
    // Stores query scalars q[0..d-1]. Host pre-loads before asserting start.
    // Read in ST_LOAD_SCALAR: addr = dim_idx, 1-cycle latency.

    wire [K-1:0]             sbuf_rd_data;
    wire                     sbuf_rd_valid;

    scalar_buffer #(
        .K        (K),
        .MAX_DIMS (MAX_DIMS)
    ) u_scalar (
        .clk         (clk),
        .rst_n       (rst_n_int),
        .active_dims (embed_dim_r[SCALAR_DIMS_W-1:0]),
        // Write port: host loads query before start
        .wr_valid    (wr_scalar_valid),
        .wr_data     (wr_scalar_data),
        .wr_addr     (wr_scalar_addr),
        /* verilator lint_off PINCONNECTEMPTY */
        .wr_ready    (),                    // Always ready
        /* verilator lint_on PINCONNECTEMPTY */
        // Read port: FSM reads scalar for current dimension
        .rd_addr     (dim_idx[SCALAR_ADDR_W-1:0]),
        .rd_data     (sbuf_rd_data),
        .rd_valid    (sbuf_rd_valid)
    );

    // Scalar broadcast register: loaded in ST_LOAD_SCALAR, held during ST_PROCESS
    reg [K-1:0] scalar_broadcast;

    //=========================================================================
    // Seeded-a Coefficient Frontend
    //=========================================================================
    // Extracts B_PES stored-b coefficients/cycle from AXI-1024 input and
    // regenerates A_PES public-a coefficients/cycle from a ChaCha20 seed stream.
    // Output feeds 16 PE/SRAM/reduction lanes: b in lanes [0..7], a in [8..15].

    wire                        unpack_out_valid;
    wire                        unpack_out_ready;
    wire [NUM_PE*K-1:0]         unpack_out_data;

    // Flush frontend buffers at group boundary (INIT_GROUP or IDLE).
    wire unpack_flush = (state == ST_INIT_GROUP) || (state == ST_IDLE);

    // Only feed data to frontend during PROCESS phase.
    wire unpack_s_valid = s_axis_tvalid && (state == ST_PROCESS);

    reg seed_issued;
    wire frontend_seed_ready;
    wire seed_fire = (state == ST_PROCESS) && !seed_issued &&
                     s_seed_valid && frontend_seed_ready;

    assign s_seed_ready = (state == ST_PROCESS) && !seed_issued &&
                          frontend_seed_ready;

    wire unpack_s_ready_int;

    seeded_a_coeff_frontend #(
        .K       (K),
        .B_PES   (B_PES),
        .A_PES   (A_PES),
        .AXIS_W  (AXIS_W)
    ) u_frontend (
        .clk           (clk),
        .rst_n         (rst_n_int),
        .flush         (unpack_flush),
        .seed_valid    (seed_fire),
        .seed_key      (s_seed_key),
        .seed_nonce    (s_seed_nonce),
        .seed_counter  (s_seed_counter),
        .seed_ready    (frontend_seed_ready),
        .s_axis_tvalid (unpack_s_valid),
        .s_axis_tready (unpack_s_ready_int),
        .s_axis_tdata  (s_axis_tdata),
        .coeff_valid   (unpack_out_valid),
        .coeff_ready   (unpack_out_ready),
        .coeff_data    (unpack_out_data)
    );

    // s_axis_tready: only accept data during PROCESS when unpack can take it
    wire process_accept_coeff = (state == ST_PROCESS) && (cycle_cnt < SRAM_DEPTH_C);

    assign s_axis_tready = unpack_s_ready_int && process_accept_coeff;

    // Unpack output ready: always consume during PROCESS (PE always ready)
    assign unpack_out_ready = process_accept_coeff;

    //=========================================================================
    // PE Array - Stateless Multiply-Add Units
    //=========================================================================
    // Each pe_mac computes: acc_out = acc_in + coeff * scalar
    // 2-cycle pipeline: Stage1 = multiply, Stage2 = add
    //
    // Timing alignment with SRAM:
    //   Cycle t:   unpack outputs coeff[k]; SRAM read issued at addr cycle_cnt
    //   Cycle t+1: SRAM read data available; registered in pe_mac as acc_in
    //   Cycle t+2: pe_mac outputs acc_out; write to SRAM at addr cycle_cnt-2

    wire [K-1:0]       pe_coeff   [0:NUM_PE-1];
    /* verilator lint_off UNUSED */
    wire               pe_valid_out [0:NUM_PE-1];  // Timing matches pe_valid_in pipeline
    /* verilator lint_on UNUSED */
    wire [ACC_W-1:0]   pe_acc_out [0:NUM_PE-1];

    // Extract individual coefficients from unpack output
    genvar gi;
    generate
        for (gi = 0; gi < NUM_PE; gi = gi + 1) begin : gen_coeff_extract
            assign pe_coeff[gi] = unpack_out_data[(gi+1)*K-1 -: K];
        end
    endgenerate

    // PE valid_in: unpack has valid data during PROCESS phase
    wire pe_valid_in = unpack_out_valid && process_accept_coeff;

    //-------------------------------------------------------------------------
    // ACC SRAM Banks - NUM_PE x (SRAM_DEPTH x 118-bit)
    //-------------------------------------------------------------------------
    // Each bank stores accumulator values for one PE's output positions.
    // Read port: feeds pe_mac's acc_in (1-cycle latency)
    // Write port: accepts pe_mac's acc_out or zero (during INIT)

    wire [ACC_W-1:0]   sram_rd_data [0:NUM_PE-1];
    /* verilator lint_off UNUSED */
    wire               sram_rd_valid [0:NUM_PE-1]; // Implicitly valid by FSM timing
    /* verilator lint_on UNUSED */

    // Backpressure from the result packer. REDUCE only issues new SRAM reads
    // when the packer has enough headroom for the reduction pipeline outputs
    // already in flight.
    wire               pack_in_ready;

    // SRAM read address: cycle_cnt during PROCESS, reduce_cnt during REDUCE
    wire [SRAM_ADDR_W-1:0] sram_rd_addr;
    assign sram_rd_addr = (state == ST_PROCESS) ? cycle_cnt[SRAM_ADDR_W-1:0] :
                          (state == ST_REDUCE)  ? reduce_cnt[SRAM_ADDR_W-1:0] :
                          {SRAM_ADDR_W{1'b0}};

    // SRAM read enable: during PROCESS (pipeline feed) or REDUCE (final read)
    wire reduce_issue = (state == ST_REDUCE) &&
                        (reduce_cnt < SRAM_DEPTH_C) &&
                        pack_in_ready;

    wire sram_rd_en = (state == ST_PROCESS && pe_valid_in) || reduce_issue;

    // SRAM write signals
    // During INIT_GROUP: write zeros at addr cycle_cnt
    // During PROCESS:    write pe_acc_out at addr cycle_cnt-2
    reg                     sram_wr_en;
    reg  [SRAM_ADDR_W-1:0]  sram_wr_addr;
    // Pipeline delay registers for write address alignment
    // PE has 2-cycle latency: write addr = cycle_cnt delayed by 2
    reg [SRAM_ADDR_W-1:0]   wr_addr_d1, wr_addr_d2;
    reg                      wr_valid_d1, wr_valid_d2;

    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            wr_addr_d1  <= {SRAM_ADDR_W{1'b0}};
            wr_addr_d2  <= {SRAM_ADDR_W{1'b0}};
            wr_valid_d1 <= 1'b0;
            wr_valid_d2 <= 1'b0;
        end else begin
            wr_addr_d1  <= cycle_cnt[SRAM_ADDR_W-1:0];
            wr_addr_d2  <= wr_addr_d1;
            wr_valid_d1 <= pe_valid_in;
            wr_valid_d2 <= wr_valid_d1;
        end
    end

    // Track whether the delayed cycle_cnt (wr_addr_d2 source) is within SRAM bounds
    // This prevents writes during pipeline drain cycles (cycle_cnt >= SRAM_DEPTH)
    reg wr_in_bounds_d1, wr_in_bounds_d2;

    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            wr_in_bounds_d1 <= 1'b0;
            wr_in_bounds_d2 <= 1'b0;
        end else begin
            // cycle_cnt < SRAM_DEPTH means address is valid
            wr_in_bounds_d1 <= (cycle_cnt < SRAM_DEPTH_C);
            wr_in_bounds_d2 <= wr_in_bounds_d1;
        end
    end

    // SRAM write mux: INIT phase writes zeros, PROCESS phase writes PE output
    // Only write during PROCESS if address is within SRAM bounds
    always @(*) begin
        if (state == ST_INIT_GROUP) begin
            sram_wr_en   = 1'b1;
            sram_wr_addr = cycle_cnt[SRAM_ADDR_W-1:0];
        end else if (state == ST_PROCESS && wr_valid_d2 && wr_in_bounds_d2) begin
            sram_wr_en   = 1'b1;
            sram_wr_addr = wr_addr_d2;
        end else begin
            sram_wr_en   = 1'b0;
            sram_wr_addr = {SRAM_ADDR_W{1'b0}};
        end
    end

    //-------------------------------------------------------------------------
    // Instantiate PE + SRAM + Solinas Reduce arrays
    //-------------------------------------------------------------------------

    // Solinas reduce output signals
    wire               reduce_valid_out [0:NUM_PE-1];
    wire [K-1:0]       reduce_result    [0:NUM_PE-1];

    // Solinas reduce input: fed from SRAM read data during REDUCE phase
    reg                reduce_valid_in;

    // Pipeline delay for reduce valid (1 cycle SRAM read latency)
    reg                reduce_feed_d1;

    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            reduce_feed_d1 <= 1'b0;
        end else begin
            reduce_feed_d1 <= reduce_issue;
        end
    end

    // Feed reduce input from SRAM read data (available 1 cycle after rd_en)
    always @(*) begin
        reduce_valid_in = reduce_feed_d1;
    end

    generate
        for (gi = 0; gi < NUM_PE; gi = gi + 1) begin : gen_pe_sram_reduce

            //-------------------------------------------------------------
            // PE MAC instance
            //-------------------------------------------------------------
            pe_mac #(
                .K     (K),
                .ACC_W (ACC_W)
            ) u_pe (
                .clk       (clk),
                .rst_n     (rst_n_int),
                .valid_in  (pe_valid_in),
                .coeff     (pe_coeff[gi]),
                .scalar    (scalar_broadcast),
                .acc_in    (sram_rd_data[gi]),   // From SRAM (1-cycle aligned)
                .valid_out (pe_valid_out[gi]),
                .acc_out   (pe_acc_out[gi])
            );

            //-------------------------------------------------------------
            // Accumulator SRAM bank instance
            //-------------------------------------------------------------
            acc_sram_bank #(
                .DEPTH (SRAM_DEPTH),
                .WIDTH (ACC_W)
            ) u_sram (
                .clk     (clk),
                .rst_n   (rst_n_int),
                // Write port
                .wr_en   (sram_wr_en),
                .wr_addr (sram_wr_addr),
                .wr_data ((state == ST_INIT_GROUP) ? {ACC_W{1'b0}} : pe_acc_out[gi]),
                // Read port
                .rd_en   (sram_rd_en),
                .rd_addr (sram_rd_addr),
                .rd_data (sram_rd_data[gi]),
                .rd_valid(sram_rd_valid[gi])
            );

            //-------------------------------------------------------------
            // Solinas reduction unit (used in REDUCE phase)
            //-------------------------------------------------------------
            solinas_reduce #(
                .K         (K),
                .ACC_WIDTH (ACC_W)
            ) u_reduce (
                .clk       (clk),
                .rst_n     (rst_n_int),
                .valid_in  (reduce_valid_in),
                .acc       (sram_rd_data[gi]),   // Fed from SRAM read during REDUCE
                .valid_out (reduce_valid_out[gi]),
                .r         (reduce_result[gi])
            );
        end
    endgenerate

    //=========================================================================
    // Result Packer
    //=========================================================================
    // Packs NUM_PE x 51-bit reduced coefficients into 512-bit AXI-Stream output.
    // Fed during REDUCE phase as solinas_reduce produces results.
    // Output feeds m_axis directly; the surrounding SSD controller is expected
    // to DMA-write this encrypted score stream into the host result buffer.

    wire                     pack_in_valid;
    /* verilator lint_off UNUSED */
    // pack_in_ready is consumed by REDUCE flow control above.
    /* verilator lint_on UNUSED */
    wire [NUM_PE*K-1:0]      pack_in_data;

    // Assemble reduced results into packed input vector
    // reduce_valid_out[0] is representative (all reduce units have same timing)
    assign pack_in_valid = reduce_valid_out[0];

    generate
        for (gi = 0; gi < NUM_PE; gi = gi + 1) begin : gen_pack_data
            assign pack_in_data[(gi+1)*K-1 -: K] = reduce_result[gi];
        end
    endgenerate

    wire pack_flush = (state == ST_INIT_GROUP) || (state == ST_IDLE);

    result_packer #(
        .K            (K),
        .NUM_PE       (NUM_PE),
        .OUT_WIDTH    (AXIS_W),
        .TOTAL_COEFFS (2 * N),         // 8192 coefficients (c0 + c1)
        .BUFFER_BEATS (6),
        .READY_MARGIN_INPUTS (4)
    ) u_pack (
        .clk     (clk),
        .rst_n   (rst_n_int),
        .flush   (pack_flush),
        // Input from solinas_reduce array
        .in_valid(pack_in_valid),
        .in_ready(pack_in_ready),
        .in_data (pack_in_data),
        // AXI-Stream Master output
        .m_valid (m_axis_tvalid),
        .m_ready (m_axis_tready),
        .m_data  (m_axis_tdata),
        .m_last  (m_axis_tlast)
    );

    //=========================================================================
    // FSM: State Register
    //=========================================================================
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            state <= ST_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // Debug output
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int)
            state_out <= 4'd0;
        else
            state_out <= state;
    end

    //=========================================================================
    // FSM: Next State Logic
    //=========================================================================
    always @(*) begin
        next_state = state;

        case (state)
            ST_IDLE: begin
                if (start)
                    next_state = ST_INIT_GROUP;
            end

            ST_INIT_GROUP: begin
                // Clear all entries in all SRAM banks
                if (cycle_cnt == SRAM_DEPTH_C - {{(CNT_W-1){1'b0}}, 1'b1})
                    next_state = ST_WAIT_BUF;
            end

            ST_WAIT_BUF: begin
                // Wait for upstream data to be available
                if (s_axis_tvalid)
                    next_state = ST_LOAD_SCALAR;
            end

            ST_LOAD_SCALAR: begin
                // scalar_buffer has 1-cycle read latency
                // After 1 cycle, sbuf_rd_valid asserts and data is captured
                if (sbuf_rd_valid)
                    next_state = ST_PROCESS;
            end

            ST_PROCESS: begin
                // SRAM_DEPTH cycles of coefficient processing + 2 pipeline drain cycles.
                if (cycle_cnt == PROCESS_LAST)
                    next_state = ST_NEXT_DIM;
            end

            ST_NEXT_DIM: begin
                // Check if all dimensions processed
                if (dim_idx + 16'd1 >= embed_dim_r)
                    next_state = ST_REDUCE;
                else
                    next_state = ST_LOAD_SCALAR;
            end

            ST_REDUCE: begin
                // Read all SRAM entries through Solinas reduce.
                // Solinas reduce has 4-cycle latency; wait for pipeline drain.
                // Transition to WRITEBACK once reduce pipeline starts producing
                if (reduce_cnt == REDUCE_LAST)
                    next_state = ST_WRITEBACK;
            end

            ST_WRITEBACK: begin
                // Wait for result_packer to emit the last beat
                if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                    next_state = ST_NEXT_GROUP;
            end

            ST_NEXT_GROUP: begin
                if (group_idx + 16'd1 >= num_groups_r)
                    next_state = ST_DONE;
                else
                    next_state = ST_INIT_GROUP;
            end

            ST_DONE: begin
                next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase

    end

    //=========================================================================
    // FSM: Output Logic (Sequential)
    //=========================================================================
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            group_idx        <= 16'b0;
            dim_idx          <= 16'b0;
            cycle_cnt        <= {CNT_W{1'b0}};
            reduce_cnt       <= {CNT_W{1'b0}};
            num_groups_r     <= 16'b0;
            embed_dim_r      <= 16'b0;
            scalar_broadcast <= {K{1'b0}};
            busy             <= 1'b0;
            done             <= 1'b0;
            seed_issued      <= 1'b0;
        end else begin
            // Defaults
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        num_groups_r  <= num_groups;
                        embed_dim_r   <= embed_dim;
                        group_idx     <= 16'b0;
                        dim_idx       <= 16'b0;
                        cycle_cnt     <= {CNT_W{1'b0}};
                        reduce_cnt    <= {CNT_W{1'b0}};
                        busy          <= 1'b1;
                        seed_issued   <= 1'b0;
                    end
                end

                ST_INIT_GROUP: begin
                    // Clear acc SRAM: write 0 at addr = cycle_cnt each cycle
                    // All banks clear simultaneously via shared sram_wr_en/addr
                    if (cycle_cnt < SRAM_DEPTH_C - {{(CNT_W-1){1'b0}}, 1'b1}) begin
                        cycle_cnt <= cycle_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                    end else begin
                        cycle_cnt <= {CNT_W{1'b0}};     // Reset for PROCESS phase
                    end
                    // Reset dim_idx for new group
                    dim_idx    <= 16'b0;
                    reduce_cnt <= {CNT_W{1'b0}};
                    seed_issued <= 1'b0;
                end

                ST_WAIT_BUF: begin
                    // Reset cycle_cnt for PROCESS
                    cycle_cnt <= {CNT_W{1'b0}};
                end

                ST_LOAD_SCALAR: begin
                    // scalar_buffer read addr = dim_idx (set combinationally above)
                    // After 1 cycle, capture read data into broadcast register
                    if (sbuf_rd_valid) begin
                        scalar_broadcast <= sbuf_rd_data;
                    end
                    cycle_cnt   <= {CNT_W{1'b0}};       // Reset for PROCESS
                    seed_issued <= 1'b0;
                end

                ST_PROCESS: begin
                    if (seed_fire) begin
                        seed_issued <= 1'b1;
                    end
                    // Consume exactly SRAM_DEPTH coefficient groups, then keep
                    // counting to drain the PE pipeline without accepting new
                    // input coefficients.
                    if ((cycle_cnt < SRAM_DEPTH_C && unpack_out_valid) ||
                        (cycle_cnt >= SRAM_DEPTH_C && cycle_cnt < PROCESS_LAST)) begin
                        cycle_cnt <= cycle_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                    end
                end

                ST_NEXT_DIM: begin
                    // Advance dimension index
                    dim_idx   <= dim_idx + 16'd1;
                    cycle_cnt <= {CNT_W{1'b0}};
                    seed_issued <= 1'b0;
                end

                ST_REDUCE: begin
                    // Advance reduce counter. New SRAM reads honor packer
                    // backpressure; pipeline-drain cycles continue after all
                    // SRAM entries have been issued.
                    if (reduce_cnt < SRAM_DEPTH_C) begin
                        if (pack_in_ready) begin
                            reduce_cnt <= reduce_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                        end
                    end else if (reduce_cnt < REDUCE_LAST) begin
                        reduce_cnt <= reduce_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                    end
                end

                ST_WRITEBACK: begin
                    // Wait for packer to finish.
                end

                ST_NEXT_GROUP: begin
                    group_idx   <= group_idx + 16'd1;
                    cycle_cnt   <= {CNT_W{1'b0}};
                    reduce_cnt  <= {CNT_W{1'b0}};
                    seed_issued <= 1'b0;
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    //=========================================================================
    // Simulation-Only Debug and Assertions
    //=========================================================================
    `ifdef SIMULATION

    // State name string for waveform debugging
    reg [12*8-1:0] state_name;
    always @(*) begin
        case (state)
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

    // Monitor state transitions
    reg [3:0] prev_state;
    always @(posedge clk) begin
        prev_state <= state;
        if (rst_n_int && state != prev_state) begin
            $display("[%0t] HE_ACCEL_SEEDED_A: %0s -> %0s (grp=%0d, dim=%0d, cyc=%0d)",
                     $time,
                     // Inline previous state name
                     (prev_state == ST_IDLE)       ? "IDLE" :
                     (prev_state == ST_INIT_GROUP) ? "INIT_GROUP" :
                     (prev_state == ST_WAIT_BUF)   ? "WAIT_BUF" :
                     (prev_state == ST_LOAD_SCALAR)? "LOAD_SCALAR" :
                     (prev_state == ST_PROCESS)    ? "PROCESS" :
                     (prev_state == ST_NEXT_DIM)   ? "NEXT_DIM" :
                     (prev_state == ST_REDUCE)     ? "REDUCE" :
                     (prev_state == ST_WRITEBACK)  ? "WRITEBACK" :
                     (prev_state == ST_NEXT_GROUP) ? "NEXT_GROUP" :
                     (prev_state == ST_DONE)       ? "DONE" : "???",
                     // Current state name
                     (state == ST_IDLE)       ? "IDLE" :
                     (state == ST_INIT_GROUP) ? "INIT_GROUP" :
                     (state == ST_WAIT_BUF)   ? "WAIT_BUF" :
                     (state == ST_LOAD_SCALAR)? "LOAD_SCALAR" :
                     (state == ST_PROCESS)    ? "PROCESS" :
                     (state == ST_NEXT_DIM)   ? "NEXT_DIM" :
                     (state == ST_REDUCE)     ? "REDUCE" :
                     (state == ST_WRITEBACK)  ? "WRITEBACK" :
                     (state == ST_NEXT_GROUP) ? "NEXT_GROUP" :
                     (state == ST_DONE)       ? "DONE" : "???",
                     group_idx, dim_idx, cycle_cnt);
        end
    end

    `endif

endmodule
