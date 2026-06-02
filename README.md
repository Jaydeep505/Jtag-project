# JTAG TAP Controller (IEEE 1149.1)

[![ci](https://github.com/Jaydeep505/Jtag-project/actions/workflows/ci.yml/badge.svg)](https://github.com/Jaydeep505/Jtag-project/actions/workflows/ci.yml)

A small, fully verified Design-for-Test (DFT) block: the Test Access Port
controller defined by IEEE 1149.1, written in SystemVerilog and verified with
self-checking testbenches, assertions, and functional coverage. The default
flow runs on Icarus Verilog; the concurrent-SVA flow runs on Verilator.

## Status

- **Day 1 (done):** 16-state TAP controller FSM + self-checking transition
  test. 16/16 state coverage, 32/32 transition coverage.
- **Day 2 (done):** instruction register (capture/shift/update), the DR mux,
  and the three mandatory data registers — BYPASS (1b), IDCODE (32b), and a
  4-cell boundary-scan register around a toy AND/OR core.
- **Day 3 (done):** assertions for the 1149.1 invariants (immediate form run
  by Icarus, concurrent-SVA form run by Verilator), functional coverage, and
  this write-up.

## Layout

```
rtl/
  jtag_pkg.sv        # tap_state_e enum (16 states); IR width + opcodes; IDCODE
  jtag_tap_fsm.sv    # the TAP controller state machine + decoded strobes
  jtag_ir.sv         # instruction register (capture / shift / update)
  jtag_tap.sv        # top: FSM + IR + DRs + DR mux + TDO stage
  jtag_sva.sv        # concurrent SVA (assert property), bound; Verilator-only
tb/
  tb_jtag_tap_fsm.sv # Day-1 directed FSM bench + state/transition coverage
  tb_jtag_top.sv     # Day-2/3 directed scan bench, wires in the checker
  jtag_assertions.sv # immediate-assertion checker (runs under Icarus)
  jtag_coverage.sv   # covergroup form, for covergroup-capable simulators
sim/                 # build + waveform artifacts (generated, git-ignored)
.github/workflows/ci.yml
Makefile
```

## Block diagram

```
                 tck  trst_n  tms                        tdi
                  |     |      |                           |
                  v     v      v                           |
            +---------------------+                        |
            |   jtag_tap_fsm      |  state[3:0]            |
            |  (16-state TAP FSM) +--------------+         |
            +---------+-----------+              |         |
                      | decoded strobes          |         |
   capture/shift/update_ir | capture/shift/update_dr |     |
   reset_n_int            v                       v         v
            +---------------------+        +---------------------------+
            |      jtag_ir        | instr  |   data registers + mux    |
            |  capture 0001       +------->|  IDCODE  (32b, LSB=1)     |
            |  shift  LSB-first   |        |  BSR     (4 cells)        |
            |  update -> held     | ir_tdo |  BYPASS  (1b)             |
            +----------+----------+        |  sel_* (one-hot)          |
                       |                   +-------------+-------------+
                       |                          dr_tdo |
                       +--------------+------------------+
                                      v
                              +---------------+
                              |  TDO mux      |  shift_ir ? ir_tdo :
                              |               |  shift_dr ? dr_tdo : 0
                              +-------+-------+
                                      v
                                     tdo

   core_in[1:0] --> toy AND/OR core --> core_out[1:0]   (wrapped by the BSR;
                                                          EXTEST drives outputs
                                                          from the update latch)
```

## The state machine

16 states, sampled on the rising edge of `tck`, selected by `tms`:

```
Test-Logic-Reset, Run-Test/Idle,
Select-DR-Scan, Capture-DR, Shift-DR, Exit1-DR, Pause-DR, Exit2-DR, Update-DR,
Select-IR-Scan, Capture-IR, Shift-IR, Exit1-IR, Pause-IR, Exit2-IR, Update-IR
```

Each state has exactly two outgoing edges, taken on `tms = 0` and `tms = 1`.
The DR and IR columns are structurally identical seven-state ladders
(Capture -> Shift -> Exit1 -> Pause -> Exit2 -> Update, with the Shift and
Pause self-loops); `Select-DR-Scan`/`Select-IR-Scan` choose between them and
`Update-*` returns to `Run-Test/Idle` (tms=0) or `Select-DR-Scan` (tms=1):

```
   Test-Logic-Reset --tms=0--> Run-Test/Idle --tms=1--> Select-DR-Scan
        ^  (tms=1 self-loop)        ^ (tms=0 loop)        /          \
        |                                          tms=0 /            \ tms=1
        |                                               v              v
        |                                          Capture-DR    Select-IR-Scan
        |                                               |          /        \
        |                                  +------ DR ladder       |  tms=1  | tms=0
        |                                  | Shift<->Exit1         v         v
        |                                  | Pause<->Exit2    (Test-Logic-  Capture-IR
        |                                  | Update                Reset)        |
        |                                  +-->(RTI / Select-DR)         IR ladder
        +-------------------- (Select-IR-Scan --tms=1--> TLR) ------------ Update
```

Reset to `Test-Logic-Reset` happens two ways: the optional asynchronous
`trst_n`, or holding `tms` high for 5 `tck` cycles (guaranteed from any state
by the diagram). The FSM exposes decoded strobes — `capture_dr/shift_dr/
update_dr`, the IR equivalents, and `reset_n_int` — which the IR and DR logic
consume.

## Instructions and data registers

The IR is 4 bits. After reset the held instruction is forced to `IDCODE`, so a
freshly reset device always presents its ID register first. Any opcode without
its own data register falls through to `BYPASS`, as 1149.1 requires.

| Opcode  | Mnemonic | Selected DR        | Notes                                   |
|---------|----------|--------------------|-----------------------------------------|
| `0000`  | EXTEST   | boundary-scan (4b) | drives `core_out` from the update latch |
| `0001`  | SAMPLE   | boundary-scan (4b) | captures the pins `{or, and, in1, in0}` |
| `0010`  | IDCODE   | IDCODE (32b)       | `0x1149_0001`, LSB = 1 by rule          |
| `1111`  | BYPASS   | BYPASS (1b)        | captures 0, single-cycle shift          |
| *other* | —        | BYPASS (1b)        | mandatory fall-through                   |

`IDCODE_VALUE` is `0x1149_0001`. Bit 0 is 1 so an IDCODE scan is
distinguishable on TDO from the single 0 a BYPASS register captures.

## Verification

The design is checked three ways, all gated in CI.

**Directed self-checking testbenches.** The Day-1 bench drives a 48-step TMS
tour built to traverse every edge of the diagram and checks each landing state
against the spec by hand; the Day-2 bench drives real scan sequences through
TDI/TDO and checks the bits (IDCODE read-back, BYPASS one-cycle delay,
boundary-scan SAMPLE capture, unused-opcode-to-BYPASS). Both `$fatal` on any
error, so a failing run returns a non-zero exit code.

**Functional coverage.** The FSM bench records every state it visits and every
(state, tms) edge it takes, and fails the build if any of the 16 states or 32
transitions is missed. This formalizes, as a pass/fail gate, the coverage the
tour was designed to hit:

```
state coverage      : 16 / 16
transition coverage : 32 / 32
```

The equivalent SystemVerilog `covergroup` (a `coverpoint` over the 16 states
plus a filtered state x state cross for the 32 legal edges) lives in
`tb/jtag_coverage.sv` for simulators that parse covergroups.

**Assertions.** Six IEEE-1149.1 invariants are checked on every TCK:

| #  | Property                                                       |
|----|----------------------------------------------------------------|
| A1 | in Test-Logic-Reset the held instruction is IDCODE             |
| A2 | exactly one data register is selected (`$onehot`)              |
| A3 | any opcode without its own DR (and BYPASS) selects BYPASS      |
| A4 | `IDCODE_VALUE` bit 0 is 1                                       |
| A5 | the held instruction is never X/Z once out of reset            |
| A6 | TDO is driven 0 whenever the TAP is not in a Shift state       |

These ship in two equivalent forms because the toolchain splits on SVA
support:

- `tb/jtag_assertions.sv` — **immediate** assertions, which Icarus Verilog 12
  supports. Wired to the DUT internals by hierarchical reference (Icarus has
  no `bind`), counting failures so the bench `$fatal`s on any violation. This
  is what gates the default `make` / CI.
- `rtl/jtag_sva.sv` — the same six properties as **concurrent** `assert
  property`, `bind`-ed into the DUT. Icarus cannot parse concurrent SVA, so
  this is guarded behind `+define+SVA_ON` and run by Verilator (`make sva`),
  which elaborates the bound assertions and checks them across the full timed
  simulation. Each assertion has been mutation-tested under both tools (inject
  a bug -> the relevant assertion fires and the run exits non-zero).

## Run it

```
make        # Icarus: both benches (FSM coverage + full-TAP directed + asserts)
make fsm    # Day 1 only:  FSM bench + state/transition coverage
make top    # Day 2/3:     full TAP + immediate-assertion checker
make sva    # Day 3:       concurrent SVA under Verilator (assert property)
make clean
```

Waveforms land in `sim/*.vcd`; open them with GTKWave or Surfer
(`surfer sim/tap_top.vcd`).

## Toolchain

```
brew install icarus-verilog verilator surfer   # macOS
sudo apt-get install -y iverilog verilator      # Debian/Ubuntu (as in CI)
```

CI runs two jobs on every push: Icarus builds and runs both benches (with
log-level PASS/FAIL gating on top of the exit code), and Verilator elaborates
and runs the concurrent SVA.

## A note on Icarus 12

Icarus Verilog 12 does not support concurrent SVA (`assert property`),
`bind`, or covergroups, and prints harmless `sorry:` advisories for `unique`
case qualifiers and constant part-selects in `always_*` blocks. None of these
are errors — they vanish under Verilator and commercial tools. The project is
structured so the Icarus flow stays self-contained and green while the
concurrent-SVA form is exercised by Verilator, so nothing is merely asserted
on paper: every property and coverage goal is actually run and gated by a
simulator.