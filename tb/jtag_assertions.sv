// jtag_assertions.sv
// Assertion checker for the IEEE 1149.1 TAP -- the version that RUNS
// in CI.
//
// Icarus Verilog 12 does not support concurrent SVA (`assert property`),
// `bind`, or `disable iff`. So the IEEE-1149.1 invariants are expressed here
// as *immediate* assertions sampled on the rising edge of TCK (which Icarus
// does support). The equivalent concurrent-SVA form of every property below
// lives in rtl/jtag_sva.sv for SVA-capable simulators.
//
// The module is instantiated by tb_jtag_top and wired -- via hierarchical
// references -- to the DUT's internal DR-select / strobe nets, since without
// `bind` there is no other way to reach them. It owns a failure counter; the
// testbench reads `u_assert.fails` into its summary and $fatals if non-zero,
// so a broken invariant fails the build with a non-zero exit code.
//
// Properties checked (all on posedge TCK):
//   A1  reset_n_int low (controller in Test-Logic-Reset) => held IR = IDCODE
//   A2  exactly one data register is selected at all times ($onehot)
//   A3  any opcode that is not IDCODE/SAMPLE/EXTEST selects BYPASS
//   A4  IDCODE_VALUE bit 0 = 1 (so an IDCODE scan is distinguishable
//       from the single 0 BYPASS captures) -- checked once at elaboration
//   A5  the held instruction is never X/Z once out of reset
//   A6  TDO is driven 0 whenever the TAP is not in a Shift state

module jtag_assertions
  import jtag_pkg::*;
(
  input  logic            tck,
  input  logic            trst_n,

  input  logic            reset_n_int,   // low in Test-Logic-Reset
  input  logic [IR_W-1:0] instruction,   // held (active) instruction
  input  logic            sel_idcode,
  input  logic            sel_bsr,
  input  logic            sel_bypass,
  input  logic            shift_ir,
  input  logic            shift_dr,
  input  logic            tdo
);

  int fails = 0;

  // A4: a static property of the parameter -- check once, at time 0.
  initial begin
    if (IDCODE_VALUE[0] !== 1'b1) begin
      fails++;
      $display("  [ASSERT FAIL] A4 IDCODE LSB != 1 (IDCODE_VALUE=0x%08h)", IDCODE_VALUE);
    end
  end

  // Recognised-opcode predicate, used by A3.
  function automatic bit known_opcode(input logic [IR_W-1:0] insn);
    return (insn == INSN_IDCODE) || (insn == INSN_SAMPLE) ||
           (insn == INSN_EXTEST) || (insn == INSN_BYPASS);
  endfunction

  // $onehot misbehaves on a concatenation argument under Icarus, so the
  // select bus is assembled into a real vector first.
  logic [2:0] dr_sel;

  always @(posedge tck) begin
    dr_sel = {sel_idcode, sel_bsr, sel_bypass};

    // A1: in Test-Logic-Reset the active instruction must be IDCODE.
    if (!reset_n_int) begin
      assert (instruction == INSN_IDCODE)
        else begin
          fails++;
          $display("  [ASSERT FAIL] A1 reset state but IR=0x%01h (expected IDCODE)", instruction);
        end
    end

    // A2: exactly one DR selected at all times.
    assert ($onehot(dr_sel))
      else begin
        fails++;
        $display("  [ASSERT FAIL] A2 DR select not one-hot: {idcode,bsr,bypass}=%b", dr_sel);
      end

    // A3: an opcode outside {IDCODE,SAMPLE,EXTEST,BYPASS} must land on BYPASS.
    //     (BYPASS itself also selects BYPASS, hence the explicit set above.)
    if (!known_opcode(instruction) || (instruction == INSN_BYPASS)) begin
      assert (sel_bypass)
        else begin
          fails++;
          $display("  [ASSERT FAIL] A3 opcode 0x%01h did not select BYPASS", instruction);
        end
    end

    // A5: the held instruction must be fully known once out of reset.
    if (reset_n_int) begin
      assert (!$isunknown(instruction))
        else begin
          fails++;
          $display("  [ASSERT FAIL] A5 instruction has X/Z bits: 0x%01h", instruction);
        end
    end

    // A6: TDO must be quiet (0) when neither Shift-IR nor Shift-DR is active.
    if (!shift_ir && !shift_dr) begin
      assert (tdo === 1'b0)
        else begin
          fails++;
          $display("  [ASSERT FAIL] A6 TDO=%b while not shifting", tdo);
        end
    end
  end

endmodule