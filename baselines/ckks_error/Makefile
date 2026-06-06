# CKKS numerical-error and ranking-validation checks for the Middleware artifact.

.PHONY: all build recall-benchmark recall-fullscale verify-results test fmt clean help

GO := GOTOOLCHAIN=go1.24.0 go
GOFLAGS := -v

BIN_DIR := bin
RESULTS_DIR := results

DB_SIZE ?= 10000
EMBED_DIM ?= 768
NUM_QUERIES ?= 100
DATASET ?= msmarco-distilbert
REAL_DATA_DIR ?= /path/to/recall-benchmark/data

all: build

build: $(BIN_DIR)/recall_benchmark $(BIN_DIR)/recall_fullscale

$(BIN_DIR)/recall_benchmark: cmd/recall_benchmark/main.go pkg/he/*.go pkg/database/*.go pkg/benchmark/*.go
	@mkdir -p $(BIN_DIR) $(RESULTS_DIR)
	$(GO) build $(GOFLAGS) -o $@ ./cmd/recall_benchmark

$(BIN_DIR)/recall_fullscale: cmd/recall_fullscale/main.go pkg/he/*.go pkg/benchmark/*.go
	@mkdir -p $(BIN_DIR) $(RESULTS_DIR)
	$(GO) build $(GOFLAGS) -o $@ ./cmd/recall_fullscale

recall-benchmark: $(BIN_DIR)/recall_benchmark
	./$(BIN_DIR)/recall_benchmark \
		--vectors $(DB_SIZE) \
		--queries $(NUM_QUERIES) \
		--dim $(EMBED_DIM) \
		--output results/recall_lattigo.json

recall-fullscale: $(BIN_DIR)/recall_fullscale
	./$(BIN_DIR)/recall_fullscale \
		--dataset $(DATASET) \
		--queries $(NUM_QUERIES) \
		--data-dir $(REAL_DATA_DIR) \
		--batch 5000 \
		--output results/recall_fullscale_$(DATASET).json

verify-results:
	python3 scripts/verify_results.py

test:
	$(GO) test -v ./...

fmt:
	$(GO) fmt ./...

clean:
	rm -rf $(BIN_DIR)/

help:
	@echo "CKKS numerical-error artifact targets"
	@echo ""
	@echo "Targets:"
	@echo "  build             Build recall_benchmark and recall_fullscale"
	@echo "  recall-benchmark  Generate the small synthetic CKKS smoke result"
	@echo "  recall-fullscale  Run plaintext full-corpus ranking plus HE validation"
	@echo "  verify-results    Validate bundled result JSON files"
	@echo "  test              Run Go tests"
	@echo "  clean             Remove local binaries"
