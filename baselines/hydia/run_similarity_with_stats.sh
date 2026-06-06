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
RSS_CSV="$OUT_DIR/similarity_rss.csv"

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

if [[ ! -f "$RSS_CSV" ]]; then
  printf "Dataset,Vectors,Exit Code,Peak Memory MB,Peak Memory Raw\n" > "$RSS_CSV"
fi

parse_vectors() {
  local dataset="$1"
  head -n 1 "$HYDIA_DIR/test/$dataset" | tr -d '[:space:]'
}

parse_mem_mb() {
  python3 - "$1" <<'PY'
import re
import sys

raw = sys.argv[1].split("/")[0].strip()
m = re.match(r"([0-9.]+)\s*([KMGTP]?i?B)", raw)
if not m:
    print("0")
    raise SystemExit

value = float(m.group(1))
unit = m.group(2)
prefix = unit[0]
if unit == "B":
    bytes_value = value
elif len(unit) == 2:
    bytes_value = value * (1000 ** ("KMGT".index(prefix) + 1))
elif len(unit) == 3 and unit[1] == "i":
    bytes_value = value * (1024 ** ("KMGT".index(prefix) + 1))
else:
    bytes_value = 0
print(f"{bytes_value / 1_000_000:.3f}")
PY
}

for dataset in "$@"; do
  vectors="$(parse_vectors "$dataset")"
  name_base="${dataset%.dat}"
  container="hydia-sim-${name_base//[^A-Za-z0-9_.-]/-}-$$"
  peak_mb="0"
  peak_raw="0B / 0B"

  docker run -d --name "$container" --runtime runc \
    -v "$OUT_DIR:/tmp/hydia-results" \
    -v "$HYDIA_DIR/test:/opt/image_matching/test:ro" \
    --entrypoint bash \
    "$IMAGE" \
    -lc "set -euo pipefail
cd /opt/image_matching/build
../tools/setup_experiment.sh
./ImageMatching '../test/$dataset' 5 similarity > '/tmp/hydia-results/${name_base}.log' 2>&1
cp similarity_latency.csv '/tmp/hydia-results/${name_base}.similarity_latency.csv'" >/dev/null

  while [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)" == "true" ]]; do
    raw="$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      mb="$(parse_mem_mb "$raw")"
      if python3 - "$mb" "$peak_mb" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)
PY
      then
        peak_mb="$mb"
        peak_raw="${mb}MB"
      fi
    fi
    sleep 0.5
  done

  exit_code="$(docker wait "$container" 2>/dev/null || echo 125)"
  docker rm "$container" >/dev/null 2>&1 || true
  peak_out="$peak_mb"
  raw_out="$peak_raw"
  if [[ "$peak_mb" == "0" ]]; then
    peak_out=""
    raw_out=""
  fi
  printf "%s,%s,%s,%s,\"%s\"\n" "$dataset" "$vectors" "$exit_code" "$peak_out" "$raw_out" >> "$RSS_CSV"

  if [[ "$exit_code" != "0" ]]; then
    echo "HyDia run failed for $dataset with exit code $exit_code" >&2
    exit "$exit_code"
  fi
done
