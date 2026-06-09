# Makefile -- IEEE 1149.1 JTAG TAP controller
#
#   make          build + run the Icarus testbenches + the vector replay
#   make fsm      FSM-only testbench (state + transition coverage)
#   make top      full TAP + immediate-assertion checker
#   make sva      concurrent SVA under Verilator (assert property)
#   make vectors  generate JTAG scan vectors (Tcl) -> sim/jtag_vectors.vec
#   make replay   replay the generated vectors against the DUT, check TDO
#   make clean    remove build/sim artifacts
#
# Both Icarus testbenches call $fatal on failure, so a failing run returns a
# non-zero exit code -- safe to drop straight into CI without grepping logs.
#
# Verification note
# -----------------
# Icarus Verilog 12 does not support concurrent SVA (`assert property`),
# `bind`, or covergroups. So the checks ship in TWO equivalent forms:
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
TCLSH     := tclsh

RTL_CORE := rtl/jtag_pkg.sv rtl/jtag_tap_fsm.sv
RTL_FULL := $(RTL_CORE) rtl/jtag_ir.sv rtl/jtag_tap.sv

VEC      := sim/jtag_vectors.vec
ATPG_VEC := sim/scan_vectors.vec

.PHONY: all fsm top sva vectors replay clean

all: fsm top replay scan

fsm: | sim
	$(IVERILOG) -o sim/tap_fsm.vvp $(RTL_CORE) tb/tb_jtag_tap_fsm.sv
	$(VVP) sim/tap_fsm.vvp

top: | sim
	$(IVERILOG) -o sim/tap_top.vvp $(RTL_FULL) tb/jtag_assertions.sv tb/tb_jtag_top.sv
	$(VVP) sim/tap_top.vvp

# Run the concurrent SVA (rtl/jtag_sva.sv) against the full-TAP stimulus
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

# Generate scan vectors with the standalone Tcl tool. It models the TAP state
# graph, computes the TMS navigation by BFS, and writes (tms tdi tdo) per TCK.
vectors: scripts/gen_jtag_vectors.tcl | sim
	$(TCLSH) scripts/gen_jtag_vectors.tcl $(VEC)

# Close the loop: replay the *generated* vectors against the real DUT and
# check TDO against the expected column ('x' = don't-care). $fatal on any
# mismatch -> non-zero exit, so this gates CI like the other benches.
replay: vectors
	$(IVERILOG) -s tb_jtag_replay -o sim/tap_replay.vvp $(RTL_FULL) tb/tb_jtag_replay.sv
	$(VVP) sim/tap_replay.vvp

atpg: scripts/atpg.py | sim
	python3 scripts/atpg.py $(ATPG_VEC)

scan: atpg | sim
	$(IVERILOG) -s tb_scan_atpg -o sim/scan.vvp rtl/scan_demo.sv tb/tb_scan_atpg.sv
	$(VVP) sim/scan.vvp

# Order-only prerequisite: git doesn't track empty dirs, so create it on demand.
sim:
	mkdir -p sim

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/obj_dir