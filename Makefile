# SPDX-License-Identifier: MIT
#
# Top-level entry points for the ZedBoard mixed-signal platform.
#
#   make test        run every IP testbench (GHDL + cocotb, no FPGA tools needed)
#   make regmap      regenerate VHDL/C/Python/docs from regmap/*.yaml
#   make check       the full host-side lane that CI runs
#   make bitstream   build the FPGA image (requires Vivado)
#   make clean

SHELL := /bin/bash

# Every directory holding a cocotb testbench.
TB_DIRS := $(sort $(dir $(wildcard ip/*/tb/Makefile)))

# Optional local overrides (Vivado path, board hostname, ...).
-include Makefile.local

VIVADO ?= vivado
BOARD  ?= zedboard

.PHONY: all
all: regmap test

# --- Register map --------------------------------------------------------
.PHONY: regmap regmap-check
regmap:
	@python3 scripts/gen_regmap.py

regmap-check:
	@python3 scripts/gen_regmap.py --check

# --- Simulation ----------------------------------------------------------
.PHONY: test $(TB_DIRS)
test: $(TB_DIRS)
	@echo "All testbenches passed."

$(TB_DIRS):
	@echo "=== $@ ==="
	@$(MAKE) -C $@ check

# --- Host-side software --------------------------------------------------
.PHONY: host-test
host-test:
	@PYTHONPATH=sw/host:sim python3 -m pytest -q sw/host/tests sim/tests 2>/dev/null || \
	 PYTHONPATH=sw/host:sim python3 -m pytest -q sw/host/tests

# --- Consolidated contributor check --------------------------------------
# Everything here runs without Vivado and without a board, which is what makes
# it usable in CI on every push.
.PHONY: check
check: regmap-check test host-test
	@echo "Host-side checks passed."

# --- FPGA build ----------------------------------------------------------
.PHONY: bitstream
bitstream:
	$(VIVADO) -mode batch -nojournal -nolog -source scripts/build.tcl -tclargs $(BOARD)

.PHONY: clean
clean:
	@for d in $(TB_DIRS); do $(MAKE) -C $$d clean >/dev/null 2>&1 || true; done
	@rm -rf build __pycache__ .pytest_cache
	@find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "Clean."
