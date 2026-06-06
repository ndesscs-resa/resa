#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path


def pct(job, key, op="read"):
    values = job.get(op, {}).get("clat_ns", {}).get("percentile", {})
    value = values.get(key)
    if value is None:
        return ""
    return float(value) / 1000.0


def summarize_file(path):
    with path.open() as f:
        data = json.load(f)

    job = data["jobs"][0]
    opts = job.get("job options", {})
    read = job.get("read", {})
    write = job.get("write", {})
    op = "read"
    stats = read
    if float(read.get("io_bytes", 0) or 0) == 0 and float(write.get("io_bytes", 0) or 0) > 0:
        op = "write"
        stats = write
    clat = stats.get("clat_ns", {})
    split, name = path.stem.split(".", 1) if "." in path.stem else ("unknown", path.stem)

    bw_bytes = stats.get("bw_bytes")
    if bw_bytes is None:
        fio_bw_units = stats.get("bw", 0)
        bw_mb_s = float(fio_bw_units) * 1024.0 / 1_000_000.0
    else:
        bw_mb_s = float(bw_bytes) / 1_000_000.0

    return {
        "split": split,
        "name": name,
        "rw": opts.get("rw", ""),
        "op": op,
        "bs": opts.get("bs", ""),
        "iodepth": opts.get("iodepth", ""),
        "numjobs": opts.get("numjobs", ""),
        "runtime_ms": stats.get("runtime", ""),
        "bw_mb_s": f"{bw_mb_s:.3f}",
        "iops": f"{float(stats.get('iops', 0.0)):.3f}",
        "clat_mean_us": f"{float(clat.get('mean', 0.0)) / 1000.0:.3f}",
        "clat_p50_us": f"{pct(job, '50.000000', op):.3f}" if pct(job, "50.000000", op) != "" else "",
        "clat_p99_us": f"{pct(job, '99.000000', op):.3f}" if pct(job, "99.000000", op) != "" else "",
        "clat_p999_us": f"{pct(job, '99.900000', op):.3f}" if pct(job, "99.900000", op) != "" else "",
        "source": str(path),
    }


def write_csv(rows, path):
    fields = [
        "split",
        "name",
        "rw",
        "op",
        "bs",
        "iodepth",
        "numjobs",
        "runtime_ms",
        "bw_mb_s",
        "iops",
        "clat_mean_us",
        "clat_p50_us",
        "clat_p99_us",
        "clat_p999_us",
        "source",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_md(rows, path):
    fields = [
        "split",
        "name",
        "op",
        "bs",
        "iodepth",
        "numjobs",
        "bw_mb_s",
        "iops",
        "clat_mean_us",
        "clat_p99_us",
    ]
    with path.open("w") as f:
        f.write("# fio Summary\n\n")
        f.write("| " + " | ".join(fields) + " |\n")
        f.write("|" + "|".join(["---"] * len(fields)) + "|\n")
        for row in rows:
            f.write("| " + " | ".join(str(row.get(field, "")) for field in fields) + " |\n")


def main():
    parser = argparse.ArgumentParser(description="Summarize fio JSON results from run_allocated_file_read.sh")
    parser.add_argument("result_dir", type=Path)
    parser.add_argument("--out-csv", type=Path, required=True)
    parser.add_argument("--out-md", type=Path)
    args = parser.parse_args()

    files = sorted(args.result_dir.glob("*.json"))
    if not files:
        raise SystemExit(f"No fio JSON files found in {args.result_dir}")

    rows = [summarize_file(path) for path in files]
    rows.sort(key=lambda r: (r["split"], r["name"]))
    write_csv(rows, args.out_csv)
    if args.out_md:
        write_md(rows, args.out_md)


if __name__ == "__main__":
    main()
