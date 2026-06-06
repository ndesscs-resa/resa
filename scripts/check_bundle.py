#!/usr/bin/env python3
"""Fast structural checks for the Middleware artifact bundle."""

from pathlib import Path
import json
import sys


ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {
    ".csv",
    ".go",
    ".json",
    ".log",
    ".md",
    ".patch",
    ".py",
    ".sh",
    ".svg",
    ".tex",
    ".txt",
    ".v",
    ".xml",
    ".ys",
    ".yml",
    ".yaml",
    ".mod",
    ".sum",
}


def join_parts(*parts: str) -> str:
    return "".join(parts)


FORBIDDEN_TEXT = [
    join_parts("M", "iB"),
    join_parts("G", "iB"),
    join_parts("K", "iB"),
    join_parts("/", "home", "/", "ljj"),
    join_parts("/", "opt", "/", "ljj"),
    join_parts("/", "data", "/", "ljj"),
    join_parts("Jae", "jin"),
    join_parts("Jae", " Jin"),
    join_parts("Hyeon", "sang"),
    join_parts("Seoul", " National"),
    join_parts("DCS", "Lab"),
    join_parts("dcs", "lab"),
    join_parts("@", "snu"),
    join_parts("@", "gmail"),
    join_parts("AI", " generated"),
    join_parts("Chat", "GPT"),
    join_parts("6", "0", "%", " utilization", " proxy"),
    join_parts("placement-", "utilization"),
    join_parts("cipher", "store"),
    join_parts("v5", ".0", ".0"),
    join_parts("artifact-", "middleware", "/"),
]

REQUIRED = [
    "README.md",
    "DEPENDENCIES.md",
    "MANIFEST.md",
    "asic/rtl/src/he_accelerator_seeded_a.v",
    "asic/rtl/src/a_seed_expander_chacha20.v",
    "asic/tb/tb_he_accelerator_seeded_a.v",
    "asic/syn/synth_seeded_a_logic_only.log",
    "asic/syn/synth_seeded_a_logic_only.v",
    "asic/syn/synthesis_results.txt",
    "asic/summary/middleware_area_power.py",
    "asic/summary/asap7_cell_power.py",
    "asic/power/tool_outputs/asap7_cell_power.json",
    "asic/power/tool_outputs/sram_pcacti.json",
    "asic/sram/accum_total_7nm.xml",
    "asic/sram/query_buf_7nm.xml",
    "baselines/hydia/hydia-similarity-depth1.patch",
    "baselines/hydia/results/resident-real-260529/scaling_512.csv",
    "baselines/ckks_error/results/recall_fullscale_nq_v3.json",
    "baselines/ckks_error/results/recall_fullscale_msmarco-distilbert_v3.json",
    "baselines/ckks_error/results/recall_fullscale_beir-cohere_v3.json",
    "storage_validation/profiles/pm9a3-memory-prior-selected.json",
    "storage_validation/patches/simplessd-pcie-gen4-v2.1.patch",
    "storage_validation/patches/simplessd-standalone-batched-block-io.patch",
    "storage_validation/results/pm9a3-simplessd-official-seq-selected-260530/sim_summary.csv",
    "storage_validation/results/pm9a3-simplessd-official-seq-selected-260530/runs/officialseq_pg8_tr5_8_12_stack42_dma3000m_sram425_2cy/hold_seqread_1m_qd8/stdout.txt",
    "storage_validation/results/pm9a3-csd-scaling-hydia512-simplessdseq-260530/scaling_512.csv",
    "ranking/gpu_he/results/gpu_he_recall_100m.json",
    "ranking/gpu_he/results/wiki_all_88m_he_recall_10k.summary.json",
    "security/lattice_estimator_params.py",
    "storage_validation/resa_datapath.py",
    "storage_validation/profiles/resa-datapath-selected.json",
    "storage_validation/results/pm9a3-csd-integrated-officialseq-simplessdseq-260530/integrated_summary.json",
    "paper_outputs/hydia_scaling.tex",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require_files() -> None:
    missing = [path for path in REQUIRED if not (ROOT / path).exists()]
    if missing:
        fail("missing required files: " + ", ".join(missing))


def check_no_generated_junk() -> None:
    forbidden_suffixes = {".vcd", ".vvp", ".pyc", ".pid", ".tmp"}
    forbidden_dirs = {"__pycache__", "bin", "data"}
    offenders = []
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT)
        if any(part in forbidden_dirs for part in rel.parts):
            offenders.append(str(rel))
        elif path.suffix in forbidden_suffixes or path.name.endswith(".local.ys"):
            offenders.append(str(rel))
    if offenders:
        fail("generated/binary junk present: " + ", ".join(offenders[:20]))


def check_forbidden_text() -> None:
    offenders = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in TEXT_SUFFIXES and path.name != ".gitignore":
            continue
        rel = path.relative_to(ROOT)
        text = path.read_text(errors="replace")
        if any(ord(ch) < 32 and ch not in "\n\r\t" for ch in text):
            offenders.append(f"{rel}: non-printing control character")
            continue
        for needle in FORBIDDEN_TEXT:
            if needle in text:
                offenders.append(f"{rel}: {needle}")
                break
    if offenders:
        fail("forbidden publication text present: " + ", ".join(offenders[:20]))


def check_wiki_summary() -> None:
    path = ROOT / "ranking/gpu_he/results/wiki_all_88m_he_recall_10k.summary.json"
    data = json.loads(path.read_text())
    mrr = float(data.get("mrr_at_10", data.get("mrr@10", data.get("paper_mrr@10", 0))))
    if round(mrr, 4) != 0.9999:
        fail(f"unexpected wiki-all MRR@10: {mrr}")


def main() -> None:
    require_files()
    check_no_generated_junk()
    check_forbidden_text()
    check_wiki_summary()
    print("Middleware artifact bundle OK")


if __name__ == "__main__":
    main()
