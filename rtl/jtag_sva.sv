// jtag_sva.sv
// Concurrent-SVA form of the IEEE 1149.1 TAP invariants.
//
// This is the canonical `assert property` statement of the same properties
// the immediate-assertion checker (tb/jtag_assertions.sv) enforces in the
// Icarus CI. Icarus Verilog 12 cannot parse concurrent assertions or `bind`,
// so the whole file is guarded behind SVA_ON and is compiled only by an
// SVA-capable simulator (Verilator with --assert, or a commercial tool).
//
//   make sva     # elaborate these assertions under Verilator
//
// The module is bound into jtag_tap by name (.*), so each port below binds
// to the like-named net inside the DUT.

`ifdef SVA_ON
module jtag_sva
  import jtag_pkg::*;
(
  input logic            tck,
  input logic            trst_n,
  input logic            reset_n_int,
  input logic [IR_W-1:0] instruction,
  input logic            sel_idcode,
  input logic            sel_bsr,
  input logic            sel_bypass,
  input logic            shift_ir,
  input logic            shift_dr,
  input logic            tdo
);

  // Recognised opcodes -> the ones with a dedicated data register.
  function automatic bit known_opcode(input logic [IR_W-1:0] insn);
    return (insn == INSN_IDCODE) || (insn == INSN_SAMPLE) ||
           (insn == INSN_EXTEST) || (insn == INSN_BYPASS);
  endfunction

  default clocking cb @(posedge tck); endclocking

  // A1: while the controller is in Test-Logic-Reset the active instruction
  //     is forced to IDCODE.
  property p_reset_idcode;
    disable iff (!trst_n) (!reset_n_int) |-> (instruction == INSN_IDCODE);
  endproperty
  a_reset_idcode : assert property (p_reset_idcode)
    else $error("A1 reset state but IR=0x%01h", instruction);

  // A2: exactly one data register is selected at all times.
  property p_onehot_dr;
    disable iff (!trst_n) $onehot({sel_idcode, sel_bsr, sel_bypass});
  endproperty
  a_onehot_dr : assert property (p_onehot_dr)
    else $error("A2 DR select not one-hot: %b%b%b", sel_idcode, sel_bsr, sel_bypass);

  // A3: any opcode without its own DR (or BYPASS) must select BYPASS.
  property p_unknown_bypass;
    disable iff (!trst_n)
      (!known_opcode(instruction) || (instruction == INSN_BYPASS)) |-> sel_bypass;
  endproperty
  a_unknown_bypass : assert property (p_unknown_bypass)
    else $error("A3 opcode 0x%01h did not select BYPASS", instruction);

  // A5: the held instruction is never X/Z once out of reset.
  property p_ir_known;
    disable iff (!trst_n) reset_n_int |-> !$isunknown(instruction);
  endproperty
  a_ir_known : assert property (p_ir_known)
    else $error("A5 instruction has X/Z bits: 0x%01h", instruction);

  // A6: TDO is driven 0 whenever the TAP is not in a Shift state.
  property p_tdo_quiet;
    disable iff (!trst_n) (!shift_ir && !shift_dr) |-> (tdo == 1'b0);
  endproperty
  a_tdo_quiet : assert property (p_tdo_quiet)
    else $error("A6 TDO=%b while not shifting", tdo);

  // A4: IDCODE bit 0 must be 1 -- a static property of the parameter.
  initial assert (IDCODE_VALUE[0] === 1'b1)
    else $error("A4 IDCODE LSB != 1 (IDCODE_VALUE=0x%08h)", IDCODE_VALUE);

endmodule

// Bind the checker into every jtag_tap instance, connecting by name.
bind jtag_tap jtag_sva u_sva (.*);
`endif