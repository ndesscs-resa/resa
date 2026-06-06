# PM9A3 SimpleSSD Official-Sequential Selected Row

## Summary

This run selects the PM9A3-class SimpleSSD row used by the Middleware CSD
integration artifact and checks it against Samsung's capacity-specific PM9A3
7.68TB U.2 sequential-read data-sheet value.
The selected row is `officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy`.
It keeps the public device envelope, uses an 8 KB effective read model,
and sets the SimpleSSD memory-model clock prior to 425MHz.
The resulting 1 MB QD8 sequential read is `6715.229 MB/s`,
`+0.23%` above the official `6700 MB/s` target and `+0.02%` above the physical
PM9A3 holdout row.

## Selected Parameters

| Field | Value |
|---|---:|
| Candidate | `officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy` |
| PCIe | Gen4 x4 |
| Channel / Way / Die / Plane | 8 / 4 / 8 / 4 |
| Effective page size | 8K |
| tR levels | 5us / 8us / 12us |
| NAND DMA | 3000m x 16B |
| Stack latency | 42us / 42us |
| SimpleSSD memory-model prior | BusClock=425m, SRAM=425m x36 DDR2 |

## Validation Rows

| Workload | SimpleSSD MB/s | Physical MB/s | Error |
|---|---:|---:|---:|
| cal_randread_4k_qd1 | 42.973 | 48.031 | -10.53% |
| cal_randread_4k_qd32 | 1370.670 | 1547.469 | -11.42% |
| cal_randread_4k_qd32_nj4 | 4480.412 | 3788.461 | +18.26% |
| cal_seqread_1m_qd32 | 6715.085 | 6734.465 | -0.29% |
| hold_randread_16k_qd8 | 1335.746 | 1278.199 | +4.50% |
| hold_randread_4k_qd64_nj4 | 4479.726 | 4487.282 | -0.17% |
| hold_seqread_1m_qd8 | 6715.229 | 6714.190 | +0.02% |

## Scope

This is the storage row used by the submission CSD integration results. The
physical rows are validation anchors, not direct integrated pipeline inputs.
This row is reported as a PM9A3-class SimpleSSD-selected storage profile.
