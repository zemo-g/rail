#!/usr/bin/env python3
# RUNG 36 LEDGER FALSIFIERS -- the ladder's falsification tests, mechanized at the SIGNED-LEDGER level.
#
# Each falsifier takes the REAL signed RSI ledger, applies ONE adversarial edit that models a ladder
# attack, and re-runs the foreign verifier. EXPECTED: the verifier REJECTS every forged ledger. If
# any forged ledger is ACCEPTED, the corresponding protection is cosmetic and the rung FAILS.
#
# The ladder's three named falsifiers (verbatim intent):
#   (1) Proxy-gaming: lower train loss, equal/worse committed holdout -> reject.
#   (2) Gate-relaxation: a self-favorable margin looser than the frozen one -> reject.
#   (3) Runaway/replay: past the committed cap, or replaying M1's cert as M2's -> reject.
# Plus a 4th the protocol enforces: a tampered (forged) trajectory -> reject.
#
# Usage: python3 rungs/r36/falsify_ledger.py [rungs/r36/out/r36_chain.txt]

import sys
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def run_foreign(path):
    r = subprocess.run([sys.executable, os.path.join(HERE, "r36_foreign_check.py"), path],
                       cwd=REPO, capture_output=True, text=True)
    return r.returncode, r.stdout.strip().splitlines()


def write_forged(lines, name):
    p = os.path.join(REPO, "rungs/r36/out", name)
    with open(p, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return p


def expect_reject(name, lines, desc):
    p = write_forged(lines, name)
    rc, out = run_foreign(p)
    tail = out[-1] if out else "(no output)"
    if rc == 0:
        print(f"  [{name}] ACCEPTED -> FALSIFY FAIL ({desc})")
        print(f"       {tail}")
        return False
    print(f"  [{name}] rejected (rc={rc}) -> correct. {desc}")
    return True


def split_gen(lines, gi):
    # return (line_index, token_list) for GEN record gi (0/1/2)
    gens = [(i, ln.split()) for i, ln in enumerate(lines) if ln.startswith("GEN ")]
    return gens[gi]


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "rungs/r36/out/r36_chain.txt")
    with open(ledger) as fh:
        base = [ln.rstrip("\n") for ln in fh if ln.strip()]

    # sanity: the honest ledger must PASS first (else the falsifiers prove nothing)
    rc, out = run_foreign(ledger)
    if rc != 0:
        print("FALSIFY-SETUP FAIL: the honest ledger does not pass the foreign verifier; aborting.")
        print("\n".join(out[-3:]))
        sys.exit(2)
    print("honest ledger passes foreign verifier -> proceeding to falsifiers")

    all_ok = True

    # ---- Falsifier (1) PROXY-GAMING: raise GEN1's committed metric so it "beats" M0 on a NUMBER it
    # did not earn (the holdout is recomputed from the trajectory, so a bumped committed metric makes
    # the chain head no longer re-derive -> reject). Models "claim a better holdout you didn't get." ----
    li, toks = split_gen(base, 1)
    forged = list(base)
    f = list(toks); f[4] = str(int(f[4]) + 50)   # token[4] = committed metric
    forged[li] = " ".join(f)
    all_ok &= expect_reject("forged_proxy.txt", forged,
                            "proxy-gaming: bumped committed holdout metric (chain head / sig must fail)")

    # ---- Falsifier (2) GATE-RELAXATION: rewrite the frozen margin_rule in the header to a looser bar
    # so a weak successor would pass. The GATE sig is over the ORIGINAL rule, so the re-derived gate
    # head/sig fail -> reject. Models "loosen your own bar after the fact." ----
    forged = list(base)
    hdr = forged[0].split()
    for idx, t in enumerate(hdr):
        if t.startswith("margin_rule="):
            hdr[idx] = "margin_rule=first_byte_mod_1_plus_0"   # margin would be 0 -> trivially passable
    forged[0] = " ".join(hdr)
    all_ok &= expect_reject("forged_relax.txt", forged,
                            "gate-relaxation: loosened frozen margin_rule (gate sig must fail)")

    # ---- Falsifier (3a) RUNAWAY: append a 4th GEN record (gen_idx 3 > cap 3). The verifier expects
    # exactly 3 GEN records (the bounded counter) -> reject. Models "keep self-improving past the cap." ----
    forged = list(base)
    _, g2toks = split_gen(base, 2)
    extra = list(g2toks)
    extra[1] = "3"   # gen_idx 3 -- past cap
    forged.append(" ".join(extra))
    all_ok &= expect_reject("forged_runaway.txt", forged,
                            "runaway: a 4th generation past the committed cap (counter must reject)")

    # ---- Falsifier (3b) REPLAY: set GEN2's prev to GEN0's head (replaying as if M2 followed M0,
    # skipping/forking M1). chain-prev breaks (GEN2.prev != GEN1.head) -> reject. ----
    li2, g2 = split_gen(base, 2)
    _, g0 = split_gen(base, 0)
    forged = list(base)
    f = list(g2); f[6] = g0[7]   # token[6]=prev, set to GEN0's head (token[7])
    forged[li2] = " ".join(f)
    all_ok &= expect_reject("forged_replay.txt", forged,
                            "replay: GEN2.prev rewired to GEN0's head (chain-prev must reject)")

    # ---- Falsifier (4) SIGNATURE TAMPER: flip one nibble of GEN1's signature -> sig must fail. ----
    li1, g1 = split_gen(base, 1)
    forged = list(base)
    f = list(g1)
    sig = f[8]
    f[8] = ("0" if sig[0] != "0" else "1") + sig[1:]
    forged[li1] = " ".join(f)
    all_ok &= expect_reject("forged_sigtamper.txt", forged,
                            "signature tamper: flipped one nibble of GEN1's sig (Ed25519 must reject)")

    if not all_ok:
        print("RUNG36-FALSIFY FAIL: at least one forged ledger was accepted.")
        sys.exit(1)
    print("RUNG36-FALSIFY PASS: every forged ledger (proxy-gaming, gate-relaxation, runaway, replay, "
          "sig-tamper) was rejected by the independent foreign verifier.")
    sys.exit(0)


if __name__ == "__main__":
    main()
