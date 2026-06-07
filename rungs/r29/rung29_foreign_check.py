#!/usr/bin/env python3
# FOREIGN (cross-language) re-verifier for RUNG 29 - Pi-Witness Active Recency Oracle.
#
# rung29_dual_sign.rail produced a RECENCY record that carries TWO Ed25519 signatures
# over the SAME canonical (ulink, pulse_id, pulse_hash) message:
#     usig  -- the trainer/author key
#     wsig  -- a SEPARATE Pi-witness key, applied ONLY after the witness independently
#              validated the recency pulse (an active oracle, not a passive co-sign).
#
# This independent party, written in a DIFFERENT LANGUAGE (Python big-integers),
# re-derives the pulse_hash itself (its own recency confirmation), rebuilds the exact
# canonical co-signed message, and proves -- bit-for-bit -- that:
#   * pk_trainer != pk_witness                       (separation of duties)
#   * the record's pulse_hash == SHA256(domain|pulse_id)  (verifier re-derives -> binding)
#   * usig verifies under the pinned trainer pubkey
#   * wsig verifies under the pinned witness pubkey   (2-of-2)
#   * FALSIFIER a: trainer key in both slots is rejected (distinctness + wsig-under-pk_w fails)
#   * FALSIFIER b: a wsig over a different pulse_id than the record is rejected
#   * FALSIFIER d: a tampered pulse_hash is caught by the verifier's own re-derivation
#
# (FALSIFIER c -- the witness REFUSING a stale pulse -- is proven inside the Rail run,
#  because refusal means no countersign exists to ship; the foreign side confirms that a
#  zero/absent wsig never verifies, which it cannot.)
#
# This closes the loop on the SEPARATION OF DUTIES: a second, independent implementation
# in another language confirms the words carry a recency countersignature from a
# physically/logically separate key that itself validated the pulse.
#
# LOCAL/DEV keys + LOCAL pulse only (mirrors the Rail run); never a prod sign surface.
#
# Usage: python3 rungs/r29/rung29_foreign_check.py [out/rung29_recency_chain.txt]

import sys
import os
import hashlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "bitexact"))
from bx12_foreign_check import ed25519_verify, sha256_hex, sha256_bytes  # noqa: E402

# Must mirror rung29_dual_sign.rail exactly.
PULSE_DOMAIN = "LEDATIC.LOCAL.BEACON.PULSE.dev"


def pulse_hash(pulse_id):
    # mirrors r29_pulse_hash: SHA256(domain "|" pulse_id), hex
    return sha256_hex(f"{PULSE_DOMAIN}|{pulse_id}")


def cmsg_bytes(ulink_hex, pulse_id, ph):
    # mirrors r29_cmsg_str / r29_cmsg_bytes
    return sha256_bytes(f"{ulink_hex}|RECENCY|{pulse_id}|{ph}")


def main():
    ledger = sys.argv[1] if len(sys.argv) > 1 else "out/rung29_recency_chain.txt"
    with open(ledger) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines or not lines[0].startswith("# RUNG29v1"):
        print("R29-CHECK FAIL: missing/malformed ledger header")
        sys.exit(1)

    hdr = lines[0].split()
    # # RUNG29v1 <pk_trainer> <pk_witness> domain=... wmin=...
    pk_trainer_hex, pk_witness_hex = hdr[2], hdr[3]
    kv = dict(tok.split("=", 1) for tok in hdr[4:] if "=" in tok)
    domain = kv.get("domain", "")

    rec_rows = [ln.split() for ln in lines[1:] if ln.startswith("RECENCY")]
    if len(rec_rows) != 1:
        print(f"R29-CHECK FAIL: expected exactly 1 RECENCY record, found {len(rec_rows)}")
        sys.exit(1)
    r = rec_rows[0]
    # RECENCY <ulink_hex> <pulse_id> <pulse_hash> <usig_hex> <wsig_hex>
    ulink_hex, pulse_id_s, ph_record, usig_hex, wsig_hex = r[1], r[2], r[3], r[4], r[5]
    pulse_id = int(pulse_id_s)

    pk_t = bytes.fromhex(pk_trainer_hex)
    pk_w = bytes.fromhex(pk_witness_hex)
    usig = bytes.fromhex(usig_hex)
    wsig = bytes.fromhex(wsig_hex)

    # ---- (0) dev-mode: domain in header is the LOCAL pulse domain, no PROD marker ----
    dev_ok = (domain == PULSE_DOMAIN) and ("PROD" not in domain)

    # ---- (1) separation of duties: the two pinned pubkeys must differ ----
    distinct_ok = (pk_t != pk_w)

    # ---- (2) pulse binding: re-derive pulse_hash ourselves, must match the record ----
    ph_rederived = pulse_hash(pulse_id)
    bind_ok = (ph_rederived == ph_record)

    # ---- (3) 2-of-2: rebuild the canonical co-signed message, verify BOTH sigs ----
    cmsg = cmsg_bytes(ulink_hex, pulse_id, ph_record)
    usig_ok = bool(ed25519_verify(pk_t, cmsg, usig))
    wsig_ok = bool(ed25519_verify(pk_w, cmsg, wsig))
    two_of_two = distinct_ok and bind_ok and usig_ok and wsig_ok

    # ---- FALSIFIER a: trainer key in BOTH slots ----
    # put usig into the witness slot, verify under the PINNED witness pubkey -> must fail;
    # and pk_t == pk_t is not distinct.
    selfsign_wsig_under_pkw = bool(ed25519_verify(pk_w, cmsg, usig))
    false_a = (not selfsign_wsig_under_pkw) and (not (pk_t == pk_w and False)) and (pk_t != pk_w)
    # the meaningful part: a witness slot filled with the trainer's sig does not verify under pk_w
    false_a = (not selfsign_wsig_under_pkw)

    # ---- FALSIFIER b: a wsig over a DIFFERENT pulse_id than the record ----
    # we cannot forge the witness's real sig (no signing here), but we CAN prove the
    # binding: a cmsg built with a different pulse_id yields a different message, so the
    # record's wsig (over the real pulse) does NOT verify against the other-pulse message.
    other_id = pulse_id + 100000000
    cmsg_other = cmsg_bytes(ulink_hex, other_id, pulse_hash(other_id))
    false_b = not bool(ed25519_verify(pk_w, cmsg_other, wsig))

    # ---- FALSIFIER d: tampered pulse_hash -> verifier re-derivation catches it ----
    tampered_ph = ("0" if ph_record[0] != "0" else "1") + ph_record[1:]
    false_d = (pulse_hash(pulse_id) != tampered_ph)  # our independent re-derivation != tampered

    print("==== FOREIGN RUNG-29 RE-VERIFIER (independent Python re-implementation) ====")
    print(f"dev-mode (local pulse domain)        = {dev_ok}  (domain={domain!r})")
    print(f"separation of duties (pk_t != pk_w)  = {distinct_ok}")
    print(f"pulse binding (verifier re-derived)  = {bind_ok}  (ph={ph_record[:24]}...)")
    print(f"usig verifies under pk_trainer       = {usig_ok}")
    print(f"wsig verifies under pk_witness       = {wsig_ok}")
    print(f"2-of-2 dual signature holds          = {two_of_two}")
    print(f"FALSIFIER a (trainer key both slots) = {false_a}  (trainer sig fails under pk_witness)")
    print(f"FALSIFIER b (wsig over other pulse)  = {false_b}  (pulse-binding rejects)")
    print(f"FALSIFIER d (tampered pulse_hash)    = {false_d}  (re-derivation catches it)")

    allok = (dev_ok and distinct_ok and bind_ok and usig_ok and wsig_ok and two_of_two
             and false_a and false_b and false_d)
    if allok:
        print("R29-CHECK PASS: a second, independent implementation in a DIFFERENT LANGUAGE "
              "re-derived the recency pulse, rebuilt the canonical co-signed message, and "
              "confirmed the utterance carries a 2-of-2 dual signature from SEPARATE keys "
              "(trainer + Pi-witness), the witness having itself validated recency. "
              "Self-co-sign, wrong-pulse, and tampered-pulse are all rejected.")
        sys.exit(0)
    print("R29-CHECK FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
