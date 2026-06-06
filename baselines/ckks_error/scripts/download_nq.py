#!/usr/bin/env python3
"""
Download Natural Questions (NQ) dataset from BeIR and encode with msmarco-distilbert-cos-v5.

Corpus: BeIR/nq corpus.jsonl.gz (~2.68M passages from Wikipedia)
Queries: BeIR/nq queries.jsonl.gz (~3,452 test queries)
Model: sentence-transformers/msmarco-distilbert-cos-v5 (768-dim, L2-normalized)

Binary format: [num_rows uint64] [num_cols uint64] [data float64...]
(Same format as download_fullscale.py)

Output (in CSD_DATA_DIR or --data-dir):
    nq_distilbert.corpus.bin   (~15.4 GB, float64)
    nq_distilbert.queries.bin   (~53 KB, float64)

Usage:
    python download_nq.py
    python download_nq.py --max-corpus 100000   # small test
    # Auto-resumes if existing corpus file is found with partial data
    CUDA_VISIBLE_DEVICES=1 python download_nq.py # use specific GPU
"""

import os
import struct
import argparse
import json
import gzip
import time
from pathlib import Path
from typing import List

import numpy as np

# Set HuggingFace cache, respecting HF_HOME if the caller already set it.
if "HF_HOME" not in os.environ:
    _default_hf = Path(os.environ.get("CSD_DATA_DIR", "./data")).parent / ".hf_cache"
    os.environ["HF_HOME"] = str(_default_hf)
if "HF_DATASETS_CACHE" not in os.environ:
    os.environ["HF_DATASETS_CACHE"] = str(Path(os.environ["HF_HOME"]) / "datasets")

DATA_DIR = Path(os.environ.get("CSD_DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

DIM = 768
MODEL_NAME = "sentence-transformers/msmarco-distilbert-cos-v5"


class BinaryArrayWriter:
    """Incrementally write 2D float64 array to binary file.

    Format: [num_rows uint64] [num_cols uint64] [row0 float64*cols] [row1 ...] ...
    """

    def __init__(self, path: Path, num_cols: int):
        self.path = path
        self.num_cols = num_cols
        self.num_rows = 0
        self.file = open(path, 'wb')
        # Reserve the header; it is rewritten with the final row count at close.
        self.file.write(struct.pack('<Q', 0))
        self.file.write(struct.pack('<Q', num_cols))

    @classmethod
    def open_for_append(cls, path: Path, num_cols: int, existing_rows: int):
        """Resume writing to an existing file."""
        obj = cls.__new__(cls)
        obj.path = path
        obj.num_cols = num_cols
        obj.num_rows = existing_rows
        obj.file = open(path, 'r+b')
        obj.file.seek(0, 2)  # Seek to end
        return obj

    def write_batch(self, rows: np.ndarray):
        """Write multiple rows (N x dim)."""
        rows = rows.astype(np.float64)
        assert rows.shape[1] == self.num_cols, f"Expected {self.num_cols} cols, got {rows.shape[1]}"
        self.file.write(rows.tobytes())
        self.num_rows += rows.shape[0]

    def close(self):
        """Finalize file with correct header."""
        self.file.seek(0)
        self.file.write(struct.pack('<Q', self.num_rows))
        self.file.close()

        size_gb = self.path.stat().st_size / 1_000_000_000
        print(f"  Written: {self.path.name}")
        print(f"    Rows: {self.num_rows:,}")
        print(f"    Size: {size_gb:.2f} GB")


def load_nq_corpus(max_corpus: int = 0) -> List[str]:
    """Load NQ corpus texts from BeIR/nq corpus.jsonl.gz.

    Each passage is encoded as "title + text" (matching BEIR convention).
    """
    from huggingface_hub import hf_hub_download

    corpus_path = hf_hub_download(
        "BeIR/nq", "corpus.jsonl.gz",
        repo_type="dataset",
        cache_dir=os.environ.get("HF_HOME"),
    )

    texts = []
    with gzip.open(corpus_path, 'rt') as f:
        for i, line in enumerate(f):
            item = json.loads(line)
            # Combine title and text (standard BEIR convention)
            title = item.get("title", "").strip()
            text = item.get("text", "").strip()
            if title:
                combined = f"{title} {text}"
            else:
                combined = text
            texts.append(combined)

            if max_corpus > 0 and (i + 1) >= max_corpus:
                break

            if (i + 1) % 500000 == 0:
                print(f"      Loaded {i+1:,} texts...")

    print(f"      Total: {len(texts):,} passages loaded")
    return texts


def load_nq_queries() -> List[str]:
    """Load NQ queries from BeIR/nq queries.jsonl.gz."""
    from huggingface_hub import hf_hub_download

    queries_path = hf_hub_download(
        "BeIR/nq", "queries.jsonl.gz",
        repo_type="dataset",
        cache_dir=os.environ.get("HF_HOME"),
    )

    queries = []
    with gzip.open(queries_path, 'rt') as f:
        for line in f:
            item = json.loads(line)
            queries.append(item["text"].strip())

    print(f"      Total: {len(queries):,} queries loaded")
    return queries


def verify_normalization(embs: np.ndarray, label: str, sample_size: int = 100):
    """Verify L2 normalization of embeddings."""
    n = min(sample_size, len(embs))
    indices = np.random.choice(len(embs), n, replace=False)
    norms = np.linalg.norm(embs[indices], axis=1)
    print(f"  L2 norm verification ({label}, {n} samples):")
    print(f"    mean={norms.mean():.8f}  min={norms.min():.8f}  max={norms.max():.8f}")
    assert np.allclose(norms, 1.0, atol=1e-4), f"L2 normalization check failed! norms range: [{norms.min():.6f}, {norms.max():.6f}]"
    print(f"    PASS: all norms ~= 1.0")


def encode_corpus(texts: List[str], output_path: Path, start_row: int = 0,
                  batch_size: int = 512, ds_batch_size: int = 10000):
    """Encode corpus texts and write to binary file.

    Uses sentence-transformers model with normalize_embeddings=True.
    The msmarco-distilbert-cos-v5 model produces L2-normalized output.
    """
    from sentence_transformers import SentenceTransformer
    import torch

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"  Device: {device}")
    if device == "cuda":
        print(f"  GPU: {torch.cuda.get_device_name()}")

    print("  Loading model...")
    model = SentenceTransformer(MODEL_NAME, device=device)

    total = len(texts)

    if start_row == 0:
        writer = BinaryArrayWriter(output_path, DIM)
    else:
        writer = BinaryArrayWriter.open_for_append(output_path, DIM, start_row)
        texts = texts[start_row:]
        print(f"  Resuming from row {start_row:,}")

    t0 = time.time()
    verified = False

    try:
        for batch_start in range(0, len(texts), ds_batch_size):
            batch_end = min(batch_start + ds_batch_size, len(texts))
            batch_texts = texts[batch_start:batch_end]

            embs = model.encode(
                batch_texts,
                normalize_embeddings=True,
                show_progress_bar=False,
                batch_size=batch_size,
            )

            # Verify first batch normalization
            if not verified:
                verify_normalization(embs, "corpus first batch")
                verified = True

            writer.write_batch(embs)

            current_total = start_row + batch_start + len(batch_texts)
            if current_total % 50000 < ds_batch_size:
                elapsed = time.time() - t0
                encoded_so_far = current_total - start_row
                rate = encoded_so_far / elapsed if elapsed > 0 else 0
                remaining = (total - current_total) / rate if rate > 0 else 0
                print(f"      Progress: {current_total:,}/{total:,} "
                      f"({current_total/total*100:.1f}%) "
                      f"| {rate:.0f} vec/s | ETA: {remaining/60:.1f}min",
                      flush=True)
    finally:
        writer.close()

    elapsed = time.time() - t0
    print(f"  Corpus encoding done in {elapsed/60:.1f} min ({elapsed/3600:.2f} h)")

    # Final normalization check on the written file
    print("  Final verification: reading back sample from binary file...")
    verify_binary_file(output_path)


def encode_queries(texts: List[str], output_path: Path, batch_size: int = 256):
    """Encode query texts and write to binary file."""
    from sentence_transformers import SentenceTransformer
    import torch

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"  Device: {device}")

    model = SentenceTransformer(MODEL_NAME, device=device)

    print(f"  Encoding {len(texts):,} queries...")
    embs = model.encode(
        texts,
        normalize_embeddings=True,
        show_progress_bar=True,
        batch_size=batch_size,
    )

    verify_normalization(embs, "queries")

    writer = BinaryArrayWriter(output_path, DIM)
    try:
        writer.write_batch(embs)
    finally:
        writer.close()


def verify_binary_file(path: Path, sample_size: int = 100):
    """Read back a binary file and verify format + normalization."""
    with open(path, 'rb') as f:
        num_rows = struct.unpack('<Q', f.read(8))[0]
        num_cols = struct.unpack('<Q', f.read(8))[0]
        print(f"    Header: {num_rows:,} rows x {num_cols} cols")

        expected_size = 16 + num_rows * num_cols * 8
        actual_size = path.stat().st_size
        assert actual_size == expected_size, \
            f"Size mismatch: expected {expected_size:,}, got {actual_size:,}"
        print(f"    Size check: PASS ({actual_size:,} bytes)")

        # Read random rows and check norms
        indices = sorted(np.random.choice(num_rows, min(sample_size, num_rows), replace=False))
        norms = []
        for idx in indices:
            offset = 16 + idx * num_cols * 8
            f.seek(offset)
            row = np.frombuffer(f.read(num_cols * 8), dtype=np.float64)
            norms.append(np.linalg.norm(row))

        norms = np.array(norms)
        print(f"    L2 norms ({len(norms)} samples): "
              f"mean={norms.mean():.8f}  min={norms.min():.8f}  max={norms.max():.8f}")
        assert np.allclose(norms, 1.0, atol=1e-4), "Normalization check FAILED"
        print(f"    PASS: all norms ~= 1.0")


def main():
    parser = argparse.ArgumentParser(description="Download NQ dataset and encode with distilbert-cos-v5")
    parser.add_argument("--data-dir", type=str, default=None,
                        help="Output data directory (default: CSD_DATA_DIR env or ./data)")
    parser.add_argument("--max-corpus", type=int, default=0,
                        help="Max corpus size (0 = all, ~2.68M)")
    parser.add_argument("--batch-size", type=int, default=512,
                        help="Model encoding batch size (default: 512 for GPU)")
    parser.add_argument("--corpus-only", action="store_true",
                        help="Only encode corpus (skip queries)")
    parser.add_argument("--queries-only", action="store_true",
                        help="Only encode queries (skip corpus)")
    parser.add_argument("--verify-only", action="store_true",
                        help="Only verify existing binary files")
    args = parser.parse_args()

    # Override DATA_DIR if --data-dir is provided
    global DATA_DIR
    if args.data_dir:
        DATA_DIR = Path(args.data_dir)
        DATA_DIR.mkdir(parents=True, exist_ok=True)

    corpus_path = DATA_DIR / "nq_distilbert.corpus.bin"
    queries_path = DATA_DIR / "nq_distilbert.queries.bin"

    print("=" * 60)
    print("NQ Dataset Download + Encode")
    print("=" * 60)
    print(f"Model: {MODEL_NAME}")
    print(f"Dimension: {DIM}")
    print(f"Output dir: {DATA_DIR}")
    print(f"Max corpus: {args.max_corpus if args.max_corpus > 0 else 'all (~2.68M)'}")

    if args.verify_only:
        print("\n[Verify] Corpus:")
        verify_binary_file(corpus_path)
        print("\n[Verify] Queries:")
        verify_binary_file(queries_path)
        return

    # Encode corpus
    if not args.queries_only:
        print("\n[1/2] Loading NQ corpus...")
        corpus_texts = load_nq_corpus(max_corpus=args.max_corpus)

        # Check for resume
        start_row = 0
        if corpus_path.exists():
            with open(corpus_path, 'rb') as f:
                existing_rows = struct.unpack('<Q', f.read(8))[0]
                existing_cols = struct.unpack('<Q', f.read(8))[0]
            if existing_cols == DIM and 0 < existing_rows < len(corpus_texts):
                start_row = existing_rows
                print(f"      Found existing file with {start_row:,} rows. Resuming.")
            elif existing_rows >= len(corpus_texts):
                print(f"      Already complete ({existing_rows:,} rows). Skipping corpus.")
                start_row = -1

        if start_row >= 0:
            print(f"\n      Encoding {len(corpus_texts):,} corpus passages...")
            encode_corpus(corpus_texts, corpus_path, start_row=start_row,
                          batch_size=args.batch_size)

    # Encode queries
    if not args.corpus_only:
        print("\n[2/2] Loading NQ queries...")
        query_texts = load_nq_queries()

        print(f"\n      Encoding {len(query_texts):,} queries...")
        encode_queries(query_texts, queries_path)

    # Final summary
    print("\n" + "=" * 60)
    print("DONE")
    print("=" * 60)
    if corpus_path.exists():
        print(f"  Corpus: {corpus_path}")
        print(f"    Size: {corpus_path.stat().st_size / 1_000_000_000:.2f} GB")
    if queries_path.exists():
        print(f"  Queries: {queries_path}")
        print(f"    Size: {queries_path.stat().st_size / 1_000_000:.2f} MB")

    print(f"\n  Output directory: {DATA_DIR}")
    print(f"  Use with recall_fullscale: --data-dir {DATA_DIR}")


if __name__ == "__main__":
    main()
