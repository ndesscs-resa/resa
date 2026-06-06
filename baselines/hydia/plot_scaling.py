#!/usr/bin/env python3
"""Build 512D HyDia/CSD scaling tables and publication-style figures."""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_TARGETS = [2**exp for exp in range(12, 28)]
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CSD_CSV = (
    SCRIPT_DIR
    / "../../storage_validation/results/pm9a3-csd-scaling-hydia512-simplessdseq-260530/scaling_512.csv"
).resolve()
REQUIRED_CSD_STATUS = "simplessd_integrated"
RESA_LABEL = "Resa"


@dataclass
class Row:
    system: str
    dimension: int
    vectors: int
    mode: str
    status: str
    measured: bool
    seconds: float
    throughput: float
    memory_mb: float | None
    memory_basis: str
    marker: str
    line: str

    def to_csv(self) -> dict[str, str]:
        return {
            "System": self.system,
            "Dimension": str(self.dimension),
            "Vectors": str(self.vectors),
            "Mode": self.mode,
            "Status": self.status,
            "Measured": "true" if self.measured else "false",
            "Seconds": f"{self.seconds:.9g}",
            "Throughput vectors/s": f"{self.throughput:.9g}",
            "Memory MB": "" if self.memory_mb is None else f"{self.memory_mb:.4f}",
            "Memory Basis": self.memory_basis,
            "Marker": self.marker,
            "Line": self.line,
        }


def parse_targets(value: str) -> list[int]:
    return [int(part) for part in value.replace(",", " ").split()]


def read_hydia_similarity(path: Path) -> dict[int, float]:
    rows: dict[int, float] = {}
    paths = [path]
    paths.extend(sorted(path.parent.glob("*.similarity_latency.csv")))
    for current_path in paths:
        if not current_path.exists():
            continue
        with current_path.open(newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                vectors_raw = row.get("Database Size (vectors)", "")
                seconds_raw = row.get("Similarity Computation (seconds)", "")
                if not vectors_raw or not seconds_raw:
                    continue
                try:
                    vectors = int(vectors_raw)
                    seconds = float(seconds_raw)
                except ValueError:
                    continue
                rows.setdefault(vectors, seconds)
    if not rows:
        raise ValueError(f"no HyDia rows found in {path}")
    return rows


def read_rss(path: Path | None) -> dict[int, float]:
    if path is None or not path.exists():
        return {}
    rows: dict[int, float] = {}
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            vectors = row.get("Vectors") or row.get("Database Size (vectors)")
            rss = row.get("Peak Memory MB")
            if not vectors or not rss:
                continue
            try:
                rss_mb = float(rss)
            except ValueError:
                continue
            if rss_mb > 0:
                rows[int(vectors)] = rss_mb
    return rows


def read_csd_scaling(path: Path, targets: set[int], dimension: int) -> list[Row]:
    rows: list[Row] = []
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            system = raw.get("System", "")
            if system and system != "CSD":
                continue
            vectors = int(raw["Vectors"])
            row_dim = int(raw.get("Dimension") or dimension)
            if vectors not in targets or row_dim != dimension:
                continue
            status = raw.get("Status") or REQUIRED_CSD_STATUS
            if status != REQUIRED_CSD_STATUS:
                raise ValueError(
                    f"CSD row {vectors} in {path} has status={status!r}; "
                    f"expected {REQUIRED_CSD_STATUS!r}"
                )
            seconds = float(raw["Seconds"])
            memory_raw = (
                raw.get("Host Result Memory MB")
                or raw.get("Memory MB")
                or raw.get("Peak Memory MB", "")
            )
            memory_basis = raw.get("Memory Basis") or "CSD model memory"
            rows.append(
                Row(
                    system=RESA_LABEL,
                    dimension=row_dim,
                    vectors=vectors,
                    mode=raw.get("Mode") or "storage-resident",
                    status=status,
                    measured=(raw.get("Measured", "").lower() == "true"),
                    seconds=seconds,
                    throughput=float(raw.get("Throughput vectors/s") or vectors / seconds),
                    memory_mb=float(memory_raw) if memory_raw else None,
                    memory_basis=memory_basis,
                    marker=raw.get("Marker") or "square",
                    line=raw.get("Line") or "solid",
                )
            )
    if not rows:
        raise ValueError(f"no CSD rows for dimension={dimension} in {path}")
    return sorted(rows, key=lambda row: row.vectors)


def build_rows(args: argparse.Namespace) -> list[Row]:
    hydia = read_hydia_similarity(args.hydia_csv)
    rss = read_rss(args.rss_csv)
    targets = sorted(set(args.targets))
    min_target = targets[0]
    target_set = set(targets)
    measured_targets = sorted(v for v in hydia if v in target_set and v >= min_target)
    if not measured_targets:
        raise ValueError(f"no HyDia rows overlap requested targets: {targets}")

    rows: list[Row] = []
    for vectors, seconds in sorted(hydia.items()):
        if vectors < min_target or vectors not in target_set:
            continue
        rows.append(
            Row(
                system="HyDia",
                dimension=args.dimension,
                vectors=vectors,
                mode="resident",
                status="resident_measured",
                measured=True,
                seconds=seconds,
                throughput=vectors / seconds,
                memory_mb=rss.get(vectors),
                memory_basis="measured peak resident set size",
                marker="filled",
                line="solid",
            )
        )

    if args.include_csd:
        csd_csv = getattr(args, "csd_csv", None)
        if csd_csv is None:
            raise ValueError("--csd-csv is required when CSD rows are included")
        rows.extend(read_csd_scaling(Path(csd_csv), target_set, args.dimension))
    return sorted(rows, key=lambda row: (row.system, row.mode, row.vectors))


def write_csv(path: Path, rows: Iterable[Row]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = list(rows)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].to_csv().keys()))
        writer.writeheader()
        for row in rows:
            writer.writerow(row.to_csv())


def require_pyplot():
    try:
        import matplotlib

        matplotlib.use("Agg")
        matplotlib.rcParams.update(
            {
                "font.family": "serif",
                "font.serif": [
                    "Times New Roman",
                    "Liberation Serif",
                    "Times",
                    "Nimbus Roman",
                    "serif",
                ],
                "mathtext.fontset": "stix",
                "pdf.fonttype": 42,
                "ps.fonttype": 42,
                "svg.fonttype": "none",
                "axes.unicode_minus": False,
            }
        )
        import matplotlib.pyplot as plt
        from matplotlib.lines import Line2D
        from matplotlib.ticker import FixedLocator, FuncFormatter, LogLocator
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "matplotlib is required for figure generation. "
            "Use the HyDia artifact container/venv or a Python environment with matplotlib."
        ) from exc
    return plt, Line2D, FixedLocator, FuncFormatter, LogLocator


def split_rows(rows: list[Row]) -> tuple[list[Row], list[Row]]:
    csd = sorted([row for row in rows if row.system in ("CSD", RESA_LABEL)], key=lambda row: row.vectors)
    hydia_measured = sorted(
        [row for row in rows if row.system == "HyDia"],
        key=lambda row: row.vectors,
    )
    return csd, hydia_measured


def vector_ticks(rows: list[Row]) -> list[int]:
    return sorted({row.vectors for row in rows if row.vectors in DEFAULT_TARGETS})


def compact_vector_ticks(rows: list[Row]) -> list[int]:
    ticks = []
    for value in vector_ticks(rows):
        exp = round(math.log2(value))
        if 2**exp == value and exp % 2 == 0:
            ticks.append(value)
    return ticks


def summary_vector_ticks(rows: list[Row]) -> list[int]:
    available = set(vector_ticks(rows))
    return [value for value in (2**12, 2**17, 2**22, 2**27) if value in available]


def tick_label(vectors: int) -> str:
    if vectors >= 1_048_576 and vectors % 1_048_576 == 0:
        return f"{vectors // 1_048_576}M"
    if vectors >= 1_000_000:
        return f"{vectors / 1_000_000:.0f}M"
    if vectors >= 1_000:
        if vectors < 1_000_000 and vectors % 1024 == 0:
            return f"{vectors // 1024}K"
        return f"{vectors / 1_000:.0f}K"
    return str(vectors)


def style_axis(ax) -> None:
    from matplotlib.ticker import NullLocator

    ax.grid(False)
    ax.minorticks_off()
    ax.xaxis.set_minor_locator(NullLocator())
    ax.yaxis.set_minor_locator(NullLocator())
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    for spine in ("left", "bottom"):
        ax.spines[spine].set_color("#444444")
        ax.spines[spine].set_linewidth(0.7)
    ax.tick_params(axis="both", which="major", labelsize=7.2, length=0, width=0, pad=1.8)
    ax.tick_params(axis="both", which="minor", length=0, width=0)


def seconds_label(value: float) -> str:
    if value <= 0:
        return ""
    if value < 1:
        return f"{value * 1000:g} ms"
    return f"{value:g} s"


def pow10_label(value: float) -> str:
    if value <= 0:
        return ""
    exponent = round(math.log10(value))
    if math.isclose(value, 10**exponent, rel_tol=1e-9, abs_tol=1e-12):
        return rf"$10^{{{exponent}}}$"
    return ""


def mb_to_gb(value: float) -> float:
    return value / 1000.0


def gb_label(value: float) -> str:
    if value <= 0:
        return ""
    if value < 1:
        mb = value * 1000.0
        if mb < 1:
            return f"{mb:.1g} MB"
        return f"{mb:g} MB"
    return f"{value:g} GB"


def save_figure(fig, out_svg: Path, pad_inches: float = 0.0) -> None:
    out_svg.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_svg, format="svg", bbox_inches="tight", pad_inches=pad_inches)
    fig.savefig(out_svg.with_suffix(".pdf"), format="pdf", bbox_inches="tight", pad_inches=pad_inches)


def plot_latency(rows: list[Row], out_svg: Path) -> None:
    plt, Line2D, FixedLocator, FuncFormatter, LogLocator = require_pyplot()
    csd, hydia_measured = split_rows(rows)
    if not hydia_measured:
        raise ValueError("HyDia measured rows are required")

    blue = "#2457a6"
    red = "#a23b3b"
    fig, ax = plt.subplots(figsize=(3.35, 2.15))
    fig.subplots_adjust(left=0.20, right=0.99, top=0.96, bottom=0.28)
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    style_axis(ax)

    ax.plot(
        [row.vectors for row in csd],
        [row.seconds for row in csd],
        color=blue,
        linewidth=2.2,
        marker="s",
        markersize=4.6,
    )
    ax.plot(
        [row.vectors for row in hydia_measured],
        [row.seconds for row in hydia_measured],
        color=red,
        linewidth=2.2,
        marker="o",
        markersize=5.0,
    )

    ticks = compact_vector_ticks(rows)
    ax.set_xticks(ticks)
    ax.set_xticklabels([tick_label(tick) for tick in ticks], rotation=45, ha="right")
    ax.set_xlim(min(vector_ticks(rows)), max(vector_ticks(rows)))
    ax.yaxis.set_major_locator(LogLocator(base=10))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _pos: seconds_label(value)))
    ax.set_xlabel("Database size (vectors)")
    ax.set_ylabel("Score latency (s)")

    legend_handles = [
        Line2D([0], [0], color=blue, marker="s", linewidth=2.2, markersize=5, label=RESA_LABEL),
        Line2D([0], [0], color=red, marker="o", linewidth=2.2, markersize=5, label="HyDia"),
    ]
    ax.legend(handles=legend_handles, loc="upper left", frameon=False, fontsize=8.0)
    save_figure(fig, out_svg)
    plt.close(fig)


def plot_memory(rows: list[Row], out_svg: Path) -> None:
    plt, Line2D, FixedLocator, FuncFormatter, LogLocator = require_pyplot()
    csd, hydia_measured = split_rows(rows)
    hydia_measured = [row for row in hydia_measured if row.memory_mb is not None]
    if not hydia_measured:
        return

    blue = "#2457a6"
    red = "#a23b3b"
    fig, ax = plt.subplots(figsize=(3.35, 2.15))
    fig.subplots_adjust(left=0.20, right=0.99, top=0.96, bottom=0.28)
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    style_axis(ax)

    ax.plot(
        [row.vectors for row in csd],
        [row.memory_mb for row in csd],
        color=blue,
        linewidth=2.2,
        marker="s",
        markersize=4.6,
    )
    ax.plot(
        [row.vectors for row in hydia_measured],
        [row.memory_mb for row in hydia_measured],
        color=red,
        linewidth=2.2,
        marker="o",
        markersize=5.0,
    )

    ticks = compact_vector_ticks(rows)
    ax.set_xticks(ticks)
    ax.set_xticklabels([tick_label(tick) for tick in ticks], rotation=45, ha="right")
    ax.set_xlim(min(vector_ticks(rows)), max(vector_ticks(rows)))
    ax.yaxis.set_major_locator(LogLocator(base=10))
    ax.set_xlabel("Database size (vectors)")
    ax.set_ylabel("Memory (MB)")

    legend_handles = [
        Line2D([0], [0], color=blue, marker="s", linewidth=2.2, markersize=5, label=RESA_LABEL),
        Line2D([0], [0], color=red, marker="o", linewidth=2.2, markersize=5, label="HyDia"),
    ]
    ax.legend(handles=legend_handles, loc="upper left", frameon=False, fontsize=8.0)
    save_figure(fig, out_svg)
    plt.close(fig)


def plot_compact(rows: list[Row], out_svg: Path, failure_vectors: int | None = None) -> None:
    plt, Line2D, FixedLocator, FuncFormatter, LogLocator = require_pyplot()
    csd, hydia_measured = split_rows(rows)
    hydia_memory = [row for row in hydia_measured if row.memory_mb is not None]
    if not hydia_measured or not hydia_memory:
        return

    blue = "#2457a6"
    red = "#a23b3b"
    fig, (ax_latency, ax_memory) = plt.subplots(1, 2, figsize=(3.35, 1.30), sharex=False)
    fig.subplots_adjust(left=0.17, right=0.995, top=0.995, bottom=0.27, wspace=0.64)

    for ax in (ax_latency, ax_memory):
        ax.set_xscale("log", base=2)
        ax.set_yscale("log")
        style_axis(ax)

    ax_latency.plot(
        [row.vectors for row in csd],
        [row.seconds for row in csd],
        color=blue,
        linewidth=1.45,
        marker="s",
        markersize=1.9,
        markeredgewidth=0.45,
    )
    ax_latency.plot(
        [row.vectors for row in hydia_measured],
        [row.seconds for row in hydia_measured],
        color=red,
        linewidth=1.45,
        marker="o",
        markersize=2.0,
        markeredgewidth=0.45,
    )
    ax_latency.set_ylabel("Latency (s)", fontsize=7.8, labelpad=2.4)
    ax_latency.yaxis.set_major_locator(FixedLocator([1e-3, 1e-2, 1e-1, 1, 10, 100]))
    ax_latency.yaxis.set_major_formatter(FuncFormatter(lambda value, _pos: pow10_label(value)))
    latency_max = max(row.seconds for row in hydia_measured + csd)
    latency_min = min(row.seconds for row in hydia_measured + csd)
    ax_latency.set_ylim(latency_min / 2.0, latency_max * 4.0)

    ax_memory.plot(
        [row.vectors for row in csd],
        [mb_to_gb(row.memory_mb) for row in csd],
        color=blue,
        linewidth=1.45,
        marker="s",
        markersize=1.9,
        markeredgewidth=0.45,
    )
    ax_memory.plot(
        [row.vectors for row in hydia_memory],
        [mb_to_gb(row.memory_mb) for row in hydia_memory],
        color=red,
        linewidth=1.45,
        marker="o",
        markersize=2.0,
        markeredgewidth=0.45,
    )
    ax_memory.set_ylabel("Memory", fontsize=7.8, labelpad=2.4)
    ax_memory.yaxis.set_major_locator(FixedLocator([1e-4, 1e-2, 1, 100]))
    ax_memory.yaxis.set_major_formatter(FuncFormatter(lambda value, _pos: gb_label(value)))
    memory_values = [mb_to_gb(row.memory_mb) for row in hydia_memory + csd]
    ax_memory.set_ylim(min(memory_values) / 2.0, max(80.0, max(memory_values) * 1.45))

    ticks = summary_vector_ticks(rows)
    x_values = vector_ticks(rows)
    x_pad = 2 ** 0.28
    for ax in (ax_latency, ax_memory):
        ax.set_xticks(ticks)
        ax.set_xticklabels([tick_label(tick) for tick in ticks])
        ax.set_xlim(min(x_values) / x_pad, max(x_values) * x_pad)
        ax.set_xlabel("Database size", fontsize=7.8, labelpad=2.2)

    legend_handles = [
        Line2D([0], [0], color=blue, marker="s", linewidth=1.45, markersize=2.2, label=RESA_LABEL),
        Line2D([0], [0], color=red, marker="o", linewidth=1.45, markersize=2.2, label="HyDia"),
    ]
    ax_latency.legend(
        handles=legend_handles,
        loc="lower left",
        bbox_to_anchor=(0.02, 1.01),
        frameon=False,
        fontsize=7.2,
        ncol=1,
        handlelength=1.1,
        labelspacing=0.12,
        borderaxespad=0.0,
    )
    save_figure(fig, out_svg, pad_inches=-0.012)
    plt.close(fig)


MEASUREMENT_LABEL = "resident run"
RSS_LABEL = "peak resident-set size"


def write_captions(out_dir: Path, rows: list[Row]) -> None:
    _, hydia_measured = split_rows(rows)
    measured_min = tick_label(hydia_measured[0].vectors)
    measured_max = tick_label(hydia_measured[-1].vectors)
    captions = f"""Latency scaling caption:
512D score latency as database size increases. Resa is the storage-resident
PM9A3-anchored model using the selected storage profile. HyDia
points are resident score-path measurements from {MEASUREMENT_LABEL}
over {measured_min}--{measured_max}.

Memory scaling caption:
Memory scaling for the same 512D setting. HyDia resident points use
{RSS_LABEL}. Resa reports the host memory occupied by result ciphertexts
after SSD-controller DMA writeback.
"""
    (out_dir / "scaling_512_captions.txt").write_text(captions)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hydia-csv", type=Path, default=Path("results/similarity_latency.csv"))
    parser.add_argument("--rss-csv", type=Path, default=Path("results/similarity_rss.csv"))
    parser.add_argument("--out-csv", type=Path, default=Path("results/scaling_512.csv"))
    parser.add_argument("--out-svg", type=Path, default=Path("results/latency_scaling_512.svg"))
    parser.add_argument("--out-memory-svg", type=Path, default=Path("results/memory_scaling_512.svg"))
    parser.add_argument("--out-compact-svg", type=Path, default=Path("results/scaling_compact_512.svg"))
    parser.add_argument("--targets", type=parse_targets, default=DEFAULT_TARGETS)
    parser.add_argument("--dimension", type=int, default=512)
    parser.add_argument("--include-csd", action="store_true", default=True)
    parser.add_argument("--no-csd", dest="include_csd", action="store_false")
    parser.add_argument("--csd-csv", type=Path, default=DEFAULT_CSD_CSV)
    parser.add_argument("--measurement-label", default="resident run")
    parser.add_argument("--rss-label", default="peak resident-set size")
    args = parser.parse_args()

    global MEASUREMENT_LABEL, RSS_LABEL
    MEASUREMENT_LABEL = args.measurement_label
    RSS_LABEL = args.rss_label

    rows = build_rows(args)
    write_csv(args.out_csv, rows)
    plot_latency(rows, args.out_svg)
    plot_memory(rows, args.out_memory_svg)
    plot_compact(rows, args.out_compact_svg)
    write_captions(args.out_csv.parent, rows)
    print(f"wrote {args.out_csv}")
    print(f"wrote {args.out_svg}")
    print(f"wrote {args.out_svg.with_suffix('.pdf')}")
    if args.out_memory_svg.exists():
        print(f"wrote {args.out_memory_svg}")
        print(f"wrote {args.out_memory_svg.with_suffix('.pdf')}")
    if args.out_compact_svg.exists():
        print(f"wrote {args.out_compact_svg}")
        print(f"wrote {args.out_compact_svg.with_suffix('.pdf')}")


if __name__ == "__main__":
    main()
