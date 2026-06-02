# Makefile -- IEEE 1149.1 JTAG TAP controller
#
#   make          build + run both Icarus testbenches (Day 1 FSM, Day 2 TAP)
#   make fsm      Day 1: FSM-only testbench (state + transition coverage)
#   make top      Day 2/3: full TAP + immediate-assertion checker
#   make sva      Day 3: concurrent SVA under Verilator (assert property)
#   make clean    remove build/sim artifacts
#
# Both Icarus testbenches call $fatal on failure, so a failing run returns a
# non-zero exit code -- safe to drop straight into CI without grepping logs.
#
# Day-3 verification note
# -----------------------
# Icarus Verilog 12 does not support concurrent SVA (`assert property`),
# `bind`, or covergroups. So Day 3 ships TWO equivalent forms:
#   * tb/jtag_assertions.sv -- immediate assertions, run + gated by Icarus
#     (`make top`); the FSM scoreboard in tb_jtag_tap_fsm.sv provides the
#     equivalent of functional coverage (16/16 states, 32/32 transitions).
#   * rtl/jtag_sva.sv       -- the same properties as concurrent `assert
#     property`, bound into the DUT, run by Verilator (`make sva`).
#     tb/jtag_coverage.sv holds the covergroup form for covergroup-capable
#     tools (guarded by +define+COVERGROUPS_ON).

IVERILOG := iverilog -g2012
VVP      := vvp
VERILATOR := verilator

RTL_CORE := rtl/jtag_pkg.sv rtl/jtag_tap_fsm.sv
RTL_FULL := $(RTL_CORE) rtl/jtag_ir.sv rtl/jtag_tap.sv

.PHONY: all fsm top sva clean

all: fsm top

fsm: | sim
	$(IVERILOG) -o sim/tap_fsm.vvp $(RTL_CORE) tb/tb_jtag_tap_fsm.sv
	$(VVP) sim/tap_fsm.vvp

top: | sim
	$(IVERILOG) -o sim/tap_top.vvp $(RTL_FULL) tb/jtag_assertions.sv tb/tb_jtag_top.sv
	$(VVP) sim/tap_top.vvp

# Day 3: run the concurrent SVA (rtl/jtag_sva.sv) against the Day-2 stimulus
# under Verilator. The properties are bound into the DUT and checked on every
# TCK; any violation aborts with a non-zero exit code. Requires Verilator >= 5.
sva: | sim
	$(VERILATOR) --binary --timing -sv --assert +define+SVA_ON \
	  --timescale 1ns/1ps -Wno-TIMESCALEMOD \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
	  --top-module tb_jtag_top \
	  $(RTL_FULL) rtl/jtag_sva.sv tb/tb_jtag_top.sv \
	  --Mdir sim/obj_dir -o tap_top_sva
	./sim/obj_dir/tap_top_sva

# Order-only prerequisite: git doesn't track empty dirs, so create it on demand.
sim:
	mkdir -p sim

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/obj_dir