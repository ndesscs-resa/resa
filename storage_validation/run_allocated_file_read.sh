#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run_allocated_file_read.sh --file PATH --out DIR [--size SIZE] [--runtime SEC] [--ramp-time SEC]

Creates a non-sparse allocated file with fio write, then runs a direct-I/O
read-only calibration/holdout matrix against that file. This avoids raw
namespace reads from deallocated LBAs returning zero without NAND access.

The target path must live on the SSD filesystem being validated.
USAGE
}

TARGET=""
OUT=""
SIZE="128G"
RUNTIME="180"
RAMP_TIME="20"
IOENGINE="${IOENGINE:-io_uring}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      TARGET="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    --size)
      SIZE="$2"
      shift 2
      ;;
    --runtime)
      RUNTIME="$2"
      shift 2
      ;;
    --ramp-time)
      RAMP_TIME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TARGET" || -z "$OUT" ]]; then
  echo "--file and --out are required" >&2
  usage >&2
  exit 2
fi

mkdir -p "$OUT"
mkdir -p "$(dirname "$TARGET")"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "target=$TARGET"
  echo "size=$SIZE"
  echo "runtime=$RUNTIME"
  echo "ramp_time=$RAMP_TIME"
  echo "ioengine=$IOENGINE"
  fio --version | sed 's/^/fio=/'
  df -h "$(dirname "$TARGET")" | sed 's/^/df=/'
  findmnt -T "$(dirname "$TARGET")" | sed 's/^/findmnt=/'
} >"$OUT/manifest.txt"

CTRL=""
SOURCE_DEV="$(findmnt -no SOURCE -T "$(dirname "$TARGET")" || true)"
if [[ "$SOURCE_DEV" =~ ^/dev/nvme[0-9]+n[0-9]+ ]]; then
  CTRL="/dev/$(basename "$SOURCE_DEV" | sed -E 's/n[0-9]+$//')"
  nvme smart-log "$CTRL" >"$OUT/smart-before.txt" 2>&1 || true
  nvme id-ns "$SOURCE_DEV" -H >"$OUT/id-ns-before.txt" 2>&1 || true
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] writing allocated validation file $TARGET ($SIZE)"
fio \
  --name=prepare_allocated_file \
  --filename="$TARGET" \
  --direct=1 \
  --ioengine="$IOENGINE" \
  --rw=write \
  --bs=1M \
  --iodepth=32 \
  --numjobs=1 \
  --size="$SIZE" \
  --time_based=0 \
  --group_reporting \
  --output="$OUT/prepare.write_1m_qd32.json" \
  --output-format=json

sync

python3 - "$TARGET" "$OUT/file-stat-before.txt" <<'PY'
import os
import sys
path, out = sys.argv[1], sys.argv[2]
st = os.stat(path)
with open(out, "w") as f:
    f.write(f"path={path}\n")
    f.write(f"size={st.st_size}\n")
    f.write(f"blocks_512={st.st_blocks}\n")
    f.write(f"allocated_bytes={st.st_blocks * 512}\n")
PY

cat >"$OUT/workloads.tsv" <<'WORKLOADS'
split	name	rw	bs	iodepth	numjobs
calibration	alloc_randread_4k_qd1	randread	4K	1	1
calibration	alloc_randread_4k_qd32	randread	4K	32	1
calibration	alloc_randread_4k_qd32_nj4	randread	4K	32	4
calibration	alloc_seqread_1m_qd32	read	1M	32	1
holdout	alloc_randread_16k_qd8	randread	16K	8	1
holdout	alloc_randread_4k_qd64_nj4	randread	4K	64	4
holdout	alloc_seqread_1m_qd8	read	1M	8	1
WORKLOADS

tail -n +2 "$OUT/workloads.tsv" | while IFS=$'\t' read -r split name rw bs iodepth numjobs; do
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] running $split/$name"
  fio \
    --name="$name" \
    --filename="$TARGET" \
    --readonly \
    --direct=1 \
    --ioengine="$IOENGINE" \
    --rw="$rw" \
    --bs="$bs" \
    --iodepth="$iodepth" \
    --numjobs="$numjobs" \
    --time_based=1 \
    --runtime="$RUNTIME" \
    --ramp_time="$RAMP_TIME" \
    --group_reporting \
    --output="$OUT/$split.$name.json" \
    --output-format=json
done

if [[ -n "$CTRL" ]]; then
  nvme smart-log "$CTRL" >"$OUT/smart-after.txt" 2>&1 || true
  nvme id-ns "$SOURCE_DEV" -H >"$OUT/id-ns-after.txt" 2>&1 || true
fi

python3 - "$TARGET" "$OUT/file-stat-after.txt" <<'PY'
import os
import sys
path, out = sys.argv[1], sys.argv[2]
st = os.stat(path)
with open(out, "w") as f:
    f.write(f"path={path}\n")
    f.write(f"size={st.st_size}\n")
    f.write(f"blocks_512={st.st_blocks}\n")
    f.write(f"allocated_bytes={st.st_blocks * 512}\n")
PY

if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  chown -R "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
  chown "$SUDO_UID:$SUDO_GID" "$TARGET" 2>/dev/null || true
fi

echo "Wrote allocated-file fio JSON results to $OUT"
