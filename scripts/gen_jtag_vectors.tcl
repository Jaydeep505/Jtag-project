#!/usr/bin/env tclsh
#
# gen_jtag_vectors.tcl
# ---------------------------------------------------------------------------
# Programmatic JTAG scan-vector generator for the IEEE 1149.1 TAP controller
# in this repo (rtl/jtag_tap_fsm.sv, rtl/jtag_pkg.sv).
#
# It models the 16-state TAP as a graph, finds the shortest TMS path between
# any two states by breadth-first search, and emits cycle-accurate (tms, tdi)
# stimulus -- plus expected TDO where the response is deterministic. This is a
# small model of what real DFT pattern tools do: you describe scans at the
# "load this instruction, shift this data" level and the tool computes the
# bit-level TMS navigation for you.
#
# Pure Tcl 8.x, no external packages. Run:
#     tclsh gen_jtag_vectors.tcl [out.vec]
# Default output: sim/jtag_vectors.vec   (plus an annotated trace on stdout)
# ---------------------------------------------------------------------------

namespace eval jtag {

    # --- TAP state graph -----------------------------------------------------
    # Transcribed verbatim from the unique-case in rtl/jtag_tap_fsm.sv.
    # NEXT($state,$tms) -> next state.  Keep this in sync with the RTL: it is
    # the single source of truth the rest of the generator reasons over.
    variable NEXT
    array set NEXT {
        TEST_LOGIC_RESET,1 TEST_LOGIC_RESET   TEST_LOGIC_RESET,0 RUN_TEST_IDLE
        RUN_TEST_IDLE,1    SELECT_DR_SCAN      RUN_TEST_IDLE,0    RUN_TEST_IDLE
        SELECT_DR_SCAN,1   SELECT_IR_SCAN      SELECT_DR_SCAN,0   CAPTURE_DR
        CAPTURE_DR,1       EXIT1_DR            CAPTURE_DR,0       SHIFT_DR
        SHIFT_DR,1         EXIT1_DR            SHIFT_DR,0         SHIFT_DR
        EXIT1_DR,1         UPDATE_DR           EXIT1_DR,0         PAUSE_DR
        PAUSE_DR,1         EXIT2_DR            PAUSE_DR,0         PAUSE_DR
        EXIT2_DR,1         UPDATE_DR           EXIT2_DR,0         SHIFT_DR
        UPDATE_DR,1        SELECT_DR_SCAN      UPDATE_DR,0        RUN_TEST_IDLE
        SELECT_IR_SCAN,1   TEST_LOGIC_RESET    SELECT_IR_SCAN,0   CAPTURE_IR
        CAPTURE_IR,1       EXIT1_IR            CAPTURE_IR,0       SHIFT_IR
        SHIFT_IR,1         EXIT1_IR            SHIFT_IR,0         SHIFT_IR
        EXIT1_IR,1         UPDATE_IR           EXIT1_IR,0         PAUSE_IR
        PAUSE_IR,1         EXIT2_IR            PAUSE_IR,0         PAUSE_IR
        EXIT2_IR,1         UPDATE_IR           EXIT2_IR,0         SHIFT_IR
        UPDATE_IR,1        SELECT_DR_SCAN      UPDATE_IR,0        RUN_TEST_IDLE
    }

    # 4-bit state encoding, matching the enum in rtl/jtag_pkg.sv (for the VCD-
    # less trace only; the standard does not mandate an encoding).
    variable ENC
    array set ENC {
        TEST_LOGIC_RESET 0  RUN_TEST_IDLE 1  SELECT_DR_SCAN 2  CAPTURE_DR 3
        SHIFT_DR 4  EXIT1_DR 5  PAUSE_DR 6  EXIT2_DR 7  UPDATE_DR 8
        SELECT_IR_SCAN 9  CAPTURE_IR 10 SHIFT_IR 11 EXIT1_IR 12
        PAUSE_IR 13 EXIT2_IR 14 UPDATE_IR 15
    }

    # IR opcodes + the device IDCODE, from rtl/jtag_pkg.sv.
    variable IR_W        4
    variable IDCODE      0x11490001
    array set OPCODE {EXTEST 0x0  SAMPLE 0x1  IDCODE 0x2  BYPASS 0xF}

    # --- generation state ----------------------------------------------------
    variable cur     TEST_LOGIC_RESET ;# current TAP state of the model
    variable cycle   0                ;# TCK count
    variable vectors {}               ;# list of {tms tdi tdo_exp state note}
}

# next_state: one TMS step in the model.
proc jtag::next_state {st tms} {
    variable NEXT
    return $NEXT($st,$tms)
}

# path: shortest TMS sequence (list of 0/1) driving src -> dst, by BFS over the
# state graph. Returns {} when src == dst. This is the heart of the tool: it
# replaces every hand-counted "tms 1,1,0,0" comment in the testbench.
proc jtag::path {src dst} {
    variable NEXT
    if {$src eq $dst} {return {}}
    set prev [dict create $src {}]    ;# state -> {pred tms}
    set queue [list $src]
    while {[llength $queue]} {
        set queue [lassign $queue node]
        foreach tms {0 1} {
            set nxt $NEXT($node,$tms)
            if {![dict exists $prev $nxt]} {
                dict set prev $nxt [list $node $tms]
                if {$nxt eq $dst} {
                    # walk predecessors back to src, collecting the TMS bits
                    set bits {}
                    set s $dst
                    while {$s ne $src} {
                        lassign [dict get $prev $s] s tms_used
                        set bits [linsert $bits 0 $tms_used]
                    }
                    return $bits
                }
                lappend queue $nxt
            }
        }
    }
    error "no TAP path from $src to $dst (graph is broken)"
}

# emit: record one TCK. Advances the model, tracks the landing state.
proc jtag::emit {tms tdi {tdo x} {note ""}} {
    variable cur; variable cycle; variable vectors
    set cur [next_state $cur $tms]
    lappend vectors [list $cycle $tms $tdi $tdo $cur $note]
    incr cycle
}

# goto: navigate to a target state, emitting TMS with TDI held at 0.
proc jtag::goto {target {note ""}} {
    variable cur
    foreach tms [path $cur $target] {
        emit $tms 0 x [expr {$tms == [lindex [path $cur $target] 0] ? $note : ""}]
    }
}

# reset_tap: 5x TMS=1 forces TLR from any state (1149.1 guarantee), then idle.
proc jtag::reset_tap {} {
    variable cur
    for {set i 0} {$i < 5} {incr i} { emit 1 0 x [expr {$i==0?"force Test-Logic-Reset (TMS high 5x)":""}] }
    set cur TEST_LOGIC_RESET
    goto RUN_TEST_IDLE "settle in Run-Test/Idle"
}

# bit: extract bit k of an integer value.
proc jtag::bit {val k} { return [expr {($val >> $k) & 1}] }

# shift: the generic capture/shift/exit primitive, parameterised by column.
#   shift_state : SHIFT_IR or SHIFT_DR
#   data, n     : n bits of TDI stimulus, shifted LSB-first
#   model       : how to predict TDO -- idcode | bypass | unknown
# Mirrors load_ir / scan_dr in tb_jtag_top.sv, but the path is computed, not
# spelled out. Assumes we start in Run-Test/Idle; returns there.
proc jtag::shift {shift_state data n model {note ""}} {
    goto $shift_state $note          ;# RTI -> Select -> Capture (capture here) -> Shift
    for {set k 0} {$k < $n} {incr k} {
        set tdi  [bit $data $k]
        set last [expr {$k == $n-1}]
        set tms  [expr {$last ? 1 : 0}] ;# last bit also leaves Shift -> Exit1
        emit $tms $tdi [predict_tdo $model $data $k]
    }
    goto RUN_TEST_IDLE               ;# Exit1 -> Update (latch) -> RTI
}

# predict_tdo: the golden model. Only some scans have a deterministic response
# from a generator's point of view; the rest are 'x' (don't-care / TB checks).
proc jtag::predict_tdo {model data k} {
    variable IDCODE
    # idcode: preloaded ID shifted LSB-first.
    # bypass: capture 0, then TDI delayed by one TCK.
    switch -- $model {
        idcode  { return [bit $IDCODE $k] }
        bypass  { return [expr {$k==0 ? 0 : [bit $data [expr {$k-1}]]}] }
        default { return x }
    }
}

# load_ir / scan_dr: the two high-level operations, named to match the bench.
proc jtag::load_ir {opcode {note ""}} {
    variable IR_W
    shift SHIFT_IR $opcode $IR_W unknown $note
}
proc jtag::scan_dr {data n {model unknown} {note ""}} {
    shift SHIFT_DR $data $n $model $note
}

# ---------------------------------------------------------------------------
# self-check: re-run the emitted TMS column through the model from TLR and
# confirm each recorded landing state agrees. Catches any drift between the
# emitter and the graph -- the same "make the spec executable" idea as the SVA.
# ---------------------------------------------------------------------------
proc jtag::self_check {} {
    variable vectors
    set st TEST_LOGIC_RESET
    foreach v $vectors {
        lassign $v cyc tms tdi tdo land note
        set st [next_state $st $tms]
        if {$st ne $land} {
            error "self-check FAIL at cycle $cyc: replay=$st recorded=$land"
        }
    }
    return [llength $vectors]
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
proc jtag::write_vec {fname} {
    variable vectors
    set fh [open $fname w]
    puts $fh "# JTAG scan vectors -- generated by gen_jtag_vectors.tcl"
    puts $fh "# one line per TCK, applied on the rising edge; tdo is expected (x = don't care)"
    puts $fh "# tms tdi tdo"
    foreach v $vectors {
        lassign $v cyc tms tdi tdo land note
        puts $fh "$tms $tdi $tdo"
    }
    close $fh
}

proc jtag::print_trace {} {
    variable vectors; variable ENC
    puts [format "%-5s %3s %3s %3s  %-17s %s" cyc tms tdi tdo state note]
    puts [string repeat - 70]
    foreach v $vectors {
        lassign $v cyc tms tdi tdo land note
        set scol [format "%s(0x%X)" $land $ENC($land)]
        puts [format "%-5d %3d %3d %3s  %-17s %s" \
              $cyc $tms $tdi $tdo $scol $note]
    }
}

# ---------------------------------------------------------------------------
# program: the scan sequence to generate. This is the part a user edits -- the
# same four scenarios the directed bench (tb_jtag_top.sv) runs, but expressed
# at the scan level. Add/reorder freely; the navigation recomputes itself.
# ---------------------------------------------------------------------------
namespace eval jtag {
    reset_tap

    # Test 1: IDCODE is the reset-default instruction; read all 32 bits.
    scan_dr 0x00000000 32 idcode "Test 1: IDCODE read (default instruction)"

    # Test 2: load BYPASS, shift 8 bits -- TDO is TDI delayed one TCK after a
    # captured 0.
    load_ir $OPCODE(BYPASS) "Test 2: load BYPASS"
    scan_dr 0xB2 8 bypass    "Test 2: BYPASS shift (expect TDI delayed 1)"

    # Test 3: SAMPLE captures the boundary-scan cells; response is pin-state
    # dependent, so it is a TB check, not a generator-predictable value.
    load_ir $OPCODE(SAMPLE) "Test 3: load SAMPLE"
    scan_dr 0x0 4 unknown   "Test 3: boundary-scan capture (4 cells)"

    # Test 4: an undecoded opcode must fall through to BYPASS (1149.1 rule).
    load_ir 0x7 "Test 4: load unused opcode 0111"
    scan_dr 0x1 4 bypass "Test 4: unused opcode behaves as BYPASS"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
set out [expr {$argc >= 1 ? [lindex $argv 0] : "sim/jtag_vectors.vec"}]
file mkdir [file dirname $out]

set n [jtag::self_check]
jtag::print_trace
jtag::write_vec $out

puts ""
puts "self-check : OK  ($n cycles replay to the recorded states)"
puts "vectors    : $out  ([llength $jtag::vectors] TCK cycles)"