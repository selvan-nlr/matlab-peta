# SPDX-License-Identifier: MIT
#
# Shared cocotb/GHDL simulation settings.
#
# A per-IP testbench Makefile sets VHDL_SOURCES, TOPLEVEL and MODULE, then
# includes this file.  Everything else -- language level, search paths, wave
# dumping, and the SUCCESS marker convention -- lives here so the per-IP
# Makefiles stay three lines long.
#
# Usage:
#   make            run the testbench
#   make WAVES=1    run and dump a GHW waveform next to the Makefile
#   make clean

ZMIX_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

SIM           ?= ghdl
TOPLEVEL_LANG := vhdl

# VHDL-2008 for both analysis and elaboration.
EXTRA_ARGS += --std=08

ifeq ($(WAVES),1)
    GHDL_RUN_ARGS += --wave=$(TOPLEVEL).ghw
endif

# Shared RTL every IP depends on, in dependency order.
COMMON_RTL := \
    $(ZMIX_ROOT)/ip/common/rtl/zmix_pkg.vhd \
    $(ZMIX_ROOT)/ip/common/rtl/axi4lite_regfile.vhd

# The BFM package and any generated Python register definitions.
export PYTHONPATH := $(ZMIX_ROOT)/sim:$(ZMIX_ROOT)/sw/host:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

# Follow the PulsePins convention: a passing run leaves a SUCCESS marker behind
# so an outer `make test` can tell "ran and passed" from "did not run".
.PHONY: check
check: $(COCOTB_RESULTS_FILE)
	@python3 $(ZMIX_ROOT)/scripts/check_results.py $(COCOTB_RESULTS_FILE) && touch SUCCESS

clean::
	@rm -rf SUCCESS *.ghw __pycache__ .pytest_cache
