// jtag_coverage.sv
// Canonical SystemVerilog functional coverage for the TAP FSM.
//
// Icarus Verilog 12 cannot parse `covergroup` (nor can Verilator 5.x), so the
// CI uses a portable state/transition scoreboard inside tb_jtag_tap_fsm.sv
// instead -- it reports 16/16 state and 32/32 transition coverage and fails
// the build if any bin is missed. This file is the equivalent covergroup form
// for a covergroup-capable simulator (VCS, Questa, Xcelium); it is guarded by
// COVERGROUPS_ON and compiled only by such a tool.
//
//   * cp_state  : every one of the 16 controller states is reached.
//   * cp_trans  : the legal 1149.1 state transitions are taken. The cross of
//                 (previous state, current state) is filtered with
//                 `illegal_bins` so only edges that exist in the diagram are
//                 counted -- mirroring the 32 edges the scoreboard tracks.
//
// Sample the group from the testbench on each rising TCK, e.g.:
//
//     tap_cov cov = new();
//     always @(posedge tck) cov.sample();   // (or cov.sample(prev, state))
//
`ifdef COVERGROUPS_ON
`timescale 1ns/1ps

module jtag_coverage
  import jtag_pkg::*;
(
  input logic       tck,
  input tap_state_e state
);

  tap_state_e prev;
  always @(posedge tck) prev <= state;

  covergroup tap_cg @(posedge tck);
    option.per_instance = 1;
    option.name         = "tap_fsm_coverage";

    // -- State coverage: all 16 controller states. ----------------------
    cp_state : coverpoint state {
      bins states[] = {[TEST_LOGIC_RESET : UPDATE_IR]};
    }

    // -- Transition coverage. -------------------------------------------
    // Cross prev x current, then keep only the edges that exist in the
    // 1149.1 diagram. With 16 states the full cross is 256 cells; the
    // illegal_bins below collapse it to the 32 real edges.
    cp_prev : coverpoint prev {
      bins states[] = {[TEST_LOGIC_RESET : UPDATE_IR]};
    }

    x_trans : cross cp_prev, cp_state {
      // Legal next-states per source (TMS=0 and TMS=1 branches):
      bins tlr   = binsof(cp_prev) intersect {TEST_LOGIC_RESET} &&
                   binsof(cp_state) intersect {TEST_LOGIC_RESET, RUN_TEST_IDLE};
      bins rti   = binsof(cp_prev) intersect {RUN_TEST_IDLE} &&
                   binsof(cp_state) intersect {RUN_TEST_IDLE, SELECT_DR_SCAN};
      bins seldr = binsof(cp_prev) intersect {SELECT_DR_SCAN} &&
                   binsof(cp_state) intersect {CAPTURE_DR, SELECT_IR_SCAN};
      bins capdr = binsof(cp_prev) intersect {CAPTURE_DR} &&
                   binsof(cp_state) intersect {SHIFT_DR, EXIT1_DR};
      bins shdr  = binsof(cp_prev) intersect {SHIFT_DR} &&
                   binsof(cp_state) intersect {SHIFT_DR, EXIT1_DR};
      bins e1dr  = binsof(cp_prev) intersect {EXIT1_DR} &&
                   binsof(cp_state) intersect {PAUSE_DR, UPDATE_DR};
      bins paudr = binsof(cp_prev) intersect {PAUSE_DR} &&
                   binsof(cp_state) intersect {PAUSE_DR, EXIT2_DR};
      bins e2dr  = binsof(cp_prev) intersect {EXIT2_DR} &&
                   binsof(cp_state) intersect {SHIFT_DR, UPDATE_DR};
      bins upddr = binsof(cp_prev) intersect {UPDATE_DR} &&
                   binsof(cp_state) intersect {RUN_TEST_IDLE, SELECT_DR_SCAN};
      bins selir = binsof(cp_prev) intersect {SELECT_IR_SCAN} &&
                   binsof(cp_state) intersect {CAPTURE_IR, TEST_LOGIC_RESET};
      bins capir = binsof(cp_prev) intersect {CAPTURE_IR} &&
                   binsof(cp_state) intersect {SHIFT_IR, EXIT1_IR};
      bins shir  = binsof(cp_prev) intersect {SHIFT_IR} &&
                   binsof(cp_state) intersect {SHIFT_IR, EXIT1_IR};
      bins e1ir  = binsof(cp_prev) intersect {EXIT1_IR} &&
                   binsof(cp_state) intersect {PAUSE_IR, UPDATE_IR};
      bins pauir = binsof(cp_prev) intersect {PAUSE_IR} &&
                   binsof(cp_state) intersect {PAUSE_IR, EXIT2_IR};
      bins e2ir  = binsof(cp_prev) intersect {EXIT2_IR} &&
                   binsof(cp_state) intersect {SHIFT_IR, UPDATE_IR};
      bins updir = binsof(cp_prev) intersect {UPDATE_IR} &&
                   binsof(cp_state) intersect {RUN_TEST_IDLE, SELECT_DR_SCAN};

      // Everything else is not a legal 1149.1 edge.
      illegal_bins others = default sequence;
    }
  endgroup

  tap_cg cov = new();

  // Report at end of simulation.
  final $display("  [covergroup] tap_fsm_coverage = %0.1f%%", cov.get_coverage());

endmodule

// Bind into every FSM instance.
bind jtag_tap_fsm jtag_coverage u_cov (.tck(tck), .state(state));
`endif