// jtag_pkg.sv
// Shared types for the IEEE 1149.1 TAP controller.
//
// The 16 controller states from the IEEE 1149.1 state diagram. The 4-bit
// encoding here is arbitrary (chosen for readability, not for any decode
// trick) -- the standard does not mandate an encoding, only the transitions.
package jtag_pkg;

  typedef enum logic [3:0] {
    TEST_LOGIC_RESET = 4'h0,
    RUN_TEST_IDLE    = 4'h1,
    SELECT_DR_SCAN   = 4'h2,
    CAPTURE_DR       = 4'h3,
    SHIFT_DR         = 4'h4,
    EXIT1_DR         = 4'h5,
    PAUSE_DR         = 4'h6,
    EXIT2_DR         = 4'h7,
    UPDATE_DR        = 4'h8,
    SELECT_IR_SCAN   = 4'h9,
    CAPTURE_IR       = 4'hA,
    SHIFT_IR         = 4'hB,
    EXIT1_IR         = 4'hC,
    PAUSE_IR         = 4'hD,
    EXIT2_IR         = 4'hE,
    UPDATE_IR        = 4'hF
  } tap_state_e;

endpackage : jtag_pkg
