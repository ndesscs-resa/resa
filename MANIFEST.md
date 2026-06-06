# Manifest

This file lists the artifact sections and the checks that are expected to run on
a clean clone.

## Sections

| Path | Contents |
|---|---|
| `README.md` | Entry point and paper-number map |
| `DEPENDENCIES.md` | Dependency matrix for quick checks and optional reruns |
| `Makefile` | Short CPU-side checks for local validation |
| `asic/` | RTL, testbenches, synthesis scripts, SRAM configs, and ASIC area/power scripts |
| `baselines/ckks_error/` | CKKS numerical-error source and frozen result JSONs |
| `baselines/hydia/` | HyDia patch/scripts and frozen resident-baseline results |
| `storage_validation/` | Allocated-file device validation rows, selected SimpleSSD profile, and Resa scaling rows |
| `ranking/gpu_he/` | Fixed-point ranking replay scripts and compact result summaries |
| `security/` | CKKS/RLWE parameter record |
| `paper_outputs/` | Figure and table files used by the paper tree |
| `scripts/` | Bundle consistency checker |

## Expected Local Checks

```bash
make quick-check
```

This target checks the file inventory, rejects build byproducts, checks the
compact ranking and CKKS result summaries, checks the ASIC area/power arithmetic,
and validates the security parameter record.

The ASIC area check stops at mapped standard-cell area plus PCACTI SRAM macro
area. The power check sums the attached ASAP7 vectorless logic-power output and
the attached PCACTI SRAM-power output.
