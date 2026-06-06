# Resa Middleware Summary and Verification

This directory contains the small scripts used to summarize the ASIC evidence in
this bundle.

## Scripts

| File | Purpose |
|------|---------|
| `middleware_area_power.py` | Reads the area constants and attached power-output JSONs, then checks the reported totals |
| `asap7_cell_power.py` | Re-runs ASAP7 Liberty vectorless logic-power estimation over the mapped netlist |
| `sram_pcacti.py` | Re-runs PCACTI over the SRAM XML configs and reports SRAM area/power |

## Quick Start

```bash
# Area/power arithmetic check. Requires Python only.
python3 middleware_area_power.py --check

# Area/power table from the recorded area values and attached tool outputs
python3 middleware_area_power.py
```

The checked footprint is mapped standard cells plus PCACTI SRAM macro area.
Routed and signoff area are outside this summary.

## Source Types

- **RECORDED**: value written directly in this small summary script.
- **FILE**: read from a small artifact input file.
- **TOOL_OUTPUT**: read from `../power/tool_outputs/*.json`.
- **DERIVED**: computed from RECORDED, FILE, or TOOL_OUTPUT inputs by an explicit formula.

## Values Checked

| Category | Result | Value | Evidence Path |
|----------|-------|-------------|---------------|
| Area | Logic cell area | 0.063805 mm^2 | Middleware synthesis-size record |
| Area | SRAM area | 0.0285 mm^2 | PCACTI SRAM XML configs: 128 KB accumulator budget plus 768-entry query buffer |
| Area | Total mapped-cell + SRAM footprint | 0.0923 mm^2 | Logic cell area + SRAM area |
| Area | Cell count | 492,697 | Middleware synthesis-size record |
| Power | Logic power | 158.3 mW | `../power/tool_outputs/asap7_cell_power.json` |
| Power | SRAM power | 33.8 mW | `../power/tool_outputs/sram_pcacti.json` |
| Power | Total power | 192.1 mW | Logic + SRAM |

## Check Output

Successful verification ends with:

```text
Middleware area/power checks OK
```

## Notes

This package reports mapped standard-cell area plus PCACTI SRAM macro area. The
query-buffer macro in the reported SRAM term is sized for the 768D
paper-workload point; a full 4096-entry query buffer is a separate macro sizing
point.
