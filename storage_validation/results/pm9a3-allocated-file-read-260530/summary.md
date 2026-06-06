# fio Summary

| split | name | op | bs | iodepth | numjobs | bw_mb_s | iops | clat_mean_us | clat_p99_us |
|---|---|---|---|---|---|---|---|---|---|
| calibration | alloc_randread_4k_qd1 | read | 4K | 1 | 1 | 48.031 | 11726.418 | 78.037 | 175.104 |
| calibration | alloc_randread_4k_qd32 | read | 4K | 32 | 1 | 1547.468 | 377799.712 | 82.624 | 154.624 |
| calibration | alloc_randread_4k_qd32_nj4 | read | 4K | 32 | 4 | 3788.461 | 924916.523 | 135.733 | 370.688 |
| calibration | alloc_seqread_1m_qd32 | read | 1M | 32 | 1 | 6734.465 | 6422.314 | 4946.319 | 5341.184 |
| holdout | alloc_randread_16k_qd8 | read | 16K | 8 | 1 | 1278.200 | 78015.072 | 95.411 | 150.528 |
| holdout | alloc_randread_4k_qd64_nj4 | read | 4K | 64 | 4 | 4487.283 | 1095526.569 | 231.336 | 806.912 |
| holdout | alloc_seqread_1m_qd8 | read | 1M | 8 | 1 | 6714.191 | 6403.112 | 1204.056 | 1564.672 |
| prepare | write_1m_qd32 | write | 1M | 32 | 1 | 4157.761 | 3965.150 | 7986.286 | 8847.360 |
