# CKKS Error and Ranking Validation

## Summary

This directory contains the Lattigo-based checks used to support the
Middleware paper's CKKS numerical-error claim. The important artifact outputs
are the bundled `results/recall_fullscale_*_v3.json` files: each one performs a
full-corpus plaintext ranking pass and then evaluates CKKS numerical behavior on
the selected validation candidates.

The code here is a numerical-fidelity artifact rather than a 100M-vector latency
baseline. It verifies the HE parameter point, measures score error, and confirms
that the paper metric `MRR@10` is preserved for the included retrieval
workloads.

## Included Code

| Path | Role |
|---|---|
| `cmd/recall_benchmark/` | small synthetic CKKS smoke run |
| `cmd/recall_fullscale/` | full-corpus plaintext ranking plus HE candidate validation |
| `pkg/he/` | Lattigo CKKS parameter setup and evaluator helpers |
| `pkg/database/` | synthetic database encoder used by the smoke run |
| `pkg/benchmark/` | timing and memory helpers |
| `scripts/verify_results.py` | structural validator for bundled JSON results |

## Quick Check

Run from `baselines/ckks_error/`:

```bash
make verify-results
```

The validator checks that the expected result JSON files are present, rejects
unexpected result files, and verifies reproducibility metadata, HE parameter
fields, error fields, and the submission `MRR@10` metric.

## Rebuild Commands

Build the two artifact binaries:

```bash
make build
```

Generate the synthetic smoke result:

```bash
make recall-benchmark DB_SIZE=10000 EMBED_DIM=768 NUM_QUERIES=100
```

Run a full-scale dataset validation after preparing the corpus/query binary
files:

```bash
./bin/recall_fullscale \
  --dataset msmarco-distilbert \
  --queries 10000 \
  --data-dir /path/to/recall-benchmark/data \
  --batch 5000 \
  --output results/recall_fullscale_msmarco-distilbert_v3.json
```

The runner streams the corpus once, maintains per-query top-k heaps for exact
plaintext ranking, and then runs CKKS validation over the chosen candidate set.
Use `--he-mode boundary --he-boundary-k 20` to validate the full-corpus top-k
boundary candidates instead of the bundled sample-candidate mode.

## Bundled Result Files

| File | Role |
|---|---|
| `results/recall_lattigo.json` | small synthetic smoke result |
| `results/recall_fullscale_nq_v3.json` | NQ full-corpus ranking plus HE validation |
| `results/recall_fullscale_msmarco-distilbert_v3.json` | MS MARCO/distilbert full-corpus ranking plus HE validation |
| `results/recall_fullscale_beir-cohere_v3.json` | BEIR/Cohere full-corpus ranking plus HE validation |

The full-scale files report exact plaintext ranking over the full corpus and HE
numerical validation over an evaluated candidate set. The submission metric is
`paper_mrr@10`, copied from `he_sample_mrr@10` in the bundled v3 results.
Recall@1 and Recall@10 are retained as auxiliary fields.

## HE Parameters

- Ring degree: `N = 4096`
- Modulus: single 51-bit CKKS prime
- SIMD slots: `N/2 = 2048`
- Operation checked: public scalar times ciphertext accumulation

The CSD hardware uses a custom Solinas prime and continuous 51-bit coefficient
packing, while Lattigo uses its own NTT-friendly prime selection. This directory
checks CKKS numerical fidelity; the Resa storage-layout evidence lives under
`asic/` and `storage_validation/`.

## Output Fields

The full-scale JSON files include:

- dataset/model/vector/query dimensions
- CKKS parameter fields
- HE validation mode and candidate count
- max/mean/std score error
- full-corpus score-gap fields
- `paper_mrr@10`
- runtime, memory, and reproducibility metadata

## References

- [Lattigo](https://github.com/tuneinsight/lattigo)
