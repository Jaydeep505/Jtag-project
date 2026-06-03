// tb_jtag_tap_fsm.sv
// Directed, self-checking testbench for the 1149.1 TAP controller FSM.
//
// Strategy:
//   1. Async reset -> confirm Test-Logic-Reset.
//   2. Walk a 48-step TMS "tour" whose expected states are taken by hand
//      from the 1149.1 state diagram. The tour is constructed to traverse
//      every one of the 32 edges (16 states x 2 TMS values) at least once.
//      A coverage array records which edges were actually exercised and the
//      test FAILS if any edge is missed.
//   3. Confirm the "5 TMS-high TCKs forces Test-Logic-Reset" property.
//   4. Re-confirm async TRST_n from a deep state.

`timescale 1ns/1ps
module tb_jtag_tap_fsm;
  import jtag_pkg::*;

  logic       tck = 1'b0;
  logic       trst_n;
  logic       tms;
  tap_state_e state;
  logic       reset_n_int, capture_dr, shift_dr, update_dr;
  logic       capture_ir, shift_ir, update_ir;

  jtag_tap_fsm dut (
    .tck(tck), .trst_n(trst_n), .tms(tms), .state(state),
    .reset_n_int(reset_n_int),
    .capture_dr(capture_dr), .shift_dr(shift_dr), .update_dr(update_dr),
    .capture_ir(capture_ir), .shift_ir(shift_ir), .update_ir(update_ir)
  );

  int errors      = 0;
  int checks      = 0;
  bit covered [16][2];   // covered[from_state][tms] -- transition coverage
  bit visited [16];      // visited[state]           -- state coverage

  // .name() may only be called on an enum *variable* in Icarus, not on a
  // net/port, so wrap it: the function argument is a variable.
  function automatic string sname(input tap_state_e s);
    return s.name();
  endfunction

  // Apply one TCK cycle: set TMS, rising edge (state updates), then check.
  task automatic step(input logic tms_v, input tap_state_e exp);
    tap_state_e from;
    from = state;
    tms  = tms_v;
    #2 tck = 1'b1;        // rising edge -> state <= next
    #2;                   // settle
    covered[int'(from)][tms_v] = 1'b1;
    visited[int'(from)]        = 1'b1;   // state coverage: source...
    visited[int'(state)]       = 1'b1;   // ...and the state just entered
    checks++;
    if (state !== exp) begin
      errors++;
      $display("  [FAIL] %0t  %-16s --tms=%0b--> got %-16s  expected %-16s",
               $time, sname(from), tms_v, sname(state), sname(exp));
    end else begin
      $display("  [ ok ] %-16s --tms=%0b--> %-16s", sname(from), tms_v, sname(state));
    end
    tck = 1'b0;
    #2;
  endtask

  // -------------------------------------------------------------------
  // 48-step tour. Each {tms, expected_state} pair is read off the spec.
  // Collectively these traverse all 32 edges (verified by coverage below).
  // -------------------------------------------------------------------
  logic       tour_tms [48];
  tap_state_e tour_exp [48];

  task automatic build_tour();
    int i; i = 0;
    `define S(T,E) begin tour_tms[i]=(T); tour_exp[i]=(E); i++; end
    `S(1, TEST_LOGIC_RESET)               //  1  TLR  stays
    `S(0, RUN_TEST_IDLE)                  //  2
    `S(0, RUN_TEST_IDLE)                  //  3  RTI  stays
    `S(1, SELECT_DR_SCAN)                 //  4
    `S(0, CAPTURE_DR)                     //  5
    `S(0, SHIFT_DR)                       //  6
    `S(0, SHIFT_DR)                       //  7  ShDR stays
    `S(1, EXIT1_DR)                       //  8
    `S(0, PAUSE_DR)                       //  9
    `S(0, PAUSE_DR)                       // 10  PauDR stays
    `S(1, EXIT2_DR)                       // 11
    `S(0, SHIFT_DR)                       // 12  Exit2->Shift
    `S(1, EXIT1_DR)                       // 13
    `S(1, UPDATE_DR)                      // 14
    `S(0, RUN_TEST_IDLE)                  // 15
    `S(1, SELECT_DR_SCAN)                 // 16
    `S(0, CAPTURE_DR)                     // 17
    `S(1, EXIT1_DR)                       // 18  Capture->Exit1
    `S(1, UPDATE_DR)                      // 19
    `S(1, SELECT_DR_SCAN)                 // 20  Update->Select-DR
    `S(1, SELECT_IR_SCAN)                 // 21
    `S(0, CAPTURE_IR)                     // 22
    `S(0, SHIFT_IR)                       // 23
    `S(0, SHIFT_IR)                       // 24  ShIR stays
    `S(1, EXIT1_IR)                       // 25
    `S(0, PAUSE_IR)                       // 26
    `S(0, PAUSE_IR)                       // 27  PauIR stays
    `S(1, EXIT2_IR)                       // 28
    `S(0, SHIFT_IR)                       // 29  Exit2->Shift
    `S(1, EXIT1_IR)                       // 30
    `S(1, UPDATE_IR)                      // 31
    `S(1, SELECT_DR_SCAN)                 // 32  Update-IR->Select-DR
    `S(1, SELECT_IR_SCAN)                 // 33
    `S(0, CAPTURE_IR)                     // 34
    `S(1, EXIT1_IR)                       // 35  Capture->Exit1
    `S(0, PAUSE_IR)                       // 36
    `S(1, EXIT2_IR)                       // 37
    `S(1, UPDATE_IR)                      // 38  Exit2->Update
    `S(0, RUN_TEST_IDLE)                  // 39  Update-IR->RTI
    `S(1, SELECT_DR_SCAN)                 // 40
    `S(0, CAPTURE_DR)                     // 41
    `S(1, EXIT1_DR)                       // 42
    `S(0, PAUSE_DR)                       // 43
    `S(1, EXIT2_DR)                       // 44
    `S(1, UPDATE_DR)                      // 45  Exit2->Update
    `S(1, SELECT_DR_SCAN)                 // 46
    `S(1, SELECT_IR_SCAN)                 // 47
    `S(1, TEST_LOGIC_RESET)              // 48  Select-IR->TLR
    `undef S
  endtask

  // -------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------
  initial begin
    $dumpfile("sim/tap_fsm.vcd");
    $dumpvars(0, tb_jtag_tap_fsm);

    // ---- 1. Async reset ----
    tms    = 1'b1;
    trst_n = 1'b0;
    #5;
    if (state !== TEST_LOGIC_RESET) begin
      errors++; $display("  [FAIL] async TRST_n did not reach TEST_LOGIC_RESET (got %s)", sname(state));
    end else
      $display("  [ ok ] async TRST_n -> TEST_LOGIC_RESET");
    checks++;
    trst_n = 1'b1;
    #5;

    // ---- 2. Transition tour ----
    $display("\n-- transition tour (every edge of the 1149.1 diagram) --");
    build_tour();
    for (int k = 0; k < 48; k++) step(tour_tms[k], tour_exp[k]);

    // ---- 3. Functional coverage: states and transitions ----
    $display("\n-- functional coverage --");
    begin
      int states_hit; int edges_hit;
      states_hit = 0; edges_hit = 0;

      // State coverage: all 16 controller states reached.
      for (int s = 0; s < 16; s++)
        if (visited[s]) states_hit++;
        else begin
          errors++;
          $display("  [FAIL] state never visited: %s", sname(tap_state_e'(s)));
        end

      // Transition coverage: all 32 edges (16 states x 2 TMS values) taken.
      for (int s = 0; s < 16; s++)
        for (int t = 0; t < 2; t++)
          if (covered[s][t]) edges_hit++;
          else begin
            errors++;
            $display("  [FAIL] edge never exercised: %s tms=%0d",
                     sname(tap_state_e'(s)), t);
          end

      checks += 2;
      $display("  state coverage      : %0d / 16", states_hit);
      $display("  transition coverage : %0d / 32", edges_hit);
    end

    // ---- 4. "5 TMS-high TCKs -> Test-Logic-Reset" from a deep state ----
    $display("\n-- 5x TMS-high forces reset --");
    // navigate TLR->RTI->SDR->CapDR->ShDR to get away from reset
    step(1, TEST_LOGIC_RESET); // from TLR, tms=1 stays in TLR
    step(0, RUN_TEST_IDLE);
    step(1, SELECT_DR_SCAN);
    step(0, CAPTURE_DR);
    step(0, SHIFT_DR);
    // now hold TMS high; reset is guaranteed within 5 cycles
    for (int k = 0; k < 5; k++) begin tms = 1'b1; #2 tck = 1'b1; #2 tck = 1'b0; #2; end
    checks++;
    if (state !== TEST_LOGIC_RESET) begin
      errors++; $display("  [FAIL] 5x TMS-high did not reach reset (got %s)", sname(state));
    end else
      $display("  [ ok ] 5x TMS-high -> TEST_LOGIC_RESET");

    // ---- summary ----
    $display("\n==================================================");
    $display(" checks run : %0d", checks);
    $display(" errors     : %0d", errors);
    if (errors == 0) $display(" RESULT     : PASS");
    else             $display(" RESULT     : FAIL");
    $display("==================================================");

    // Honest exit code: fail the build (non-zero) on any error, instead of
    // always returning 0 via a bare $finish.
    if (errors != 0) $fatal(1, "FSM verification FAILED with %0d error(s)", errors);
    $finish;
  end

  // Safety net so a hang can't masquerade as a pass.
  initial begin
    #100000;
    $fatal(1, "TIMEOUT: testbench did not finish");
  end

endmodule : tb_jtag_tap_fsm