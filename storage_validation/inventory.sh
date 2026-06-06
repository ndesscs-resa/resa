#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: inventory.sh --ctrl /dev/nvmeX --ns /dev/nvmeXnY --out DIR

Collects non-destructive device inventory for SSD validation.
Root is recommended for nvme id-ctrl/id-ns/smart-log, but sysfs/lsblk/lspci
are collected even without root.
USAGE
}

CTRL=""
NS=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctrl)
      CTRL="$2"
      shift 2
      ;;
    --ns)
      NS="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
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

if [[ -z "$OUT" ]]; then
  echo "--out is required" >&2
  usage >&2
  exit 2
fi

mkdir -p "$OUT"

run_capture() {
  local name="$1"
  shift
  {
    echo "$ $*"
    "$@"
    local status=$?
    echo
    echo "exit_status=$status"
    return "$status"
  } >"$OUT/$name" 2>&1 || true
}

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -a)"
  echo "user=$(id)"
  echo "ctrl=$CTRL"
  echo "ns=$NS"
  command -v fio >/dev/null 2>&1 && fio --version | sed 's/^/fio=/'
  command -v nvme >/dev/null 2>&1 && nvme version | sed 's/^/nvme_cli=/'
} >"$OUT/manifest.txt"

run_capture "nvme-list.json" nvme list -o json
run_capture "lsblk.txt" lsblk -o NAME,MODEL,SERIAL,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINTS
run_capture "findmnt.txt" findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS
run_capture "lspci-nvme.txt" bash -lc "lspci -nn | awk 'BEGIN{IGNORECASE=1} /non-volatile|nvme|ssd|samsung|hynix/' || true"
run_capture "lspci-vv.txt" lspci -vv

{
  for b in /sys/block/nvme*n1; do
    [[ -e "$b" ]] || continue
    echo "### $b"
    for f in device/model device/serial device/firmware_rev size queue/logical_block_size queue/physical_block_size queue/rotational; do
      printf '%s=' "$f"
      cat "$b/$f" 2>/dev/null || true
    done
  done
} >"$OUT/sysfs-block.txt"

{
  for d in /sys/class/nvme/nvme*; do
    [[ -e "$d" ]] || continue
    echo "### $d"
    readlink -f "$d/device" || true
    for f in model serial firmware_rev; do
      printf '%s=' "$f"
      cat "$d/$f" 2>/dev/null || true
    done
  done
} >"$OUT/sysfs-nvme.txt"

{
  for dev in /sys/class/nvme/nvme*/device; do
    [[ -e "$dev" ]] || continue
    bdf=$(basename "$(readlink -f "$dev")")
    echo "### $bdf"
    for f in current_link_speed current_link_width max_link_speed max_link_width vendor device; do
      printf '%s=' "$f"
      cat "$dev/$f" 2>/dev/null || true
    done
  done
} >"$OUT/sysfs-pcie-link.txt"

if [[ -n "$CTRL" ]]; then
  run_capture "id-ctrl.txt" nvme id-ctrl "$CTRL" -H
  run_capture "smart-before.txt" nvme smart-log "$CTRL"
fi

if [[ -n "$NS" ]]; then
  run_capture "id-ns.txt" nvme id-ns "$NS" -H
fi

if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  chown -R "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
fi

echo "Wrote inventory to $OUT"
