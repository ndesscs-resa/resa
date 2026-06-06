#!/usr/bin/env python3
"""Record the lattice-estimator parameter point used by this artifact."""

import argparse
import json
import math


Q = 2**51 - 2**17 + 1
PARAMS = {
    "ring_dimension_n": 4096,
    "ciphertext_modulus_q": Q,
    "log2_q": math.log2(Q),
    "error_distribution": "rounded Gaussian",
    "sigma": 3.2,
    "secret_distribution": "dense ternary",
    "target_security_bits": 128,
}


SNIPPET = r"""
from estimator import *

n = 4096
q = 2**51 - 2**17 + 1
params = LWE.Parameters(
    n=n,
    q=q,
    Xs=ND.UniformMod(3),          # dense ternary {-1,0,1}
    Xe=ND.DiscreteGaussian(3.2),  # rounded Gaussian error
    m=n,                          # RLWE-to-LWE conservative sample count
)
print(LWE.estimate(params))
"""


def check() -> None:
    assert PARAMS["ring_dimension_n"] == 4096
    assert PARAMS["ciphertext_modulus_q"] == 2_251_799_813_554_177
    assert 50.99 < PARAMS["log2_q"] < 51.01
    assert PARAMS["sigma"] == 3.2
    assert PARAMS["target_security_bits"] == 128
    print("Security parameter record OK")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--print-estimator-snippet", action="store_true")
    args = parser.parse_args()
    if args.check:
        check()
        return
    if args.print_estimator_snippet:
        print(SNIPPET.strip())
        return
    if args.json:
        print(json.dumps(PARAMS, indent=2))
        return
    print("CKKS/RLWE security parameter record")
    for key, value in PARAMS.items():
        print(f"  {key}: {value}")


if __name__ == "__main__":
    main()
