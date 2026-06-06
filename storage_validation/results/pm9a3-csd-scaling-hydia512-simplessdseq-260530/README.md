# PM9A3 SimpleSSD-Integrated CSD Scaling

## Summary

This directory contains the CSD curve used in the HyDia scaling figure.
Each CSD point connects the selected PM9A3-class SimpleSSD sequential-read stream to the fixed-function Resa pipeline.
The CSD rows are deterministic integrated simulation rows.
For each corpus size, the script reuses the selected SimpleSSD validation row as the storage producer and recomputes the CSD pipeline schedule.
Scope: PM9A3-class SimpleSSD-selected storage profile plus Resa datapath timing.

## Configuration

- Profile manifest: `storage_validation/profiles/pm9a3-memory-prior-selected.json`
- Datapath profile: `storage_validation/profiles/resa-datapath-selected.json`
- Candidate: `officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy`
- Workload anchor: `hold_seqread_1m_qd8`
- Stream source: `simplessd_host_read_validation`
- Stream bandwidth: `6715.229 MB/s`
- Dimension: `512`
- Resa input source: `axis`
- Buffer groups: `3`
- Result ciphertext bytes: `65536`
- Result memory model: `host result ciphertext array; one result ciphertext per storage group`

## Source Rows

| Row | Value |
|---|---:|
| SimpleSSD BW | 6715.229 MB/s |
| SimpleSSD mean latency | 1244.866 us |
| Physical PM9A3 holdout BW | 6714.191 MB/s |
| Physical PM9A3 holdout mean latency | 1204.056 us |
| Raw parameter page BW | 7706.491 MB/s |
| Stream efficiency vs raw page model | 0.871 |

## Key Rows

- `2^23` vectors: `4.157842s`, `134.2 MB` host result ciphertext memory.
- `2^24` vectors: `8.315152s`, `268.4 MB` host result ciphertext memory.

## Scope Notes

- Selected PM9A3-class SimpleSSD storage profile.
- Fixed-function Resa datapath timing profile.
- Physical fio rows used as validation anchors for the selected storage row.
- Host memory counted as result ciphertext array storage after writeback.

## Files

- `scaling_512.csv`: CSD rows consumed by `baselines/hydia/prepare_paper_outputs.py`.
- `summary.json`: provenance summary for the generated scaling rows.
