#!/usr/bin/env python3
"""
Full-corpus HE-style ranking validation on real .fbin datasets.

Input format follows BigANN/cuVS fbin:
  uint32 num_vectors, uint32 dim, then row-major float32 vectors.

For each query, the script scans the full fp32 database on GPU and compares:
  - fp32 plaintext dot-product ranking
  - fixed-point HE-style const x ctxt ranking

The submission ranking metric is MRR@10 against the plaintext ranking.

The HE-style score quantizes database values at 2^26 and query values at 2^23,
matching the paper's asymmetric scale split. The integer accumulator fits in
signed int64 for normalized embedding dot products and is decoded as a signed
score at product scale 2^49.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import torch


SCALE_DB = 1 << 26
SCALE_QUERY = 1 << 23
SCALE_PRODUCT = SCALE_DB * SCALE_QUERY


def read_fbin_header(path: Path) -> Tuple[int, int]:
    with path.open("rb") as f:
        rows, dim = struct.unpack("<II", f.read(8))
    return rows, dim


def open_fbin_memmap(path: Path, limit: int = 0) -> Tuple[np.memmap, int, int]:
    rows, dim = read_fbin_header(path)
    if limit > 0:
        rows = min(rows, limit)
    expected_bytes = 8 + rows * dim * 4
    actual_bytes = path.stat().st_size
    if actual_bytes < expected_bytes:
        raise RuntimeError(
            f"{path} is incomplete for {rows}x{dim}: need {expected_bytes} bytes, have {actual_bytes}"
        )
    arr = np.memmap(path, dtype=np.float32, mode="r", offset=8, shape=(rows, dim))
    return arr, rows, dim


def open_ibin_memmap(path: Path, limit: int = 0) -> Tuple[np.memmap, int, int]:
    rows, dim = read_fbin_header(path)
    if limit > 0:
        rows = min(rows, limit)
    expected_bytes = 8 + rows * dim * 4
    actual_bytes = path.stat().st_size
    if actual_bytes < expected_bytes:
        raise RuntimeError(
            f"{path} is incomplete for {rows}x{dim}: need {expected_bytes} bytes, have {actual_bytes}"
        )
    arr = np.memmap(path, dtype=np.int32, mode="r", offset=8, shape=(rows, dim))
    return arr, rows, dim


def merge_topk(
    global_scores: torch.Tensor,
    global_indices: torch.Tensor,
    local_scores: torch.Tensor,
    local_indices: torch.Tensor,
    k: int,
) -> Tuple[torch.Tensor, torch.Tensor]:
    scores = torch.cat([global_scores, local_scores])
    indices = torch.cat([global_indices, local_indices])
    vals, pos = torch.topk(scores, k=min(k, scores.numel()), largest=True, sorted=True)
    return vals, indices[pos]


def merge_topk_batched(
    global_scores: torch.Tensor,
    global_indices: torch.Tensor,
    local_scores: torch.Tensor,
    local_indices: torch.Tensor,
    k: int,
) -> Tuple[torch.Tensor, torch.Tensor]:
    scores = torch.cat([global_scores, local_scores], dim=0)
    indices = torch.cat([global_indices, local_indices], dim=0)
    vals, pos = torch.topk(scores, k=min(k, scores.shape[0]), dim=0, largest=True, sorted=True)
    return vals, torch.gather(indices, 0, pos)


def quantize_to_int64(x: torch.Tensor, scale: int) -> torch.Tensor:
    return torch.round(x * scale).to(torch.int64)


def prepare_queries(queries: torch.Tensor, metric: str) -> torch.Tensor:
    if metric == "dot":
        return queries
    if metric == "sqeuclidean":
        return 2.0 * queries
    raise RuntimeError(f"unsupported metric: {metric}")


def score_chunk(
    x: torch.Tensor,
    x_int: torch.Tensor,
    q_float: torch.Tensor,
    q_int: torch.Tensor,
    metric: str,
) -> Tuple[torch.Tensor, torch.Tensor]:
    plain_scores = x @ q_float.T
    he_acc = torch.sum(x_int[:, None, :] * q_int[None, :, :], dim=2, dtype=torch.int64)
    he_scores = he_acc.to(torch.float64) / float(SCALE_PRODUCT)
    if metric == "sqeuclidean":
        x_norm = torch.sum(x * x, dim=1)
        x_norm_int = quantize_to_int64(x_norm, SCALE_DB)
        norm_plain = x_norm[:, None]
        norm_he = (x_norm_int.to(torch.float64) * float(SCALE_QUERY)) / float(SCALE_PRODUCT)
        plain_scores = plain_scores - norm_plain
        he_scores = he_scores - norm_he[:, None]
    return plain_scores, he_scores


def finalize_query_result(
    qid: int,
    plain_scores: torch.Tensor,
    plain_indices: torch.Tensor,
    he_scores: torch.Tensor,
    he_indices: torch.Tensor,
    max_abs_base_seen: float,
    max_abs_query: float,
    dim: int,
    official_neighbors: Optional[np.ndarray] = None,
) -> Dict[str, object]:
    plain_top = [int(v) for v in plain_indices.cpu().tolist()]
    he_top = [int(v) for v in he_indices.cpu().tolist()]
    plain_top1 = plain_top[0]
    rr = 0.0
    he_rank = None
    for rank, idx in enumerate(he_top[:10], start=1):
        if idx == plain_top1:
            he_rank = rank
            rr = 1.0 / rank
            break

    result = {
        "query_id": qid,
        "plain_top10_indices": plain_top[:10],
        "he_top10_indices": he_top[:10],
        "plain_top10_scores": [float(v) for v in plain_scores[:10].cpu().tolist()],
        "he_top10_scores": [float(v) for v in he_scores[:10].cpu().tolist()],
        "plain_top1_he_rank": he_rank,
        "reciprocal_rank@10": rr,
        "top10_exact_match": plain_top[:10] == he_top[:10],
        "max_abs_base_seen": max_abs_base_seen,
        "max_abs_query": max_abs_query,
        "int64_accumulator_bound": max_abs_base_seen * SCALE_DB * max_abs_query * SCALE_QUERY * dim,
    }
    if official_neighbors is not None:
        official_top = [int(v) for v in official_neighbors[:10].tolist()]
        result.update(
            {
                "official_top10_indices": official_top,
                "plain_top1_matches_official": plain_top[0] == official_top[0],
                "he_top1_matches_official": he_top[0] == official_top[0],
                "plain_official_top10_overlap": len(set(plain_top[:10]) & set(official_top)) / 10.0,
                "he_official_top10_overlap": len(set(he_top[:10]) & set(official_top)) / 10.0,
                "plain_official_top10_exact_match": plain_top[:10] == official_top,
                "he_official_top10_exact_match": he_top[:10] == official_top,
            }
        )
    return result


def scan_all_queries(
    base: np.memmap,
    queries_np: np.ndarray,
    args: argparse.Namespace,
    device: torch.device,
    official_neighbors: Optional[np.ndarray] = None,
) -> List[Dict[str, object]]:
    rows, dim = base.shape
    num_queries = queries_np.shape[0]
    k = args.k
    query_batch = max(1, args.query_batch)

    q_float_all = torch.from_numpy(np.array(queries_np, dtype=np.float32, copy=True)).to(device=device)
    q_float_all = prepare_queries(q_float_all, args.metric)
    q_int_all = quantize_to_int64(q_float_all, SCALE_QUERY)
    q_abs_max_all = torch.max(torch.abs(q_float_all), dim=1).values
    q_abs_max_global = float(torch.max(q_abs_max_all).item())

    plain_top_scores = torch.full((k, num_queries), -float("inf"), device=device, dtype=torch.float32)
    plain_top_indices = torch.full((k, num_queries), -1, device=device, dtype=torch.int64)
    he_top_scores = torch.full((k, num_queries), -float("inf"), device=device, dtype=torch.float64)
    he_top_indices = torch.full((k, num_queries), -1, device=device, dtype=torch.int64)

    max_abs_base_seen = 0.0
    start = time.time()
    chunks = math.ceil(rows / args.batch)
    for chunk_id, start_row in enumerate(range(0, rows, args.batch)):
        end_row = min(start_row + args.batch, rows)
        host = np.array(base[start_row:end_row], dtype=np.float32, copy=True)
        x = torch.from_numpy(host).to(device=device, non_blocking=True)
        x_int = quantize_to_int64(x, SCALE_DB)

        chunk_abs_max = float(torch.max(torch.abs(x)).item())
        max_abs_base_seen = max(max_abs_base_seen, chunk_abs_max)
        acc_bound = max_abs_base_seen * SCALE_DB * q_abs_max_global * SCALE_QUERY * dim
        if acc_bound >= (2**63 - 1):
            raise RuntimeError(
                "int64 accumulator bound exceeded: "
                f"max_abs_base={max_abs_base_seen}, max_abs_query={q_abs_max_global}, "
                f"dim={dim}, bound={acc_bound:.3e}"
            )

        local_k = min(k, end_row - start_row)
        query_batches = math.ceil(num_queries / query_batch)
        for q_batch_id, q_start in enumerate(range(0, num_queries, query_batch)):
            q_end = min(q_start + query_batch, num_queries)
            q_float = q_float_all[q_start:q_end]
            q_int = q_int_all[q_start:q_end]

            plain_scores, he_scores = score_chunk(x, x_int, q_float, q_int, args.metric)

            p_vals, p_pos = torch.topk(plain_scores, k=local_k, dim=0, largest=True, sorted=True)
            h_vals, h_pos = torch.topk(he_scores, k=local_k, dim=0, largest=True, sorted=True)
            p_idx = p_pos.to(torch.int64) + start_row
            h_idx = h_pos.to(torch.int64) + start_row

            plain_top_scores[:, q_start:q_end], plain_top_indices[:, q_start:q_end] = merge_topk_batched(
                plain_top_scores[:, q_start:q_end],
                plain_top_indices[:, q_start:q_end],
                p_vals,
                p_idx,
                k,
            )
            he_top_scores[:, q_start:q_end], he_top_indices[:, q_start:q_end] = merge_topk_batched(
                he_top_scores[:, q_start:q_end],
                he_top_indices[:, q_start:q_end],
                h_vals,
                h_idx,
                k,
            )

            del plain_scores, he_scores

            if args.query_progress_every and (
                (q_batch_id + 1) % args.query_progress_every == 0
                or q_batch_id + 1 == query_batches
            ):
                if device.type == "cuda":
                    torch.cuda.synchronize()
                elapsed = time.time() - start
                print(
                    f"chunk={chunk_id + 1}/{chunks} query_batches={q_batch_id + 1}/{query_batches} "
                    f"queries_done={q_end}/{num_queries} elapsed={elapsed:.2f}s",
                    flush=True,
                )

        if args.progress_every and ((chunk_id + 1) % args.progress_every == 0 or chunk_id + 1 == chunks):
            if device.type == "cuda":
                torch.cuda.synchronize()
            elapsed = time.time() - start
            print(
                f"chunks={chunk_id + 1}/{chunks} vectors={end_row}/{rows} "
                f"queries={num_queries} query_batch={query_batch} elapsed={elapsed:.2f}s",
                flush=True,
            )

        del x, x_int

    if device.type == "cuda":
        torch.cuda.synchronize()

    q_abs_cpu = q_abs_max_all.cpu().tolist()
    return [
        finalize_query_result(
            qid=qid,
            plain_scores=plain_top_scores[:, qid],
            plain_indices=plain_top_indices[:, qid],
            he_scores=he_top_scores[:, qid],
            he_indices=he_top_indices[:, qid],
            max_abs_base_seen=max_abs_base_seen,
            max_abs_query=float(q_abs_cpu[qid]),
            dim=dim,
            official_neighbors=official_neighbors[qid] if official_neighbors is not None else None,
        )
        for qid in range(num_queries)
    ]


def scan_one_query(
    base: np.memmap,
    query: np.ndarray,
    qid: int,
    args: argparse.Namespace,
    device: torch.device,
) -> Dict[str, object]:
    rows, dim = base.shape
    k = args.k
    q_float = torch.from_numpy(query.astype(np.float32, copy=False)).to(device=device)
    q_float = prepare_queries(q_float, args.metric)
    q_int = quantize_to_int64(q_float, SCALE_QUERY)

    q_abs_max = float(torch.max(torch.abs(q_float)).item())
    plain_top_scores = torch.empty(0, device=device, dtype=torch.float32)
    plain_top_indices = torch.empty(0, device=device, dtype=torch.int64)
    he_top_scores = torch.empty(0, device=device, dtype=torch.float64)
    he_top_indices = torch.empty(0, device=device, dtype=torch.int64)
    max_abs_base_seen = 0.0

    start = time.time()
    chunks = math.ceil(rows / args.batch)
    for chunk_id, start_row in enumerate(range(0, rows, args.batch)):
        end_row = min(start_row + args.batch, rows)
        host = np.asarray(base[start_row:end_row], dtype=np.float32)
        x = torch.from_numpy(host).to(device=device, non_blocking=True)
        chunk_abs_max = float(torch.max(torch.abs(x)).item())
        max_abs_base_seen = max(max_abs_base_seen, chunk_abs_max)
        acc_bound = max_abs_base_seen * SCALE_DB * q_abs_max * SCALE_QUERY * dim
        if acc_bound >= (2**63 - 1):
            raise RuntimeError(
                "int64 accumulator bound exceeded: "
                f"max_abs_base={max_abs_base_seen}, max_abs_query={q_abs_max}, "
                f"dim={dim}, bound={acc_bound:.3e}"
            )

        x_int = quantize_to_int64(x, SCALE_DB)
        plain_scores, he_scores_batched = score_chunk(
            x, x_int, q_float.view(1, -1), q_int.view(1, -1), args.metric
        )
        plain_scores = plain_scores[:, 0]
        he_scores = he_scores_batched[:, 0]

        local_k = min(k, end_row - start_row)
        p_vals, p_pos = torch.topk(plain_scores, k=local_k, largest=True, sorted=True)
        h_vals, h_pos = torch.topk(he_scores, k=local_k, largest=True, sorted=True)
        base_idx = torch.tensor(start_row, device=device, dtype=torch.int64)
        p_idx = p_pos.to(torch.int64) + base_idx
        h_idx = h_pos.to(torch.int64) + base_idx

        plain_top_scores, plain_top_indices = merge_topk(
            plain_top_scores, plain_top_indices, p_vals, p_idx, k
        )
        he_top_scores, he_top_indices = merge_topk(he_top_scores, he_top_indices, h_vals, h_idx, k)

        if args.progress_every and ((chunk_id + 1) % args.progress_every == 0 or chunk_id + 1 == chunks):
            if device.type == "cuda":
                torch.cuda.synchronize()
            elapsed = time.time() - start
            print(
                f"query={qid} chunks={chunk_id + 1}/{chunks} "
                f"vectors={end_row}/{rows} elapsed={elapsed:.2f}s",
                flush=True,
            )

        del x, plain_scores, x_int, he_scores_batched, he_scores

    plain_top = [int(v) for v in plain_top_indices.cpu().tolist()]
    he_top = [int(v) for v in he_top_indices.cpu().tolist()]
    plain_top1 = plain_top[0]
    rr = 0.0
    he_rank = None
    for rank, idx in enumerate(he_top[:10], start=1):
        if idx == plain_top1:
            he_rank = rank
            rr = 1.0 / rank
            break

    return {
        "query_id": qid,
        "plain_top10_indices": plain_top[:10],
        "he_top10_indices": he_top[:10],
        "plain_top10_scores": [float(v) for v in plain_top_scores[:10].cpu().tolist()],
        "he_top10_scores": [float(v) for v in he_top_scores[:10].cpu().tolist()],
        "plain_top1_he_rank": he_rank,
        "reciprocal_rank@10": rr,
        "top10_exact_match": plain_top[:10] == he_top[:10],
        "max_abs_base_seen": max_abs_base_seen,
        "max_abs_query": q_abs_max,
        "int64_accumulator_bound": max_abs_base_seen * SCALE_DB * q_abs_max * SCALE_QUERY * dim,
    }


def run(args: argparse.Namespace) -> Dict[str, object]:
    device = torch.device(args.device)
    if device.type == "cuda":
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA requested but unavailable")
        torch.cuda.set_device(device)
        torch.cuda.empty_cache()
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False

    base, rows, dim = open_fbin_memmap(Path(args.base), args.limit)
    queries, q_rows, q_dim = open_fbin_memmap(Path(args.queries), args.queries_limit)
    if dim != q_dim:
        raise RuntimeError(f"dimension mismatch: base dim={dim}, query dim={q_dim}")

    num_queries = min(args.num_queries, q_rows)
    if num_queries <= 0:
        num_queries = q_rows

    official_neighbors = None
    if args.groundtruth_neighbors:
        gt, gt_rows, gt_k = open_ibin_memmap(Path(args.groundtruth_neighbors), num_queries)
        if gt_rows < num_queries:
            raise RuntimeError(
                f"groundtruth has {gt_rows} queries, but validation needs {num_queries}"
            )
        if gt_k < args.k:
            raise RuntimeError(f"groundtruth has k={gt_k}, but validation needs k={args.k}")
        official_neighbors = np.asarray(gt[:num_queries, : args.k], dtype=np.int64)

    if device.type == "cuda":
        torch.cuda.synchronize()
    start = time.time()
    per_query = scan_all_queries(
        base, np.asarray(queries[:num_queries]), args, device, official_neighbors
    )
    if device.type == "cuda":
        torch.cuda.synchronize()
    elapsed = time.time() - start

    rr = [q["reciprocal_rank@10"] for q in per_query]
    mrr10 = sum(rr) / len(rr)
    r1 = [1.0 if q["plain_top1_he_rank"] == 1 else 0.0 for q in per_query]
    r10 = [1.0 if q["plain_top1_he_rank"] is not None else 0.0 for q in per_query]
    exact = [1.0 if q["top10_exact_match"] else 0.0 for q in per_query]
    official_summary = {}
    if official_neighbors is not None:
        official_summary = {
            "groundtruth_neighbors": str(Path(args.groundtruth_neighbors)),
            "plain_top1_matches_official_rate": sum(
                1.0 if q["plain_top1_matches_official"] else 0.0 for q in per_query
            )
            / len(per_query),
            "he_top1_matches_official_rate": sum(
                1.0 if q["he_top1_matches_official"] else 0.0 for q in per_query
            )
            / len(per_query),
            "plain_official_top10_overlap_mean": sum(
                q["plain_official_top10_overlap"] for q in per_query
            )
            / len(per_query),
            "he_official_top10_overlap_mean": sum(
                q["he_official_top10_overlap"] for q in per_query
            )
            / len(per_query),
            "plain_official_top10_exact_match_rate": sum(
                1.0 if q["plain_official_top10_exact_match"] else 0.0 for q in per_query
            )
            / len(per_query),
            "he_official_top10_exact_match_rate": sum(
                1.0 if q["he_official_top10_exact_match"] else 0.0 for q in per_query
            )
            / len(per_query),
        }

    result = {
        "implementation": "PyTorch CUDA fbin full-corpus HE-style ranking validator",
        "base": str(Path(args.base)),
        "queries": str(Path(args.queries)),
        "device": str(device),
        "torch_version": torch.__version__,
        "gpu_name": torch.cuda.get_device_name(device) if device.type == "cuda" else "cpu",
        "vectors": rows,
        "embedding_dim": dim,
        "queries_used": num_queries,
        "batch": args.batch,
        "query_batch": args.query_batch,
        "metric": args.metric,
        "scale_db": SCALE_DB,
        "scale_query": SCALE_QUERY,
        "scale_product": SCALE_PRODUCT,
        "int64_max": 2**63 - 1,
        "runtime_seconds": elapsed,
        "vectors_per_second_per_query": rows * num_queries / elapsed if elapsed > 0 else None,
        "he_recall@1": sum(r1) / len(r1),
        "he_recall@10": sum(r10) / len(r10),
        "he_mrr@10": mrr10,
        "paper_metric": "MRR@10",
        "paper_mrr@10": mrr10,
        "top10_exact_match_rate": sum(exact) / len(exact),
        "per_query": per_query,
        "notes": [
            "Plaintext ranking uses fp32 scoring with TF32 disabled.",
            "For sqeuclidean, ranking uses the equivalent score 2*q dot x - ||x||^2; the query norm is omitted because it is constant within a query.",
            "HE-style ranking uses asymmetric fixed-point quantization at 2^26 and 2^23.",
            "The full run scans the base corpus once per chunk and evaluates all selected queries in query batches.",
            "This validates fixed-point ranking preservation for the actual fp32 fbin corpus/query set.",
            "If metric-matched groundtruth neighbors are supplied, official-neighbor agreement is recorded as an auxiliary field.",
        ],
    }
    result.update(official_summary)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--queries", required=True)
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--batch", type=int, default=262144)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--queries-limit", type=int, default=0)
    parser.add_argument("--num-queries", type=int, default=0)
    parser.add_argument("--query-batch", type=int, default=4)
    parser.add_argument("--k", type=int, default=10)
    parser.add_argument("--progress-every", type=int, default=0)
    parser.add_argument("--query-progress-every", type=int, default=0)
    parser.add_argument("--groundtruth-neighbors", default="")
    parser.add_argument("--metric", choices=["dot", "sqeuclidean"], default="dot")
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    result = run(args)
    print(json.dumps(result, indent=2))
    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(out.suffix + ".tmp")
        tmp.write_text(json.dumps(result, indent=2) + "\n")
        os.replace(tmp, out)


if __name__ == "__main__":
    main()
