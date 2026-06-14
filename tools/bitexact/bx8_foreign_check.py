#!/usr/bin/env python3
# BX8 D3 foreign witness: a pure-Python re-implementation of stdlib/bpe.rail's
# BPE train + encode. If it reproduces the SAME merge list and the SAME token-id
# sequence from the SAME corpus bytes that Rail trained on, the tokenizer is a
# foreign-reproducible fixed algorithm -- so the model's INPUT (token ids) is
# bit-for-bit pinned, which is what BX12's "reproduce every checkpoint from
# data+config+seed" needs for a fixed seed.
#
# Mirrors the stdlib array algorithm exactly:
#   * base vocab = distinct chars, first-appearance order
#   * pair key   = a*2^20 + b
#   * best pair  = max adjacency count; tie-break the SMALLEST key
#   * merge      = greedy left-to-right, consume both tokens on a hit
#   * stop       = target reached OR best count < 2
# Usage: python3 bx8_foreign_check.py /tmp/bx8_dump.txt /tmp/bx8_corpus.txt

import sys

MUL = 1048576  # 2^20, same pair-key multiplier as bpe_pair_key


def base_vocab(text):
    uniq, seen = [], set()
    for c in text:
        if c not in seen:
            seen.add(c)
            uniq.append(c)
    return uniq


def best_pair(arr, n):
    counts = {}
    for i in range(n - 1):
        k = arr[i] * MUL + arr[i + 1]
        counts[k] = counts.get(k, 0) + 1
    if not counts:
        return (0, 0)
    best_k, best_c = 0, 0
    # ascending key order + strict '>' == stdlib's in-order tree walk
    # (keeps the smallest key among the max-count pairs).
    for k in sorted(counts):
        if counts[k] > best_c:
            best_c = counts[k]
            best_k = k
    return (best_k, best_c)


def apply_merge(tokens, a, b, nid):
    out, i, n = [], 0, len(tokens)
    while i < n:
        if i == n - 1:
            out.append(tokens[i])
            i += 1
        elif tokens[i] == a and tokens[i + 1] == b:
            out.append(nid)
            i += 2
        else:
            out.append(tokens[i])
            i += 1
    return out


def train(text, target):
    uniq = base_vocab(text)
    base_size = len(uniq)
    cid = {c: i for i, c in enumerate(uniq)}
    if target <= base_size:
        return [], base_size
    arr = [cid[c] for c in text]
    merges, size, n = [], base_size, len(arr)
    while size < target:
        bk, bc = best_pair(arr, n)
        if bc < 2:
            break
        a, b, nid = bk // MUL, bk - (bk // MUL) * MUL, size
        arr = apply_merge(arr, a, b, nid)
        n = len(arr)
        merges.append((a, b, nid))
        size += 1
    return merges, size


def encode(text, uniq, merges):
    cid = {c: i for i, c in enumerate(uniq)}
    tokens = [cid[c] for c in text]
    for (a, b, nid) in merges:
        tokens = apply_merge(tokens, a, b, nid)
    return tokens


def main():
    dump = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bx8_dump.txt"
    corpus_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/bx8_corpus.txt"
    target = 90

    with open(corpus_path) as fh:
        corpus = fh.read()

    uniq = base_vocab(corpus)
    merges, vsize = train(corpus, target)
    ids = encode(corpus, uniq, merges)

    with open(dump) as fh:
        lines = fh.read().split("\n")
    rail_vsize = int(lines[0])
    rail_merges_flat = [int(x) for x in lines[1].split()]
    rail_merges = [tuple(rail_merges_flat[i:i + 3]) for i in range(0, len(rail_merges_flat), 3)]
    rail_ids = [int(x) for x in lines[2].split()]

    ok = True
    if vsize != rail_vsize:
        print(f"MISMATCH vocab size: python={vsize} rail={rail_vsize}")
        ok = False
    if merges != rail_merges:
        ok = False
        bad = 0
        for r, (pm, rm) in enumerate(zip(merges, rail_merges)):
            if pm != rm:
                bad += 1
                if bad <= 10:
                    print(f"MISMATCH merge {r}: python={pm} rail={rm}")
        if len(merges) != len(rail_merges):
            print(f"MISMATCH merge count: python={len(merges)} rail={len(rail_merges)}")
    if ids != rail_ids:
        ok = False
        bad = 0
        for c, (pi, ri) in enumerate(zip(ids, rail_ids)):
            if pi != ri:
                bad += 1
                if bad <= 10:
                    print(f"MISMATCH id {c}: python={pi} rail={ri}")
        if len(ids) != len(rail_ids):
            print(f"MISMATCH id count: python={len(ids)} rail={len(rail_ids)}")

    if ok:
        print(f"BX8 D3 PASS: BPE reproduced bit-for-bit "
              f"({len(merges)} merges + {len(ids)} token ids, foreign Python == Rail)")
        sys.exit(0)
    print("BX8 D3 FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
