# HyDia Similarity Baseline

This directory records the local HyDia patch used to time HyDia's encrypted
similarity computation under the score-generation objective used by the paper.
The upstream HyDia artifact is used as an external checkout.

Baseline definition:

- Start from the public HyDia artifact: `https://github.com/n7koirala/image_matching/`.
- Use approach `5`, the HyDia diagonal transform implementation.
- Run `DiagonalSender::computeSimilarity()` only.
- Disable homomorphic thresholding, membership aggregation, and identification
  result formatting.
- Set CKKS multiplicative depth to `1`, the minimum depth needed by the
  ciphertext-ciphertext score multiplication.

This is a favorable HyDia measurement point relative to its published full
membership/identification protocol, whose artifact uses depth `11` because it
also includes the depth-10 homomorphic threshold comparison.

## Patch

Run the wrapper commands in this file from `baselines/hydia/`.

Apply `hydia-similarity-depth1.patch` inside a clean HyDia checkout:

```bash
git clone https://github.com/n7koirala/image_matching.git
cd image_matching
git apply /path/to/hydia-similarity-depth1.patch
docker build --tag popets2025-hydia-similarity .
```

Then run, inside the container build directory:

```bash
../tools/setup_experiment.sh
./ImageMatching ../test/2_10.dat 5 similarity
```

The run appends a row to `similarity_latency.csv` with the depth, batch size,
query encryption time, query ciphertext count, similarity computation time, and
similarity result ciphertext count.

The artifact wrapper applies the patch when needed,
builds the Docker image, runs one or more datasets, and copies the CSV into this
directory's `results/` folder:

```bash
./run_similarity.sh /path/to/image_matching 2_10.dat 2_14.dat
```

`run_similarity_with_stats.sh` runs the same score-only experiment one dataset
per container and polls Docker cgroup memory while the container is live:

```bash
./run_similarity_with_stats.sh /path/to/image_matching 2_10.dat 2_15.dat
```

It writes `results/similarity_rss.csv`. The polling interval is 0.5 s, so this
is a practical peak-memory estimate for plotting, not an instruction-count-level
memory trace.

The bundled resident rows were materialized from per-size native HyDia runs.
For a fresh native rerun, build the HyDia `ImageMatching` binary in the upstream
checkout and keep its OpenFHE runtime libraries available, then run:

```bash
HYDIA_OUT_DIR=results/resident-rerun \
  ./run_native_until_oom.sh /path/to/image_matching 12 24
```

Datasets passed to the wrapper must already exist under the HyDia checkout's
`test/` directory. The upstream checkout ships `2_10.dat` through `2_14.dat`;
larger synthetic files can be generated from the HyDia `build/` directory:

```bash
../tools/gen_dataset.sh 2_15.dat 32768
```

## Resident scaling plot

HyDia's artifact is a resident-database artifact at the experiment level: the
dataset is read and enrolled before the timed score path. This directory plots
only resident runs that completed successfully.

`plot_scaling.py` builds a 512D scaling CSV and SVG over powers of two from
`2^12` to `2^27` vectors:

```bash
./plot_scaling.py
```

The output files are:

- `results/scaling_512.csv`
- `results/latency_scaling_512.svg`
- `results/latency_scaling_512.pdf`
- `results/memory_scaling_512.svg`, when `similarity_rss.csv` contains HyDia
  peak-memory rows.
- `results/memory_scaling_512.pdf`

Rows marked `resident_measured` are direct HyDia score-only measurements. If a
resident run reaches an OOM/resource-failure boundary, that boundary is kept in
the raw result directory for provenance, but the figure stops at the largest
completed resident row.

The combined scaling CSV uses `Memory MB` with a `Memory Basis` column. HyDia
rows report measured peak resident-set size. Resa rows report host memory for
the result ciphertext array after SSD-controller DMA writeback.

## Paper outputs

`prepare_paper_outputs.py` turns a resident result directory into the files that
the report consumes:

```bash
./prepare_paper_outputs.py \
  --results-dir results/resident-real-260529 \
  --paper-dir /path/to/paper-tree
```

The script:

- combines per-size `2_*.similarity_latency.csv` files into
  `similarity_latency.csv`;
- reconstructs `similarity_rss.csv` from `/usr/bin/time -v` files, which also
  repairs runs where the live script failed to parse RSS;
- creates `scaling_512.csv`, `latency_scaling_512.{svg,pdf}`, and
  `memory_scaling_512.{svg,pdf}`;
- copies the submission PDFs into the target paper tree's `figures/`;
- writes the target paper tree's `generated/hydia_scaling.tex`.

The bundled measured resident rows are under `results/resident-real-260529/`;
rerunning the script materializes the figure block from those rows.
