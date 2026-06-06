.PHONY: quick-check rtl-smoke ckks-result-check area-power-check security-check clean

quick-check:
	python3 scripts/check_bundle.py
	$(MAKE) area-power-check
	$(MAKE) ckks-result-check
	$(MAKE) security-check

rtl-smoke:
	$(MAKE) -C asic verify

ckks-result-check:
	$(MAKE) -C baselines/ckks_error verify-results

area-power-check:
	python3 asic/summary/middleware_area_power.py --check

security-check:
	python3 security/lattice_estimator_params.py --check

clean:
	$(MAKE) -C asic clean
	$(MAKE) -C baselines/ckks_error clean
	$(MAKE) -C ranking/gpu_he clean
