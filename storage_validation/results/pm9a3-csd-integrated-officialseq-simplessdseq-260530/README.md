# PM9A3 SimpleSSD + CSD Integrated Device Pipeline

## Summary

This result connects the selected PM9A3-class SimpleSSD profile and the Resa datapath in one device-local pipeline.
The SSD controller supplies a device-local stream to the Resa AXI-Stream input and DMA-writes Resa's compact encrypted result stream to host memory.
That DMA writeback is part of the controller result path; the synthesized Resa RTL emits the encrypted result stream.
The primary stream source is `simplessd_host_read_validation` and the end-to-end latency is `73.389s`.
The bottleneck is `ssd_read_to_csd_stream`.
This is a device-level timing schedule built from the selected storage simulation output and the Resa datapath timing profile.

## Selected Storage Profile

| Field | Value |
|---|---:|
| Candidate | `officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy` |
| PCIe | Gen4 x4 |
| Channel / Way / Die / Plane | 8 / 4 / 8 / 4 |
| Effective page size | 8K |
| Page allocation | CWDP |
| tR levels | 5us / 8us / 12us |
| NAND DMA | 3000m x 16B |
| Cache / prefetch | 0 / false |
| SimpleSSD memory-model prior | BusClock=425m, SRAM=425m x36 DDR2 |

## Device-Local Pipeline

| Stage | Per-group time | Notes |
|---|---:|---|
| SSD controller read path -> Resa stream boundary | 3.005867 ms | `6715.229 MB/s` storage producer |
| Resa AXI-Stream input | 0.315392 ms | `64000.000 MB/s`, source `axis` |
| Resa arithmetic | 0.786432 ms | 768 ctxts/group, 512 cycles/ctxt |
| SSD-controller DMA writeback | 8.077600 us | compact encrypted score ciphertext to host memory |
| Resa stage accounting | 0.786432 ms | `overlap_input_with_compute` |

## Aggregate Result

| Metric | Value |
|---|---:|
| Database size | 492.819 GB |
| Groups | 24,415 |
| Buffer capacity | 3 groups |
| Storage-only time | 73.388 s |
| Integrated e2e latency | 73.389 s |
| Producer active fraction | 100.00% |
| Resa compute active fraction | 26.16% |
| Resa input active fraction | 10.49% |
| Resa storage wait | 53.991 s |
| Producer buffer stall | 0.000 s |

## Scope

This result is used for the PM9A3-class device-local scan model.
The strict SRAM x36 bandwidth field belongs to the SimpleSSD memory-model prior used to reproduce host-visible storage behavior.
The Resa input stream defaults to the synthesized AXI input port because the accelerator consumes the controller-provided local stream instead of issuing host NVMe reads.
