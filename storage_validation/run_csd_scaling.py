#!/usr/bin/env python3
"""Generate CSD scaling rows from the selected SimpleSSD-integrated model."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

import run_csd_integrated as integrated
import simulate_csd_e2e as e2e


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = (
    SCRIPT_DIR
    / "results"
    / "pm9a3-csd-scaling-hydia512-simplessdseq-260530"
)
DEFAULT_PROFILE_MANIFEST = SCRIPT_DIR / "profiles" / "pm9a3-memory-prior-selected.json"
DEFAULT_TARGETS = [2**exp for exp in range(12, 28)]
MB = 1_000_000.0
HOST_RESULT_MEMORY_BASIS = (
    "host result ciphertext array; one result ciphertext per storage group"
)


def parse_targets(value: str) -> list[int]:
    values: list[int] = []
    for part in value.replace(",", " ").split():
        if part.startswith("2^"):
            values.append(2 ** int(part[2:]))
        else:
            values.append(int(part))
    return values


def run_one(
    *,
    vectors: int,
    dim: int,
    stream: dict[str, Any],
    datapath_profile: Path,
    csd_input_bw_mb_s: float,
    csd_input_source: str,
    buffer_groups: int,
    overlap_input_compute: bool,
) -> dict[str, Any]:
    config = e2e.DatapathConfig.from_json(datapath_profile)
    config.db.n_vectors = vectors
    config.db.embedding_dim = dim

    layout = e2e.DataLayout(config)
    compute = e2e.compute_group_timing(config)
    writeback = e2e.writeback_timing(config)

    group_bytes = layout.total_db_bytes / config.db.n_groups
    storage_to_stream_s = group_bytes / stream["bw_bytes_s"]
    csd_input_s = group_bytes / (csd_input_bw_mb_s * MB)
    compute_s = compute.total_time_us / 1_000_000.0
    writeback_s = writeback.total_time_us / 1_000_000.0
    result_ciphertexts = config.db.n_groups
    host_result_memory_mb = result_ciphertexts * config.writeback.result_bytes / MB

    pipe = integrated.bounded_pipeline(
        n_groups=config.db.n_groups,
        storage_to_stream_s=storage_to_stream_s,
        csd_input_s=csd_input_s,
        compute_s=compute_s,
        writeback_s=writeback_s,
        buffer_groups=buffer_groups,
        overlap_input_compute=overlap_input_compute,
        trace_groups=0,
    )

    csd_group_s = pipe["csd_group_ms"] / 1000.0
    return {
        "System": "CSD",
        "Dimension": dim,
        "Vectors": vectors,
        "Mode": "storage-resident",
        "Status": "simplessd_integrated",
        "Measured": "false",
        "Seconds": pipe["e2e_latency_s"],
        "Throughput vectors/s": vectors / pipe["e2e_latency_s"],
        "Host Result Memory MB": host_result_memory_mb,
        "Memory Basis": HOST_RESULT_MEMORY_BASIS,
        "Result Ciphertexts": result_ciphertexts,
        "Result Ciphertext Bytes": config.writeback.result_bytes,
        "Marker": "square",
        "Line": "solid",
        "Simulation Source": stream["source"],
        "Stream BW MB/s": stream["bw_mb_s"],
        "CSD Input BW MB/s": csd_input_bw_mb_s,
        "CSD Input Source": csd_input_source,
        "Groups": config.db.n_groups,
        "DB Size GB": layout.total_db_gb_decimal,
        "Group Bytes MB": group_bytes / MB,
        "Storage Group ms": storage_to_stream_s * 1000.0,
        "CSD Input ms": csd_input_s * 1000.0,
        "CSD Compute ms": compute.total_time_us / 1000.0,
        "Writeback us": writeback.total_time_us,
        "Storage Only s": storage_to_stream_s * config.db.n_groups,
        "Bottleneck": integrated.bottleneck(storage_to_stream_s, csd_group_s),
    }


def load_profile(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"profile manifest not found: {path}")
    return json.loads(path.read_text())


def validate_selected_profile(
    *,
    profile: dict[str, Any],
    candidate: str,
    workload: str,
    stream_source: str,
    row: dict[str, str] | None,
    measured: dict[str, str] | None,
) -> list[str]:
    warnings: list[str] = []
    if profile.get("candidate") != candidate:
        raise SystemExit(
            f"profile candidate {profile.get('candidate')!r} does not match --candidate {candidate!r}"
        )

    validation = profile.get("validation", {}).get("rows", {})
    expected = validation.get(workload)
    if expected is None:
        warnings.append(f"workload {workload!r} is not listed in the selected profile validation rows")
    elif row is not None:
        sim_bw = float(row["sim_bw_mb_s"])
        expected_bw = float(expected["simplessd_mb_s"])
        if abs(sim_bw - expected_bw) > 1e-3:
            raise SystemExit(
                f"SimpleSSD row mismatch for {workload}: CSV has {sim_bw}, profile has {expected_bw}"
            )
    if row is None and stream_source == "simplessd_seq":
        raise SystemExit("submission simplessd_seq scaling requires a selected SimpleSSD row")
    if measured is None:
        warnings.append(f"physical validation row for {workload!r} was not found")
    return warnings


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(rows[0].keys())
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_readme(
    path: Path,
    args: argparse.Namespace,
    rows: list[dict[str, Any]],
    stream: dict[str, Any],
    profile: dict[str, Any],
    row: dict[str, str] | None,
    measured: dict[str, str] | None,
    warnings: list[str],
) -> None:
    row_23 = next((row for row in rows if int(row["Vectors"]) == 2**23), rows[-1])
    row_24 = next((row for row in rows if int(row["Vectors"]) == 2**24), None)
    boundary = profile.get("boundary", "PM9A3-class SimpleSSD-selected storage profile")
    lines = [
        "# PM9A3 SimpleSSD-Integrated CSD Scaling",
        "",
        "## Summary",
        "",
        "This directory contains the CSD curve used in the HyDia scaling figure.",
        "Each CSD point connects the selected PM9A3-class SimpleSSD sequential-read stream to the fixed-function Resa pipeline.",
        "The CSD rows are deterministic integrated simulation rows.",
        "For each corpus size, the script reuses the selected SimpleSSD validation row as the storage producer and recomputes the CSD pipeline schedule.",
        f"Scope: {boundary}",
        "",
        "## Configuration",
        "",
        f"- Profile manifest: `{e2e.artifact_path(args.profile_manifest)}`",
        f"- Datapath profile: `{e2e.artifact_path(args.datapath_profile)}`",
        f"- Candidate: `{args.candidate}`",
        f"- Workload anchor: `{args.workload}`",
        f"- Stream source: `{stream['source']}`",
        f"- Stream bandwidth: `{stream['bw_mb_s']:.3f} MB/s`",
        f"- Dimension: `{args.dim}`",
        f"- Resa input source: `{args.csd_input_source}`",
        f"- Buffer groups: `{args.buffer_groups}`",
        f"- Result ciphertext bytes: `{rows[0]['Result Ciphertext Bytes']}`",
        f"- Result memory model: `{rows[0]['Memory Basis']}`",
        "",
        "## Source Rows",
        "",
        "| Row | Value |",
        "|---|---:|",
    ]
    if row is not None:
        lines.extend(
            [
                f"| SimpleSSD BW | {float(row['sim_bw_mb_s']):.3f} MB/s |",
                f"| SimpleSSD mean latency | {float(row['sim_clat_mean_us']):.3f} us |",
            ]
        )
    if measured is not None:
        lines.extend(
            [
                f"| Physical PM9A3 holdout BW | {float(measured['bw_mb_s']):.3f} MB/s |",
                f"| Physical PM9A3 holdout mean latency | {float(measured['clat_mean_us']):.3f} us |",
            ]
        )
    lines.extend(
        [
            f"| Raw parameter page BW | {stream['raw_page_bw_mb_s']:.3f} MB/s |",
            f"| Stream efficiency vs raw page model | {stream['efficiency_vs_raw']:.3f} |",
        "",
        "## Key Rows",
        "",
        f"- `2^23` vectors: `{float(row_23['Seconds']):.6f}s`, `{float(row_23['Host Result Memory MB']):.1f} MB` host result ciphertext memory.",
        ]
    )
    if row_24 is not None:
        lines.append(
            f"- `2^24` vectors: `{float(row_24['Seconds']):.6f}s`, "
            f"`{float(row_24['Host Result Memory MB']):.1f} MB` host result ciphertext memory."
        )
    lines.extend(
        [
            "",
            "## Scope Notes",
            "",
            "- Selected PM9A3-class SimpleSSD storage profile.",
            "- Fixed-function Resa datapath timing profile.",
            "- Physical fio rows used as validation anchors for the selected storage row.",
            "- Host memory counted as result ciphertext array storage after writeback.",
            "",
            "## Files",
            "",
            "- `scaling_512.csv`: CSD rows consumed by `baselines/hydia/prepare_paper_outputs.py`.",
            "- `summary.json`: provenance summary for the generated scaling rows.",
            "",
        ]
    )
    if warnings:
        lines.extend(["## Warnings", ""])
        lines.extend(f"- {warning}" for warning in warnings)
        lines.append("")
    path.write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary-csv", type=Path, default=integrated.DEFAULT_SUMMARY_CSV)
    parser.add_argument("--measured-csv", type=Path, default=integrated.DEFAULT_MEASURED_CSV)
    parser.add_argument("--config-dir", type=Path, default=integrated.DEFAULT_CONFIG_DIR)
    parser.add_argument("--profile-manifest", type=Path, default=DEFAULT_PROFILE_MANIFEST)
    parser.add_argument("--candidate", default=integrated.DEFAULT_CANDIDATE)
    parser.add_argument("--workload", default=integrated.DEFAULT_WORKLOAD)
    parser.add_argument("--datapath-profile", type=Path, default=integrated.DEFAULT_DATAPATH_PROFILE)
    parser.add_argument("--targets", type=parse_targets, default=DEFAULT_TARGETS)
    parser.add_argument("--dim", type=int, default=512)
    parser.add_argument(
        "--stream-source",
        choices=["measured_seq", "simplessd_seq", "parameter_raw"],
        default="simplessd_seq",
    )
    parser.add_argument("--raw-efficiency", type=float, default=None)
    parser.add_argument(
        "--csd-input-source",
        choices=["axis", "strict_sram", "fixed"],
        default="axis",
    )
    parser.add_argument("--csd-input-bandwidth-mb-s", type=float, default=None)
    parser.add_argument("--buffer-groups", type=int, default=3)
    parser.add_argument("--serialize-input-compute", action="store_true")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    config_path = args.config_dir / f"{args.candidate}.ssd.xml"
    if not config_path.exists():
        raise SystemExit(f"SimpleSSD config not found: {config_path}")

    params = e2e.parse_candidate_config(config_path)
    row = e2e.parse_simplessd_row(args.summary_csv, args.candidate, args.workload)
    measured = e2e.parse_measured_row(args.measured_csv, args.workload)
    profile = load_profile(args.profile_manifest)
    warnings = validate_selected_profile(
        profile=profile,
        candidate=args.candidate,
        workload=args.workload,
        stream_source=args.stream_source,
        row=row,
        measured=measured,
    )
    stream = e2e.internal_storage_stream(
        params=params,
        row=row,
        measured=measured,
        read_granularity=args.stream_source,
        efficiency=args.raw_efficiency,
    )

    memory = integrated.parse_memory_params(config_path)
    datapath_config = e2e.DatapathConfig.from_json(args.datapath_profile)
    axis_bw = integrated.axis_input_bw_mb_s(datapath_config)
    if args.csd_input_source == "axis":
        csd_input_bw = axis_bw
    elif args.csd_input_source == "strict_sram":
        if memory["strict_sram_bw_mb_s"] is None:
            raise SystemExit("strict_sram source requires SRAM clock/data-width fields")
        csd_input_bw = memory["strict_sram_bw_mb_s"]
    else:
        if args.csd_input_bandwidth_mb_s is None:
            raise SystemExit("--csd-input-source=fixed requires --csd-input-bandwidth-mb-s")
        csd_input_bw = args.csd_input_bandwidth_mb_s

    rows = [
        run_one(
            vectors=vectors,
            dim=args.dim,
            stream=stream,
            datapath_profile=args.datapath_profile,
            csd_input_bw_mb_s=csd_input_bw,
            csd_input_source=args.csd_input_source,
            buffer_groups=args.buffer_groups,
            overlap_input_compute=not args.serialize_input_compute,
        )
        for vectors in sorted(set(args.targets))
    ]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.out_dir / "scaling_512.csv", rows)
    summary = {
        "schema_version": 1,
        "integration_kind": "simplessd_profile_plus_device_local_csd_scaling",
        "candidate": args.candidate,
        "workload": args.workload,
        "profile_manifest": e2e.artifact_path(args.profile_manifest),
        "datapath_profile": e2e.artifact_path(args.datapath_profile),
        "stream_source": args.stream_source,
        "profile_boundary": profile.get("boundary"),
        "profile_role": profile.get("role"),
        "storage_stream": stream,
        "storage_params": params,
        "memory_params": memory,
        "simplessd_row": row,
        "measured_validation_row": measured,
        "profile_validation": profile.get("validation", {}),
        "profile_reported_use": profile.get("reported_use", {}),
        "known_limitations": profile.get("known_limitations", []),
        "warnings": warnings,
        "reported_boundary": (
            "CSD scaling rows are deterministic integrated simulation rows: "
            "selected PM9A3-class SimpleSSD sequential stream plus Resa AXI input, "
            "RTL-derived compute, and SSD-controller DMA writeback of compact "
            "encrypted results to host memory."
        ),
        "result_memory_model": {
            "basis": HOST_RESULT_MEMORY_BASIS,
            "result_ciphertext_bytes": datapath_config.writeback.result_bytes,
            "result_ciphertexts_per_group": 1,
            "vectors_per_group": datapath_config.db.vectors_per_group,
            "device_result_buffering": "result ciphertexts are DMA-written to host memory",
        },
        "csd_input_source": args.csd_input_source,
        "csd_input_bw_mb_s": csd_input_bw,
        "targets": sorted(set(args.targets)),
        "dimension": args.dim,
        "rows_csv": e2e.artifact_path(args.out_dir / "scaling_512.csv"),
    }
    (args.out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    write_readme(args.out_dir / "README.md", args, rows, stream, profile, row, measured, warnings)
    print(f"wrote {args.out_dir / 'scaling_512.csv'}")


if __name__ == "__main__":
    main()
