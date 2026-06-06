#!/usr/bin/env python3
"""Validate that bundled baseline result files are current and interpretable."""

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"

REQUIRED_FULLSCALE = {
    "recall_fullscale_nq_v3.json",
    "recall_fullscale_msmarco-distilbert_v3.json",
    "recall_fullscale_beir-cohere_v3.json",
}
FORBIDDEN = {
    "recall_fullscale_sift10m_v3.json",
}
EXPECTED_SMALL = {"recall_lattigo.json"}
KNOWN = REQUIRED_FULLSCALE | EXPECTED_SMALL

EXPECTED_META = {
    "recall_fullscale_nq_v3.json": ("nq", "msmarco-distilbert-cos-v5", 2_681_468, None, 3_452, 768),
    "recall_fullscale_msmarco-distilbert_v3.json": ("msmarco-distilbert", "msmarco-distilbert-cos-v5", 8_841_823, None, 10_000, 768),
    "recall_fullscale_beir-cohere_v3.json": ("beir-cohere", "Cohere-embed-english-v3", 8_841_823, None, 10_000, 1024),
}

FULLSCALE_REQUIRED_FIELDS = {
    "implementation",
    "dataset",
    "model",
    "num_vectors",
    "num_queries",
    "dim",
    "he_sample_size",
    "he_max_error",
    "he_mean_error",
    "he_rank_correlation",
    "he_sample_recall@1",
    "he_sample_recall@10",
    "he_sample_mrr@10",
    "paper_metric",
    "paper_mrr@10",
    "score_gap_min",
    "runtime_seconds_total",
    "peak_memory_gb",
    "reproducibility",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        fail(f"could not parse {path.name}: {exc}")


def main() -> None:
    files = {p.name for p in RESULTS.glob("*.json")}
    forbidden = sorted(files & FORBIDDEN)
    unexpected = sorted(files - KNOWN - FORBIDDEN)
    missing = sorted((REQUIRED_FULLSCALE | EXPECTED_SMALL) - files)
    if forbidden:
        fail("forbidden stale/non-text result files present: " + ", ".join(forbidden))
    if unexpected:
        fail("unexpected result files present: " + ", ".join(unexpected))
    if missing:
        fail("expected result files missing: " + ", ".join(missing))

    fullscale_files = REQUIRED_FULLSCALE
    for name in sorted(fullscale_files):
        data = load_json(RESULTS / name)
        missing_fields = sorted(FULLSCALE_REQUIRED_FIELDS - set(data))
        if missing_fields:
            fail(f"{name} missing fields: {', '.join(missing_fields)}")
        exp_dataset, exp_model, exp_vectors, min_vectors, exp_queries, exp_dim = EXPECTED_META[name]
        expected_pairs = {
            "dataset": exp_dataset,
            "model": exp_model,
            "num_queries": exp_queries,
            "dim": exp_dim,
        }
        for field, expected in expected_pairs.items():
            if data[field] != expected:
                fail(f"{name} {field}={data[field]!r}, expected {expected!r}")
        if exp_vectors is not None and data["num_vectors"] != exp_vectors:
            fail(f"{name} num_vectors={data['num_vectors']!r}, expected {exp_vectors!r}")
        if min_vectors is not None and data["num_vectors"] < min_vectors:
            fail(f"{name} num_vectors={data['num_vectors']!r}, expected at least {min_vectors!r}")
        params = data.get("params", {})
        if params.get("N") != 4096 or params.get("logQ") != "51":
            fail(f"{name} has unexpected HE params: {params}")
        if data["he_sample_size"] != 1000:
            fail(f"{name} has he_sample_size={data['he_sample_size']}, expected 1000")
        if data["paper_metric"] != "MRR@10":
            fail(f"{name} paper_metric={data['paper_metric']!r}, expected 'MRR@10'")
        if abs(float(data["paper_mrr@10"]) - float(data["he_sample_mrr@10"])) > 1e-12:
            fail(f"{name} paper_mrr@10 does not match he_sample_mrr@10")
        if data["he_sample_recall@1"] < 1.0 or data["he_sample_recall@10"] < 1.0 or data["paper_mrr@10"] < 1.0:
            fail(f"{name} does not preserve submission MRR@10")
        for field in ["he_max_error", "he_mean_error", "score_gap_min", "runtime_seconds_total", "peak_memory_gb"]:
            if float(data[field]) <= 0:
                fail(f"{name} has non-positive {field}: {data[field]}")
        if float(data["safety_margin"]) < 1.0:
            fail(f"{name} has safety_margin < 1")
        repro = data["reproducibility"]
        for field in ["seed", "go_version", "num_cpu", "lattigo_version"]:
            if field not in repro:
                fail(f"{name} reproducibility metadata missing {field}")
        if repro["lattigo_version"] != "v5.0.7":
            fail(f"{name} has lattigo_version={repro['lattigo_version']!r}, expected 'v5.0.7'")

    small = load_json(RESULTS / "recall_lattigo.json")
    for field in ["num_vectors", "num_queries", "dim", "recall@10", "mrr@10"]:
        if field not in small:
            fail(f"recall_lattigo.json missing {field}")
    if small["recall@10"] < 1.0 or small["mrr@10"] < 1.0:
        fail("recall_lattigo.json does not preserve top-10 ranking")

    print("Baseline result bundle OK")
    print(f"Validated {len(fullscale_files)} full-scale files and 1 synthetic smoke file")


if __name__ == "__main__":
    main()
