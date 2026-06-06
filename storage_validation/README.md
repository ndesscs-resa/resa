# Storage Validation Artifact

## Summary

This directory contains the storage evidence used by the Middleware artifact:
allocated-file PM9A3 validation rows, the selected PM9A3-class SimpleSSD row,
and the device-local Resa timing simulations built from that row. The selected
storage row is a SimpleSSD parameter choice validated against physical PM9A3
read rows. It is used as a PM9A3-class storage profile, not as a vendor-internal
parameter claim.

The submission CSD latency path is:

```text
selected SimpleSSD sequential read row
  -> SSD-controller local stream boundary
  -> Resa AXI-Stream input
  -> fixed-function seeded-a Resa datapath
  -> SSD-controller DMA writeback of compact encrypted results
```

It is a deterministic device-pipeline timing simulation that combines the
selected storage stream with the fixed-function Resa datapath profile.

## Included Evidence

| Path | Role |
|---|---|
| `results/pm9a3-allocated-file-read-260530/` | allocated-file PM9A3 rows used for NAND-backed validation |
| `profiles/pm9a3-memory-prior-selected.json` | selected SimpleSSD storage profile record |
| `profiles/resa-datapath-selected.json` | fixed-function Resa datapath timing profile |
| `results/pm9a3-simplessd-official-seq-selected-260530/` | selected SimpleSSD run output and config |
| `results/pm9a3-csd-integrated-officialseq-simplessdseq-260530/` | integrated 100M-vector CSD pipeline result |
| `results/pm9a3-csd-scaling-hydia512-simplessdseq-260530/` | CSD scaling rows used by the HyDia comparison figure |

## Read-Only PM9A3 Measurement

Run the commands in this section from `storage_validation/`.

Inventory:

```bash
sudo ./inventory.sh --ctrl /dev/nvmeX --ns /dev/nvmeXn1 --out results/pm9a3-inventory
```

Allocated-file read matrix:

```bash
./run_allocated_file_read.sh \
  --file /path/to/pm9a3-allocated-read-128g.bin \
  --out results/pm9a3-allocated-file-read \
  --size 128G \
  --runtime 180 \
  --ramp-time 20

python3 ./summarize_fio.py \
  results/pm9a3-allocated-file-read \
  --out-csv results/pm9a3-allocated-file-read/summary.csv \
  --out-md results/pm9a3-allocated-file-read/summary.md
```

## Selected SimpleSSD Row

Selected candidate:

```text
officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy
```

Key validation rows:

| Workload | SimpleSSD MB/s | Physical MB/s | Error |
|---|---:|---:|---:|
| `hold_seqread_1m_qd8` | 6715.229 | 6714.190 | +0.02% |
| `hold_randread_16k_qd8` | 1335.746 | 1278.199 | +4.50% |
| `hold_randread_4k_qd64_nj4` | 4479.726 | 4487.282 | -0.17% |

The sequential row is also `+0.23%` against the Samsung PM9A3 7.68TB U.2
data-sheet sequential-read value of 6700 MB/s. The weakest calibration row is
4 KB QD32 with four jobs, where SimpleSSD overpredicts by `+18.26%`; that row is
kept in the profile record as a small-random validation gap. The integrated CSD
path uses the selected sequential stream row.

## Integrated CSD Pipeline

Generate the 100M-vector integrated pipeline result:

```bash
./run_csd_integrated.py \
  --stream-source simplessd_seq \
  --out-dir results/pm9a3-csd-integrated-officialseq-simplessdseq-260530
```

The selected run reports `73.389s` end-to-end latency. The bottleneck is the SSD
read stream, not Resa arithmetic or the AXI input stage.

Generate the 512D scaling rows used by the HyDia figure:

```bash
./run_csd_scaling.py \
  --stream-source simplessd_seq \
  --workload hold_seqread_1m_qd8 \
  --out-dir results/pm9a3-csd-scaling-hydia512-simplessdseq-260530
```

At `2^23` vectors, the selected scaling row reports `4.157843s` and 134.2 MB
of host memory for result ciphertexts.

## Safety Rules

- Run `inventory.sh` first and verify model, serial, firmware, namespace size, and PCIe link speed.
- Do not use a mounted namespace unless this is explicitly a local smoke test.
- Do not run write workloads on a namespace containing data.
- Archive SMART before and after every validation run.
- Redact hostnames, user names, serial numbers, and namespace GUIDs before publishing fresh inventory/output files.
- Label results as fresh-state, sustained-state, or read-only current-state. Do not mix them.

## Calibration/Holdout Split

| Split | Workload |
|---|---|
| calibration | sequential read, 128 KB, QD32 |
| calibration | sequential read, 1 MB, QD32 |
| calibration | random read, 4 KB, QD1 |
| calibration | random read, 4 KB, QD32 |
| calibration | random read, 4 KB, QD32, 4 jobs |
| holdout | sequential read, 64 KB, QD8 |
| holdout | sequential read, 1 MB, QD8 |
| holdout | random read, 16 KB, QD8 |
| holdout | random read, 64 KB, QD64 |
| holdout | random read, 4 KB, QD64, 4 jobs |

The calibration rows select the SimpleSSD profile. The holdout rows are kept as
validation rows; the integrated CSD pipeline uses the selected SimpleSSD row as
its storage producer.
