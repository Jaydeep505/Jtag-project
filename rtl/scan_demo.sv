// scan_demo.sv
// ---------------------------------------------------------------------------
// A minimal *full-scan* design block, to demonstrate the two DFT techniques
// that sit underneath JTAG: internal scan insertion and the ATPG patterns
// that exploit it. (The TAP controller in this repo is the access mechanism;
// scan is what you actually shift through it on a real chip.)
//
// The functional circuit is trivial on purpose: four flops q[3:0] whose next
// value is a small combinational cloud n = f(q). The point is not f -- it is
// what scan insertion does to the flops.
//
// Scan insertion
// --------------
// Every flop is replaced by a "muxed-D" scan flop: a 2:1 mux on the D input
// chooses between the functional value (n[i]) and the scan path (the previous
// flop's output), selected by scan_en:
//
//        scan_en=0 (capture / functional):  q[i] <= n[i]
//        scan_en=1 (shift):                 q[i] <= q[i-1]   (q[0] <= scan_in)
//
// The flops are stitched head-to-tail into one shift register:
//        scan_in -> q0 -> q1 -> q2 -> q3 -> scan_out
// so in shift mode the chain is fully controllable (load any q via scan_in)
// and fully observable (read any q via scan_out). That is the whole trick:
// it makes the sequential flops behave like scan-accessible pins, leaving
// only the combinational f to be tested -- which is what ATPG targets.
//
// Test loop (per pattern): shift in a value (scan_en=1, N cycles) -> capture
// one functional clock (scan_en=0) -> shift the response out (scan_en=1)
// while shifting the next pattern in. tb/tb_scan_atpg.sv drives exactly this.
//
// Fault injection
// ---------------
// To let the testbench prove ATPG results in hardware (the same "mutation
// test" idea used for the SVA in this repo), the combinational cloud can have
// a single stuck-at fault forced onto one net at run time:
//     fault_en=1, fault_site=<code>, fault_val=<0|1>
// Codes match the net names in scripts/atpg.py:
//     1 -> n0    (output of the q0&q1 AND)
//     2 -> ginv1 (the ~q1 net feeding the lower AND of the n3 cone)
// With fault_en=0 the block is the clean DUT.

module scan_demo #(
  parameter int N = 4
) (
  input  logic         clk,
  input  logic         rst_n,       // async, active-low

  input  logic         scan_en,     // 1 = shift, 0 = capture/functional
  input  logic         scan_in,     // chain head
  output logic         scan_out,    // chain tail (= q[N-1])

  // run-time single stuck-at fault injection (for mutation testing)
  input  logic         fault_en,
  input  logic [3:0]   fault_site,
  input  logic         fault_val,

  output logic [N-1:0] q            // exposed for waveform / debug
);

  // -------- combinational cloud  n = f(q) --------------------------------
  // Kept bit-identical to evaluate() in scripts/atpg.py.
  logic and01, or12, and03, ginv1, g3a, g3b;
  logic [N-1:0] n;

  always_comb begin
    and01 = q[0] & q[1];
    or12  = q[1] | q[2];
    and03 = q[0] & q[3];

    ginv1 = ~q[1];
    if (fault_en && fault_site == 4'd2) ginv1 = fault_val;   // site 2

    g3a = q[0] & q[1];
    g3b = q[0] & ginv1;

    n[0] = and01;
    if (fault_en && fault_site == 4'd1) n[0] = fault_val;    // site 1
    n[1] = or12;
    n[2] = and03;
    n[3] = g3a | g3b;            // = q0&q1 + q0&~q1 == q0  (redundant cone)
  end

  // -------- muxed-D scan flops, stitched into a chain --------------------
  // scan_en selects the scan path; the chain runs q0 -> q1 -> ... -> q[N-1].
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      q <= '0;
    else if (scan_en)
      q <= (q << 1) | scan_in;     // shift: q0<=scan_in, q[i]<=q[i-1]
    else
      q <= n;                      // capture: functional next value
  end

  assign scan_out = q[N-1];

endmodule