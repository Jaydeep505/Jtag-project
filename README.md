# JTAG TAP Controller (IEEE 1149.1)

A small, verified Design-for-Test (DFT) block: the Test Access Port controller
defined by IEEE 1149.1. Built in SystemVerilog, simulated with Icarus Verilog.

## Status

- **Day 1 (done):** 16-state TAP controller FSM + self-checking transition test.
- Day 2 (planned): instruction register (capture/shift/update), DR mux, and the
  mandatory data registers — BYPASS (1b), IDCODE (32b), and a small
  boundary-scan register.
- Day 3 (planned): SVA assertions, functional coverage, write-up.

## Layout

```
rtl/
  jtag_pkg.sv        # tap_state_e enum (the 16 states)
  jtag_tap_fsm.sv    # the TAP controller state machine
tb/
  tb_jtag_tap_fsm.sv # directed, self-checking transition testbench
sim/
  tap_fsm.vcd        # waveform dump (generated)
Makefile
```

## The state machine

16 states, sampled on the rising edge of `tck`, selected by `tms`:

```
Test-Logic-Reset, Run-Test/Idle,
Select-DR-Scan, Capture-DR, Shift-DR, Exit1-DR, Pause-DR, Exit2-DR, Update-DR,
Select-IR-Scan, Capture-IR, Shift-IR, Exit1-IR, Pause-IR, Exit2-IR, Update-IR
```

Reset to `Test-Logic-Reset` happens two ways: the optional asynchronous
`trst_n`, or holding `tms` high for 5 `tck` cycles (guaranteed by the diagram
from any state). The FSM exposes decoded strobes — `capture_dr/shift_dr/
update_dr`, the IR equivalents, and `reset_n_int` — which the Day-2 IR/DR
logic will consume.

## Run it

```
make        # compile + run the self-checking testbench
make wave   # also open the VCD in GTKWave
make clean
```

## Test results (Day 1)

The testbench drives a 48-step TMS tour constructed to traverse every edge of
the 1149.1 diagram, with expected states taken by hand from the spec. It then
checks edge coverage and both reset paths.

```
edges covered: 32 / 32
checks run : 55
errors     : 0
RESULT     : PASS
```
