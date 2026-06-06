#!/usr/bin/env python3
"""Generate HyDia-format synthetic 512D datasets faster than the bash helper."""

from __future__ import annotations

import argparse
import random
from pathlib import Path


def write_vector(f, values) -> None:
    f.write(" ".join(str(v) for v in values))
    f.write(" \n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("vectors", type=int)
    parser.add_argument("--dim", type=int, default=512)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        f.write(f"{args.vectors}\n")
        write_vector(f, [1] * args.dim)
        write_vector(f, [rng.randint(1, 3) for _ in range(args.dim)])
        for _ in range(args.vectors - 1):
            write_vector(f, [rng.randint(-99, 99) for _ in range(args.dim)])


if __name__ == "__main__":
    main()

