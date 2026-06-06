# Storage Validation Profiles

## Summary

This directory keeps the two small profile records consumed by the CSD timing
scripts: the selected PM9A3-class SimpleSSD storage row and the fixed-function
Resa datapath timing record. The files keep the storage assumptions and Resa
cycle-count assumptions separate.

## Files

| File | Role |
|---|---|
| `pm9a3-memory-prior-selected.json` | Selected SimpleSSD storage profile for the PM9A3 sequential CSD scan |
| `resa-datapath-selected.json` | Resa b8+a8 AXI-1024 datapath parameters used by integrated/scaling runners |

## Scope

The storage profile combines public PM9A3 fields, a SimpleSSD source-aligned
memory-model prior, and physical allocated-file read validation into a
PM9A3-class storage simulation profile. The Resa datapath profile records the
fixed-function timing parameters used to turn that storage stream into a
device-local CSD pipeline schedule.
