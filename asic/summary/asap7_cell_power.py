#!/usr/bin/env python3
"""ASAP7 mapped-netlist vectorless logic-power estimator.

This script records vectorless logic power for the seeded-a path from the ASAP7
RVT NLDM Liberty files and the Yosys-mapped gate-level Verilog netlist. It does
not scale power from another design point.
"""

import argparse
import json
import os
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


DEFAULT_FREQUENCY_MHZ = 500.0
DEFAULT_VOLTAGE_V = 0.7
DEFAULT_SIGNAL_ACTIVITY = 0.5
DEFAULT_CLOCK_TRANSITIONS_PER_CYCLE = 2.0

RVT_LIBERTY_NAMES = [
    "asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib",
    "asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib",
    "asap7sc7p5t_OA_RVT_TT_nldm_211120.lib",
    "asap7sc7p5t_AO_RVT_TT_nldm_211120.lib",
    "asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib",
]


@dataclass
class LibertyCell:
    name: str
    area_units: float
    leakage_power_pW: float
    pins: Dict[str, Dict[str, object]]
    internal_energy_fJ_by_pin: Dict[str, float]
    source_lib: str


@dataclass
class Asap7LogicPowerResult:
    netlist: str
    liberty_dir: str
    missing_cell_types: List[str]
    leakage_mw: float
    net_switching_mw: float
    internal_switching_mw: float
    dynamic_mw: float
    total_mw: float
    frequency_mhz: float
    voltage_v: float
    signal_activity: float
    clock_transitions_per_cycle: float
    clock_load_fF: float
    signal_load_fF: float


def artifact_root() -> Path:
    return Path(__file__).resolve().parents[1]


def repo_root() -> Path:
    return artifact_root().parent


def default_liberty_dir() -> Path:
    env = os.environ.get("ASAP7_LIB_DIR")
    if env:
        return Path(env)
    return repo_root() / "asic-tools" / "asap7" / "asap7sc7p5t_28" / "LIB" / "NLDM"


def default_netlist_path() -> Path:
    return artifact_root() / "syn" / "synth_seeded_a_logic_only.v"


def extract_brace_block(text: str, brace_pos: int) -> str:
    depth = 0
    for idx in range(brace_pos, len(text)):
        ch = text[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace_pos + 1:idx]
    raise ValueError("unterminated Liberty block")


def parse_numbers(text: str) -> List[float]:
    return [float(x) for x in re.findall(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", text)]


def liberty_files(liberty_dir: Path) -> List[Path]:
    files = [liberty_dir / name for name in RVT_LIBERTY_NAMES]
    missing = [str(path) for path in files if not path.exists()]
    if missing:
        raise FileNotFoundError("missing ASAP7 Liberty files: " + ", ".join(missing))
    return files


def parse_liberty(liberty_dir: Path) -> Dict[str, LibertyCell]:
    cells: Dict[str, LibertyCell] = {}
    for path in liberty_files(liberty_dir):
        text = path.read_text(errors="ignore")
        for match in re.finditer(r"cell\s*\(([^)]+)\)\s*\{", text):
            name = match.group(1)
            body = extract_brace_block(text, match.end() - 1)
            area_match = re.search(r"\barea\s*:\s*([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)", body)
            area_units = float(area_match.group(1)) if area_match else 0.0

            leakages = []
            for leak_match in re.finditer(r"leakage_power\s*\(\)\s*\{", body):
                leak_body = extract_brace_block(body, leak_match.end() - 1)
                if "related_pg_pin : VSS" in leak_body:
                    continue
                value_match = re.search(r"value\s*:\s*([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)", leak_body)
                if value_match:
                    value = float(value_match.group(1))
                    if value > 0:
                        leakages.append(value)

            pins: Dict[str, Dict[str, object]] = {}
            for pin_match in re.finditer(r"pin\s*\(([^)]+)\)\s*\{", body):
                pin_name = pin_match.group(1)
                pin_body = extract_brace_block(body, pin_match.end() - 1)
                direction_match = re.search(r"direction\s*:\s*(\w+)", pin_body)
                capacitance_match = re.search(
                    r"\bcapacitance\s*:\s*([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)",
                    pin_body,
                )
                direction = direction_match.group(1) if direction_match else ""
                capacitance_fF = float(capacitance_match.group(1)) if capacitance_match else 0.0
                is_clock = "clock : true" in pin_body or pin_name.upper() in {"CLK", "CK", "CLKN", "CLK_N"}
                pins[pin_name] = {
                    "direction": direction,
                    "capacitance_fF": capacitance_fF,
                    "clock": is_clock,
                }

            internal_by_pin: Dict[str, List[float]] = {}
            for power_match in re.finditer(r"internal_power\s*\(\)\s*\{", body):
                power_body = extract_brace_block(body, power_match.end() - 1)
                if "related_pg_pin : VSS" in power_body:
                    continue
                related_match = re.search(r'related_pin\s*:\s*"?([^";]+)"?', power_body)
                related_pin = related_match.group(1).strip() if related_match else ""
                values: List[float] = []
                for values_match in re.finditer(r"values\s*\((.*?)\);", power_body, re.S):
                    values.extend(abs(value) for value in parse_numbers(values_match.group(1)))
                if values:
                    internal_by_pin.setdefault(related_pin, []).extend(values)

            cells[name] = LibertyCell(
                name=name,
                area_units=area_units,
                leakage_power_pW=sum(leakages) / len(leakages) if leakages else 0.0,
                pins=pins,
                internal_energy_fJ_by_pin={
                    pin: sum(values) / len(values) for pin, values in internal_by_pin.items()
                },
                source_lib=path.name,
            )
    return cells


def parse_mapped_netlist(netlist_path: Path) -> Iterable[Tuple[str, str]]:
    text = netlist_path.read_text(errors="ignore")
    instance_re = re.compile(
        r"^\s*([A-Za-z0-9_]+_ASAP7_[A-Za-z0-9_]+)\s+(\\?[^\s(]+)\s*\((.*?)\);",
        re.M | re.S,
    )
    pin_re = re.compile(r"\.([A-Za-z0-9_\[\]]+)\s*\(\s*([^()]+?)\s*\)")
    for instance in instance_re.finditer(text):
        cell_type = instance.group(1)
        connections = instance.group(3)
        yield cell_type, connections


def estimate_logic_power(
    netlist_path: Path | None = None,
    liberty_dir: Path | None = None,
    frequency_mhz: float = DEFAULT_FREQUENCY_MHZ,
    voltage_v: float = DEFAULT_VOLTAGE_V,
    signal_activity: float = DEFAULT_SIGNAL_ACTIVITY,
    clock_transitions_per_cycle: float = DEFAULT_CLOCK_TRANSITIONS_PER_CYCLE,
) -> Asap7LogicPowerResult:
    netlist_path = netlist_path or default_netlist_path()
    liberty_dir = liberty_dir or default_liberty_dir()
    if not netlist_path.exists():
        raise FileNotFoundError(f"missing mapped netlist: {netlist_path}")
    cells = parse_liberty(liberty_dir)
    pin_re = re.compile(r"\.([A-Za-z0-9_\[\]]+)\s*\(\s*([^()]+?)\s*\)")

    missing = set()
    leakage_pW = 0.0
    clock_load_fF = 0.0
    signal_load_fF = 0.0
    internal_clock_fJ = 0.0
    internal_signal_fJ = 0.0

    for cell_type, connections in parse_mapped_netlist(netlist_path):
        cell = cells.get(cell_type)
        if cell is None:
            missing.add(cell_type)
            continue
        leakage_pW += cell.leakage_power_pW

        for pin_match in pin_re.finditer(connections):
            pin_name = pin_match.group(1)
            pin_info = cell.pins.get(pin_name)
            if not pin_info or pin_info["direction"] != "input":
                continue
            capacitance_fF = float(pin_info["capacitance_fF"])
            if bool(pin_info["clock"]):
                clock_load_fF += capacitance_fF
            else:
                signal_load_fF += capacitance_fF

        for pin_name, energy_fJ in cell.internal_energy_fJ_by_pin.items():
            if pin_name.upper() in {"CLK", "CK", "CLKN", "CLK_N"}:
                internal_clock_fJ += energy_fJ
            else:
                internal_signal_fJ += energy_fJ

    frequency_hz = frequency_mhz * 1e6
    clock_net_energy_fJ = clock_load_fF * voltage_v * voltage_v * clock_transitions_per_cycle
    signal_net_energy_fJ = signal_load_fF * voltage_v * voltage_v * signal_activity
    internal_energy_fJ = (
        internal_clock_fJ * clock_transitions_per_cycle +
        internal_signal_fJ * signal_activity
    )
    net_switching_mw = (clock_net_energy_fJ + signal_net_energy_fJ) * 1e-15 * frequency_hz * 1e3
    internal_switching_mw = internal_energy_fJ * 1e-15 * frequency_hz * 1e3
    leakage_mw = leakage_pW * 1e-9
    dynamic_mw = net_switching_mw + internal_switching_mw

    return Asap7LogicPowerResult(
        netlist=str(netlist_path),
        liberty_dir=str(liberty_dir),
        missing_cell_types=sorted(missing),
        leakage_mw=leakage_mw,
        net_switching_mw=net_switching_mw,
        internal_switching_mw=internal_switching_mw,
        dynamic_mw=dynamic_mw,
        total_mw=leakage_mw + dynamic_mw,
        frequency_mhz=frequency_mhz,
        voltage_v=voltage_v,
        signal_activity=signal_activity,
        clock_transitions_per_cycle=clock_transitions_per_cycle,
        clock_load_fF=clock_load_fF,
        signal_load_fF=signal_load_fF,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="ASAP7 mapped-netlist logic-power estimator")
    parser.add_argument("--netlist", type=Path, default=default_netlist_path())
    parser.add_argument("--liberty-dir", type=Path, default=default_liberty_dir())
    parser.add_argument("--frequency-mhz", type=float, default=DEFAULT_FREQUENCY_MHZ)
    parser.add_argument("--voltage-v", type=float, default=DEFAULT_VOLTAGE_V)
    parser.add_argument("--signal-activity", type=float, default=DEFAULT_SIGNAL_ACTIVITY)
    parser.add_argument("--clock-transitions-per-cycle", type=float, default=DEFAULT_CLOCK_TRANSITIONS_PER_CYCLE)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    result = estimate_logic_power(
        netlist_path=args.netlist,
        liberty_dir=args.liberty_dir,
        frequency_mhz=args.frequency_mhz,
        voltage_v=args.voltage_v,
        signal_activity=args.signal_activity,
        clock_transitions_per_cycle=args.clock_transitions_per_cycle,
    )
    if result.missing_cell_types:
        raise SystemExit("missing Liberty cells: " + ", ".join(result.missing_cell_types))
    if args.json:
        payload = asdict(result)
        payload["netlist"] = "asic/syn/synth_seeded_a_logic_only.v"
        payload["liberty_dir"] = "${ASAP7_LIB_DIR:-../asic-tools/asap7/asap7sc7p5t_28/LIB/NLDM}"
        print(json.dumps(payload, indent=2))
        return

    print("ASAP7 mapped-netlist logic estimate")
    print(f"  leakage power:      {result.leakage_mw:.3f} mW")
    print(f"  net switching:      {result.net_switching_mw:.1f} mW")
    print(f"  internal switching: {result.internal_switching_mw:.1f} mW")
    print(f"  total logic power:  {result.total_mw:.1f} mW")
    print(f"  activity model:     signal={result.signal_activity}, clock={result.clock_transitions_per_cycle} transitions/cycle")


if __name__ == "__main__":
    main()
