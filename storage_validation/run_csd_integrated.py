#!/usr/bin/env python3
"""Integrate the selected PM9A3 SimpleSSD profile with the Resa datapath.

This runner models the device-local path used by the artifact: a
SimpleSSD-calibrated PM9A3 stream feeds the Resa AXI-Stream input, and the SSD
controller DMA-writes the compact encrypted result stream to the host result
buffer.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import simulate_csd_e2e as e2e


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_SUMMARY_CSV = (
    SCRIPT_DIR
    / "results"
    / "pm9a3-simplessd-official-seq-selected-260530"
    / "sim_summary.csv"
)
DEFAULT_CONFIG_DIR = (
    SCRIPT_DIR
    / "results"
    / "pm9a3-simplessd-official-seq-selected-260530"
    / "configs"
)
DEFAULT_MEASURED_CSV = (
    SCRIPT_DIR
    / "results"
    / "pm9a3-allocated-file-read-260530"
    / "summary_for_simplessd.csv"
)
DEFAULT_DATAPATH_PROFILE = e2e.DEFAULT_DATAPATH_PROFILE
DEFAULT_CANDIDATE = "officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy"
DEFAULT_WORKLOAD = "hold_seqread_1m_qd8"

MB = 1_000_000.0


def bandwidth_mb_s(bytes_per_s: float) -> float:
    return bytes_per_s / MB


def seconds_ms(value: float) -> float:
    return value * 1000.0


def seconds_us(value: float) -> float:
    return value * 1_000_000.0


def parse_memory_params(config_path: Path) -> dict[str, Any]:
    root = e2e.load_tree(config_path).getroot()

    def optional(section_path: list[str], name: str) -> str | None:
        try:
            return e2e.config_text(root, section_path, name)
        except KeyError:
            return None

    flattened_bus = optional(["memory"], "BusClock")
    system_bus = optional(["memory", "system"], "BusClock")
    sram_clock = optional(["memory", "sram"], "Clock")
    sram_data_rate = optional(["memory", "sram"], "DataRate")
    sram_data_width = optional(["memory", "sram"], "DataWidth")
    sram_read_latency = optional(["memory", "sram"], "ReadLatency")
    sram_write_latency = optional(["memory", "sram"], "WriteLatency")

    sram_bw_mb_s = None
    if sram_clock and sram_data_rate and sram_data_width:
        clock_hz = e2e.parse_rate_bytes_s(sram_clock)
        bits_per_tick = float(sram_data_rate) * float(sram_data_width)
        sram_bw_mb_s = bandwidth_mb_s(clock_hz * bits_per_tick / 8.0)

    return {
        "memory_bus_clock": flattened_bus,
        "memory_system_bus_clock": system_bus,
        "sram_clock": sram_clock,
        "sram_data_rate": int(sram_data_rate) if sram_data_rate else None,
        "sram_data_width_bits": int(sram_data_width) if sram_data_width else None,
        "sram_read_latency_cycles": int(sram_read_latency) if sram_read_latency else None,
        "sram_write_latency_cycles": int(sram_write_latency) if sram_write_latency else None,
        "strict_sram_bw_mb_s": sram_bw_mb_s,
    }


def axis_input_bw_mb_s(config: Any) -> float:
    bytes_per_cycle = config.compute.axis_width_bits / 8.0
    cycles_per_s = config.compute.clock_mhz * 1_000_000.0
    return bandwidth_mb_s(bytes_per_cycle * cycles_per_s)


def bounded_pipeline(
    *,
    n_groups: int,
    storage_to_stream_s: float,
    csd_input_s: float,
    compute_s: float,
    writeback_s: float,
    buffer_groups: int,
    overlap_input_compute: bool,
    trace_groups: int,
) -> dict[str, Any]:
    producer_available_s = 0.0
    csd_available_s = 0.0
    buffer_slot_free_s: list[float] = []
    trace: list[dict[str, Any]] = []
    producer_buffer_stall_s = 0.0
    csd_wait_storage_s = 0.0

    for index in range(n_groups):
        producer_start_s = producer_available_s
        if index >= buffer_groups:
            slot_free_s = buffer_slot_free_s[index - buffer_groups]
            if slot_free_s > producer_start_s:
                producer_buffer_stall_s += slot_free_s - producer_start_s
                producer_start_s = slot_free_s

        producer_end_s = producer_start_s + storage_to_stream_s
        producer_available_s = producer_end_s

        csd_start_s = max(csd_available_s, producer_end_s)
        if producer_end_s > csd_available_s:
            csd_wait_storage_s += producer_end_s - csd_available_s

        input_start_s = csd_start_s
        input_end_s = input_start_s + csd_input_s

        if overlap_input_compute:
            compute_start_s = csd_start_s
            compute_end_s = compute_start_s + compute_s
            writeback_start_s = max(input_end_s, compute_end_s)
        else:
            compute_start_s = input_end_s
            compute_end_s = compute_start_s + compute_s
            writeback_start_s = compute_end_s

        writeback_end_s = writeback_start_s + writeback_s
        csd_available_s = writeback_end_s
        buffer_slot_free_s.append(input_end_s)

        if index < trace_groups or index >= max(trace_groups, n_groups - trace_groups):
            trace.append(
                {
                    "group": index,
                    "storage_stream_start_ms": seconds_ms(producer_start_s),
                    "storage_stream_end_ms": seconds_ms(producer_end_s),
                    "csd_input_start_ms": seconds_ms(input_start_s),
                    "csd_input_end_ms": seconds_ms(input_end_s),
                    "compute_start_ms": seconds_ms(compute_start_s),
                    "compute_end_ms": seconds_ms(compute_end_s),
                    "writeback_end_ms": seconds_ms(writeback_end_s),
                }
            )

    total_s = max(producer_available_s, csd_available_s)
    csd_body_s = (
        max(csd_input_s, compute_s)
        if overlap_input_compute
        else csd_input_s + compute_s
    )
    return {
        "e2e_latency_s": total_s,
        "producer_active_s": storage_to_stream_s * n_groups,
        "producer_buffer_stall_s": producer_buffer_stall_s,
        "csd_input_active_s": csd_input_s * n_groups,
        "csd_compute_active_s": compute_s * n_groups,
        "csd_writeback_active_s": writeback_s * n_groups,
        "csd_body_group_ms": seconds_ms(csd_body_s),
        "csd_group_ms": seconds_ms(csd_body_s + writeback_s),
        "csd_wait_storage_s": csd_wait_storage_s,
        "trace": trace,
    }


def bottleneck(storage_group_s: float, csd_group_s: float) -> str:
    if storage_group_s >= csd_group_s:
        return "ssd_read_to_csd_stream"
    return "csd_local_input_or_compute"


def format_tr_levels(values: dict[str, str]) -> str:
    return " / ".join(values[k] for k in sorted(values))


def write_markdown(path: Path, result: dict[str, Any]) -> None:
    pipe = result["device_pipeline"]
    stages = pipe["stages_per_group"]
    stream = result["storage_stream"]
    params = result["storage_params"]
    memory = result["memory_params"]
    asic = result["asic"]
    lines = [
        "# PM9A3 SimpleSSD + CSD Integrated Device Pipeline",
        "",
        "## Summary",
        "",
        "This result connects the selected PM9A3-class SimpleSSD profile and the Resa datapath in one device-local pipeline.",
        "The SSD controller supplies a device-local stream to the Resa AXI-Stream input and DMA-writes Resa's compact encrypted result stream to host memory.",
        "That DMA writeback is part of the controller result path; the synthesized Resa RTL emits the encrypted result stream.",
        f"The primary stream source is `{stream['source']}` and the end-to-end latency is `{pipe['e2e_latency_s']:.3f}s`.",
        f"The bottleneck is `{pipe['bottleneck']}`.",
        "This is a device-level timing schedule built from the selected storage simulation output and the Resa datapath timing profile.",
        "",
        "## Selected Storage Profile",
        "",
        "| Field | Value |",
        "|---|---:|",
        f"| Candidate | `{result['candidate']}` |",
        f"| PCIe | Gen{params['pcie_generation']} x{params['pcie_lanes']} |",
        f"| Channel / Way / Die / Plane | {params['channel']} / {params['way']} / {params['die']} / {params['plane']} |",
        f"| Effective page size | {params['page_size']} |",
        f"| Page allocation | {params['page_allocation']} |",
        f"| tR levels | {format_tr_levels(params['tr'])} |",
        f"| NAND DMA | {params['dma_speed']} x {params['data_width_bytes']}B |",
        f"| Cache / prefetch | {params['cache_mode']} / {params['read_prefetch']} |",
        f"| SimpleSSD memory-model prior | BusClock={memory['memory_bus_clock']}, SRAM={memory['sram_clock']} x{memory['sram_data_width_bits']} DDR{memory['sram_data_rate']} |",
        "",
        "## Device-Local Pipeline",
        "",
        "| Stage | Per-group time | Notes |",
        "|---|---:|---|",
        f"| SSD controller read path -> Resa stream boundary | {stages['ssd_read_to_csd_stream_ms']:.6f} ms | `{stream['bw_mb_s']:.3f} MB/s` storage producer |",
        f"| Resa AXI-Stream input | {stages['csd_axi_input_ms']:.6f} ms | `{pipe['csd_input_bw_mb_s']:.3f} MB/s`, source `{pipe['csd_input_bw_source']}` |",
        f"| Resa arithmetic | {stages['csd_compute_ms']:.6f} ms | {asic['ctxts_per_group']} ctxts/group, {asic['cycles_per_ctxt']} cycles/ctxt |",
        f"| SSD-controller DMA writeback | {stages['result_writeback_us']:.6f} us | compact encrypted score ciphertext to host memory |",
        f"| Resa stage accounting | {stages['csd_body_ms']:.6f} ms | `{pipe['input_compute_accounting']}` |",
        "",
        "## Aggregate Result",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Database size | {result['data_layout']['db_size_gb_decimal']:.3f} GB |",
        f"| Groups | {result['data_layout']['n_groups']:,} |",
        f"| Buffer capacity | {pipe['buffer_groups']} groups |",
        f"| Storage-only time | {pipe['storage_only_s']:.3f} s |",
        f"| Integrated e2e latency | {pipe['e2e_latency_s']:.3f} s |",
        f"| Producer active fraction | {pipe['producer_active_pct']:.2f}% |",
        f"| Resa compute active fraction | {pipe['csd_compute_active_pct']:.2f}% |",
        f"| Resa input active fraction | {pipe['csd_input_active_pct']:.2f}% |",
        f"| Resa storage wait | {pipe['csd_wait_storage_s']:.3f} s |",
        f"| Producer buffer stall | {pipe['producer_buffer_stall_s']:.3f} s |",
        "",
        "## Scope",
        "",
        "This result is used for the PM9A3-class device-local scan model.",
        "The strict SRAM x36 bandwidth field belongs to the SimpleSSD memory-model prior used to reproduce host-visible storage behavior.",
        "The Resa input stream defaults to the synthesized AXI input port because the accelerator consumes the controller-provided local stream instead of issuing host NVMe reads.",
        "",
    ]
    path.write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a device-local SimpleSSD profile + CSD pipeline model."
    )
    parser.add_argument("--summary-csv", type=Path, default=DEFAULT_SUMMARY_CSV)
    parser.add_argument("--measured-csv", type=Path, default=DEFAULT_MEASURED_CSV)
    parser.add_argument("--config-dir", type=Path, default=DEFAULT_CONFIG_DIR)
    parser.add_argument("--candidate", default=DEFAULT_CANDIDATE)
    parser.add_argument("--workload", default=DEFAULT_WORKLOAD)
    parser.add_argument("--datapath-profile", type=Path, default=DEFAULT_DATAPATH_PROFILE)
    parser.add_argument("--vectors", type=int, default=None)
    parser.add_argument("--dim", type=int, default=None)
    parser.add_argument(
        "--stream-source",
        choices=["measured_seq", "simplessd_seq", "parameter_raw"],
        default="measured_seq",
        help="SSD-controller read path -> Resa stream source.",
    )
    parser.add_argument("--raw-efficiency", type=float, default=None)
    parser.add_argument(
        "--csd-input-source",
        choices=["axis", "strict_sram", "fixed"],
        default="axis",
        help="Bandwidth source for the Resa AXI-Stream input stage.",
    )
    parser.add_argument(
        "--csd-input-bandwidth-mb-s",
        type=float,
        default=None,
        help="Required when --csd-input-source=fixed.",
    )
    parser.add_argument("--buffer-groups", type=int, default=3)
    parser.add_argument("--serialize-input-compute", action="store_true")
    parser.add_argument("--trace-groups", type=int, default=3)
    parser.add_argument("--out-dir", type=Path, default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.buffer_groups <= 0:
        raise SystemExit("--buffer-groups must be positive")

    config_path = args.config_dir / f"{args.candidate}.ssd.xml"
    if not config_path.exists():
        raise SystemExit(f"SimpleSSD config not found: {config_path}")

    params = e2e.parse_candidate_config(config_path)
    row = e2e.parse_simplessd_row(args.summary_csv, args.candidate, args.workload)
    measured = e2e.parse_measured_row(args.measured_csv, args.workload)
    stream = e2e.internal_storage_stream(
        params=params,
        row=row,
        measured=measured,
        read_granularity=args.stream_source,
        efficiency=args.raw_efficiency,
    )

    config = e2e.DatapathConfig.from_json(args.datapath_profile)
    if args.vectors is not None:
        config.db.n_vectors = args.vectors
    if args.dim is not None:
        config.db.embedding_dim = args.dim

    layout = e2e.DataLayout(config)
    compute = e2e.compute_group_timing(config)
    writeback = e2e.writeback_timing(config)
    memory = parse_memory_params(config_path)

    axis_bw = axis_input_bw_mb_s(config)
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

    group_bytes = layout.total_db_bytes / config.db.n_groups
    storage_to_stream_s = group_bytes / stream["bw_bytes_s"]
    csd_input_s = group_bytes / (csd_input_bw * MB)
    compute_s = compute.total_time_us / 1_000_000.0
    writeback_s = writeback.total_time_us / 1_000_000.0
    overlap_input_compute = not args.serialize_input_compute

    integrated = bounded_pipeline(
        n_groups=config.db.n_groups,
        storage_to_stream_s=storage_to_stream_s,
        csd_input_s=csd_input_s,
        compute_s=compute_s,
        writeback_s=writeback_s,
        buffer_groups=args.buffer_groups,
        overlap_input_compute=overlap_input_compute,
        trace_groups=args.trace_groups,
    )

    csd_body_s = integrated["csd_body_group_ms"] / 1000.0
    csd_group_s = integrated["csd_group_ms"] / 1000.0
    storage_only_s = storage_to_stream_s * config.db.n_groups
    e2e_latency_s = integrated["e2e_latency_s"]
    result = {
        "schema_version": 1,
        "integration_kind": "simplessd_profile_plus_device_local_csd_pipeline",
        "candidate": args.candidate,
        "workload": args.workload,
        "summary_csv": e2e.artifact_path(args.summary_csv),
        "measured_csv": e2e.artifact_path(args.measured_csv),
        "config_path": e2e.artifact_path(config_path),
        "datapath_profile": e2e.artifact_path(args.datapath_profile),
        "storage_params": params,
        "memory_params": memory,
        "storage_stream": stream,
        "simplessd_row": row,
        "measured_row": measured,
        "data_layout": {
            "n_vectors": config.db.n_vectors,
            "embedding_dim": config.db.embedding_dim,
            "n_groups": config.db.n_groups,
            "group_bytes": group_bytes,
            "group_bytes_mb": group_bytes / MB,
            "db_size_gb_decimal": layout.total_db_gb_decimal,
        },
        "asic": {
            "datapath_mode": config.compute.datapath_mode,
            "axis_width_bits": config.compute.axis_width_bits,
            "clock_mhz": config.compute.clock_mhz,
            "ctxts_per_group": config.db.ctxts_per_group,
            "cycles_per_ctxt": compute.cycles_per_ctxt,
            "axis_peak_mb_s": axis_bw,
            "compute_group_ms": compute.total_time_us / 1000.0,
            "writeback_group_us": writeback.total_time_us,
            "result_writeback_path": "resa_axis_stream_to_ssd_controller_dma_to_host_memory",
        },
        "device_pipeline": {
            "stream_source": args.stream_source,
            "buffer_groups": args.buffer_groups,
            "csd_input_bw_source": args.csd_input_source,
            "csd_input_bw_mb_s": csd_input_bw,
            "input_compute_accounting": (
                "overlap_input_with_compute"
                if overlap_input_compute
                else "serialize_input_then_compute"
            ),
            "stages_per_group": {
                "ssd_read_to_csd_stream_ms": seconds_ms(storage_to_stream_s),
                "csd_axi_input_ms": seconds_ms(csd_input_s),
                "csd_compute_ms": seconds_ms(compute_s),
                "result_writeback_us": seconds_us(writeback_s),
                "csd_body_ms": integrated["csd_body_group_ms"],
                "csd_group_ms": integrated["csd_group_ms"],
            },
            "storage_only_s": storage_only_s,
            "e2e_latency_s": e2e_latency_s,
            "bottleneck": bottleneck(storage_to_stream_s, csd_group_s),
            "producer_active_s": integrated["producer_active_s"],
            "producer_active_pct": 100.0 * integrated["producer_active_s"] / e2e_latency_s,
            "producer_buffer_stall_s": integrated["producer_buffer_stall_s"],
            "csd_input_active_s": integrated["csd_input_active_s"],
            "csd_input_active_pct": 100.0 * integrated["csd_input_active_s"] / e2e_latency_s,
            "csd_compute_active_s": integrated["csd_compute_active_s"],
            "csd_compute_active_pct": 100.0 * integrated["csd_compute_active_s"] / e2e_latency_s,
            "csd_writeback_active_s": integrated["csd_writeback_active_s"],
            "csd_body_active_s": csd_body_s * config.db.n_groups,
            "csd_body_active_pct": 100.0 * csd_body_s * config.db.n_groups / e2e_latency_s,
            "csd_wait_storage_s": integrated["csd_wait_storage_s"],
            "trace": integrated["trace"],
        },
        "reported_boundary": (
            "PM9A3-class SimpleSSD storage profile integrated with a device-local "
            "fixed-function Resa scan datapath. The model validates the storage "
            "producer with physical PM9A3 rows, feeds the Resa AXI-Stream input "
            "without moving group payloads through host memory, and models "
            "SSD-controller DMA writeback of encrypted score ciphertexts to host "
            "memory."
        ),
    }

    if args.out_dir:
        args.out_dir.mkdir(parents=True, exist_ok=True)
        (args.out_dir / "integrated_summary.json").write_text(json.dumps(result, indent=2))
        write_markdown(args.out_dir / "README.md", result)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    print("PM9A3 SimpleSSD + CSD integrated pipeline")
    print("=" * 48)
    print(f"candidate:      {args.candidate}")
    print(f"stream source:  {stream['source']}")
    print(f"stream BW:      {stream['bw_mb_s']:.3f} MB/s")
    print(f"Resa input BW:  {csd_input_bw:.3f} MB/s ({args.csd_input_source})")
    print(f"groups:         {config.db.n_groups:,}")
    print(f"buffer groups:  {args.buffer_groups}")
    print(f"storage group:  {seconds_ms(storage_to_stream_s):.6f} ms")
    print(f"Resa body group:{integrated['csd_body_group_ms']:.6f} ms")
    print(f"storage-only:   {storage_only_s:.3f} s")
    print(f"integrated e2e: {e2e_latency_s:.3f} s")
    print(f"bottleneck:     {result['device_pipeline']['bottleneck']}")


if __name__ == "__main__":
    main()
