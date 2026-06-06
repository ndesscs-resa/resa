# GPU HE Result Bundle

Current tracked result files:

- `gpu_he_100m.json`: synthetic 100M arithmetic replay.
- `gpu_he_recall_100m.json`: synthetic 100M one-query ranking replay.
- `gpu_he_recall_1m.json`: small ranking replay.
- `gpu_he_smoke.json`: smoke test.
- `wiki_all_88m_he_recall_10k.summary.json`: portable summary of the full
  RAPIDS/cuVS wiki-all 87,555,327-vector, 10,000-query replay.

Generated local evidence files:

- `wiki_all_88m_he_recall_10k.json`: raw per-query full-run JSON.
- `wiki_all_88m_he_recall_10k.log`: full-run log.

The raw full-run files are useful for audit but are ignored by git because they
are generated and bulky. The summary JSON carries the submission metrics.
