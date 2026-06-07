#!/usr/bin/env python3
# RUNG 28 SECOND FALSIFIER: pulse_id<->genesis consistency.
#
# Catches a "the pulse fields are just recorded text" regression. Here we swap ONLY the header
# pulse_hex/pulse_id to a different pulse but DELIBERATELY LEAVE the genesis unchanged (as if an
# attacker relabeled which pulse the run claims to anchor to, without re-deriving genesis).
#
# WHY this must fail: the foreign verifier recomputes genesis = H(pulse_hex | corpus_sha) from the
# RECORDED pulse and asserts it equals the recorded genesis. With a swapped pulse but stale genesis,
# H(forged_pulse|corpus) != recorded_genesis -> pulse_bind_ok = False -> REJECT. This proves the
# recorded pulse is cryptographically bound to the chain root, not free-floating metadata.
#
# Usage: python3 rungs/r28/falsify_keep_genesis.py [out/utterance_chain.txt]

import sys, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "out/utterance_chain.txt")
    with open(ledger) as fh:
        lines = fh.readlines()
    hdr = lines[0].rstrip("\n").split()
    kv_idx = {tok.split("=")[0]: i for i, tok in enumerate(hdr) if "=" in tok}
    if "pulse_hex" not in kv_idx or "pulse_id" not in kv_idx:
        print("FALSIFY-SETUP FAIL: real ledger has no pulse binding to forge"); sys.exit(2)

    real_phex = hdr[kv_idx["pulse_hex"]].split("=", 1)[1]
    real_pid = hdr[kv_idx["pulse_id"]].split("=", 1)[1]
    forged_phex = ("0" if real_phex[0] != "0" else "1") + real_phex[1:]
    forged_pid = str(int(real_pid) + 1)

    # swap the pulse fields but KEEP genesis (hdr[3]) stale -> binding self-check must reject
    hdr[kv_idx["pulse_hex"]] = "pulse_hex=" + forged_phex
    hdr[kv_idx["pulse_id"]] = "pulse_id=" + forged_pid
    lines[0] = " ".join(hdr) + "\n"

    forged_path = os.path.join(REPO, "out/utterance_chain.FORGED_genesis.txt")
    with open(forged_path, "w") as fh:
        fh.writelines(lines)

    print(f"[falsify] real   pulse_hex={real_phex[:16]}...  genesis(unchanged)={hdr[3][:16]}...")
    print(f"[falsify] forged pulse_hex={forged_phex[:16]}...  (genesis left STALE on purpose)")
    print(f"[falsify] running r28 foreign verifier (MUST REJECT on pulse<->genesis mismatch)...")

    r = subprocess.run([sys.executable, os.path.join(HERE, "r28_foreign_check.py"), forged_path],
                       cwd=REPO, capture_output=True, text=True)
    tail = "\n".join(r.stdout.strip().splitlines()[-6:])
    print(tail)
    if r.returncode == 0:
        print("FALSIFY FAIL: a ledger whose recorded pulse does NOT derive its genesis was ACCEPTED. RUNG FAILS.")
        sys.exit(1)
    print("FALSIFY PASS: pulse<->genesis binding enforced (recorded pulse must re-derive the chain root).")
    sys.exit(0)


if __name__ == "__main__":
    main()
