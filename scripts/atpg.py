#!/usr/bin/env python3
# atpg.py
# ---------------------------------------------------------------------------
# A tiny stuck-at ATPG (Automatic Test Pattern Generator) for the full-scan
# demo block in rtl/scan_demo.sv.
#
# What this models, and why it matters for DFT
# --------------------------------------------
# rtl/scan_demo.sv is a 4-flop circuit whose flops have been turned into a
# scan chain (muxed-D flops + scan_enable). Full scan makes every flop:
#   * controllable -- you shift any value you like into it (scan-in), and
#   * observable   -- you shift the captured value back out (scan-out).
# That collapses the hard *sequential* test problem into a *combinational*
# one: you only have to test the cloud of logic n = f(q) that sits between
# the flops, because the flops on either side are now just scan-accessible
# pins. A test "pattern" is therefore just a 4-bit value to load into q; the
# "response" is f(q) captured back into the flops and shifted out.
#
# The classic fault model is single stuck-at: every net can be stuck-at-0 or
# stuck-at-1. ATPG finds, for each fault, an input that makes the good and
# faulty circuits produce different outputs (excitation + propagation). Here
# every output bit of f is captured into a flop, so propagation is automatic
# and detection reduces to: does some pattern make faulty f(q) != good f(q)?
#
# The input space is only 16 patterns, so this does *exhaustive* fault
# simulation -- exact, and easy to check by hand. Real tools (TetraMAX,
# Tessent) can't enumerate 2^N for large N, so they use structural algorithms
# (PODEM/FAN) plus fault dropping and collapsing. The interface is the same:
# in -> a fault list and a pattern set, out -> fault coverage. The net-level
# fault list here is also un-collapsed and stem-only; commercial tools model
# per-pin faults and collapse equivalent ones first.
#
#   python3 scripts/atpg.py [out.vec]      (default sim/scan_vectors.vec)
# ---------------------------------------------------------------------------

import sys

N = 4  # scan-chain length / number of flops

# --- the combinational cloud n = f(q), as a gate netlist -------------------
# Net names are the fault sites. This MUST stay identical to the always_comb
# block in rtl/scan_demo.sv -- it is the single source of truth they share.
# Two named nets carry integer "site" codes so the SV mutation testbench can
# inject the same faults in hardware:
#     site 1 -> n0   (output of the q0&q1 AND)
#     site 2 -> ginv1 (the ~q1 net feeding the lower AND of the n3 cone)
NETS = ["q0", "q1", "q2", "q3",
        "and01", "or12", "and03", "ginv1", "g3a", "g3b",
        "n0", "n1", "n2", "n3"]

OUT_BITS = ["n0", "n1", "n2", "n3"]   # nets captured into flops (observable)


def evaluate(q, fault=None):
    """Evaluate f(q) -> 4-bit list [n0,n1,n2,n3].
    q is an int 0..15 (bit i = q[i]). `fault` is None or (net_name, value)."""
    v = {}

    def put(name, val):
        # write a net, applying the injected stuck-at if it targets this net
        if fault is not None and fault[0] == name:
            val = fault[1]
        v[name] = val & 1

    put("q0", (q >> 0) & 1)
    put("q1", (q >> 1) & 1)
    put("q2", (q >> 2) & 1)
    put("q3", (q >> 3) & 1)

    put("and01", v["q0"] & v["q1"])
    put("or12",  v["q1"] | v["q2"])
    put("and03", v["q0"] & v["q3"])
    put("ginv1", (~v["q1"]) & 1)
    put("g3a",   v["q0"] & v["q1"])
    put("g3b",   v["q0"] & v["ginv1"])

    put("n0", v["and01"])
    put("n1", v["or12"])
    put("n2", v["and03"])
    put("n3", v["g3a"] | v["g3b"])   # = q0&q1 + q0&~q1  ==  q0  (redundant cone)

    return [v[b] for b in OUT_BITS]


def main():
    out = sys.argv[1] if len(sys.argv) >= 2 else "sim/scan_vectors.vec"

    # good-machine responses for every pattern
    good = {q: evaluate(q) for q in range(1 << N)}

    # full single stuck-at fault list: each net SA0 and SA1
    faults = [(net, sa) for net in NETS for sa in (0, 1)]

    # exhaustive fault simulation: which patterns detect each fault
    detect = {}                       # fault -> set(patterns that detect it)
    for f in faults:
        hits = {q for q in range(1 << N) if evaluate(q, f) != good[q]}
        detect[f] = hits

    detectable = [f for f in faults if detect[f]]
    redundant  = [f for f in faults if not detect[f]]

    # greedy set-cover: fewest patterns that detect all detectable faults
    uncovered = set(detectable)
    chosen = []
    while uncovered:
        # pick the pattern that newly detects the most still-uncovered faults
        best_q, best_gain = None, -1
        for q in range(1 << N):
            gain = sum(1 for f in uncovered if q in detect[f])
            if gain > best_gain:
                best_q, best_gain = q, gain
        chosen.append(best_q)
        uncovered -= {f for f in detectable if best_q in detect[f]}
    chosen.sort()

    coverage = 100.0 * len(detectable) / len(faults)

    # ---- self-check: the chosen set really must cover every detectable fault
    covered = set()
    for q in chosen:
        covered |= {f for f in detectable if q in detect[f]}
    if covered != set(detectable):
        sys.exit("atpg self-check FAILED: pattern set does not cover all "
                 "detectable faults")

    # ---- report ----
    print("ATPG stuck-at run for rtl/scan_demo.sv (full scan, N=%d flops)" % N)
    print("-" * 60)
    print("fault sites (nets) : %d" % len(NETS))
    print("total faults       : %d  (each net SA0 + SA1)" % len(faults))
    print("detectable         : %d" % len(detectable))
    print("redundant          : %d" % len(redundant))
    print("fault coverage     : %.1f%%" % coverage)
    print("test patterns      : %d  -> %s"
          % (len(chosen), " ".join("0x%X" % q for q in chosen)))
    if redundant:
        print()
        print("redundant (UNTESTABLE) faults -- no input distinguishes them")
        print("from the good circuit; they sit on logic that cannot affect an")
        print("output. A real flow either removes the redundancy or signs off")
        print("the coverage loss:")
        for net, sa in redundant:
            print("    %-6s stuck-at-%d" % (net, sa))

    # ---- emit the scan replay vectors ----
    # One line per test pattern, eight space-separated bits:
    #     q3 q2 q1 q0   n3 n2 n1 n0
    # the first nibble is the value to scan in (load), the second is f(load)
    # captured into the flops, to be scanned out and checked. Bits are listed
    # MSB-first (q3/n3 first) to match the chain readout order in the bench.
    with open(out, "w") as fh:
        fh.write("# scan ATPG patterns -- generated by scripts/atpg.py\n")
        fh.write("# full-scan test of rtl/scan_demo.sv; one pattern per line\n")
        fh.write("# columns: q3 q2 q1 q0  n3 n2 n1 n0   "
                 "(load = scan-in, capture = expected scan-out)\n")
        for q in chosen:
            resp = good[q]                       # [n0,n1,n2,n3]
            load = [(q >> i) & 1 for i in (3, 2, 1, 0)]      # q3..q0
            cap  = [resp[i] for i in (3, 2, 1, 0)]           # n3..n0
            fh.write("%s   %s   # load q=0x%X -> capture f(q)=0x%X\n"
                     % (" ".join(map(str, load)), " ".join(map(str, cap)),
                        q, sum(b << i for i, b in enumerate(resp))))

    print()
    print("self-check : OK  (pattern set covers all %d detectable faults)"
          % len(detectable))
    print("vectors    : %s  (%d patterns)" % (out, len(chosen)))


if __name__ == "__main__":
    main()