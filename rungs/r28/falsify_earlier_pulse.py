#!/usr/bin/env python3
# RUNG 28 FALSIFIER (the ladder's primary falsification test).
#
# "Swap only the genesis/pulse_id to an EARLIER pulse, leaving weight commitments untouched:
#  because init weights are pulse-seeded, re-derived lm4_cell0 != committed epoch-0 w_hex ->
#  okD0/okUtterRepro -> 0 -> fail."
#
# This takes the REAL signed ledger and rewrites ONLY the header pulse_hex (+ pulse_id, + the
# pulse-derived genesis) to a DIFFERENT (earlier) pulse value. Every committed weight hash,
# utterance hash, and signature byte is left BYTE-FOR-BYTE untouched. It then runs the r28 foreign
# verifier on the forged ledger and asserts it REJECTS.
#
# WHY this must fail: the foreign verifier re-derives the initial weights from the (forged) pulse.
# A different pulse -> different poff -> different cell0 init -> the re-derived epoch-0 (and final)
# w_hex no longer equals the committed one -> training head mismatch -> chain_ok / whex_ok / utter_ok
# collapse. If the forged ledger ever PASSES, the seed-binding is cosmetic and the rung FAILS.
#
# Note: we ALSO recompute the forged genesis = H(forged_pulse | corpus) so the verifier's
# pulse-binding self-check (genesis == H(pulse|corpus)) still passes -- forcing the rejection to
# come from the WEIGHTS not reproducing, which is the deep claim, not a trivial header inconsistency.
#
# Usage: python3 rungs/r28/falsify_earlier_pulse.py [out/utterance_chain.txt]

import sys, os, subprocess, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def sha256_hex(s):
    return hashlib.sha256(s.encode("latin-1")).hexdigest()


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "out/utterance_chain.txt")
    with open(ledger) as fh:
        lines = fh.readlines()
    hdr = lines[0].rstrip("\n").split()
    kv_idx = {}
    for i, tok in enumerate(hdr):
        if "=" in tok:
            kv_idx[tok.split("=")[0]] = i
    if "pulse_hex" not in kv_idx or "pulse_id" not in kv_idx:
        print("FALSIFY-SETUP FAIL: real ledger has no pulse binding to forge"); sys.exit(2)

    corpus_sha = hdr[5]
    real_phex = hdr[kv_idx["pulse_hex"]].split("=", 1)[1]
    real_pid = hdr[kv_idx["pulse_id"]].split("=", 1)[1]

    # an EARLIER / DIFFERENT pulse value (a real, smaller pulse_id; value flips first byte so poff moves)
    forged_phex = ("0" if real_phex[0] != "0" else "1") + real_phex[1:]
    # ensure poff actually changes (first byte mod 13); if not, perturb second nibble too
    if int(forged_phex[0:2], 16) % 13 == int(real_phex[0:2], 16) % 13:
        forged_phex = forged_phex[0] + ("0" if forged_phex[1] != "0" else "1") + forged_phex[2:]
    forged_pid = str(max(0, int(real_pid) - 1000))                 # an earlier pulse_id
    forged_genesis = sha256_hex(forged_phex + "|" + corpus_sha)    # keep header self-consistent

    # rewrite ONLY the pulse fields + genesis; leave ALL weight/utterance/sig bytes untouched
    hdr[3] = forged_genesis
    hdr[kv_idx["pulse_hex"]] = "pulse_hex=" + forged_phex
    hdr[kv_idx["pulse_id"]] = "pulse_id=" + forged_pid
    lines[0] = " ".join(hdr) + "\n"

    forged_path = os.path.join(REPO, "out/utterance_chain.FORGED_pulse.txt")
    with open(forged_path, "w") as fh:
        fh.writelines(lines)

    print(f"[falsify] real   pulse_id={real_pid} value_hex={real_phex[:16]}... poff={int(real_phex[0:2],16)%13}")
    print(f"[falsify] forged pulse_id={forged_pid} value_hex={forged_phex[:16]}... poff={int(forged_phex[0:2],16)%13}")
    print(f"[falsify] weight/utterance/sig bytes: UNTOUCHED. genesis recomputed for self-consistency.")
    print(f"[falsify] running r28 foreign verifier on the forged ledger (MUST REJECT)...")

    r = subprocess.run([sys.executable, os.path.join(HERE, "r28_foreign_check.py"), forged_path],
                       cwd=REPO, capture_output=True, text=True)
    tail = "\n".join(r.stdout.strip().splitlines()[-6:])
    print(tail)
    if r.returncode == 0:
        print("FALSIFY FAIL: the forged-pulse ledger was ACCEPTED -> seed-binding is cosmetic. RUNG FAILS.")
        sys.exit(1)
    print("FALSIFY PASS: the forged-pulse ledger was REJECTED -> the init is genuinely pulse-seeded "
          "(swapped pulse -> divergent re-derived weights -> head/utterance mismatch). not-before bound holds.")
    sys.exit(0)


if __name__ == "__main__":
    main()
