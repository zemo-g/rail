#!/usr/bin/env python3
"""Verify a Rail attested training ledger (segment or minibatch).

The Rail loop builds each record's hash as:
    record_hash = sha256( prev_hash_str + json.dumps(fields, sort_keys=True) )
where `fields` are the record's INTEGER/HEX-only fields (everything except
`record_hash`), serialized with Python's default separators (", " / ": ") and
sorted keys -- which is byte-identical to the Rail `canon_open` construction.

The chain is valid when, for every record:
  (1) prev_hash == previous record's record_hash (genesis prev = 64 zeros)
  (2) recomputed record_hash == stored record_hash

Usage: verify_segment_chain.py <ledger.jsonl>
Prints CHAIN-VALID / CHAIN-INVALID and exits 0/1.
"""
import sys, json, hashlib

def main(path):
    prev = "0" * 64
    n = 0
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            raw = raw.strip()
            if not raw:
                continue
            rec = json.loads(raw)
            stored = rec.pop("record_hash")
            # chain link
            if rec["prev_hash"] != prev:
                print(f"CHAIN-INVALID: line {lineno} prev_hash mismatch "
                      f"(got {rec['prev_hash'][:16]}.. expected {prev[:16]}..)")
                return 1
            preimage = rec["prev_hash"] + json.dumps(rec, sort_keys=True)
            calc = hashlib.sha256(preimage.encode()).hexdigest()
            if calc != stored:
                print(f"CHAIN-INVALID: line {lineno} record_hash mismatch "
                      f"(calc {calc[:16]}.. stored {stored[:16]}..)")
                return 1
            prev = stored
            n += 1
    print(f"CHAIN-VALID: {n} records, tip {prev[:24]}...")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
