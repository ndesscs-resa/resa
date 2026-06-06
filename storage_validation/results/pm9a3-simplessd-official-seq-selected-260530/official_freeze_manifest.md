# PM9A3 Selected-Profile Manifest

This SimpleSSD grid keeps Samsung-public PM9A3 fields fixed and searches the
remaining simulator parameters.

| Field | Fixed value | Use |
|---|---|---|
| PCIe link | Gen4 x4 | SimpleSSD host interface |
| Channel count | 8 | Fixed SimpleSSD FIL topology |
| NAND type | TLC (`NANDType=2`) | SimpleSSD NAND model |
| Product capacity | 7.68TB U.2 PM9A3 target; SimpleSSD --capacity is a simulation scale knob | Paper-facing device description |
| Simulation capacity | 8G | Runtime scale for SimpleSSD state |

Allowed fitting variables include way/die/plane, page size, page allocation,
NAND bus timing, NAND read/program timing, cache policy, and warm-up/FTL policy.
Standalone storage-stack latency may be used only as a reported harness parameter.
With the batched `BlockIOLayer` dispatch patch, symmetric stack latency is a
per-request delay rather than a serialized request service time. Without that
patch, nonzero `SubmissionLatency` creates an artificial 4 KB high-QD ceiling.
Submission rows keep `IOQueues=1`.
PCIe generation/lane, NAND type, and channel count are held fixed.
