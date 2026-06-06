# Makefile for Resa middleware RTL testbenches
# Usage: make all      -- compile and run all tests
#        make tb_xxx   -- compile and run specific test
#        make compile  -- compile only
#        make clean    -- remove generated files

IVERILOG = iverilog
VVP      = vvp
VERILATOR ?= verilator
IFLAGS   = -g2012 -DSIMULATION
VLINT_FLAGS = --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY
SRC_DIR  = $(CURDIR)/../rtl/src

# Source files
SRC_PE_MAC           = $(SRC_DIR)/pe_mac.v
SRC_ACC_SRAM_BANK    = $(SRC_DIR)/acc_sram_bank.v
SRC_SOLINAS_REDUCE   = $(SRC_DIR)/solinas_reduce.v
SRC_CONTINUOUS_UNPACK= $(SRC_DIR)/continuous_unpack.v
SRC_RESULT_PACKER    = $(SRC_DIR)/result_packer.v
SRC_SCALAR_BUFFER    = $(SRC_DIR)/scalar_buffer.v
SRC_RESET_SYNC       = $(SRC_DIR)/reset_sync.v
SRC_HE_ACCEL_SEEDED  = $(SRC_DIR)/he_accelerator_seeded_a.v
SRC_HE_ACCEL_SEEDED_INGRESS = $(SRC_DIR)/he_accelerator_seeded_a_ingress.v
SRC_CHACHA20         = $(SRC_DIR)/chacha20_block_stream.v
SRC_A_SEED_CHACHA20  = $(SRC_DIR)/a_seed_expander_chacha20.v
SRC_SEEDED_FRONTEND  = $(SRC_DIR)/seeded_a_coeff_frontend.v
SRC_SEEDED_GROUP_INGRESS = $(SRC_DIR)/seeded_a_group_ingress.v

SRCS_SEEDED = $(SRC_PE_MAC) $(SRC_ACC_SRAM_BANK) $(SRC_SOLINAS_REDUCE) \
              $(SRC_CONTINUOUS_UNPACK) $(SRC_RESULT_PACKER) \
              $(SRC_SCALAR_BUFFER) $(SRC_RESET_SYNC) $(SRC_CHACHA20) \
              $(SRC_A_SEED_CHACHA20) $(SRC_SEEDED_FRONTEND) \
              $(SRC_HE_ACCEL_SEEDED)

SRCS_SEEDED_INGRESS = $(SRC_PE_MAC) $(SRC_ACC_SRAM_BANK) $(SRC_SOLINAS_REDUCE) \
                      $(SRC_CONTINUOUS_UNPACK) $(SRC_RESULT_PACKER) \
                      $(SRC_SCALAR_BUFFER) $(SRC_RESET_SYNC) $(SRC_CHACHA20) \
                      $(SRC_A_SEED_CHACHA20) $(SRC_SEEDED_FRONTEND) \
                      $(SRC_SEEDED_GROUP_INGRESS) $(SRC_HE_ACCEL_SEEDED) \
                      $(SRC_HE_ACCEL_SEEDED_INGRESS)

# Testbench targets
TESTS = tb_pe_mac tb_acc_sram_bank tb_solinas_reduce tb_continuous_unpack tb_result_packer tb_chacha20_block_stream tb_seeded_a_coeff_frontend tb_seeded_a_group_ingress tb_he_accelerator_seeded_a tb_he_accelerator_seeded_a_ingress

.PHONY: all compile lint clean $(TESTS)
.NOTPARALLEL:

all: $(TESTS)
	@echo ""
	@echo "========================================"
	@echo "  All testbenches completed."
	@echo "========================================"

compile: $(addsuffix .vvp, $(TESTS))

lint:
	$(VERILATOR) $(VLINT_FLAGS) $(SRCS_SEEDED) --top-module he_accelerator_seeded_a
	$(VERILATOR) $(VLINT_FLAGS) $(SRCS_SEEDED_INGRESS) --top-module he_accelerator_seeded_a_ingress

# --- tb_pe_mac ---
tb_pe_mac.vvp: tb_pe_mac.v $(SRC_PE_MAC)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_pe_mac: tb_pe_mac.vvp
	@echo ""; echo "=== Running tb_pe_mac ==="
	$(VVP) $<

# --- tb_acc_sram_bank ---
tb_acc_sram_bank.vvp: tb_acc_sram_bank.v $(SRC_ACC_SRAM_BANK)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_acc_sram_bank: tb_acc_sram_bank.vvp
	@echo ""; echo "=== Running tb_acc_sram_bank ==="
	$(VVP) $<

# --- tb_solinas_reduce ---
tb_solinas_reduce.vvp: tb_solinas_reduce.v $(SRC_SOLINAS_REDUCE)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_solinas_reduce: tb_solinas_reduce.vvp
	@echo ""; echo "=== Running tb_solinas_reduce ==="
	$(VVP) $<

# --- tb_continuous_unpack ---
tb_continuous_unpack.vvp: tb_continuous_unpack.v $(SRC_CONTINUOUS_UNPACK)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_continuous_unpack: tb_continuous_unpack.vvp
	@echo ""; echo "=== Running tb_continuous_unpack ==="
	$(VVP) $<

# --- tb_result_packer ---
tb_result_packer.vvp: tb_result_packer.v $(SRC_RESULT_PACKER)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_result_packer: tb_result_packer.vvp
	@echo ""; echo "=== Running tb_result_packer ==="
	$(VVP) $<

# --- tb_chacha20_block_stream ---
tb_chacha20_block_stream.vvp: tb_chacha20_block_stream.v $(SRC_CHACHA20)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_chacha20_block_stream: tb_chacha20_block_stream.vvp
	@echo ""; echo "=== Running tb_chacha20_block_stream ==="
	$(VVP) $<

# --- tb_seeded_a_coeff_frontend ---
tb_seeded_a_coeff_frontend.vvp: tb_seeded_a_coeff_frontend.v $(SRC_CONTINUOUS_UNPACK) $(SRC_CHACHA20) $(SRC_A_SEED_CHACHA20) $(SRC_SEEDED_FRONTEND)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_seeded_a_coeff_frontend: tb_seeded_a_coeff_frontend.vvp
	@echo ""; echo "=== Running tb_seeded_a_coeff_frontend ==="
	$(VVP) $<

# --- tb_seeded_a_group_ingress ---
tb_seeded_a_group_ingress.vvp: tb_seeded_a_group_ingress.v $(SRC_SEEDED_GROUP_INGRESS)
	$(IVERILOG) $(IFLAGS) -o $@ $^

tb_seeded_a_group_ingress: tb_seeded_a_group_ingress.vvp
	@echo ""; echo "=== Running tb_seeded_a_group_ingress ==="
	$(VVP) $<

# --- tb_he_accelerator_seeded_a (Seeded-a Integration Oracle Test) ---
tb_he_accelerator_seeded_a.vvp: tb_he_accelerator_seeded_a.v $(SRCS_SEEDED)
	$(IVERILOG) $(IFLAGS) -o $@ $< $(SRCS_SEEDED)

tb_he_accelerator_seeded_a: tb_he_accelerator_seeded_a.vvp
	@echo ""; echo "=== Running tb_he_accelerator_seeded_a (Seeded-a Integration Oracle Test) ==="
	$(VVP) $<

# --- tb_he_accelerator_seeded_a_ingress (Compact-Ingress Integration Oracle Test) ---
tb_he_accelerator_seeded_a_ingress.vvp: tb_he_accelerator_seeded_a_ingress.v $(SRCS_SEEDED_INGRESS)
	$(IVERILOG) $(IFLAGS) -o $@ $< $(SRCS_SEEDED_INGRESS)

tb_he_accelerator_seeded_a_ingress: tb_he_accelerator_seeded_a_ingress.vvp
	@echo ""; echo "=== Running tb_he_accelerator_seeded_a_ingress (Compact-Ingress Oracle Test) ==="
	$(VVP) $<

clean:
	rm -f *.vvp *.vcd
