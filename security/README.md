# Security Parameter Record

This directory records the CKKS/RLWE parameter point used for the Middleware
submission.

## Parameter Point

| Parameter | Value |
|---|---:|
| Ring dimension | `N = 4096` |
| Ciphertext modulus | `Q = 2^51 - 2^17 + 1` |
| `log2(Q)` budget used online | 51 bits |
| Error distribution | rounded Gaussian, sigma = 3.2 |
| Secret distribution | dense ternary |
| Target | 128-bit security |

## Reproduction

Install the Albrecht et al. lattice-estimator with Sage support for a fresh
estimator rerun, then run:

```bash
python3 lattice_estimator_params.py --print-estimator-snippet
```

Then execute the emitted snippet under an estimator-enabled Python/Sage
environment. The bundled quick check validates the parameter record from the
recorded fields.
