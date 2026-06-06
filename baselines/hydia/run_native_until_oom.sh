#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/image_matching [start_exp] [end_exp]" >&2
  echo "example: $0 /path/to/image_matching 12 26" >&2
  exit 1
fi

HYDIA_DIR="$1"
START_EXP="${2:-12}"
END_EXP="${3:-26}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${HYDIA_OUT_DIR:-$SCRIPT_DIR/results}"
GENERATOR="${HYDIA_GENERATOR:-$SCRIPT_DIR/gen_dataset_fast.py}"
RSS_CSV="$OUT_DIR/similarity_rss.csv"
FAILURE_FILE="$OUT_DIR/resident_failure.csv"
OPENFHE_LIB="${OPENFHE_LIB:-$(cd "$HYDIA_DIR/.." && pwd)/openfhe-install/lib}"

if [[ -d "$OPENFHE_LIB" ]]; then
  export LD_LIBRARY_PATH="$OPENFHE_LIB:${LD_LIBRARY_PATH:-}"
fi

mkdir -p "$OUT_DIR" "$HYDIA_DIR/test" "$HYDIA_DIR/build"

if [[ ! -x "$HYDIA_DIR/build/ImageMatching" ]]; then
  echo "ImageMatching binary not found at $HYDIA_DIR/build/ImageMatching" >&2
  exit 1
fi

if [[ ! -f "$RSS_CSV" ]]; then
  printf "Dataset,Vectors,Exit Code,Peak Memory MB,Peak Memory Raw\n" > "$RSS_CSV"
fi
if [[ ! -f "$FAILURE_FILE" ]]; then
  printf "Dataset,Vectors,Exit Code,Reason\n" > "$FAILURE_FILE"
fi

parse_peak_mb() {
  local time_file="$1"
  python3 - "$time_file" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, errors="replace").read()
m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
if not m:
    print("")
else:
    print(f"{int(m.group(1)) * 1024.0 / 1_000_000.0:.3f}")
PY
}

for exp in $(seq "$START_EXP" "$END_EXP"); do
  vectors=$((1 << exp))
  dataset="2_${exp}.dat"
  dataset_path="$HYDIA_DIR/test/$dataset"
  name_base="${dataset%.dat}"
  echo "=== HyDia native resident score-only $dataset ($vectors vectors) ==="

  if [[ ! -f "$dataset_path" ]]; then
    "$GENERATOR" "$dataset_path" "$vectors" --dim 512 --seed $((42 + exp))
  fi
  du -h "$dataset_path"

  cd "$HYDIA_DIR/build"
  rm -rf serial latency.csv accuracy.csv similarity_latency.csv
  ../tools/setup_experiment.sh

  set +e
  /usr/bin/time -v -o "$OUT_DIR/${name_base}.time" \
    ./ImageMatching "../test/$dataset" 5 similarity \
    > "$OUT_DIR/${name_base}.log" 2>&1
  rc=$?
  set -e

  if [[ -f similarity_latency.csv ]]; then
    cp similarity_latency.csv "$OUT_DIR/${name_base}.similarity_latency.csv"
  fi

  peak_mb="$(parse_peak_mb "$OUT_DIR/${name_base}.time")"
  raw=""
  if [[ -n "$peak_mb" ]]; then
    raw="${peak_mb}MB"
  fi
  printf "%s,%s,%s,%s,\"%s\"\n" "$dataset" "$vectors" "$rc" "$peak_mb" "$raw" >> "$RSS_CSV"

  if [[ "$rc" -ne 0 ]]; then
    printf "%s,%s,%s,\"ImageMatching exited nonzero; see %s.log and %s.time\"\n" \
      "$dataset" "$vectors" "$rc" "$name_base" "$name_base" >> "$FAILURE_FILE"
    echo "resident run failed at $dataset (exit $rc); stopping"
    exit "$rc"
  fi

  df -h "$HYDIA_DIR" "$OUT_DIR" | tail -n +2
done
