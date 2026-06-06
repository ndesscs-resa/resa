# Resa Synthesis Directory

This directory contains the Yosys scripts for ASAP7 7nm logic-only synthesis of
the CSD HE accelerator. SRAM modules are blackboxed during logic synthesis and
accounted for separately through the PCACTI SRAM methodology in `../sram/`.

## Files

| File | Description |
|------|-------------|
| `synth_seeded_a_logic_only.ys` | Seeded-a top Yosys synthesis with SRAM blackboxed |
| `acc_sram_bank_bb.v` | Blackbox declaration for accumulator SRAM |
| `scalar_buffer_bb.v` | Blackbox declaration for query scalar buffer |
| `synthesis_results.txt` | Human-readable Middleware synthesis-size record |
| `synth_seeded_a_logic_only.log` | Recorded Yosys 0.51 ASAP7 synthesis log |

## Prerequisites

- Yosys >= 0.40
- ASAP7 7nm PDK liberty files

```bash
git clone https://github.com/The-OpenROAD-Project/asap7
export ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM
```

## Middleware Verification

Use the Middleware artifact checker for the area/power arithmetic:

```bash
cd asic
make verify-results
```

That checker reports mapped standard-cell area plus PCACTI SRAM macro area, the
pre-layout scope used by the artifact summary.

## Current Expected Results

| Metric | Value |
|--------|-------|
| Total cells | 492,697 |
| Cell area | 54,721.495620 ASAP7 units |
| Mapped standard-cell area | 0.063805 mm^2 |
| SRAM area | 0.0285 mm^2, from PCACTI methodology input |
| Total mapped-cell + SRAM footprint | 0.0923 mm^2, reported as 0.092 mm^2 |

## Local Raw Synthesis Run

From the repository root:

```bash
cd asic
export ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM
yosys -V
make synth
```

`make synth` creates `syn/synth_seeded_a_logic_only.local.ys` with absolute
Liberty paths, runs Yosys, writes the raw log to
`syn/synth_seeded_a_logic_only.log`, and writes the mapped gate-level netlist to
`syn/synth_seeded_a_logic_only.v`.

The synthesis script is short:

| Step | Script lines |
|---|---|
| SRAM blackboxes | `read_verilog ./acc_sram_bank_bb.v`, `read_verilog ./scalar_buffer_bb.v` |
| RTL input set | `read_verilog ../rtl/src/*.v` entries in `synth_seeded_a_logic_only.ys` |
| Top module | `synth -top he_accelerator_seeded_a -flatten` |
| Technology mapping | `dfflibmap` and `abc` against ASAP7 RVT NLDM Liberty files |
| Area report | `stat` over the ASAP7 RVT Liberty files |

Expected current result with the recorded tool flow:

```text
Top module: he_accelerator_seeded_a
Total cells: 492,697
Cell area: 54,721.495620 ASAP7 units
Mapped standard-cell area used by the artifact: 0.063805 mm^2
```

The raw Yosys cell mix can move if a reviewer uses a different Yosys/ABC build
or a different ASAP7 Liberty release. For this submission, the recorded evidence
is `synthesis_results.txt`, `synth_seeded_a_logic_only.v`, the Yosys log, and
the attached power-output JSONs. `make synth` rebuilds the mapped netlist from
the RTL.

## Scope

- ASAP7 is used as the research 7nm standard-cell library for the mapped logic
  record.
- SRAM macros are handled through the PCACTI records under `../sram/`.
- Place-and-route, DRC/LVS, and signoff timing are outside the synthesis record.
