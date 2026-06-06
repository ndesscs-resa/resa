#!/usr/bin/env python3
"""Materialize HyDia resident result files into paper-ready figures/snippet."""

from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
from pathlib import Path

import plot_scaling


SCRIPT_DIR = Path(__file__).resolve().parent
ARTIFACT_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_CSD_CSV = (
    SCRIPT_DIR
    / "../../storage_validation/results/pm9a3-csd-scaling-hydia512-simplessdseq-260530/scaling_512.csv"
).resolve()

LATENCY_HEADER = [
    "Approach",
    "Operation",
    "Database Size (vectors)",
    "Query Ciphertexts",
    "Batch Size",
    "Query Encryption (seconds)",
    "Depth",
    "Similarity Computation (seconds)",
    "Similarity Ciphertexts",
]


def vector_count_from_name(path: Path) -> int | None:
    match = re.match(r"2_(\d+)", path.name)
    if not match:
        return None
    return 1 << int(match.group(1))


def combine_latency(results_dir: Path) -> Path | None:
    rows: list[dict[str, str]] = []
    for path in sorted(results_dir.glob("2_*.similarity_latency.csv"), key=lambda p: vector_count_from_name(p) or 0):
        with path.open(newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(row)

    if not rows:
        existing = results_dir / "similarity_latency.csv"
        return existing if existing.exists() else None

    out = results_dir / "similarity_latency.csv"
    with out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=LATENCY_HEADER)
        writer.writeheader()
        for row in sorted(rows, key=lambda r: int(r["Database Size (vectors)"])):
            writer.writerow({key: row.get(key, "") for key in LATENCY_HEADER})
    return out


def parse_time_file(path: Path) -> tuple[int | None, float | None]:
    text = path.read_text(errors="replace")
    signal_match = re.search(r"Command terminated by signal\s+(\d+)", text)
    exit_match = re.search(r"Exit status:\s*(\d+)", text)
    rss_match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
    if signal_match:
        exit_code = 128 + int(signal_match.group(1))
    else:
        exit_code = int(exit_match.group(1)) if exit_match else None
    rss_mb = int(rss_match.group(1)) * 1024.0 / 1_000_000.0 if rss_match else None
    return exit_code, rss_mb


def repair_rss(results_dir: Path) -> Path | None:
    rows: list[tuple[str, int, int | None, float | None]] = []
    for path in sorted(results_dir.glob("2_*.time"), key=lambda p: vector_count_from_name(p) or 0):
        vectors = vector_count_from_name(path)
        if vectors is None:
            continue
        exit_code, rss_mb = parse_time_file(path)
        rows.append((f"{path.stem}.dat", vectors, exit_code, rss_mb))

    if not rows:
        existing = results_dir / "similarity_rss.csv"
        return existing if existing.exists() else None

    out = results_dir / "similarity_rss.csv"
    with out.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Dataset", "Vectors", "Exit Code", "Peak Memory MB", "Peak Memory Raw"])
        for dataset, vectors, exit_code, rss_mb in rows:
            writer.writerow(
                [
                    dataset,
                    vectors,
                    "" if exit_code is None else exit_code,
                    "" if rss_mb is None else f"{rss_mb:.3f}",
                    "" if rss_mb is None else f"{rss_mb:.3f}MB",
                ]
            )
    return out


def first_failure(results_dir: Path) -> int | None:
    failure_csv = results_dir / "resident_failure.csv"
    if failure_csv.exists():
        with failure_csv.open(newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                vectors = row.get("Vectors")
                if vectors:
                    return int(vectors)

    for path in sorted(results_dir.glob("2_*.time"), key=lambda p: vector_count_from_name(p) or 0):
        vectors = vector_count_from_name(path)
        exit_code, _ = parse_time_file(path)
        if vectors is not None and exit_code not in (None, 0):
            return vectors
    return None


def measured_vectors(latency_csv: Path | None) -> list[int]:
    if latency_csv is None or not latency_csv.exists():
        return []
    rows = plot_scaling.read_hydia_similarity(latency_csv)
    targets = set(plot_scaling.DEFAULT_TARGETS)
    return sorted(v for v in rows if v in targets)


def power_of_two_label(vectors: int) -> str:
    if vectors > 0 and vectors & (vectors - 1) == 0:
        return rf"$2^{{{vectors.bit_length() - 1}}}$"
    return plot_scaling.tick_label(vectors)


def million_label(vectors: int) -> str:
    return f"{vectors / 1_000_000:.1f}M"


def artifact_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ARTIFACT_ROOT))
    except ValueError:
        return str(path)


def write_pending_snippet(path: Path, reason: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "% Generated by baselines/hydia/prepare_paper_outputs.py\n"
        "% HYDIA_RESIDENT_RESULTS_PENDING\n"
        f"% {reason}\n"
    )


def write_figure_snippet(
    path: Path,
    include_memory: bool,
    measured: list[int],
    source_label: str,
    draft_note: str | None,
    failure_vectors: int | None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    source_comment = f"% HYDIA_SOURCE_NOTE: {draft_note}\n" if draft_note else ""

    if include_memory:
        body = rf"""\begin{{figure}}[!t]
\centering
\includegraphics[width=\linewidth]{{figures/hydia_scaling_512.pdf}}
\caption{{Resa and HyDia score-path scaling.}}
\Description{{Two compact log-scale line plots compare Resa and HyDia score latency and memory as database size grows. Resa latency comes from the PM9A3-anchored storage-stream model and RTL cycle counts; Resa memory is the host result-ciphertext array after SSD-controller DMA writeback, while HyDia memory is measured resident-set size.}}
\label{{fig:hydia-scaling-512}}
\end{{figure}}
"""
    else:
        body = rf"""\begin{{figure}}[!t]
\centering
\includegraphics[width=\linewidth]{{figures/hydia_latency_scaling_512.pdf}}
\caption{{Resa and HyDia score-path latency scaling.}}
\Description{{A log-scale line plot compares Resa and HyDia score latency as database size grows. HyDia is plotted over resident measurements.}}
\label{{fig:hydia-scaling-512}}
\end{{figure}}
"""
    body = body.replace("SOURCE_LABEL", source_label)
    path.write_text(
        "% Generated by baselines/hydia/prepare_paper_outputs.py\n"
        + source_comment
        + body
    )


def copy_if_exists(src: Path, dst: Path) -> bool:
    if not src.exists():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return True


def write_scaling_provenance(
    path: Path,
    *,
    rows: list[plot_scaling.Row],
    args: argparse.Namespace,
    latency_csv: Path | None,
    rss_csv: Path | None,
    failure_vectors: int | None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    def find(system: str, vectors: int) -> plot_scaling.Row | None:
        return next((row for row in rows if row.system == system and row.vectors == vectors), None)

    csd_23 = find("Resa", 2**23)
    csd_24 = find("Resa", 2**24)
    hydia_23 = find("HyDia", 2**23)
    payload = {
        "schema_version": 1,
        "figure": "hydia_scaling_512",
        "dimension": args.dimension,
        "csd_csv": artifact_path(args.csd_csv),
        "hydia_latency_csv": None if latency_csv is None else artifact_path(latency_csv),
        "hydia_rss_csv": None if rss_csv is None else artifact_path(rss_csv),
        "hydia_failure_vectors": failure_vectors,
        "boundary": (
            "Resa rows are imported from the PM9A3-anchored storage-stream model and RTL cycle counts. "
            "HyDia rows are measured resident score-path rows."
        ),
        "key_rows": {
            "csd_2^23_s": None if csd_23 is None else csd_23.seconds,
            "csd_2^24_s": None if csd_24 is None else csd_24.seconds,
            "hydia_2^23_s": None if hydia_23 is None else hydia_23.seconds,
            "csd_2^23_host_result_memory_mb": None if csd_23 is None else csd_23.memory_mb,
            "csd_2^24_host_result_memory_mb": None if csd_24 is None else csd_24.memory_mb,
            "hydia_2^23_peak_rss_mb": None if hydia_23 is None else hydia_23.memory_mb,
            "speedup_at_2^23": (
                None
                if csd_23 is None or hydia_23 is None
                else hydia_23.seconds / csd_23.seconds
            ),
        },
    }
    path.write_text(json.dumps(payload, indent=2))


def materialize(args: argparse.Namespace) -> None:
    results_dir = args.results_dir.resolve()
    paper_dir = args.paper_dir.resolve()
    paper_snippet = paper_dir / "generated" / "hydia_scaling.tex"

    latency_csv = combine_latency(results_dir)
    rss_csv = repair_rss(results_dir)
    measured = measured_vectors(latency_csv)
    if not measured:
        write_pending_snippet(paper_snippet, "No valid HyDia latency rows are available yet.")
        print(f"wrote pending snippet {paper_snippet}")
        return

    latency_svg = results_dir / "latency_scaling_512.svg"
    memory_svg = results_dir / "memory_scaling_512.svg"
    compact_svg = results_dir / "scaling_compact_512.svg"
    out_csv = results_dir / "scaling_512.csv"

    plot_args = argparse.Namespace(
        hydia_csv=latency_csv,
        rss_csv=rss_csv,
        out_csv=out_csv,
        out_svg=latency_svg,
        out_memory_svg=memory_svg,
        out_compact_svg=compact_svg,
        targets=plot_scaling.DEFAULT_TARGETS,
        dimension=args.dimension,
        include_csd=True,
        csd_csv=args.csd_csv,
    )
    plot_scaling.MEASUREMENT_LABEL = args.measurement_label
    plot_scaling.RSS_LABEL = args.rss_label
    rows = plot_scaling.build_rows(plot_args)
    plot_scaling.write_csv(out_csv, rows)
    plot_scaling.plot_latency(rows, latency_svg)
    plot_scaling.plot_memory(rows, memory_svg)
    failure_vectors = first_failure(results_dir)
    plot_scaling.plot_compact(rows, compact_svg, failure_vectors=failure_vectors)
    plot_scaling.write_captions(results_dir, rows)
    write_scaling_provenance(
        results_dir / "scaling_512_provenance.json",
        rows=rows,
        args=args,
        latency_csv=latency_csv,
        rss_csv=rss_csv,
        failure_vectors=failure_vectors,
    )

    figures_dir = paper_dir / "figures"
    copy_if_exists(latency_svg.with_suffix(".pdf"), figures_dir / "hydia_latency_scaling_512.pdf")
    copy_if_exists(latency_svg, figures_dir / "hydia_latency_scaling_512.svg")
    have_memory = copy_if_exists(memory_svg.with_suffix(".pdf"), figures_dir / "hydia_memory_scaling_512.pdf")
    copy_if_exists(memory_svg, figures_dir / "hydia_memory_scaling_512.svg")
    copy_if_exists(compact_svg.with_suffix(".pdf"), figures_dir / "hydia_scaling_512.pdf")
    copy_if_exists(compact_svg, figures_dir / "hydia_scaling_512.svg")
    write_figure_snippet(
        paper_snippet,
        have_memory,
        measured,
        args.snippet_source_label,
        args.draft_note,
        failure_vectors,
    )
    print(f"wrote {out_csv}")
    print(f"wrote {paper_snippet}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", type=Path, default=Path("results/resident-real-260529"))
    parser.add_argument("--paper-dir", type=Path, default=Path("paper-tree"))
    parser.add_argument("--dimension", type=int, default=512)
    parser.add_argument("--csd-csv", type=Path, default=DEFAULT_CSD_CSV)
    parser.add_argument("--measurement-label", default="resident run")
    parser.add_argument("--rss-label", default="peak resident-set size")
    parser.add_argument("--snippet-source-label", default="resident run")
    parser.add_argument("--draft-note", default=None)
    materialize(parser.parse_args())


if __name__ == "__main__":
    main()
