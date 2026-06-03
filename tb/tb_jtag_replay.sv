// tb_jtag_replay.sv
// ---------------------------------------------------------------------------
// Replays externally-generated JTAG scan vectors against the jtag_tap DUT.
//
// Reads sim/jtag_vectors.vec (produced by scripts/gen_jtag_vectors.tcl),
// drives one (tms, tdi) pair per TCK, and checks TDO against the expected
// column. A literal 'x' in that column means "don't care" -- a response the
// generator could not predict (e.g. a pin-state-dependent boundary-scan
// capture), so those cycles are driven but not checked here.
//
// This closes the loop: the bits a separate Tcl tool computed actually run
// against the RTL, and CI fails ($fatal -> non-zero exit) on any mismatch.
//
// Vector-file format (whitespace columns, '#' comments):
//     tms tdi tdo        e.g.   0 0 1   /   1 0 x
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_jtag_replay;
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

  int checks  = 0;   // TDO bits actually compared (the non-x cycles)
  int errors  = 0;
  int applied = 0;   // total TCK cycles driven

  // File-parsing scratch.
  integer        fd, code, nf;
  reg [8*256-1:0] line;          // one text line
  reg [7:0]       ta, tb, tc;    // the three single-char tokens, as ASCII
  logic           tms_b, tdi_b, exp_b;
  bit             care;

  initial begin
    $dumpfile("sim/tap_replay.vcd");
    $dumpvars(0, tb_jtag_replay);

    // Drive the toy core pins to a defined value (only matters for waveforms;
    // the boundary-scan response bits are 'x' in the vectors, so unchecked).
    core_in = 2'b10;
    tdi = 1'b0;
    tms = 1'b1;

    // Real asynchronous reset pulse. The vectors' leading 5x TMS=1 would reach
    // Test-Logic-Reset on their own, but a clean trst_n edge resets under both
    // 2- and 4-state simulators (same pattern as tb_jtag_top.sv).
    trst_n = 1'b1; #2;
    trst_n = 1'b0; #5;
    trst_n = 1'b1; #5;

    fd = $fopen("sim/jtag_vectors.vec", "r");
    if (fd == 0)
      $fatal(1, "replay: cannot open sim/jtag_vectors.vec (run the Tcl generator first)");

    while (!$feof(fd)) begin
      code = $fgets(line, fd);
      nf   = (code != 0) ? $sscanf(line, "%s %s %s", ta, tb, tc) : 0;

      // Process only well-formed data lines: three tokens, not a '#' comment.
      if (nf == 3 && ta !== "#") begin
        tms_b = (ta === "1");
        tdi_b = (tb === "1");
        care  = (tc !== "x") && (tc !== "X");           // 'x' => don't-care
        exp_b = (tc === "1");

        // Present this cycle's stimulus, then sample TDO *before* the rising
        // edge -- TDO reflects the state established by the previous edge, the
        // same instant tb_jtag_top.sv samples it during a shift.
        tms = tms_b;
        tdi = tdi_b;
        #1;
        if (care) begin
          checks++;
          if (tdo !== exp_b) begin
            errors++;
            $display("  [FAIL] cycle %0d (state=0x%0h): TDO=%b expected %b",
                     applied, state, tdo, exp_b);
          end
        end

        // Rising edge advances the FSM + shift registers, then settle low.
        #1 tck = 1'b1;
        #2;
        tck = 1'b0;
        #2;
        applied++;
      end
    end
    $fclose(fd);

    $display("\n================ REPLAY SUMMARY ================");
    $display("cycles applied   : %0d", applied);
    $display("TDO checks       : %0d", checks);
    $display("TDO errors       : %0d", errors);
    if (errors == 0) $display("RESULT     : PASS");
    else             $display("RESULT     : FAIL");
    $display("===============================================");

    if (errors != 0)
      $fatal(1, "replay FAILED with %0d TDO mismatch(es)", errors);
    $finish;
  end

  // Safety net so a hang can't masquerade as a pass.
  initial begin
    #200000;
    $fatal(1, "TIMEOUT: replay testbench did not finish");
  end

endmodule