#!/usr/bin/env python3
# BX9 D3 foreign witness: the corpus is part of the attestation, so an
# independent party must be able to (a) recompute its content hash with a
# stock SHA-256, and (b) re-assemble the exact corpus bytes from the named
# source files. Both must match the Rail manifest bit-for-bit, which proves
# the data pin is foreign-reproducible -- the precondition for BX12's
# "reproduce every checkpoint from data+config+seed".
#
# Usage: python3 bx9_foreign_check.py /tmp/bx9_manifest.txt
#   (run from the repo root or tools/bitexact/; source paths are repo-relative)

import sys
import os
import hashlib


def repo_root():
    # this script lives in <repo>/tools/bitexact/
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main():
    manifest = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bx9_manifest.txt"
    root = repo_root()
    corpus_path = os.path.join(root, "tools/bitexact/bx9_corpus.txt")

    sources, rail_bytes, rail_sha = None, None, None
    with open(manifest) as fh:
        for line in fh:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "sources":
                sources = parts[1:]
            elif parts[0] == "bytes":
                rail_bytes = int(parts[1])
            elif parts[0] == "sha256":
                rail_sha = parts[1]

    if sources is None or rail_bytes is None or rail_sha is None:
        print("BX9 D3 FAIL: manifest missing sources/bytes/sha256")
        sys.exit(1)

    # (a) recompute SHA-256 over the frozen corpus artifact with stock hashlib
    with open(corpus_path, "rb") as fh:
        corpus = fh.read()
    py_sha = hashlib.sha256(corpus).hexdigest()
    py_bytes = len(corpus)

    # (b) re-assemble the corpus from the named source files, in order
    reasm = b"".join(open(os.path.join(root, s), "rb").read() for s in sources)
    reasm_sha = hashlib.sha256(reasm).hexdigest()

    ok = True
    if py_bytes != rail_bytes:
        print(f"MISMATCH bytes: python={py_bytes} rail={rail_bytes}")
        ok = False
    if py_sha != rail_sha:
        print(f"MISMATCH sha256: python={py_sha} rail={rail_sha}")
        ok = False
    if reasm_sha != rail_sha:
        print(f"MISMATCH reassembled-from-sources sha256: python={reasm_sha} rail={rail_sha}")
        print("  (the corpus could not be reproduced from the named source files)")
        ok = False

    if ok:
        print(f"BX9 D3 PASS: corpus content hash reproduced bit-for-bit "
              f"(SHA-256 {py_sha}, {py_bytes} bytes; re-assembled from {len(sources)} sources)")
        sys.exit(0)
    print("BX9 D3 FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
