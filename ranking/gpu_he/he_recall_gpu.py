#!/usr/bin/env python3
"""
100M-scale HE arithmetic ranking validation.

This experiment generates deterministic signed fixed-point embeddings, scans the
full corpus on GPU, and compares:

  1. plaintext signed inner products
  2. the same inner products computed as const x ctxt modular arithmetic over
     q = 2^51 - 2^17 + 1 and decoded back to signed scores

Its submission metric is MRR@10 of the plaintext top result under the HE
ranking. The scope is arithmetic/ranking validation on a deterministic
fixed-point corpus.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from pathlib import Path
from typing import Dict, Tuple

import torch

from he_constctxt_gpu import Q, VECTORS_PER_GROUP, constctxt_reduce_gpu


EMBED_BITS = 8
QUERY_BITS_RECALL = 16


def make_signed_query(dim: int, seed: int, device: torch.device) -> torch.Tensor:
    gen = torch.Generator(device=device)
    gen.manual_seed(seed)
    return torch.randint(
        -(1 << (QUERY_BITS_RECALL - 1)),
        1 << (QUERY_BITS_RECALL - 1),
        (dim,),
        device=device,
        dtype=torch.int64,
        generator=gen,
    )


def make_signed_embeddings(dim: int, count: int, seed: int, device: torch.device) -> torch.Tensor:
    gen = torch.Generator(device=device)
    gen.manual_seed(seed)
    return torch.randint(
        -(1 << (EMBED_BITS - 1)),
        1 << (EMBED_BITS - 1),
        (dim, count),
        device=device,
        dtype=torch.int64,
        generator=gen,
    )


def decode_signed_mod_q(x: torch.Tensor) -> torch.Tensor:
    return torch.where(x > Q // 2, x - Q, x)


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


def run_one_query(args: argparse.Namespace, query_id: int, query: torch.Tensor) -> Dict[str, object]:
    device = query.device
    groups = math.ceil(args.vectors / VECTORS_PER_GROUP)
    k = args.k

    plain_top_scores = torch.empty(0, device=device, dtype=torch.int64)
    plain_top_indices = torch.empty(0, device=device, dtype=torch.int64)
    he_top_scores = torch.empty(0, device=device, dtype=torch.int64)
    he_top_indices = torch.empty(0, device=device, dtype=torch.int64)

    start = time.time()
    for g in range(groups):
        active = args.vectors - g * VECTORS_PER_GROUP
        if active <= 0:
            break
        if active > VECTORS_PER_GROUP:
            active = VECTORS_PER_GROUP

        emb = make_signed_embeddings(args.dim, VECTORS_PER_GROUP, args.seed + 1_000_003 * g, device)
        if active < VECTORS_PER_GROUP:
            emb_active = emb[:, :active]
        else:
            emb_active = emb

        plain_scores = torch.sum(emb_active * query.view(-1, 1), dim=0, dtype=torch.int64)

        coeff_mod = torch.remainder(emb_active, Q)
        he_mod = constctxt_reduce_gpu(coeff_mod, query)
        he_scores = decode_signed_mod_q(he_mod)

        local_k = min(k, active)
        p_vals, p_pos = torch.topk(plain_scores, k=local_k, largest=True, sorted=True)
        h_vals, h_pos = torch.topk(he_scores, k=local_k, largest=True, sorted=True)
        base = g * VECTORS_PER_GROUP
        p_idx = p_pos.to(torch.int64) + base
        h_idx = h_pos.to(torch.int64) + base

        plain_top_scores, plain_top_indices = merge_topk(
            plain_top_scores, plain_top_indices, p_vals, p_idx, k
        )
        he_top_scores, he_top_indices = merge_topk(he_top_scores, he_top_indices, h_vals, h_idx, k)

        if args.progress_every and ((g + 1) % args.progress_every == 0 or g + 1 == groups):
            torch.cuda.synchronize() if device.type == "cuda" else None
            elapsed = time.time() - start
            done = min((g + 1) * VECTORS_PER_GROUP, args.vectors)
            print(
                f"query={query_id} progress groups={g + 1}/{groups} "
                f"vectors={done}/{args.vectors} elapsed={elapsed:.2f}s",
                flush=True,
            )

        del emb, emb_active, plain_scores, coeff_mod, he_mod, he_scores

    plain_top = [int(x) for x in plain_top_indices.cpu().tolist()]
    he_top = [int(x) for x in he_top_indices.cpu().tolist()]
    plain_top1 = plain_top[0]

    reciprocal_rank = 0.0
    he_rank = None
    for rank, idx in enumerate(he_top[:10], start=1):
        if idx == plain_top1:
            he_rank = rank
            reciprocal_rank = 1.0 / rank
            break

    exact_top10 = plain_top[:10] == he_top[:10]

    return {
        "query_id": query_id,
        "plain_top10_indices": plain_top[:10],
        "he_top10_indices": he_top[:10],
        "plain_top10_scores": [int(x) for x in plain_top_scores[:10].cpu().tolist()],
        "he_top10_scores": [int(x) for x in he_top_scores[:10].cpu().tolist()],
        "plain_top1_he_rank": he_rank,
        "reciprocal_rank@10": reciprocal_rank,
        "top10_exact_match": exact_top10,
    }


def run(args: argparse.Namespace) -> Dict[str, object]:
    if not torch.cuda.is_available() and args.device.startswith("cuda"):
        raise RuntimeError("CUDA device requested but torch.cuda.is_available() is false")

    device = torch.device(args.device)
    if device.type == "cuda":
        torch.cuda.set_device(device)
        torch.cuda.empty_cache()

    queries = [
        make_signed_query(args.dim, args.seed + 65_537 * q, device)
        for q in range(args.queries)
    ]

    if args.cpu_check:
        q = queries[0][: min(args.dim, 16)]
        emb = make_signed_embeddings(q.numel(), 128, args.seed + 999, device)
        plain = torch.sum(emb * q.view(-1, 1), dim=0, dtype=torch.int64).cpu()
        he = decode_signed_mod_q(constctxt_reduce_gpu(torch.remainder(emb, Q), q)).cpu()
        if not torch.equal(plain, he):
            diff = torch.nonzero(plain != he).flatten()
            i = int(diff[0].item())
            raise AssertionError(f"CPU-style plaintext/HE mismatch at {i}: {plain[i]} vs {he[i]}")

    if device.type == "cuda":
        torch.cuda.synchronize()
    start = time.time()

    per_query = []
    for qid, query in enumerate(queries):
        per_query.append(run_one_query(args, qid, query))

    if device.type == "cuda":
        torch.cuda.synchronize()
    elapsed = time.time() - start

    rr = [q["reciprocal_rank@10"] for q in per_query]
    mrr10 = sum(rr) / len(rr)
    r1 = [1.0 if q["plain_top1_he_rank"] == 1 else 0.0 for q in per_query]
    r10 = [1.0 if q["plain_top1_he_rank"] is not None else 0.0 for q in per_query]
    exact = [1.0 if q["top10_exact_match"] else 0.0 for q in per_query]

    return {
        "implementation": "PyTorch CUDA full-corpus HE arithmetic ranking validator",
        "device": str(device),
        "torch_version": torch.__version__,
        "gpu_name": torch.cuda.get_device_name(device) if device.type == "cuda" else "cpu",
        "vectors": args.vectors,
        "vectors_per_group": VECTORS_PER_GROUP,
        "groups": math.ceil(args.vectors / VECTORS_PER_GROUP),
        "embedding_dim": args.dim,
        "queries": args.queries,
        "top_k": args.k,
        "modulus_q": Q,
        "embedding_bits": EMBED_BITS,
        "query_bits": QUERY_BITS_RECALL,
        "runtime_seconds": elapsed,
        "vectors_per_second_per_query": (args.vectors * args.queries / elapsed) if elapsed > 0 else None,
        "he_recall@1": sum(r1) / len(r1),
        "he_recall@10": sum(r10) / len(r10),
        "he_mrr@10": mrr10,
        "paper_metric": "MRR@10",
        "paper_mrr@10": mrr10,
        "top10_exact_match_rate": sum(exact) / len(exact),
        "cpu_crosscheck": bool(args.cpu_check),
        "per_query": per_query,
        "notes": [
            "Synthetic signed fixed-point embeddings are generated deterministically per group.",
            "HE scores use the same 51-bit modular const x ctxt arithmetic and are decoded to signed scores.",
            "Scope: full-corpus arithmetic/ranking validation on a deterministic fixed-point corpus.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vectors", type=int, default=1_000_000)
    parser.add_argument("--dim", type=int, default=768)
    parser.add_argument("--queries", type=int, default=1)
    parser.add_argument("--k", type=int, default=10)
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--cpu-check", action="store_true")
    parser.add_argument("--progress-every", type=int, default=0)
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
