# SRAM Estimation

Resa uses on-chip SRAM for the accumulator banks and query scalar buffer.
Since SRAM macros are technology-specific and cannot be synthesized from RTL,
we estimate their area and power using PCACTI, a FinFET-aware CACTI variant.

## Tool

**PCACTI** (Parameterized CACTI for FinFET Memory Estimation)
- Paper: ICECS 2024
- Source: https://github.com/ARC-Lab-UF/PCACTI

## Configurations

| Config File | Component | Size | Geometry |
|-------------|-----------|------|----------|
| `accum_bank_7nm.xml` | Single accumulator macro point | 1024 x 118-bit (16 KB) | Dual-port (1R+1W) |
| `accum_total_7nm.xml` | Aggregate accumulator SRAM budget | 128 KB total | 8-bank UCA model, area-equivalent to the seeded-a 16 x 512-bank layout |
| `query_buf_7nm.xml` | Query scalar buffer for the paper workloads | 768 x 51-bit (8 KB) | Single RW port |

All configs target 7nm FinFET at 85C class temperature.
The query buffer is sized for the largest embedding dimension carried by the
artifact's checked workloads. The RTL is parameterized with `MAX_DIMS=4096`, but
the reported 0.0285 mm2 SRAM term is the 768-entry paper-workload macro, not a
fully provisioned 4096-entry query SRAM. With the same PCACTI settings, a
4096-entry query buffer is 32 KB, area 0.0029 mm2, and read-only query-buffer
power about 6.5 mW; the mapped-cell + SRAM footprint would be about 0.0946 mm2.

## Running

```bash
# Run all estimations
chmod +x run_pcacti.sh
./run_pcacti.sh
```

The script runs the PCACTI binary from the PCACTI tool directory so that the
tool's `xmls/` support paths resolve. Set `PCACTI_BIN` or `PCACTI_WORKDIR` only
if the default repository-local `tools/pcacti_xml/cacti` path is not the desired
PCACTI build.

## Recorded Area Results

| Component | Area (mm2) |
|-----------|-----------:|
| Accumulator aggregate | 0.0278 |
| Query buffer | 0.0007 |
| **Total SRAM** | **0.0285** |

The Middleware area/power checker reads the SRAM power from
`../power/tool_outputs/sram_pcacti.json`. The attached PCACTI output reports
33.8469 mW for the aggregate accumulator/query SRAM configuration.
