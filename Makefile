# Makefile -- IEEE 1149.1 JTAG TAP controller
#
#   make          build + run both testbenches (Day 1 FSM, Day 2 full TAP)
#   make fsm      Day 1: FSM-only testbench
#   make top      Day 2: full TAP (IR + BYPASS/IDCODE/boundary-scan)
#   make clean    remove build/sim artifacts
#
# The Day 2 testbench calls $fatal on failure, so a failing run returns a
# non-zero exit code -- safe to drop straight into CI without grepping logs.

IVERILOG := iverilog -g2012
VVP      := vvp

RTL_CORE := rtl/jtag_pkg.sv rtl/jtag_tap_fsm.sv
RTL_FULL := $(RTL_CORE) rtl/jtag_ir.sv rtl/jtag_tap.sv

.PHONY: all fsm top clean

all: fsm top

fsm: | sim
	$(IVERILOG) -o sim/tap_fsm.vvp $(RTL_CORE) tb/tb_jtag_tap_fsm.sv
	$(VVP) sim/tap_fsm.vvp

top: | sim
	$(IVERILOG) -o sim/tap_top.vvp $(RTL_FULL) tb/tb_jtag_top.sv
	$(VVP) sim/tap_top.vvp

# Order-only prerequisite: git doesn't track empty dirs, so create it on demand.
sim:
	mkdir -p sim

clean:
	rm -rf sim/*.vvp sim/*.vcd