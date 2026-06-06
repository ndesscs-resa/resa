#!/usr/bin/env bash
#
# Resa SRAM Estimation using PCACTI
#
# PCACTI: Parameterized CACTI for FinFET memory estimation
#   Paper: "PCACTI: FinFET SRAM/cache estimation tool", ICECS 2024
#   Source: https://github.com/ARC-Lab-UF/PCACTI (or contact authors)
#
# Prerequisites:
#   1. Build PCACTI from source (C++, standard build)
#   2. Set PCACTI_BIN or PCACTI_WORKDIR if the default repository-local
#      tools/pcacti_xml/cacti path is not the desired build
#
# Usage: ./run_pcacti.sh
#
# The XML configs reference PCACTI support files through relative paths under
# xmls/. Run the binary from the PCACTI tool directory so those paths resolve.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_TOOL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/tools/pcacti_xml"
PCACTI_WORKDIR="${PCACTI_WORKDIR:-$DEFAULT_TOOL_DIR}"
PCACTI_BIN="${PCACTI_BIN:-$PCACTI_WORKDIR/cacti}"

if [[ ! -x "$PCACTI_BIN" ]]; then
    echo "ERROR: PCACTI binary not found or not executable: $PCACTI_BIN"
    echo "Set PCACTI_BIN=/path/to/cacti or PCACTI_WORKDIR=/path/to/pcacti_tool_dir."
    exit 1
fi

run_pcacti() {
    (cd "$PCACTI_WORKDIR" && "$PCACTI_BIN" -infile "$1")
}

echo "=========================================="
echo " Resa SRAM Estimation (7nm FinFET)"
echo "=========================================="
echo ""

# --- Accumulator SRAM: single macro point ---
echo "--- Accumulator Macro Point (single, 16KB) ---"
echo "Config: 1024 entries x 118 bits, dual-port (1R+1W)"
run_pcacti "$SCRIPT_DIR/accum_bank_7nm.xml" 2>&1 | tail -10
echo ""

# --- Aggregate accumulator SRAM budget ---
echo "--- Accumulator Total (128KB aggregate) ---"
echo "Config: 128KB aggregate, area-equivalent to seeded-a 16 x 512-bank layout"
run_pcacti "$SCRIPT_DIR/accum_total_7nm.xml" 2>&1 | tail -10
echo ""

# --- Query Buffer ---
echo "--- Query Buffer (8KB) ---"
echo "Config: 768 entries x 51 bits, single RW port"
run_pcacti "$SCRIPT_DIR/query_buf_7nm.xml" 2>&1 | tail -10
echo ""

echo "=========================================="
echo " Recorded artifact results:"
echo "=========================================="
echo "  Accum total aggregate: area ~0.0278 mm2, power ~32.2 mW"
echo "  Query buffer:          area ~0.0007 mm2, power ~1.6 mW"
echo "  Total SRAM:            area ~0.0285 mm2, power ~33.8 mW"
echo "=========================================="
