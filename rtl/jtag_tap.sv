// jtag_tap.sv
// Full IEEE 1149.1 TAP: FSM (Day 1) + instruction register + the three
// mandatory data registers, with the DR mux and the TDO output stage.
//
// Data registers:
//   BYPASS  - 1 bit,  captures 0, gives a single-bit shift path.
//   IDCODE  - 32 bit, captures the hardcoded device ID (LSB = 1).
//   BSR     - 4-cell boundary-scan register around a toy combinational core
//             (2 inputs -> AND/OR). SAMPLE captures the pins; EXTEST drives
//             the outputs from the update latch instead of the core.
//
// Instruction -> DR selection (any unrecognised opcode falls through to
// BYPASS, as 1149.1 requires).

module jtag_tap
  import jtag_pkg::*;
(
  input  logic       tck,
  input  logic       trst_n,
  input  logic       tms,
  input  logic       tdi,
  output logic       tdo,

  output tap_state_e state,        // exposed for debug / verification
  output logic [IR_W-1:0] instruction,

  // toy "system" pins wrapped by the boundary-scan register
  input  logic [1:0] core_in,
  output logic [1:0] core_out
);

  // -------- FSM (Day 1) --------------------------------------------------
  logic reset_n_int;
  logic capture_dr, shift_dr, update_dr;
  logic capture_ir, shift_ir, update_ir;

  jtag_tap_fsm u_fsm (
    .tck(tck), .trst_n(trst_n), .tms(tms), .state(state),
    .reset_n_int(reset_n_int),
    .capture_dr(capture_dr), .shift_dr(shift_dr), .update_dr(update_dr),
    .capture_ir(capture_ir), .shift_ir(shift_ir), .update_ir(update_ir)
  );

  // -------- Instruction register ----------------------------------------
  logic ir_tdo;

  jtag_ir u_ir (
    .tck(tck), .trst_n(trst_n), .tdi(tdi),
    .capture_ir(capture_ir), .shift_ir(shift_ir), .update_ir(update_ir),
    .reset_n_int(reset_n_int),
    .instruction(instruction), .ir_tdo(ir_tdo)
  );

  // -------- DR selection -------------------------------------------------
  logic sel_idcode, sel_bsr, sel_bypass;
  always_comb begin
    sel_idcode = (instruction == INSN_IDCODE);
    sel_bsr    = (instruction == INSN_SAMPLE) || (instruction == INSN_EXTEST);
    sel_bypass = ~(sel_idcode | sel_bsr);   // everything else -> BYPASS
  end

  // -------- BYPASS register (1 bit) -------------------------------------
  logic bypass_sr;
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n)                         bypass_sr <= 1'b0;
    else if (sel_bypass && capture_dr)   bypass_sr <= 1'b0;
    else if (sel_bypass && shift_dr)     bypass_sr <= tdi;
  end

  // -------- IDCODE register (32 bit) ------------------------------------
  logic [31:0] idcode_sr;
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n)                         idcode_sr <= IDCODE_VALUE;
    else if (sel_idcode && capture_dr)   idcode_sr <= IDCODE_VALUE;
    else if (sel_idcode && shift_dr)     idcode_sr <= {tdi, idcode_sr[31:1]};
  end

  // -------- Toy core + boundary-scan register (4 cells) -----------------
  // Cell order (LSB first on TDO): {or_out, and_out, core_in[1], core_in[0]}
  logic and_f, or_f;
  assign and_f = core_in[0] & core_in[1];
  assign or_f  = core_in[0] | core_in[1];

  logic [3:0] bsr;          // shift stage
  logic [1:0] out_latch;    // EXTEST output update latch
  logic [1:0] bsr_out_cells;
  assign bsr_out_cells = bsr[3:2];

  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n)                       bsr <= '0;
    else if (sel_bsr && capture_dr)    bsr <= {or_f, and_f, core_in[1], core_in[0]};
    else if (sel_bsr && shift_dr)      bsr <= {tdi, bsr[3:1]};
  end

  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n)                       out_latch <= 2'b00;
    else if (sel_bsr && update_dr)     out_latch <= bsr_out_cells;
  end

  // In EXTEST the pins are driven by the boundary cells; otherwise by the core.
  assign core_out = (instruction == INSN_EXTEST) ? out_latch : {or_f, and_f};

  // -------- DR mux + TDO output stage -----------------------------------
  logic dr_tdo;
  always_comb begin
    if      (sel_idcode) dr_tdo = idcode_sr[0];
    else if (sel_bsr)    dr_tdo = bsr[0];
    else                 dr_tdo = bypass_sr;
  end

  // TDO presents the IR shift output in Shift-IR, the selected DR's in
  // Shift-DR, and 0 otherwise.
  always_comb begin
    if      (shift_ir) tdo = ir_tdo;
    else if (shift_dr) tdo = dr_tdo;
    else               tdo = 1'b0;
  end

endmodule