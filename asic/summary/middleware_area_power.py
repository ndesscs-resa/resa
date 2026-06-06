#!/usr/bin/env python3
"""Middleware area/power record for the Resa datapath.

Area is reported as mapped standard-cell area plus PCACTI SRAM macro area. Power
is read from attached tool-output JSONs under ../power/tool_outputs.
"""

import argparse
import json
import math
import re
from pathlib import Path


AREA_RECORD = {
    "cell_count": 492_697,
    "yosys_cell_area_units": 54_721.495620,
    "mapped_cell_area_mm2": 0.063805,
    "sram_area_mm2": 0.0285,
    "total_mapped_plus_sram_area_mm2": 0.0923,
}


def artifact_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_tool_output(name: str) -> dict:
    path = artifact_root() / "power" / "tool_outputs" / name
    return json.loads(path.read_text())


def parse_number(value: str) -> float:
    return float(value.replace(",", ""))


def parse_synthesis_record() -> dict:
    text = (artifact_root() / "syn" / "synthesis_results.txt").read_text()

    def one(pattern: str) -> float:
        match = re.search(pattern, text)
        if not match:
            raise ValueError(f"missing synthesis_results field: {pattern}")
        return parse_number(match.group(1))

    return {
        "cell_count": int(one(r"Total cells:\s*([0-9,]+)")),
        "yosys_cell_area_units": one(r"Cell area:\s*([0-9,.]+)\s+ASAP7 units"),
        "mapped_cell_area_mm2": one(r"Mapped standard-cell area:\s*([0-9.]+)\s+mm\^2"),
        "sram_area_mm2": one(r"SRAM area:\s*([0-9.]+)\s+mm\^2"),
        "total_mapped_plus_sram_area_mm2": one(
            r"Total mapped-cell \+ SRAM footprint:\s*([0-9.]+)\s+mm\^2"
        ),
    }


def parse_yosys_log() -> dict:
    text = (artifact_root() / "syn" / "synth_seeded_a_logic_only.log").read_text(errors="replace")
    cells = re.findall(r"Number of cells:\s*([0-9]+)", text)
    area = re.findall(
        r"Chip area for module '\\he_accelerator_seeded_a':\s*([0-9.]+)",
        text,
    )
    if not cells or not area:
        raise ValueError("could not parse final Yosys cell count/chip area")
    return {
        "cell_count": int(cells[-1]),
        "yosys_cell_area_units": float(area[-1]),
    }


def compute() -> dict:
    logic_power = load_tool_output("asap7_cell_power.json")
    sram_power = load_tool_output("sram_pcacti.json")
    synthesis_record = parse_synthesis_record()
    yosys_log = parse_yosys_log()
    total_area = AREA_RECORD["mapped_cell_area_mm2"] + AREA_RECORD["sram_area_mm2"]
    total_power = float(logic_power["total_mw"]) + float(sram_power["power_mw"])
    return {
        "configuration": "Resa seeded-a b8+a8 AXI-1024 datapath",
        "method": "mapped standard-cell area + PCACTI SRAM macro area; area record cross-checked against attached synthesis summary and raw Yosys log; ASAP7 vectorless logic-power output + PCACTI SRAM-power output",
        "area_inputs": AREA_RECORD,
        "area_cross_checks": {
            "synthesis_results_txt": synthesis_record,
            "yosys_log_final": yosys_log,
        },
        "power_tool_outputs": {
            "logic": {
                "path": "asic/power/tool_outputs/asap7_cell_power.json",
                "method": "ASAP7 Liberty vectorless estimate over Yosys-mapped netlist",
                "logic_power_mw": logic_power["total_mw"],
            },
            "sram": {
                "path": "asic/power/tool_outputs/sram_pcacti.json",
                "method": "PCACTI SRAM estimate over artifact XML configs",
                "sram_power_mw": sram_power["power_mw"],
            },
        },
        "derived": {
            "total_mapped_plus_sram_area_mm2": total_area,
            "paper_total_mapped_plus_sram_area_mm2": round(total_area, 3),
            "total_power_mw": total_power,
            "paper_total_power_mw": round(total_power, 1),
        },
        "notes": [
            "Area is reported at pre-layout mapped-standard-cell plus PCACTI-SRAM scope.",
            "Power is computed from the attached logic and SRAM tool-output JSONs.",
            "The footprint is the Resa datapath record used by the Middleware artifact.",
        ],
    }


def check(result: dict) -> None:
    derived = result["derived"]
    tests = {
        "synthesis_cell_count": (
            result["area_cross_checks"]["synthesis_results_txt"]["cell_count"],
            AREA_RECORD["cell_count"],
            0,
        ),
        "yosys_log_cell_count": (
            result["area_cross_checks"]["yosys_log_final"]["cell_count"],
            AREA_RECORD["cell_count"],
            0,
        ),
        "synthesis_yosys_cell_area_units": (
            result["area_cross_checks"]["synthesis_results_txt"]["yosys_cell_area_units"],
            AREA_RECORD["yosys_cell_area_units"],
            1e-6,
        ),
        "yosys_log_cell_area_units": (
            result["area_cross_checks"]["yosys_log_final"]["yosys_cell_area_units"],
            AREA_RECORD["yosys_cell_area_units"],
            1e-6,
        ),
        "synthesis_mapped_cell_area_mm2": (
            result["area_cross_checks"]["synthesis_results_txt"]["mapped_cell_area_mm2"],
            AREA_RECORD["mapped_cell_area_mm2"],
            1e-6,
        ),
        "synthesis_sram_area_mm2": (
            result["area_cross_checks"]["synthesis_results_txt"]["sram_area_mm2"],
            AREA_RECORD["sram_area_mm2"],
            0.001,
        ),
        "paper_total_mapped_plus_sram_area_mm2": (
            derived["paper_total_mapped_plus_sram_area_mm2"],
            AREA_RECORD["total_mapped_plus_sram_area_mm2"],
            0.001,
        ),
        "paper_total_power_mw": (derived["paper_total_power_mw"], 192.1, 0.1),
    }
    failures = []
    for name, (actual, expected, tol) in tests.items():
        if math.fabs(actual - expected) > tol:
            failures.append(f"{name}: actual={actual}, expected={expected}, tol={tol}")
    if failures:
        raise SystemExit("Middleware area/power check failed: " + "; ".join(failures))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = compute()
    if args.check:
        check(result)
        print("Middleware area/power checks OK")
        return
    if args.json:
        print(json.dumps(result, indent=2))
        return
    d = result["derived"]
    print("Middleware Resa mapped-cell/SRAM footprint and tool-output power record")
    print(f"  cells:             {AREA_RECORD['cell_count']:,}")
    print(f"  mapped cell area:  {AREA_RECORD['mapped_cell_area_mm2']:.5f} mm^2")
    print(f"  SRAM area:         {AREA_RECORD['sram_area_mm2']:.4f} mm^2")
    print(f"  mapped+SRAM area:  {d['paper_total_mapped_plus_sram_area_mm2']:.3f} mm^2")
    print(f"  logic power:       {result['power_tool_outputs']['logic']['logic_power_mw']:.1f} mW")
    print(f"  SRAM power:        {result['power_tool_outputs']['sram']['sram_power_mw']:.1f} mW")
    print(f"  total power:       {d['paper_total_power_mw']:.1f} mW")


if __name__ == "__main__":
    main()
