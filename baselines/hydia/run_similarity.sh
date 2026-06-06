#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/image_matching [dataset ...]" >&2
  echo "example: $0 /path/to/image_matching 2_10.dat 2_15.dat" >&2
  exit 1
fi

HYDIA_DIR="$1"
shift

if [[ $# -eq 0 ]]; then
  set -- 2_10.dat
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/hydia-similarity-depth1.patch"
IMAGE="${HYDIA_IMAGE:-popets2025-hydia-similarity}"
OUT_DIR="${HYDIA_OUT_DIR:-$SCRIPT_DIR/results}"

mkdir -p "$OUT_DIR"

cd "$HYDIA_DIR"
if ! git diff --quiet -- src/main.cpp tools/setup_experiment.sh; then
  echo "HyDia checkout already has local changes; leaving them in place." >&2
elif git apply --check "$PATCH_FILE"; then
  git apply "$PATCH_FILE"
else
  echo "Patch is already applied or does not match this checkout." >&2
fi

if [[ "${HYDIA_REBUILD:-0}" == "1" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build --tag "$IMAGE" .
fi

docker run --rm --runtime runc \
  -v "$OUT_DIR:/tmp/hydia-results" \
  -v "$HYDIA_DIR/test:/opt/image_matching/test:ro" \
  --entrypoint bash \
  "$IMAGE" \
  -lc 'set -euo pipefail
cd /opt/image_matching/build
../tools/setup_experiment.sh
for dataset in "$@"; do
  ./ImageMatching "../test/$dataset" 5 similarity | tee "/tmp/hydia-results/${dataset%.dat}.log"
done
cp similarity_latency.csv /tmp/hydia-results/' \
  hydia-similarity "$@"
