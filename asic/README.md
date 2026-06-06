# Resa HE Accelerator -- Middleware ASIC Artifact

## Overview

This directory contains the Resa RTL, testbenches, synthesis scripts, and SRAM
estimation files used by the Middleware submission. Resa is a
near-storage accelerator for private RAG. It evaluates homomorphic inner products
between encrypted database vectors and plaintext query vectors inside the SSD
controller path.

The modeled host interface is a custom `CSD_SEARCH` command with a host
result-buffer descriptor. The SSD controller streams stored records into Resa on
a device-local AXI-Stream and DMA-writes Resa's compact encrypted score
ciphertext stream back to host memory.

The accelerator uses CKKS with the Solinas prime Q = 2^51 - 2^17 + 1. It
processes packed ciphertext polynomials at ring dimension N = 4096. The current
datapath is the seeded-a b8+a8 configuration: 8 stored-b lanes, 8 generated-a
lanes, 16 multiply-accumulate processing elements, and banked accumulator SRAM.

This directory is used for the following checks:
- Functional correctness of RTL leaf modules (35 unit checks)
- Top-level accelerator flow on a scaled configuration (FSM progress, multi-group completion, output emission)
- Seeded-a logic size record for the Middleware submission (492,697 cells, 0.063805 mm^2 mapped cell area)
- SRAM area via PCACTI 7nm FinFET estimation (~0.0285 mm^2)
- Middleware area/power arithmetic for mapped cells plus PCACTI SRAM macros

The scaled top-level integration test checks FSM progress, bounded AXI output
backpressure, output emission, and all packed output coefficients against an
exact nonzero-query seeded-a oracle.
Leaf-module tests independently check `pe_mac`, `solinas_reduce`,
`continuous_unpack`, `result_packer`, and `seeded_a_coeff_frontend`.

## Prerequisites

**Required (functional verification):**
- Icarus Verilog >= 12.0 (`apt install iverilog`)

**Optional (synthesis):**
- Yosys >= 0.40 (`conda install -c litex-hub yosys` or build from source)
- ASAP7 7nm PDK liberty files ([GitHub](https://github.com/The-OpenROAD-Project/asap7))

**Optional (SRAM estimation):**
- PCACTI ([GitHub](https://github.com/ARC-Lab-UF/PCACTI))

## Quick Start

Run from the `asic/` directory:

```bash
# Run RTL unit tests and the scaled top-level flow test (~1 minute)
make verify

# ASAP7 synthesis of the main seeded-a top (requires Yosys + ASAP7 PDK)
export ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM
make synth
```

## Directory Structure

```
asic/
  README.md                    -- This file
  Makefile                     -- make verify, make synth, make clean
  rtl/src/
    pe_mac.v                   -- Processing element: acc = acc + coeff * scalar
    acc_sram_bank.v            -- Dual-port accumulator SRAM bank (1024 x 118-bit)
    continuous_unpack.v        -- Bitstream unpacker: 512/1024-bit AXI -> 8 x 51-bit
    result_packer.v            -- Result packer: 8 x 51-bit -> 512-bit AXI
    solinas_reduce.v           -- Modular reduction for Q = 2^51 - 2^17 + 1
    scalar_buffer.v            -- Parameterized query scalar buffer
    reset_sync.v               -- 2-stage reset synchronizer
    chacha20_block_stream.v    -- 512-bit/cycle pipelined ChaCha20 block stream
    a_seed_expander_chacha20.v -- Seeded-a ChaCha20 expansion, 8 x 51-bit/cycle
    seeded_a_coeff_frontend.v  -- AXI-1024 b-stream + generated-a frontend
    he_accelerator_seeded_a.v  -- End-to-end seeded-a b8+a8 main top
  tb/
    Makefile                   -- make all / make clean
    tb_pe_mac.v                -- 8 tests: multiply-accumulate correctness
    tb_acc_sram_bank.v         -- 6 tests: SRAM read/write/forwarding
    tb_solinas_reduce.v        -- 14 tests: modular reduction edge cases
    tb_continuous_unpack.v     -- 3 tests: full 8192-coeff unpacking
    tb_result_packer.v         -- 4 tests: packing + bitstream round-trip
  syn/
    synth_seeded_a_logic_only.ys -- Yosys script: seeded-a top ASAP7 synthesis
    acc_sram_bank_bb.v         -- SRAM blackbox declaration (area via PCACTI)
    scalar_buffer_bb.v         -- Scalar buffer blackbox declaration
  sram/
    README.md                  -- SRAM estimation instructions
    accum_bank_7nm.xml         -- PCACTI config: single accumulator bank (16 KB)
    accum_total_7nm.xml        -- PCACTI config: aggregate accumulator SRAM (128 KB)
    query_buf_7nm.xml          -- PCACTI config: 768-entry query buffer (8 KB)
    run_pcacti.sh              -- Script to run all PCACTI estimations
  summary/
    middleware_area_power.py   -- Middleware mapped-cell + SRAM area/power checker
    sram_pcacti.py             -- PCACTI SRAM summary helper
```

## RTL Module Descriptions

| Module | Description | Key Parameters |
|--------|-------------|----------------|
| `pe_mac` | Stateless 2-stage pipelined multiply-accumulate: acc_out = acc_in + coeff * scalar | K=51 bit inputs, ACC_W=118 bit output |
| `acc_sram_bank` | Dual-port SRAM (1R+1W) with write-first forwarding | DEPTH=1024, WIDTH=118 |
| `continuous_unpack` | Shift-register unpacker extracting 8 x 51-bit coefficients per cycle from 512-bit AXI stream | 1536-bit internal buffer |
| `result_packer` | Shift-register packer converting 8 x 51-bit reduced coefficients into 512-bit AXI stream | Tracks 8192 coefficients per ciphertext |
| `solinas_reduce` | 3-stage pipelined reduction mod Q = 2^51 - 2^17 + 1 using shift-and-add (no multiplier) | Input: 118-bit, Output: 51-bit |
| `scalar_buffer` | Single-port RAM storing query scalars with variable active dimension | MAX_DIMS=4096, K=51 |
| `reset_sync` | 2-stage synchronizer for async reset deassertion | STAGES=2 |
| `chacha20_block_stream` | Fully pipelined ChaCha20 block function, one 512-bit block/cycle after fill | 10 double-round stages |
| `a_seed_expander_chacha20` | 512-bit/cycle PRG expander for the generated-a lane | A_PES=8, K=51 |
| `seeded_a_coeff_frontend` | AXI-1024 stored-b unpacker plus ChaCha20 generated-a frontend | B_PES=8, A_PES=8 |
| `seeded_a_group_ingress` | Compact AXI parser for a 256-bit group seed followed by stored-b payloads | N=4096, K=51, AXIS_W=1024 |
| `he_accelerator_seeded_a` | Seeded-a arithmetic core with stored-b AXI-1024 input and generated-a lanes | 16 PEs, 16 x 512 accumulator banks |
| `he_accelerator_seeded_a_ingress` | Submission top that binds compact group records to the arithmetic core | 16 PEs, AXI-1024 group stream |

The seeded-`a` ingress top is the datapath used for the current paper numbers.
It stores `b` plus a 256-bit seed per packing group and regenerates
dimension-separated public `a` polynomials on the CSD.
The throughput-matched configuration uses `b8+a8` with AXI-1024: the stored-b
stream supplies 8 coefficients/cycle and the ChaCha20 expander supplies 8
generated-a coefficients/cycle. The Middleware submission records this top as
492,697 cells and 0.063805 mm2 mapped standard-cell area. The reported datapath
footprint is mapped cells plus PCACTI SRAM: 0.063805 + 0.0285 = 0.0923 mm2,
rounded to 0.092 mm2. This is a pre-layout datapath footprint.

## Architecture

```
AXI-S group stream --> seeded_a_group_ingress --> seeded_a_coeff_frontend --> 16 x pe_mac --> 16 x acc_sram_bank
                              seed metadata ----> ChaCha20 expansion -----------^                    |
                                                                                  scalar_buffer        v
	                                                                                               16 x solinas_reduce
	                                                                                                        |
	                                                                                                        v
	                                                                                                  result_packer --> AXI-S out --> SSD-controller DMA to host memory
```

- **16 PEs** split as 8 stored-b lanes and 8 generated-a lanes, with banked accumulator SRAM
- **10-state FSM**: IDLE -> INIT_GROUP -> WAIT_BUF -> LOAD_SCALAR -> PROCESS -> NEXT_DIM -> REDUCE -> WRITEBACK -> NEXT_GROUP -> DONE
- **Coefficient-striped packing**: 51-bit coefficient shards are striped across NAND channels and packed without padding in each channel-local stream
- **Solinas prime** Q = 2^51 - 2^17 + 1: reduction via shift-and-add, no hardware multiplier
- **Result path**: Resa emits encrypted score ciphertext beats; the surrounding SSD controller result path performs the host-memory DMA writeback.
- **Seeded-a timing reference**: `../storage_validation/profiles/resa-datapath-selected.json`
  records the b8+a8 AXI-1024 datapath parameters used by the PM9A3/SimpleSSD
  integrated latency rows under `../storage_validation/`.
- **Seeded-a e2e RTL**: `he_accelerator_seeded_a` integrates the AXI-1024
  stored-b frontend, ChaCha20 generated-a path, 16 PE lanes, accumulator SRAM
  banks, Solinas reduction, and result packing. `tb_he_accelerator_seeded_a`
  verifies this top against a nonzero-query oracle.

## Testbench Details

| Testbench | Tests | What It Verifies |
|-----------|------:|-----------------|
| `tb_pe_mac` | 8 | Zero/one/identity, large values near Q, back-to-back pipeline, accumulation chain |
| `tb_acc_sram_bank` | 6 | Basic R/W at addr 0/1/last, write-first forwarding, full-depth sweep, overwrite |
| `tb_solinas_reduce` | 14 | Zero, one, Q-1, multiples of Q, powers of 2 (2^51, 2^102, 2^117), pipeline overlap |
| `tb_continuous_unpack` | 3 | Full 8192-coeff unpacking with known pattern, ciphertext boundary detection, flush/reset |
| `tb_result_packer` | 4 | Beat count (816 expected), tlast assertion, full bitstream round-trip, flush |
| `tb_chacha20_block_stream` | vector | RFC 8439 ChaCha20 block-function test vector |
| `tb_he_accelerator_seeded_a` | flow + oracle | Scaled seeded-a top-level flow; verifies all packed output coefficients against a nonzero-query oracle under bounded output backpressure |
| **Total Unit Tests** | **35** | Top-level flow test reported separately |

**Expected output** (all clean, no ERROR messages):

```
tb_pe_mac: 8 PASSED, 0 FAILED (total 8)                ALL TESTS PASSED
tb_acc_sram_bank: 6 PASSED, 0 FAILED (total 6)         ALL TESTS PASSED
tb_solinas_reduce: 14 PASSED, 0 FAILED (total 14)      ALL TESTS PASSED
tb_continuous_unpack: 3 PASSED, 0 FAILED (total 3)     ALL TESTS PASSED
tb_result_packer: 4 PASSED, 0 FAILED (total 4)         ALL TESTS PASSED
```

## Synthesis (Optional)

Requires Yosys and ASAP7 7nm PDK liberty files.

The result verifier checks the current mapped-cell/SRAM arithmetic from the
recorded Middleware synthesis-size row and attached power-output files.

```bash
# 1. Download ASAP7 PDK
git clone https://github.com/The-OpenROAD-Project/asap7

# 2. Set library path
export ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM
yosys -V
make synth
```

`make synth` expands the ASAP7 Liberty paths into
`syn/synth_seeded_a_logic_only.local.ys`, runs Yosys, writes the raw log to
`syn/synth_seeded_a_logic_only.log`, and writes the mapped netlist to
`syn/synth_seeded_a_logic_only.v`.

**Middleware synthesis-size record** (ASAP7 7nm, Yosys, SRAM blackboxed):

| Metric | Value |
|--------|-------|
| Total cells | 492,697 |
| Cell area | 54,721.495620 ASAP7 units |
| Mapped standard-cell area | 0.063805 mm^2 |

Note: SRAM macros (acc_sram_bank, scalar_buffer) are blackboxed during
synthesis. Their area is estimated separately using PCACTI.

## SRAM Estimation (Optional)

See `sram/README.md` for detailed instructions.

```bash
cd sram
chmod +x run_pcacti.sh
./run_pcacti.sh
```

**Expected SRAM results** (PCACTI, 7nm FinFET, 85C):

| Component | Config | Area (mm^2) | Power (mW) |
|-----------|--------|-------------|------------|
| Accumulator (aggregate) | 128 KB total accumulator SRAM | 0.0278 | 29.7 (leakage) + 2.6 (dynamic) |
| Query buffer | 768 x 51-bit = ~8 KB | 0.0007 | 1.6 |
| **Total SRAM** | | **0.0285** | **~33.8** |

The query-buffer macro is sized for the largest paper workload in this bundle
(768 dimensions). The RTL keeps `MAX_DIMS=4096` as a parameterized control
limit. A fully provisioned 4096-entry query SRAM is a separate sensitivity
point: using the same PCACTI settings, it would make the SRAM term about 0.0308
mm^2 and the mapped-cell + SRAM footprint about 0.0946 mm^2.

## Middleware Area/Power Record

The submission check script is Python-only:

```bash
python3 summary/middleware_area_power.py --check
python3 summary/middleware_area_power.py
```

**Recorded power breakdown** (500 MHz, attached tool outputs):

| Component | Power (mW) | Source |
|-----------|------------|--------|
| Seeded-a logic | 158.3 | `power/tool_outputs/asap7_cell_power.json` |
| SRAM | 33.8 | `power/tool_outputs/sram_pcacti.json` |
| **Total** | **192.1** | Derived by `summary/middleware_area_power.py` |

The area record is pre-layout mapped standard-cell area plus PCACTI SRAM macro
area. Routed and signoff quantities are outside this record. Power is computed
from the attached logic and SRAM tool-output JSONs.

## Design Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Ring dimension (N) | 4096 | Parameter point checked in `security/` |
| Coefficient width (K) | 51 bits | Solinas prime Q = 2^51 - 2^17 + 1 |
| Accumulator width (ACC_W) | 118 bits | Supports 65,536 accumulations without overflow: 2 x 51 + 16 = 118 |
| Number of PEs | 16 (b8+a8) | Throughput-matched stored-b and generated-a lanes |
| SRAM depth per bank | 512 | 2 x N / 16 = 512 |
| AXI-Stream width | 1024 bits | Stored-b stream for the seeded-a datapath |
| Evaluated embedding dims | 512 and 768 | Query SRAM macro is sized for the largest included workload |
| RTL `MAX_DIMS` parameter | 4096 | Control/interface parameter; not the query-SRAM macro size used in the 0.0923 mm^2 record |
| Modulus Q | 2^51 - 2^17 + 1 | Solinas prime: enables multiplier-free reduction |

## Result Evidence

| Result | Artifact Evidence | How to Verify |
|-------------|-------------------|---------------|
| RTL unit tests pass | Testbenches in `tb/` | `make verify` |
| Top-level flow and nonzero-query oracle complete | Scaled `tb_he_accelerator_seeded_a` | `make verify` |
| 0.063805 mm^2 mapped logic cell area | Middleware synthesis-size record | `python3 summary/middleware_area_power.py` |
| ~0.0285 mm^2 SRAM area | PCACTI 7nm configs | `cd sram && ./run_pcacti.sh` |
| 0.0923 mm^2 mapped-cell + SRAM footprint | Logic cell area + SRAM area, pre-layout footprint | `make summary` |
| 192.1 mW total power | 158.3 mW ASAP7 logic output + 33.8 mW PCACTI SRAM output | `make summary` |
| 500 MHz datapath timing | RTL cycle counts evaluated at a 500 MHz modeled clock | `../storage_validation/profiles/resa-datapath-selected.json` |
| 492,697 cells | Middleware synthesis-size record | `python3 summary/middleware_area_power.py` |
| Multiplier-free reduction | `solinas_reduce.v` uses only shifts and adds | Inspect source code |
| b8+a8 datapath | `he_accelerator_seeded_a.v` instantiates 16 `pe_mac` lanes | Inspect source code |

## Reproducing from Scratch

Run these commands from the `asic/` directory.

```bash
# 1. Verify functional correctness
make verify
# Expected: 35/35 unit checks pass; top-level flow test completes with 0 errors

# 2. Synthesis (if ASAP7 available)
export ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM
yosys -V
make synth
# Outputs: syn/synth_seeded_a_logic_only.log and syn/synth_seeded_a_logic_only.v
# Expected current Middleware size record: 492,697 cells, 54,721.495620 ASAP7 area units

# 3. SRAM estimation (if PCACTI available)
cd sram && ./run_pcacti.sh
# Expected: 0.028 mm^2 total SRAM area

# 4. Generate consolidated summary
make summary
# Outputs formatted area/power table

# 5. Check Middleware area/power arithmetic
make verify-results
# Expected: mapped-cell + SRAM area and attached power-output totals match
```

## Summary Check

Generate a consolidated Middleware area/power record:

```bash
# ASCII table summary
make summary

# JSON format
python3 summary/middleware_area_power.py --json

# Check arithmetic
make verify-results
```

**Summary output:**

```
Middleware Resa mapped-cell/SRAM footprint and tool-output power record
  cells:             492,697
  mapped cell area:  0.06381 mm^2
  SRAM area:         0.0285 mm^2
  mapped+SRAM area:  0.092 mm^2
  logic power:       158.3 mW
  SRAM power:        33.8 mW
  total power:       192.1 mW
```

See `summary/README.md` for the input files and arithmetic.

## License

This artifact is provided for academic review.
