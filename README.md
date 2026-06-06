# Middleware Submission Artifact

This directory contains the artifact bundle for the Middleware submission.

This bundle is kept narrow. It contains the files used to check the current
paper numbers. Large datasets, raw full-corpus logs, tool installations, and
exploratory runs are left out.

## Contents

| Path | What it contains |
|---|---|
| `DEPENDENCIES.md` | Quick-check and optional rerun dependency matrix |
| `asic/` | Resa seeded-a RTL, testbenches, synthesis scripts, SRAM configs, and the area/power summary scripts |
| `baselines/ckks_error/` | Lattigo-based CKKS error checks and the result JSONs used for the approximation-error discussion |
| `baselines/hydia/` | HyDia patch/scripts plus the frozen resident-baseline result slice |
| `storage_validation/` | PM9A3 allocated-file validation rows, the selected SimpleSSD profile, and Resa scaling rows for the 512D comparison |
| `ranking/gpu_he/` | Fixed-point full-corpus ranking replay scripts and portable summary results |
| `security/` | CKKS/RLWE parameter record and lattice-estimator rerun snippet |
| `paper_outputs/` | Figure/table files consumed by the Middleware paper tree |

## Quick Check

The quick check covers the short structural and arithmetic checks. Longer GPU,
HyDia, and synthesis reruns are listed in `DEPENDENCIES.md`.

```bash
make quick-check
```

It checks:

- the expected files are present
- temporary build products such as VCD/VVP/pycache files are absent
- the fixed-point wiki-all summary has MRR@10 = 0.9999
- the CKKS result bundle is internally consistent
- the ASIC area/power summary matches the attached tool-output files
- the security parameter record is self-consistent

`DEPENDENCIES.md` lists what is needed for the short checks and what is needed
only for heavier reruns.

## Paper-Number Map

| Paper number | Artifact file |
|---|---|
| Resa 8.4M-vector 512D latency: 4.16 s | `storage_validation/results/pm9a3-csd-scaling-hydia512-simplessdseq-260530/scaling_512.csv` |
| HyDia 8.4M-vector 512D score path: 203.2 s | `baselines/hydia/results/resident-real-260529/scaling_512.csv` |
| HyDia peak resident memory: about 139 GB | `baselines/hydia/results/resident-real-260529/scaling_512.csv` |
| Resa 8.4M-vector host result memory: 134.2 MB | `storage_validation/results/pm9a3-csd-scaling-hydia512-simplessdseq-260530/scaling_512.csv` |
| wiki-all fixed-point replay MRR@10: 0.9999 | `ranking/gpu_he/results/wiki_all_88m_he_recall_10k.summary.json` |
| CKKS sampled max errors: about 1e-5 | `baselines/ckks_error/results/recall_fullscale_*_v3.json` |
| ASIC mapped-cell + SRAM footprint: 0.0923 mm2, reported as 0.092 mm2 | `asic/summary/middleware_area_power.py` |
| ASIC power estimate: 192.1 mW | `asic/power/tool_outputs/*.json` and `asic/summary/middleware_area_power.py` |
| CKKS/RLWE parameter point | `security/README.md`, `security/lattice_estimator_params.py` |

## ASIC Boundary

The area number is a pre-layout datapath footprint: mapped standard-cell area
plus PCACTI SRAM macro area. The SRAM term includes the 128 KB accumulator
budget and a 768-entry query-scalar buffer, matching the largest 768D workload
carried by this artifact. Detailed physical-design scope notes are in
`asic/README.md`.

The power number is the sum of two attached outputs:

- ASAP7 Liberty vectorless logic-power output: 158.276 mW
- PCACTI SRAM-power output: 33.847 mW

The checker reports their sum as 192.1 mW.
