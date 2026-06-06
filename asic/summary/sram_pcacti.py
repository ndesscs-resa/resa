#!/usr/bin/env python3
"""PCACTI SRAM checker for the seeded-a ASIC artifact.

This helper runs the PCACTI executable against the artifact XML configurations
and derives the SRAM area and power used by the ASIC summary.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


CLOCK_MHZ = 500.0


@dataclass
class PcactiMacro:
    name: str
    config: str
    bank_count: int
    area_mm2: float
    leakage_per_bank_mw: float
    leakage_mw: float
    read_energy_nj: float
    write_energy_nj: float
    read_accesses_per_cycle: float
    write_accesses_per_cycle: float
    dynamic_mw: float
    total_power_mw: float
    technology_nm: int
    temperature_k: int
    transistor_type: str


@dataclass
class SramPcactiResult:
    clock_mhz: float
    area_mm2: float
    leakage_mw: float
    dynamic_mw: float
    power_mw: float
    macros: list[PcactiMacro]


def artifact_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def project_dir() -> Path:
    return artifact_dir().parent


def pcacti_tool_dir() -> Path:
    env = os.environ.get("PCACTI_WORKDIR")
    if env:
        return Path(env)
    return project_dir() / "tools" / "pcacti_xml"


def default_pcacti_bin() -> Path:
    return pcacti_tool_dir() / "cacti"


def resolve_pcacti_bin() -> str:
    env = os.environ.get("PCACTI_BIN")
    if env:
        return env
    candidate = default_pcacti_bin()
    if candidate.exists():
        return str(candidate)
    return "pcacti"


def run_pcacti(config_path: Path) -> str:
    tool_dir = pcacti_tool_dir()
    if not tool_dir.exists():
        raise RuntimeError(f"missing PCACTI tool directory: {tool_dir}")
    proc = subprocess.run(
        [resolve_pcacti_bin(), "-infile", str(config_path)],
        cwd=tool_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )
    output = proc.stdout + proc.stderr
    if proc.returncode != 0:
        raise RuntimeError(f"PCACTI failed for {config_path}:\n{output}")
    return output


def parse_first(pattern: str, text: str, cast=float):
    match = re.search(pattern, text)
    if not match:
        raise RuntimeError(f"could not parse pattern: {pattern}")
    return cast(match.group(1))


def parse_macro(
    name: str,
    config_name: str,
    read_accesses_per_cycle: float,
    write_accesses_per_cycle: float,
) -> PcactiMacro:
    config_path = artifact_dir() / "sram" / config_name
    text = run_pcacti(config_path)
    bank_count = parse_first(r"Cache banks \(UCA\)\s*:\s*(\d+)", text, int)
    technology_nm = parse_first(r"Technology\s*:\s*(\d+)nm", text, int)
    temperature_k = parse_first(r"Temperature\s*:\s*(\d+)K", text, int)
    transistor_type = parse_first(r"Transistor type\s*:\s*([A-Za-z0-9_-]+)", text, str)
    area_mm2 = parse_first(r"Cache area \(mm2\):\s*([0-9.eE+-]+)", text, float)
    leakage_per_bank_mw = parse_first(
        r"Total leakage power of a bank \(mW\):\s*([0-9.eE+-]+)",
        text,
        float,
    )
    read_energy_nj = parse_first(
        r"Total dynamic read energy per access \(nJ\):\s*([0-9.eE+-]+)",
        text,
        float,
    )
    write_energy_nj = parse_first(
        r"Total dynamic write energy per access \(nJ\):\s*([0-9.eE+-]+)",
        text,
        float,
    )
    leakage_mw = leakage_per_bank_mw * bank_count
    dynamic_mw = (
        read_energy_nj * read_accesses_per_cycle
        + write_energy_nj * write_accesses_per_cycle
    ) * CLOCK_MHZ
    return PcactiMacro(
        name=name,
        config=config_name,
        bank_count=bank_count,
        area_mm2=area_mm2,
        leakage_per_bank_mw=leakage_per_bank_mw,
        leakage_mw=leakage_mw,
        read_energy_nj=read_energy_nj,
        write_energy_nj=write_energy_nj,
        read_accesses_per_cycle=read_accesses_per_cycle,
        write_accesses_per_cycle=write_accesses_per_cycle,
        dynamic_mw=dynamic_mw,
        total_power_mw=leakage_mw + dynamic_mw,
        technology_nm=technology_nm,
        temperature_k=temperature_k,
        transistor_type=transistor_type,
    )


def run_sram_pcacti() -> SramPcactiResult:
    macros = [
        parse_macro(
            name="accumulator",
            config_name="accum_total_7nm.xml",
            read_accesses_per_cycle=1.0,
            write_accesses_per_cycle=1.0,
        ),
        parse_macro(
            name="query_buffer",
            config_name="query_buf_7nm.xml",
            read_accesses_per_cycle=1.0,
            write_accesses_per_cycle=0.0,
        ),
    ]
    area = sum(m.area_mm2 for m in macros)
    leakage = sum(m.leakage_mw for m in macros)
    dynamic = sum(m.dynamic_mw for m in macros)
    return SramPcactiResult(
        clock_mhz=CLOCK_MHZ,
        area_mm2=area,
        leakage_mw=leakage,
        dynamic_mw=dynamic,
        power_mw=leakage + dynamic,
        macros=macros,
    )


def validate_process_sanity(result: SramPcactiResult) -> list[str]:
    failures: list[str] = []
    for macro in result.macros:
        if macro.technology_nm != 7:
            failures.append(f"{macro.name}: expected 7nm, got {macro.technology_nm}nm")
        if macro.transistor_type.lower() != "finfet":
            failures.append(f"{macro.name}: expected FinFET, got {macro.transistor_type}")
        if macro.temperature_k < 358:
            failures.append(f"{macro.name}: expected >=358K, got {macro.temperature_k}K")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description="Run live PCACTI SRAM estimate")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = run_sram_pcacti()
        failures = validate_process_sanity(result)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        data = asdict(result)
        data["process_sanity_failures"] = failures
        print(json.dumps(data, indent=2))
    else:
        print("Live PCACTI SRAM estimate")
        print(f"  area:    {result.area_mm2:.4f} mm^2")
        print(f"  leakage: {result.leakage_mw:.1f} mW")
        print(f"  dynamic: {result.dynamic_mw:.1f} mW")
        print(f"  power:   {result.power_mw:.1f} mW")
        if failures:
            for failure in failures:
                print(f"  FAIL: {failure}")
        else:
            print("  process sanity: PASS")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
