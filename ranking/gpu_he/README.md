# GPU HE Arithmetic Validation

This directory contains a CUDA-backed validator for the paper's core HE
arithmetic path. It executes the same coefficient-domain `const x ctxt` modular
MAC computed by the CSD accelerator:

```text
score_poly[j] = sum_i query_scalar[i] * ctxt_i[j] mod q
q = 2^51 - 2^17 + 1
```

The validator's role is large-scale arithmetic checking, not the paper's
performance baseline. It replays the HE arithmetic at large scale and compares
small/random cases against a CPU reference.

## Why PyTorch CUDA?

This checker uses the installed PyTorch CUDA runtime and NVIDIA driver; `nvcc`
is not required.

## What It Validates

- 51-bit Solinas-prime modular arithmetic.
- Signed query scalars with the paper's 23-bit query scale.
- Streaming groups of 4096 vectors, matching the column-method layout.
- Both ciphertext polynomials (`b` and generated/public `a`) as independent
  coefficient streams.
- 100M-vector arithmetic throughput without materializing the 493 GB encrypted
  database.

The synthetic GPU path generates deterministic ciphertext coefficients. This
keeps the arithmetic regression reproducible while avoiding a 493 GB test
fixture. For real-corpus ranking preservation, `he_recall_fbin_gpu.py` streams a
real fp32 `.fbin` corpus such as RAPIDS/cuVS wiki-all and compares full-corpus
fp32 top-10 results against the HE-style fixed-point replay. The validator
supports both dot-product scoring and squared-Euclidean scoring. For
squared-Euclidean, it ranks by the equivalent score
`2*q dot x - ||x||^2`; the omitted query norm is constant within a query. This
score remains a const x ctxt MAC if the encrypted database stores `||x||^2` as an
extra encrypted coordinate. In the ASIC model, this is represented as an
additional stored column rather than as a change to the embedding model itself.

## Commands

The `make -C` commands below are written for the repository root.

Smoke test with CPU cross-check:

```bash
make -C ranking/gpu_he smoke
```

100M-vector run on GPU 1:

```bash
make -C ranking/gpu_he run-100m GPU=1
```

100M-vector ranking validation on GPU 1:

```bash
make -C ranking/gpu_he recall-100m GPU=1
```

Download RAPIDS/cuVS wiki-all:

```bash
bash ranking/gpu_he/download_wiki_all.sh /path/to/wiki_all_88M
```

Run the full RAPIDS/cuVS wiki-all validation. This uses all 10,000 queries in
`queries.fbin`, compares each query against the full 88M-vector base, and uses
the RAPIDS 88M ground-truth neighbors as a metric sanity check:

```bash
make -C ranking/gpu_he wiki-all-10k GPU=1 WIKI_ALL_DIR=/path/to/wiki_all_88M
```

A one-query smoke run is also available for checking paths and GPU memory before
the full run:

```bash
make -C ranking/gpu_he wiki-all-smoke GPU=1 WIKI_ALL_DIR=/path/to/wiki_all_88M
```

The output JSON records vector count, runtime, fixed-point scales, top-10
indices, reciprocal-rank@10 of the fp32 top-1 under the fixed-point ranking,
exact top-10 match rate, official-neighbor agreement, and an int64 accumulator
bound derived from the observed vector/query ranges.

The full 10,000-query JSON includes per-query records and is treated as a
full evidence file. The portable submission summary is
`results/wiki_all_88m_he_recall_10k.summary.json`.

## Recorded 100M Run

On GPU 1 (`NVIDIA GeForce RTX 4090`), the 100M-vector run completed:

| Metric | Value |
|--------|-------|
| Vectors | 100,000,000 |
| Groups | 24,415 |
| Dimension | 768 |
| Polynomials | 2 (`b`, `a`) |
| Coefficient-MACs | 153,600,000,000 |
| Runtime | 31.947 s |
| Throughput | 4.81B coefficient-MAC/s |

The result is stored in `results/gpu_he_100m.json`.

## Recorded 100M Ranking Run

The ranking validator computes plaintext signed dot products and HE modular
`const x ctxt` dot products over the same 100M deterministic fixed-point corpus,
then merges global top-10 rankings across all groups.

| Metric | Value |
|--------|-------|
| Vectors | 100,000,000 |
| Dimension | 768 |
| Queries | 1 |
| Runtime | 19.008 s |
| Paper metric, MRR@10 | 1.000 |
| Top-10 exact match | 1.000 |

The result is stored in `results/gpu_he_recall_100m.json`.

## Recorded RAPIDS/cuVS Wiki-All Run

The full-corpus replay over RAPIDS/cuVS wiki-all completed on the 87,555,327
vector base with all 10,000 queries.

| Metric | Value |
|--------|-------|
| Vectors | 87,555,327 |
| Dimension | 768 |
| Queries | 10,000 |
| Score | squared Euclidean, ranked as `2*q dot x - ||x||^2` |
| Paper metric, MRR@10 | 0.9999 |
| Exact top-10 match | 0.9995 |
| Official-neighbor top-10 overlap | 0.9999 |

The portable summary is stored in
`results/wiki_all_88m_he_recall_10k.summary.json`. The raw per-query JSON and
run log are full evidence files and are ignored by git.
