# Storage Validation Results Index

## Summary

This directory keeps only the allocated-file storage validation rows and
generated CSD timing rows used by the Middleware artifact. The selected storage
row is `officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy`; integrated CSD
latency rows use that SimpleSSD row as the storage producer.

## Included Results

| Result directory | Role |
|---|---|
| `pm9a3-allocated-file-read-260530/` | allocated-file PM9A3 validation rows |
| `pm9a3-simplessd-official-seq-selected-260530/` | selected PM9A3-class SimpleSSD storage profile output |
| `pm9a3-csd-integrated-officialseq-simplessdseq-260530/` | 100M-vector integrated device-pipeline timing result |
| `pm9a3-csd-scaling-hydia512-simplessdseq-260530/` | 512D scaling rows consumed by the HyDia comparison figure |

## Scope

The physical PM9A3 rows are validation anchors for the selected SimpleSSD
storage row. The integrated rows are deterministic timing simulation outputs
that use that selected row as the storage producer for the Resa datapath.
