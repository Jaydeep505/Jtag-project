// jtag_ir.sv
// IEEE 1149.1 instruction register.
//
// Three phases, driven by the TAP FSM strobes:
//   Capture-IR : load a fixed pattern whose two LSBs are 01 (mandated by
//                1149.1 so the captured value is recognisable on TDO).
//   Shift-IR   : shift LSB-first from TDI toward TDO (ir_tdo = bit 0).
//   Update-IR  : latch the shifted value into the held instruction.
// Reset (async TRST_n or Test-Logic-Reset via TMS) forces IDCODE, so a
// freshly reset device always presents its IDCODE register first.

module jtag_ir
  import jtag_pkg::*;
(
  input  logic            tck,
  input  logic            trst_n,
  input  logic            tdi,

  input  logic            capture_ir,
  input  logic            shift_ir,
  input  logic            update_ir,
  input  logic            reset_n_int,   // low in Test-Logic-Reset

  output logic [IR_W-1:0] instruction,   // held (active) instruction bits
  output logic            ir_tdo         // serial output of the shift stage
);

  logic [IR_W-1:0] shiftreg;
  logic [IR_W-1:0] held;

  // Shift stage.
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n)         shiftreg <= '0;
    else if (capture_ir) shiftreg <= 4'b0001;                 // two LSBs = 01
    else if (shift_ir)   shiftreg <= {tdi, shiftreg[IR_W-1:1]};
  end

  assign ir_tdo = shiftreg[0];

  // Held instruction. Both reset paths force IDCODE.
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n)           held <= INSN_IDCODE;
    else if (!reset_n_int) held <= INSN_IDCODE;
    else if (update_ir)    held <= shiftreg;
  end

  assign instruction = held;

endmodule