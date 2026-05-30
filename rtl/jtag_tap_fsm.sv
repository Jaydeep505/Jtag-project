// jtag_tap_fsm.sv
// IEEE 1149.1 Test Access Port (TAP) controller state machine.
//
// 16-state FSM driven by TMS, sampled on the RISING edge of TCK.
// TRST_n is the optional asynchronous, active-low reset that forces the
// controller into Test-Logic-Reset (1149.1 also allows reaching this state
// by holding TMS high for 5 TCKs, which this FSM does naturally).
//
// This block is the Day-1 deliverable: state sequencing only. The decoded
// strobe outputs (capture_*, shift_*, update_*) are the hooks the IR/DR
// logic will hang off in Day 2.

module jtag_tap_fsm
  import jtag_pkg::*;
(
  input  logic       tck,       // test clock
  input  logic       trst_n,    // async active-low reset (optional in 1149.1)
  input  logic       tms,       // test mode select, sampled on posedge tck

  output tap_state_e state,     // current controller state

  // decoded control strobes for downstream IR/DR logic (used in Day 2)
  output logic       reset_n_int, // de-asserted (0) while in Test-Logic-Reset
  output logic       capture_dr,
  output logic       shift_dr,
  output logic       update_dr,
  output logic       capture_ir,
  output logic       shift_ir,
  output logic       update_ir
);

  tap_state_e next;

  // ---------------------------------------------------------------------
  // Next-state logic -- a direct transcription of the 1149.1 state diagram.
  // For each state: TMS=1 takes the "right/up" branch, TMS=0 the "down/left".
  // ---------------------------------------------------------------------
  always_comb begin
    // For each state: the first literal is the TMS=1 target, the second TMS=0.
    unique case (state)
      TEST_LOGIC_RESET : if (tms) next = TEST_LOGIC_RESET; else next = RUN_TEST_IDLE;
      RUN_TEST_IDLE    : if (tms) next = SELECT_DR_SCAN;   else next = RUN_TEST_IDLE;

      SELECT_DR_SCAN   : if (tms) next = SELECT_IR_SCAN;   else next = CAPTURE_DR;
      CAPTURE_DR       : if (tms) next = EXIT1_DR;         else next = SHIFT_DR;
      SHIFT_DR         : if (tms) next = EXIT1_DR;         else next = SHIFT_DR;
      EXIT1_DR         : if (tms) next = UPDATE_DR;        else next = PAUSE_DR;
      PAUSE_DR         : if (tms) next = EXIT2_DR;         else next = PAUSE_DR;
      EXIT2_DR         : if (tms) next = UPDATE_DR;        else next = SHIFT_DR;
      UPDATE_DR        : if (tms) next = SELECT_DR_SCAN;   else next = RUN_TEST_IDLE;

      SELECT_IR_SCAN   : if (tms) next = TEST_LOGIC_RESET; else next = CAPTURE_IR;
      CAPTURE_IR       : if (tms) next = EXIT1_IR;         else next = SHIFT_IR;
      SHIFT_IR         : if (tms) next = EXIT1_IR;         else next = SHIFT_IR;
      EXIT1_IR         : if (tms) next = UPDATE_IR;        else next = PAUSE_IR;
      PAUSE_IR         : if (tms) next = EXIT2_IR;         else next = PAUSE_IR;
      EXIT2_IR         : if (tms) next = UPDATE_IR;        else next = SHIFT_IR;
      UPDATE_IR        : if (tms) next = SELECT_DR_SCAN;   else next = RUN_TEST_IDLE;

      default          : next = TEST_LOGIC_RESET;
    endcase
  end

  // ---------------------------------------------------------------------
  // State register: TMS is sampled on the rising edge of TCK.
  // ---------------------------------------------------------------------
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) state <= TEST_LOGIC_RESET;
    else         state <= next;
  end

  // ---------------------------------------------------------------------
  // Decoded outputs (combinational decode of current state).
  // ---------------------------------------------------------------------
  assign reset_n_int = (state != TEST_LOGIC_RESET);
  assign capture_dr  = (state == CAPTURE_DR);
  assign shift_dr    = (state == SHIFT_DR);
  assign update_dr   = (state == UPDATE_DR);
  assign capture_ir  = (state == CAPTURE_IR);
  assign shift_ir    = (state == SHIFT_IR);
  assign update_ir   = (state == UPDATE_IR);

endmodule : jtag_tap_fsm
