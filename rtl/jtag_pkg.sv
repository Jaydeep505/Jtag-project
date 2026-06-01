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

  // ---- Day 2 additions: instruction-register width and mandatory opcodes.
  // 4-bit IR. EXTEST conventionally all-zero, BYPASS all-one; everything
  // not explicitly decoded must select BYPASS (1149.1 safety requirement).
  localparam int unsigned IR_W = 4;

  typedef enum logic [IR_W-1:0] {
    INSN_EXTEST  = 4'b0000,
    INSN_SAMPLE  = 4'b0001,   // SAMPLE/PRELOAD -> boundary-scan register
    INSN_IDCODE  = 4'b0010,   // -> 32-bit IDCODE register
    INSN_BYPASS  = 4'b1111    // -> 1-bit BYPASS register
  } jtag_insn_e;

  // Hardcoded device identification register value.
  // 1149.1 requires bit 0 == 1 so a IDCODE scan is distinguishable from the
  // single 0 a BYPASS register captures. The nibbles are just a readable
  // nod to the standard; pick anything with LSB=1 for a real part.
  localparam logic [31:0] IDCODE_VALUE = 32'h1149_0001;

endpackage : jtag_pkg