#!/usr/bin/env python3
"""
CUDA-backed validator for the paper's coefficient-domain const x ctxt HE MAC.

The ASIC datapath computes, for each packed group and ciphertext polynomial:

    out[j] = sum_i coeff[i, j] * scalar[i] mod q

where q = 2^51 - 2^17 + 1. Query scalars use the paper's 23-bit plaintext
scale and may be negative. A negative scalar -s is equivalent to the modular
plaintext q-s, so this validator accumulates signed small scalars and reduces
the final coefficient modulo q. That validates the output HE coefficient values
while the RTL tests validate the internal 118-bit accumulator timing/path.

The full-scale mode streams deterministic synthetic coefficient groups rather
than materializing a 493 GB encrypted database.
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


Q = (1 << 51) - (1 << 17) + 1
SOLINAS_C = (1 << 17) - 1
VECTORS_PER_GROUP = 4096
COEFF_BITS = 51
QUERY_BITS = 23
COEFF_LO_BITS = 28
COEFF_HI_SHIFT_IN_BASE = 23  # 51 - 28


def make_query(dim: int, seed: int, device: torch.device) -> torch.Tensor:
    gen = torch.Generator(device=device)
    gen.manual_seed(seed)
    # Signed 23-bit constants cover both positive and negative plaintext scalar
    # encodings.
    mag = torch.randint(1, 1 << QUERY_BITS, (dim,), device=device, dtype=torch.int64, generator=gen)
    sign_bit = torch.randint(0, 2, (dim,), device=device, dtype=torch.int64, generator=gen)
    sign = sign_bit * 2 - 1
    return mag * sign


def make_coeffs(dim: int, coeffs: int, seed: int, device: torch.device) -> torch.Tensor:
    gen = torch.Generator(device=device)
    gen.manual_seed(seed)
    return torch.randint(0, Q, (dim, coeffs), device=device, dtype=torch.int64, generator=gen)


def constctxt_reduce_gpu(coeff: torch.Tensor, query: torch.Tensor) -> torch.Tensor:
    """Return sum_i coeff[i,j] * query[i] mod Q for all j.

    The product can be 74 bits, so it is split exactly into low/high base-2^51
    limbs using 28-bit coefficient decomposition:

        coeff = c0 + c1*2^28
        abs(q) <= 2^23
        coeff*q = low + high*2^51

    low and high are accumulated independently in signed int64 and reduced via
    2^51 = 2^17 - 1 (mod Q).
    """
    abs_q = torch.abs(query).view(-1, 1)
    sign = torch.sign(query).view(-1, 1)

    c0_mask = (1 << COEFF_LO_BITS) - 1
    c1_low_mask = (1 << COEFF_HI_SHIFT_IN_BASE) - 1
    base_mask = (1 << COEFF_BITS) - 1

    c0 = torch.bitwise_and(coeff, c0_mask)
    c1 = torch.bitwise_right_shift(coeff, COEFF_LO_BITS)

    p0 = c0 * abs_q
    p1 = c1 * abs_q
    low_pre = p0 + torch.bitwise_left_shift(torch.bitwise_and(p1, c1_low_mask), COEFF_LO_BITS)
    low = torch.bitwise_and(low_pre, base_mask)
    high = torch.bitwise_right_shift(p1, COEFF_HI_SHIFT_IN_BASE) + torch.bitwise_right_shift(low_pre, COEFF_BITS)

    signed_low = low * sign
    signed_high = high * sign
    low_sum = torch.sum(signed_low, dim=0, dtype=torch.int64)
    high_sum = torch.sum(signed_high, dim=0, dtype=torch.int64)

    low_mod = torch.remainder(low_sum, Q)
    high_mod = torch.remainder(high_sum * SOLINAS_C, Q)
    return torch.remainder(low_mod + high_mod, Q)


def constctxt_reduce_cpu(coeff: torch.Tensor, query: torch.Tensor) -> torch.Tensor:
    coeff_cpu = coeff.cpu().tolist()
    query_cpu = query.cpu().tolist()
    dim = len(query_cpu)
    n = len(coeff_cpu[0])
    out = []
    for j in range(n):
        acc = 0
        for i in range(dim):
            # Use the modular scalar representation here, not signed arithmetic,
            # so the CPU check compares the GPU's signed-small implementation
            # against the exact 51-bit field operation seen by hardware.
            acc += coeff_cpu[i][j] * (query_cpu[i] % Q)
        out.append(acc % Q)
    return torch.tensor(out, dtype=torch.int64)


def run(args: argparse.Namespace) -> Dict[str, object]:
    if not torch.cuda.is_available() and args.device.startswith("cuda"):
        raise RuntimeError("CUDA device requested but torch.cuda.is_available() is false")

    device = torch.device(args.device)
    if device.type == "cuda":
        torch.cuda.set_device(device)
        torch.cuda.empty_cache()

    groups = math.ceil(args.vectors / VECTORS_PER_GROUP)
    coeffs_per_group = VECTORS_PER_GROUP
    total_vectors_processed = groups * VECTORS_PER_GROUP
    polys = 2
    query = make_query(args.dim, args.seed, device)

    if args.cpu_check:
        check_dim = min(args.dim, 16)
        check_coeffs = min(coeffs_per_group, 128)
        check_query = query[:check_dim]
        check_coeff = make_coeffs(check_dim, check_coeffs, args.seed + 999, device)
        gpu = constctxt_reduce_gpu(check_coeff, check_query).cpu()
        cpu = constctxt_reduce_cpu(check_coeff, check_query)
        if not torch.equal(gpu, cpu):
            diffs = torch.nonzero(gpu != cpu).flatten()
            first = int(diffs[0].item())
            raise AssertionError(
                f"CPU/GPU mismatch at coeff {first}: gpu={int(gpu[first])}, cpu={int(cpu[first])}"
            )

    if device.type == "cuda":
        torch.cuda.synchronize()
    start = time.time()

    processed_groups = 0
    for g in range(groups):
        active_vectors = args.vectors - g * VECTORS_PER_GROUP
        if active_vectors <= 0:
            break
        if active_vectors > VECTORS_PER_GROUP:
            active_vectors = VECTORS_PER_GROUP

        for poly in range(polys):
            coeff = make_coeffs(args.dim, coeffs_per_group, args.seed + 1_000_003 * g + 97 * poly, device)
            out = constctxt_reduce_gpu(coeff, query)
            if active_vectors < VECTORS_PER_GROUP:
                out = out[:active_vectors]
            del coeff, out

        processed_groups += 1

        if args.progress_every and (processed_groups % args.progress_every == 0 or processed_groups == groups):
            if device.type == "cuda":
                torch.cuda.synchronize()
            elapsed = time.time() - start
            vec_done = min(processed_groups * VECTORS_PER_GROUP, args.vectors)
            rate = vec_done / elapsed if elapsed > 0 else 0.0
            print(
                f"progress groups={processed_groups}/{groups} "
                f"vectors={vec_done}/{args.vectors} elapsed={elapsed:.2f}s rate={rate:.2f} vec/s",
                flush=True,
            )

    if device.type == "cuda":
        torch.cuda.synchronize()
    elapsed = time.time() - start

    coeff_mac_count = args.vectors * args.dim * polys
    return {
        "implementation": "PyTorch CUDA exact split-limb const-x-ctxt validator",
        "device": str(device),
        "torch_version": torch.__version__,
        "gpu_name": torch.cuda.get_device_name(device) if device.type == "cuda" else "cpu",
        "vectors_requested": args.vectors,
        "vectors_per_group": VECTORS_PER_GROUP,
        "groups": groups,
        "embedding_dim": args.dim,
        "polys_per_ciphertext": polys,
        "modulus_q": Q,
        "query_bits": QUERY_BITS,
        "coeff_bits": COEFF_BITS,
        "coeff_mac_count": coeff_mac_count,
        "runtime_seconds": elapsed,
        "vectors_per_second": args.vectors / elapsed if elapsed > 0 else None,
        "coeff_macs_per_second": coeff_mac_count / elapsed if elapsed > 0 else None,
        "cpu_crosscheck": bool(args.cpu_check),
        "notes": [
            "Synthetic ciphertext coefficients are generated deterministically per group.",
            "Signed 23-bit query scalars validate the modular output of CKKS plaintext constants.",
            "This validates coefficient-domain HE arithmetic, not semantic recall.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vectors", type=int, default=8192)
    parser.add_argument("--dim", type=int, default=768)
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
