# Dependencies

## Short Version

`make quick-check` uses GNU Make, Bash, and Python 3.10 or newer. GPU, Docker,
Yosys, ASAP7, PCACTI, SimpleSSD, fio, PM9A3-device, Sage, and large-dataset
workflows are optional reruns.

Heavier reruns are listed separately below. External tools are installed
separately unless a file is explicitly listed as part of the artifact. The
recorded result files are included for checking the paper numbers without
installing every optional toolchain.

## Always Needed

| Use | Dependency | Notes |
|---|---|---|
| `make quick-check` | GNU Make | Runs short structural checks only |
| `make quick-check` | Bash/coreutils | Used by the Makefile and helper scripts |
| Python scripts | Python `>=3.10` | Uses modern type syntax such as `str | Path`; quick-check uses only the standard library |

## Quick-Check Inputs

| Check | Extra dependency | Command |
|---|---|---|
| bundle inventory | none beyond Python | `python3 scripts/check_bundle.py` |
| ASIC area/power arithmetic | none beyond Python | `python3 asic/summary/middleware_area_power.py --check` |
| CKKS result JSON validation | none beyond Python | `make -C baselines/ckks_error verify-results` |
| security parameter record | none beyond Python | `python3 security/lattice_estimator_params.py --check` |

## ASIC RTL, Synthesis, SRAM, And Power

| Rerun | Dependency | Artifact path / variable |
|---|---|---|
| RTL tests | Icarus Verilog, tested with `iverilog`/`vvp` | `make -C asic verify` |
| RTL lint | Verilator | `make -C asic lint` |
| mapped-cell synthesis | Yosys `>=0.40`; recorded netlist was generated with Yosys 0.51 | `make -C asic synth` |
| mapped-cell synthesis | ASAP7 RVT NLDM Liberty files | set `ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM` |
| live logic-power recomputation | ASAP7 RVT NLDM Liberty files and the mapped netlist | `python3 asic/summary/asap7_cell_power.py --json` |
| live SRAM estimate | PCACTI binary and working directory | set `PCACTI_BIN` or `PCACTI_WORKDIR` if the default is not valid |

The synthesis flow reads `asic/syn/synth_seeded_a_logic_only.ys`, blackboxes
`acc_sram_bank` and `scalar_buffer`, maps `he_accelerator_seeded_a` through ASAP7
RVT Liberty files, and writes `asic/syn/synth_seeded_a_logic_only.v`. SRAM area
and power are handled separately through the PCACTI configs in `asic/sram/`.

## Storage Validation And SimpleSSD

| Rerun | Dependency | Notes |
|---|---|---|
| PM9A3 inventory | Linux, `nvme-cli`, `lsblk`, `lspci`, optional root | `storage_validation/inventory.sh` |
| allocated-file PM9A3 rows | Linux, `fio`, `nvme-cli`, a safe allocated file on the target SSD | `storage_validation/run_allocated_file_read.sh` |
| fio summary | Python `>=3.10`, standard library only | `storage_validation/summarize_fio.py` |
| selected SimpleSSD row rerun | external SimpleSSD standalone 2.1-style checkout and CMake build | apply patches under `storage_validation/patches/` before running |
| CSD integrated/scaling timing | Python `>=3.10`, standard library only | `storage_validation/run_csd_integrated.py`, `storage_validation/run_csd_scaling.py` |

The selected SimpleSSD outputs are bundled under
`storage_validation/results/pm9a3-simplessd-official-seq-selected-260530/`.
Rerunning the selected storage row requires an external SimpleSSD standalone
checkout; this artifact carries the two local patches used by the run:

- `storage_validation/patches/simplessd-pcie-gen4-v2.1.patch`
- `storage_validation/patches/simplessd-standalone-batched-block-io.patch`

## CKKS Error And Ranking Validation

| Rerun | Dependency | Notes |
|---|---|---|
| bundled JSON validation | Python standard library | `make -C baselines/ckks_error verify-results` |
| Go binaries | Go with toolchain download enabled; Makefile uses `GOTOOLCHAIN=go1.24.0` | `make -C baselines/ckks_error build` |
| Go HE library | Lattigo from `go.mod`/`go.sum` | fetched by `go` when building |
| synthetic CKKS smoke | Go build dependencies only | `make -C baselines/ckks_error recall-benchmark` |
| full-scale text retrieval rerun | large corpus/query `.bin` files, Go, enough RAM/disk | `cmd/recall_fullscale` |
| dataset preparation | Python packages `numpy`, `datasets`, `sentence-transformers`, `torch`, `huggingface_hub` | scripts under `baselines/ckks_error/scripts/` |

Large dataset binaries and HuggingFace caches are external inputs.

## HyDia Baseline

| Rerun | Dependency | Notes |
|---|---|---|
| HyDia score-only run | external HyDia checkout, Git, Docker | apply `baselines/hydia/hydia-similarity-depth1.patch` |
| HyDia native resident run | external HyDia checkout with `build/ImageMatching`, OpenFHE runtime libraries | `baselines/hydia/run_native_until_oom.sh` |
| HyDia memory polling | Docker CLI and cgroup memory reporting | `baselines/hydia/run_similarity_with_stats.sh` |
| figure/table regeneration | Python `>=3.10`, `matplotlib` for plots | `baselines/hydia/plot_scaling.py`, `baselines/hydia/prepare_paper_outputs.py` |

Use an external upstream HyDia checkout and generated datasets for reruns. The
frozen resident result slice used by the paper is bundled under
`baselines/hydia/results/resident-real-260529/`.

## GPU Fixed-Point Ranking Replay

| Rerun | Dependency | Notes |
|---|---|---|
| GPU smoke / 100M replay | NVIDIA driver and CUDA-capable PyTorch | no `nvcc` required |
| Python packages | `torch`, `numpy` | scripts under `ranking/gpu_he/` |
| wiki-all replay | RAPIDS/cuVS wiki-all `.fbin`/`.ibin` dataset, about 251 GB fp32 base/query/groundtruth archive | `ranking/gpu_he/download_wiki_all.sh` |

The raw 10,000-query wiki-all JSON and the 251 GB dataset are external inputs.
The portable summary used by the paper is bundled as
`ranking/gpu_he/results/wiki_all_88m_he_recall_10k.summary.json`.

## Security Estimator Rerun

| Rerun | Dependency | Notes |
|---|---|---|
| bundled parameter check | Python standard library | `python3 security/lattice_estimator_params.py --check` |
| estimator rerun | Albrecht et al. lattice-estimator with Sage support | print snippet with `--print-estimator-snippet` |

Use a separate lattice-estimator/Sage environment for estimator reruns.

## External Data And Tools Not Included

- ASAP7 PDK Liberty files
- PCACTI binary/source checkout
- SimpleSSD standalone checkout/build directory
- physical PM9A3 device
- upstream HyDia checkout and Docker image
- RAPIDS/cuVS wiki-all dataset
- full text-retrieval corpus/query binaries and HuggingFace caches
- Sage/lattice-estimator installation
