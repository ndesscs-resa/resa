#!/usr/bin/env python3
"""
Download full-scale datasets for the recall validation.

Target scales:
- BEIR MS MARCO + Cohere embed-v3: ~8.8M passages (1024-dim)
- MS MARCO passages + msmarco-distilbert-cos-v5: 8,841,823 passages (768-dim)

This script downloads datasets in streaming mode to avoid memory issues,
and saves directly to binary format for Go loading.

Binary format: [num_rows uint64] [num_cols uint64] [data float64...]

Usage:
    python download_fullscale.py --dataset beir-cohere
    python download_fullscale.py --dataset msmarco-distilbert --max-corpus 1000000
"""

import os
import struct
import argparse
from pathlib import Path
import numpy as np

# Set HuggingFace cache, respecting HF_HOME if the caller already set it.
if "HF_HOME" not in os.environ:
    _default_hf = Path(os.environ.get("CSD_DATA_DIR", "./data")).parent / ".hf_cache"
    os.environ["HF_HOME"] = str(_default_hf)
if "HF_DATASETS_CACHE" not in os.environ:
    os.environ["HF_DATASETS_CACHE"] = str(Path(os.environ["HF_HOME"]) / "datasets")

DATA_DIR = Path(os.environ.get("CSD_DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)


def normalize_vector(v: np.ndarray) -> np.ndarray:
    """L2 normalize a single vector."""
    norm = np.linalg.norm(v)
    if norm < 1e-10:
        return v
    return v / norm


class BinaryArrayWriter:
    """Incrementally write 2D float64 array to binary file."""

    def __init__(self, path: Path, num_cols: int):
        self.path = path
        self.num_cols = num_cols
        self.num_rows = 0
        self.file = open(path, 'wb')
        # Reserve the header; it is rewritten with the final row count at close.
        self.file.write(struct.pack('<Q', 0))
        self.file.write(struct.pack('<Q', num_cols))

    def write_row(self, row: np.ndarray):
        """Write a single row."""
        assert len(row) == self.num_cols, f"Expected {self.num_cols} cols, got {len(row)}"
        row = row.astype(np.float64)
        self.file.write(row.tobytes())
        self.num_rows += 1

    def write_batch(self, rows: np.ndarray):
        """Write multiple rows."""
        rows = rows.astype(np.float64)
        for row in rows:
            self.write_row(row)

    def close(self):
        """Finalize file with correct header."""
        # Update num_rows in header
        self.file.seek(0)
        self.file.write(struct.pack('<Q', self.num_rows))
        self.file.close()

        size_gb = self.path.stat().st_size / 1_000_000_000
        print(f"  Written: {self.path.name}")
        print(f"    Rows: {self.num_rows:,}")
        print(f"    Size: {size_gb:.2f} GB")


def download_beir_cohere_fullscale(max_corpus: int = 0, max_queries: int = 10000):
    """
    Download BEIR MS MARCO with Cohere embed-english-v3.

    Full dataset has ~8.8M passages.
    1024 dimensions, L2 normalized.
    """
    print("\n" + "="*60)
    print("Downloading BEIR + Cohere embed-v3 (Full Scale)")
    print("="*60)

    from datasets import load_dataset

    corpus_path = DATA_DIR / "beir_cohere_fullscale.corpus.bin"
    queries_path = DATA_DIR / "beir_cohere_fullscale.queries.bin"

    dim = 1024

    # Download corpus
    print("\n[1/2] Downloading corpus embeddings...")
    print("      This may take 10-30 minutes for full dataset...")

    corpus_ds = load_dataset(
        "Cohere/beir-embed-english-v3",
        "msmarco-corpus",
        split="train",
        streaming=True
    )

    writer = BinaryArrayWriter(corpus_path, dim)

    try:
        for i, item in enumerate(corpus_ds):
            emb = np.array(item["emb"], dtype=np.float64)
            emb = normalize_vector(emb)
            writer.write_row(emb)

            if (i + 1) % 100000 == 0:
                print(f"      Progress: {i+1:,} embeddings loaded...")

            if max_corpus > 0 and (i + 1) >= max_corpus:
                print(f"      Reached max_corpus limit ({max_corpus:,})")
                break
    finally:
        writer.close()

    actual_corpus_size = writer.num_rows

    # Download queries
    print("\n[2/2] Downloading query embeddings...")

    queries_ds = load_dataset(
        "Cohere/beir-embed-english-v3",
        "msmarco-queries",
        split="train",
        streaming=True
    )

    writer = BinaryArrayWriter(queries_path, dim)

    try:
        for i, item in enumerate(queries_ds):
            emb = np.array(item["emb"], dtype=np.float64)
            emb = normalize_vector(emb)
            writer.write_row(emb)

            if max_queries > 0 and (i + 1) >= max_queries:
                break
    finally:
        writer.close()

    print(f"\n[DONE] BEIR + Cohere full-scale download complete")
    print(f"  Corpus: {actual_corpus_size:,} vectors ({dim}-dim)")
    print(f"  Queries: {writer.num_rows:,}")
    print(f"  Files:")
    print(f"    {corpus_path}")
    print(f"    {queries_path}")

    return actual_corpus_size, writer.num_rows


def download_msmarco_distilbert_fullscale(max_corpus: int = 0, max_queries: int = 10000):
    """
    Download MS MARCO passages and encode with msmarco-distilbert-cos-v5.

    Uses sentence-transformers/msmarco-corpus (8,841,823 pre-deduplicated passages).
    768 dimensions, L2 normalized (cos version).

    Supports resume: checks existing file row count and skips already-encoded rows.
    """
    print("\n" + "="*60)
    print("Downloading MS MARCO + msmarco-distilbert-cos-v5 (Full Scale)")
    print("="*60)

    from datasets import load_dataset
    from sentence_transformers import SentenceTransformer
    import torch
    import time

    corpus_path = DATA_DIR / "msmarco_distilbert_fullscale.corpus.bin"
    queries_path = DATA_DIR / "msmarco_distilbert_fullscale.queries.bin"

    dim = 768
    batch_size = 8  # Small batch is faster on CPU (146/s vs 51/s with 512)

    # Check GPU
    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    print(f"  Device: {device}")

    # Load model
    print("  Loading sentence-transformers model...")
    model = SentenceTransformer("sentence-transformers/msmarco-distilbert-cos-v5", device=device)

    # Load MS MARCO corpus (clean, pre-deduplicated, 8.8M passages)
    print("\n[1/2] Loading and encoding corpus passages...")
    print("      Source: sentence-transformers/msmarco-corpus (passage split)")
    print("      Total: 8,841,823 passages")

    corpus_ds = load_dataset(
        "sentence-transformers/msmarco-corpus",
        "passage",
        split="train",
    )

    total_passages = len(corpus_ds)
    if max_corpus > 0:
        total_passages = min(total_passages, max_corpus)
    print(f"      Target: {total_passages:,} passages")

    # Check for resume
    start_row = 0
    if corpus_path.exists():
        with open(corpus_path, 'rb') as f:
            existing_rows = struct.unpack('<Q', f.read(8))[0]
            existing_cols = struct.unpack('<Q', f.read(8))[0]
        if existing_cols == dim and existing_rows > 0 and existing_rows < total_passages:
            start_row = existing_rows
            print(f"      Resuming from row {start_row:,} (found existing file)")
        elif existing_rows >= total_passages:
            print(f"      Already complete ({existing_rows:,} rows). Skipping corpus.")
            start_row = -1  # Signal skip

    if start_row >= 0:
        if start_row == 0:
            writer = BinaryArrayWriter(corpus_path, dim)
        else:
            # Open for append: reopen file, seek to end
            writer = BinaryArrayWriter.__new__(BinaryArrayWriter)
            writer.path = corpus_path
            writer.num_cols = dim
            writer.num_rows = start_row
            writer.file = open(corpus_path, 'r+b')
            writer.file.seek(0, 2)  # Seek to end

        t0 = time.time()

        # Select subset if needed, then skip already-encoded rows
        subset = corpus_ds.select(range(start_row, total_passages))
        encode_batch_size = batch_size  # Model encoding batch (8 is optimal on CPU)
        ds_batch_size = 10000          # Dataset iteration batch (Arrow-level, fast)

        try:
            for batch in subset.iter(batch_size=ds_batch_size):
                texts = batch["text"]
                embs = model.encode(
                    texts,
                    normalize_embeddings=True,
                    show_progress_bar=False,
                    batch_size=encode_batch_size,
                )
                embs_f64 = embs.astype(np.float64)
                writer.file.write(embs_f64.tobytes())
                writer.num_rows += len(embs)

                if writer.num_rows % 50000 < ds_batch_size:
                    elapsed = time.time() - t0
                    rate = (writer.num_rows - start_row) / elapsed
                    remaining = (total_passages - writer.num_rows) / rate if rate > 0 else 0
                    print(f"      Progress: {writer.num_rows:,}/{total_passages:,} "
                          f"({writer.num_rows/total_passages*100:.1f}%) "
                          f"| {rate:.0f} vec/s | ETA: {remaining/3600:.1f}h",
                          flush=True)
        finally:
            writer.close()

        elapsed = time.time() - t0
        print(f"      Corpus encoding done in {elapsed/3600:.1f}h")
        print(f"      Final: {writer.num_rows:,} vectors")

    # Encode queries from MS MARCO dev queries
    print("\n[2/2] Encoding queries...")

    queries_ds = load_dataset(
        "sentence-transformers/msmarco-corpus",
        "query",
        split="train",
    )

    n_queries = min(len(queries_ds), max_queries)
    print(f"      Encoding {n_queries:,} queries...")

    query_texts = queries_ds.select(range(n_queries))["text"]

    embs = model.encode(query_texts, normalize_embeddings=True, show_progress_bar=True, batch_size=256)

    writer = BinaryArrayWriter(queries_path, dim)
    try:
        embs_f64 = embs.astype(np.float64)
        writer.file.write(embs_f64.tobytes())
        writer.num_rows = len(embs)
    finally:
        writer.close()

    print(f"\n[DONE] MS MARCO + distilbert full-scale download complete")
    print(f"  Corpus: {total_passages:,} vectors ({dim}-dim)")
    print(f"  Queries: {n_queries:,}")
    print(f"  Files:")
    print(f"    {corpus_path}")
    print(f"    {queries_path}")

    return total_passages, n_queries


def main():
    parser = argparse.ArgumentParser(description="Download full-scale datasets")
    parser.add_argument("--data-dir", type=str, default=None,
                       help="Output data directory (default: CSD_DATA_DIR env or ./data)")
    parser.add_argument("--dataset", type=str, required=True,
                       choices=["beir-cohere", "msmarco-distilbert"],
                       help="Dataset to download")
    parser.add_argument("--max-corpus", type=int, default=0,
                       help="Max corpus size (0 = all)")
    parser.add_argument("--max-queries", type=int, default=10000,
                       help="Max queries")

    args = parser.parse_args()

    # Override DATA_DIR if --data-dir is provided
    global DATA_DIR
    if args.data_dir:
        DATA_DIR = Path(args.data_dir)
        DATA_DIR.mkdir(parents=True, exist_ok=True)

    print("="*60)
    print("Full-Scale Dataset Download")
    print("="*60)
    print(f"Dataset: {args.dataset}")
    print(f"Max corpus: {args.max_corpus if args.max_corpus > 0 else 'unlimited'}")
    print(f"Max queries: {args.max_queries}")
    print(f"Output dir: {DATA_DIR}")

    if args.dataset == "beir-cohere":
        download_beir_cohere_fullscale(args.max_corpus, args.max_queries)
    elif args.dataset == "msmarco-distilbert":
        download_msmarco_distilbert_fullscale(args.max_corpus, args.max_queries)


if __name__ == "__main__":
    main()
