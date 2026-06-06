.PHONY: smoke recall-smoke run-100m recall-100m wiki-all-smoke wiki-all-10k wiki-all clean

PYTHON ?= python3
GPU ?= 0
OUT_DIR ?= results

smoke:
	$(PYTHON) he_constctxt_gpu.py --vectors 8192 --dim 16 --device cuda:$(GPU) \
		--cpu-check --output $(OUT_DIR)/gpu_he_smoke.json

recall-smoke:
	$(PYTHON) he_recall_gpu.py --vectors 1000000 --dim 768 --queries 1 --device cuda:$(GPU) \
		--cpu-check --progress-every 64 --output $(OUT_DIR)/gpu_he_recall_1m.json

run-100m:
	$(PYTHON) he_constctxt_gpu.py --vectors 100000000 --dim 768 --device cuda:$(GPU) \
		--progress-every 256 --output $(OUT_DIR)/gpu_he_100m.json

recall-100m:
	$(PYTHON) he_recall_gpu.py --vectors 100000000 --dim 768 --queries 1 --device cuda:$(GPU) \
		--cpu-check --progress-every 1024 --output $(OUT_DIR)/gpu_he_recall_100m.json

WIKI_ALL_DIR ?= /path/to/wiki_all_88M
WIKI_QUERY_BATCH ?= 4
WIKI_METRIC ?= sqeuclidean

wiki-all-smoke:
	$(PYTHON) he_recall_fbin_gpu.py \
		--base $(WIKI_ALL_DIR)/base.88M.fbin \
		--queries $(WIKI_ALL_DIR)/queries.fbin \
		--groundtruth-neighbors $(WIKI_ALL_DIR)/groundtruth.88M.neighbors.ibin \
		--metric $(WIKI_METRIC) \
		--num-queries 1 --device cuda:$(GPU) --progress-every 32 \
		--output $(OUT_DIR)/wiki_all_88m_he_recall_1q.json

wiki-all-10k:
	$(PYTHON) he_recall_fbin_gpu.py \
		--base $(WIKI_ALL_DIR)/base.88M.fbin \
		--queries $(WIKI_ALL_DIR)/queries.fbin \
		--groundtruth-neighbors $(WIKI_ALL_DIR)/groundtruth.88M.neighbors.ibin \
		--metric $(WIKI_METRIC) \
		--num-queries 0 --query-batch $(WIKI_QUERY_BATCH) --device cuda:$(GPU) \
		--progress-every 1 --query-progress-every 256 \
		--output $(OUT_DIR)/wiki_all_88m_he_recall_10k.json

wiki-all: wiki-all-10k

clean:
	rm -rf __pycache__
