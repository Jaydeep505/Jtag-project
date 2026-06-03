// tb_jtag_top.sv
// Directed verification of the full TAP (jtag_tap).
//
// Drives real JTAG scan sequences through TDI/TDO and checks the bits:
//   1. After reset the active instruction is IDCODE; scanning DR returns
//      the 32-bit IDCODE_VALUE (LSB first, so the first TDO bit is 1).
//   2. Loading BYPASS gives a 1-bit DR: TDO is TDI delayed by one TCK,
//      with a leading 0 from the capture.
//   3. Loading SAMPLE captures the toy core's pins into the boundary-scan
//      register; scanning DR returns {or, and, in1, in0} for the driven pins.
//
// Exit code is honest: $fatal (non-zero) on any failure, $finish on pass.

`timescale 1ns/1ps
module tb_jtag_top;
  import jtag_pkg::*;

  logic            tck = 1'b0;
  logic            trst_n;
  logic            tms;
  logic            tdi;
  logic            tdo;
  tap_state_e      state;
  logic [IR_W-1:0] instruction;
  logic [1:0]      core_in;
  logic [1:0]      core_out;

  jtag_tap dut (
    .tck(tck), .trst_n(trst_n), .tms(tms), .tdi(tdi), .tdo(tdo),
    .state(state), .instruction(instruction),
    .core_in(core_in), .core_out(core_out)
  );

  // Immediate-assertion checker (runs in the Icarus CI).
  // Under SVA_ON the concurrent assertions in rtl/jtag_sva.sv (bound into the
  // DUT) do the checking instead, so the immediate checker is left out to
  // avoid running two equivalent assertion sets at once.
`ifndef SVA_ON
  jtag_assertions u_assert (
    .tck(tck), .trst_n(trst_n),
    .reset_n_int(dut.reset_n_int),
    .instruction(instruction),
    .sel_idcode(dut.sel_idcode),
    .sel_bsr(dut.sel_bsr),
    .sel_bypass(dut.sel_bypass),
    .shift_ir(dut.shift_ir),
    .shift_dr(dut.shift_dr),
    .tdo(tdo)
  );
`endif

  int errors = 0;
  int checks = 0;

  // One TCK cycle with the given TMS; TDI must be set by the caller first.
  task automatic tck_pulse(input logic tms_v);
    tms = tms_v;
    #2 tck = 1'b1;   // rising edge: FSM + registers update
    #2;              // settle
    tck = 1'b0;
    #2;
  endtask

  task automatic check(input bit cond, input string msg);
    checks++;
    if (cond) $display("  [ ok ] %s", msg);
    else begin
      errors++;
      $display("  [FAIL] %s", msg);
    end
  endtask

  // Assumes RUN_TEST_IDLE. Loads `instr` into the IR, returns to RTI.
  task automatic load_ir(input logic [IR_W-1:0] instr);
    tck_pulse(1);                       // RTI       -> Select-DR
    tck_pulse(1);                       // Select-DR -> Select-IR
    tck_pulse(0);                       // Select-IR -> Capture-IR
    tck_pulse(0);                       // Capture-IR-> Shift-IR (capture here)
    for (int k = 0; k < IR_W; k++) begin
      tdi = instr[k];                   // LSB first
      tck_pulse(k == IR_W-1);           // last bit asserts TMS -> Exit1-IR
    end
    tck_pulse(1);                       // Exit1-IR  -> Update-IR (latch)
    tck_pulse(0);                       // Update-IR -> RTI
  endtask

  // Assumes RUN_TEST_IDLE. Scans `n` bits through the selected DR.
  // Feeds tdi_data LSB-first; captures TDO LSB-first into tdo_data.
  task automatic scan_dr(input  logic [63:0] tdi_data,
                         input  int          n,
                         output logic [63:0] tdo_data);
    tck_pulse(1);                       // RTI       -> Select-DR
    tck_pulse(0);                       // Select-DR -> Capture-DR
    tck_pulse(0);                       // Capture-DR-> Shift-DR (capture here)
    tdo_data = '0;
    for (int k = 0; k < n; k++) begin
      tdo_data[k] = tdo;                // sample current LSB before shifting
      tdi         = tdi_data[k];
      tck_pulse(k == n-1);              // last bit asserts TMS -> Exit1-DR
    end
    tck_pulse(1);                       // Exit1-DR  -> Update-DR
    tck_pulse(0);                       // Update-DR -> RTI
  endtask

  logic [63:0] got;

  initial begin
    $dumpfile("sim/tap_top.vcd");
    $dumpvars(0, tb_jtag_top);

    tdi = 0; tms = 1; core_in = 2'b00;

    // ---- Async reset ---------------------------------------------------
    // Start de-asserted, then drive a real high->low edge: the async resets
    // are negedge-triggered, so a TB that begins with trst_n already 0 would
    // produce no edge under a 2-state simulator (e.g. Verilator). The pulse
    // below resets cleanly under both 2- and 4-state tools.
    trst_n = 1'b1; #2;
    trst_n = 1'b0; #5;
    trst_n = 1'b1; #5;
    check(state == TEST_LOGIC_RESET, "async reset -> Test-Logic-Reset");
    check(instruction == INSN_IDCODE, "reset default instruction = IDCODE");

    // Move into RUN_TEST_IDLE.
    tck_pulse(0);
    check(state == RUN_TEST_IDLE, "TMS=0 from reset -> Run-Test-Idle");

    // ---- Test 1: IDCODE read (instruction is still IDCODE) -------------
    $display("\n-- Test 1: IDCODE scan --");
    scan_dr(64'h0, 32, got);
    check(got[31:0] == IDCODE_VALUE,
          $sformatf("IDCODE = 0x%08h (expected 0x%08h)", got[31:0], IDCODE_VALUE));
    check(got[0] == 1'b1, "IDCODE LSB = 1 (distinguishes from BYPASS)");

    // ---- Test 2: BYPASS 1-bit path ------------------------------------
    $display("\n-- Test 2: BYPASS scan --");
    load_ir(INSN_BYPASS);
    check(instruction == INSN_BYPASS, "instruction latched = BYPASS");
    scan_dr(64'hB2, 8, got);            // feed 8'b1011_0010
    // BYPASS captures 0, then TDO = TDI delayed one TCK.
    check(got[0] == 1'b0, "BYPASS capture bit = 0");
    begin
      logic [7:0] fed; logic ok;
      fed = 8'hB2; ok = 1'b1;
      for (int k = 1; k < 8; k++) if (got[k] !== fed[k-1]) ok = 1'b0;
      check(ok, "BYPASS TDO = TDI delayed by one TCK");
    end

    // ---- Test 3: boundary-scan SAMPLE ---------------------------------
    $display("\n-- Test 3: boundary-scan (SAMPLE) capture --");
    core_in = 2'b10;                    // in1=1, in0=0  -> and=0, or=1
    load_ir(INSN_SAMPLE);
    check(instruction == INSN_SAMPLE, "instruction latched = SAMPLE");
    scan_dr(64'h0, 4, got);
    // cells (LSB first): {or, and, in1, in0} = {1,0,1,0} = 4'b1010
    check(got[3:0] == 4'b1010,
          $sformatf("BSR capture = 0x%01h (expected 0xA)", got[3:0]));

    // ---- Test 4: unused opcode falls through to BYPASS ----------------
    $display("\n-- Test 4: unrecognised opcode -> BYPASS --");
    load_ir(4'b0111);                   // not a defined instruction
    scan_dr(64'h1, 4, got);
    check(got[0] == 1'b0 && got[1] == 1'b1,
          "unused opcode behaves as BYPASS (1-bit delay)");

    // ---- Tally ---------------------------------------------------------
    begin
      int assert_fails;
      int total_errors;
`ifdef SVA_ON
      assert_fails = 0;   // concurrent SVA reports via $error under --assert
`else
      assert_fails = u_assert.fails;
`endif
      total_errors = errors + assert_fails;
      $display("\n================ SUMMARY ================");
      $display("directed checks  : %0d", checks);
      $display("directed errors  : %0d", errors);
      $display("assertion fails  : %0d", assert_fails);
      $display("total errors     : %0d", total_errors);
      if (total_errors == 0) $display("RESULT     : PASS");
      else                   $display("RESULT     : FAIL");
      $display("=========================================");

      if (total_errors != 0)
        $fatal(1, "TAP verification FAILED with %0d error(s)", total_errors);
    end
    $finish;
  end

  // Safety net so a hang can't masquerade as a pass.
  initial begin
    #100000;
    $fatal(1, "TIMEOUT: testbench did not finish");
  end

endmodule