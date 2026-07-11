#!/usr/bin/env python3
"""Build 4 gate judge -- PAIRED signal-run gates, declared in the harness header
BEFORE any training arm ran. Reads the hash-chained ledgers, pairs each training
arm's per-step pre-update CE (ptgt_f24) with the a0 probe's CE on the SAME step
(and asserts the windows really were identical via batch_sha256), then judges the
pre-declared gates (a)-(g). Chain validity itself is verify_segment_chain.py's job
(the driver runs it per ledger); this script re-checks pairing + gate arithmetic.

Usage: judge_build4.py <trial_dir>
"""
import json, sys

F = 16777216.0
PEAK, FLOOR, WARM, MAXMB = 1677, 168, 5, 74


def load(path):
    recs = {}
    with open(path) as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            r = json.loads(raw)
            if r["step"] >= 0:
                recs[r["step"]] = r
    return recs


def ce(recs):
    return {s: r["ptgt_f24"] / F for s, r in recs.items()}


def floors(cevals):
    return [s for s, v in sorted(cevals.items()) if v > 12.0]


def main(d):
    a0 = load(f"{d}/attested_mbstream_SIG75_B8_a0_ledger.jsonl")
    wsd = load(f"{d}/attested_mbstream_SIG75_B8_a1e4_wsd_ledger.jsonl")
    con = load(f"{d}/attested_mbstream_SIG75_B8_a1e4_ledger.jsonl")
    b1 = load(f"{d}/attested_mbstream_SIG75_B1_a1e4_ledger.jsonl")
    n = MAXMB + 1
    for name, arm in (("a0", a0), ("wsd", wsd), ("const", con), ("b1", b1)):
        assert len(arm) == n, f"{name}: {len(arm)} steps, expected {n}"

    # pairing integrity: B8 arms must have seen EXACTLY the probe's windows
    for name, arm in (("wsd", wsd), ("const", con)):
        bad = [s for s in range(n) if arm[s]["batch_sha256"] != a0[s]["batch_sha256"]]
        assert not bad, f"{name}: batch_sha mismatch vs a0 at steps {bad[:5]} -- pairing INVALID"
    print(f"pairing OK: wsd+const batch_sha256 identical to a0 on all {n} steps")

    cea0, cew, cec, ceb = ce(a0), ce(wsd), ce(con), ce(b1)
    dw = {s: cew[s] - cea0[s] for s in cew}
    dc = {s: cec[s] - cea0[s] for s in cec}
    last5 = range(n - 5, n)
    w_last5 = sum(dw[s] for s in last5) / 5
    c_last5 = sum(dc[s] for s in last5) / 5
    w_all = sum(dw.values()) / n
    c_all = sum(dc.values()) / n

    # (c) second clause: wsd alr sequence matches the declared shape exactly
    shape_ok = True
    for s in range(n):
        want = (PEAK * (s + 1)) // WARM if s < WARM else PEAK - (((PEAK - FLOOR) * (s - WARM)) // (MAXMB - WARM))
        got = wsd[s]["alr_f24"]
        if got != want:
            print(f"  alr shape MISMATCH at step {s}: got {got} want {want}")
            shape_ok = False
    const_alr_ok = all(con[s]["alr_f24"] == PEAK for s in range(n))

    fw, fc, fb = floors(cew), floors(cec), floors(ceb)
    ga = len(fw) == 0
    gb = w_last5 <= -1.0
    ge = len(fc) == 0
    gf = w_last5 <= c_last5 + 0.3

    print(f"\narm CE grand means: a0 {sum(cea0.values())/n:.4f}  wsd {sum(cew.values())/n:.4f}  "
          f"const {sum(cec.values())/n:.4f}  b1 {sum(ceb.values())/n:.4f}")
    print(f"paired d (arm - a0):  wsd all-step {w_all:+.4f}, last5 {w_last5:+.4f}  |  "
          f"const all-step {c_all:+.4f}, last5 {c_last5:+.4f}")
    print(f"floor events: wsd {len(fw)} {fw}  const {len(fc)} {fc}  b1 {len(fb)} {fb}")
    print(f"worst step CE: wsd {max(cew.values()):.3f}  const {max(cec.values()):.3f}  b1 {max(ceb.values()):.3f}")
    print(f"\nGATES (pre-declared 2026-07-11):")
    print(f"  (a) wsd zero floor events:            {'PASS' if ga else 'FAIL'}")
    print(f"  (b) wsd paired last5 <= -1.0:         {'PASS' if gb else 'FAIL'}  ({w_last5:+.4f})")
    print(f"  (c) chains valid + alr shape exact:   {'PASS' if (shape_ok and const_alr_ok) else 'FAIL'} (chain validity per driver)")
    print(f"  (d) determinism byte-identical:       judged by driver cmp")
    print(f"  (e) const zero floor events:          {'PASS' if ge else 'FAIL'}")
    print(f"  (f) wsd last5 <= const last5 + 0.3:   {'PASS' if gf else 'FAIL'}  ({w_last5:+.4f} vs {c_last5:+.4f})")
    print(f"  (g) B1@1e4 with signal [report-only]: {len(fb)} floor events, worst {max(ceb.values()):.3f}")
    ok = ga and gb and shape_ok and const_alr_ok and ge and gf
    print(f"\nBUILD4-{'GATES-PASS' if ok else 'GATE-FAIL (decompose honestly, do not hide)'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
