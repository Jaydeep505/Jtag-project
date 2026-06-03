// jtag_tap_fsm.sv
// IEEE 1149.1 Test Access Port (TAP) controller state machine.
//
// 16-state FSM driven by TMS, sampled on the RISING edge of TCK.
// TRST_n is the optional asynchronous, active-low reset that forces the
// controller into Test-Logic-Reset (1149.1 also allows reaching this state
// by holding TMS high for 5 TCKs, which this FSM does naturally).
//
// State sequencing only. The decoded strobe outputs (capture_*, shift_*,
// update_*, reset_n_int) are the hooks the IR and DR logic hang off.

module jtag_tap_fsm
  import jtag_pkg::*;
(
  input  logic       tck,         // test clock
  input  logic       trst_n,      // async active-low reset (optional in 1149.1)
  input  logic       tms,         // test mode select, sampled on posedge tck

  output tap_state_e state,        // current controller state

  // decoded control strobes for downstream IR/DR logic
  output logic       reset_n_int,  // de-asserted (0) while in Test-Logic-Reset
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
    unique case (state)
      TEST_LOGIC_RESET : next = tap_state_e'(tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE);
      RUN_TEST_IDLE    : next = tap_state_e'(tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE);

      SELECT_DR_SCAN   : next = tap_state_e'(tms ? SELECT_IR_SCAN   : CAPTURE_DR);
      CAPTURE_DR       : next = tap_state_e'(tms ? EXIT1_DR         : SHIFT_DR);
      SHIFT_DR         : next = tap_state_e'(tms ? EXIT1_DR         : SHIFT_DR);
      EXIT1_DR         : next = tap_state_e'(tms ? UPDATE_DR        : PAUSE_DR);
      PAUSE_DR         : next = tap_state_e'(tms ? EXIT2_DR         : PAUSE_DR);
      EXIT2_DR         : next = tap_state_e'(tms ? UPDATE_DR        : SHIFT_DR);
      UPDATE_DR        : next = tap_state_e'(tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE);

      SELECT_IR_SCAN   : next = tap_state_e'(tms ? TEST_LOGIC_RESET : CAPTURE_IR);
      CAPTURE_IR       : next = tap_state_e'(tms ? EXIT1_IR         : SHIFT_IR);
      SHIFT_IR         : next = tap_state_e'(tms ? EXIT1_IR         : SHIFT_IR);
      EXIT1_IR         : next = tap_state_e'(tms ? UPDATE_IR        : PAUSE_IR);
      PAUSE_IR         : next = tap_state_e'(tms ? EXIT2_IR         : PAUSE_IR);
      EXIT2_IR         : next = tap_state_e'(tms ? UPDATE_IR        : SHIFT_IR);
      UPDATE_IR        : next = tap_state_e'(tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE);

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
  // Decoded strobes: each is high while the controller is in its state.
  // ---------------------------------------------------------------------
  always_comb begin
    reset_n_int = (state != TEST_LOGIC_RESET);
    capture_dr  = (state == CAPTURE_DR);
    shift_dr    = (state == SHIFT_DR);
    update_dr   = (state == UPDATE_DR);
    capture_ir  = (state == CAPTURE_IR);
    shift_ir    = (state == SHIFT_IR);
    update_ir   = (state == UPDATE_IR);
  end

endmodule