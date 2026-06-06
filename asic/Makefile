# Resa ASIC Artifact -- Makefile
# Usage:
#   make verify        -- Run RTL unit tests plus top-level flow test (requires iverilog)
#   make synth         -- ASAP7 seeded-a b8+a8 synthesis (requires yosys + ASAP7 PDK)
#   make summary       -- Generate Middleware mapped-cell/SRAM area and tool-output power record
#   make sram-check    -- Run live PCACTI SRAM estimate
#   make verify-results     -- Verify Middleware area/power arithmetic
#   make clean              -- Remove generated files

.PHONY: verify synth synth-seeded summary sram-check verify-results lint clean all

all: verify summary

verify:
	$(MAKE) -C tb all

lint:
	$(MAKE) -C tb lint

synth: synth-seeded

synth-seeded:
	@echo "NOTE: Set ASAP7_LIB_DIR to your ASAP7 liberty directory first."
	@echo "  export ASAP7_LIB_DIR=/path/to/asap7/asap7sc7p5t_28/LIB/NLDM"
	@: "$${ASAP7_LIB_DIR:?Set ASAP7_LIB_DIR to your ASAP7 liberty directory}"
	cd syn && sed "s|\$$ASAP7_LIB_DIR|$${ASAP7_LIB_DIR}|g" synth_seeded_a_logic_only.ys > synth_seeded_a_logic_only.local.ys
	(cd syn && yosys synth_seeded_a_logic_only.local.ys) | tee syn/synth_seeded_a_logic_only.log
	python3 summary/middleware_area_power.py

summary:
	python3 summary/middleware_area_power.py

sram-check:
	python3 summary/sram_pcacti.py

verify-results:
	@echo "Checking Middleware mapped-cell/SRAM area and attached tool-output power arithmetic..."
	python3 summary/middleware_area_power.py --check

clean:
	$(MAKE) -C tb clean
	rm -f syn/synth_seeded_a_logic_only.local.ys
