# Power Tool Outputs

This directory contains the two power-output files used by the ASIC summary. The
summary script reads these files and adds the logic and SRAM terms.

## Attached Outputs

| File | Producer | Reported value |
|---|---|---:|
| `tool_outputs/asap7_cell_power.json` | `python3 ../summary/asap7_cell_power.py --json` | 158.276 mW logic |
| `tool_outputs/sram_pcacti.json` | `python3 ../summary/sram_pcacti.py --json` | 33.847 mW SRAM |

The checker reports the derived total as:

```text
158.276 mW + 33.847 mW = 192.122 mW, reported as 192.1 mW
```

## Regeneration

From the `asic/` directory:

```bash
python3 summary/asap7_cell_power.py --json > power/tool_outputs/asap7_cell_power.json
python3 summary/sram_pcacti.py --json > power/tool_outputs/sram_pcacti.json
python3 summary/middleware_area_power.py --check
```

The ASAP7 logic-power script requires the ASAP7 RVT NLDM Liberty files. Set
`ASAP7_LIB_DIR` if they are not available at the repository default path. The
PCACTI script requires the checked-in or locally configured PCACTI binary used by
`sram/run_pcacti.sh`.
