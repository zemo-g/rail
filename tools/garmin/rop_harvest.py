#!/usr/bin/env python3
"""
tools/garmin/rop_harvest.py - Harvest Thumb-2 ROP gadgets from extracted Garmin firmware.

A ROP gadget is a short Thumb-2 instruction sequence ending in a
register-controlled branch (pop {.., pc}, bx Rn, mov pc, Rn). When we
ever land an exploit that lets us control SP and the values it points at,
we chain gadgets to do useful work.

This harvester walks the extracted firmware, decodes from every 2-byte
boundary, and reports sequences of <= 6 instructions ending in a
PC-pivoting return.

Output: a JSON catalogue + a human-readable summary, ranked by
usefulness (gadgets that load r0/r1 from stack are highest value).
"""
import argparse, capstone, json, struct, sys, re
from collections import defaultdict

THUMB_RETURN_PATTERNS = [
    # 16-bit
    re.compile(r'^pop\s+\{[^}]*pc[^}]*\}$'),
    re.compile(r'^bx\s+r\d+$'),
    re.compile(r'^bx\s+lr$'),
    # 32-bit
    re.compile(r'^pop\.w\s+\{[^}]*pc[^}]*\}$'),
    re.compile(r'^ldmia\.w\s+sp!,\s*\{[^}]*pc[^}]*\}$'),
]


def is_return(inst):
    full = f"{inst.mnemonic} {inst.op_str}".strip()
    return any(p.match(full) for p in THUMB_RETURN_PATTERNS)


def is_branch(inst):
    if is_return(inst):
        return True
    if inst.mnemonic in ('b', 'bl', 'b.w', 'bl.w', 'bx', 'blx',
                         'cbz', 'cbnz', 'tbb', 'tbh'):
        return True
    if inst.mnemonic.startswith('b.') and inst.mnemonic != 'b.w':
        return True
    return False


def usefulness_score(seq):
    """Higher score = more interesting gadget."""
    score = 0
    text = ' ; '.join(f"{i.mnemonic} {i.op_str}" for i in seq)
    # Pop r0/r1/r2/r3 and pc -> argument-setting gadgets, very useful
    if 'pop' in text and ('r0' in text or 'r1' in text or 'r2' in text or 'r3' in text):
        score += 5
    # Direct return without state change
    if len(seq) == 1:
        score += 1
    # MOV between low regs - useful for argument setup
    if any(i.mnemonic == 'mov' for i in seq):
        score += 1
    # Memory load - useful for reading state
    if any(i.mnemonic in ('ldr', 'ldr.w', 'ldrb', 'ldrh') for i in seq):
        score += 2
    # Memory store - useful for writing state
    if any(i.mnemonic in ('str', 'str.w', 'strb', 'strh') for i in seq):
        score += 3
    # Function call mid-gadget - dangerous, dedup later
    if any(i.mnemonic in ('bl', 'bl.w', 'blx') for i in seq):
        score -= 2
    return score


def harvest(data, code_start=0x2000, max_inst=6):
    md = capstone.Cs(capstone.CS_ARCH_ARM,
                     capstone.CS_MODE_THUMB | capstone.CS_MODE_MCLASS)
    md.detail = False
    gadgets = []
    n = len(data)
    for start in range(code_start, n - 8, 2):
        seq = []
        offset = start
        for _ in range(max_inst):
            if offset + 2 > n:
                break
            try:
                inst = next(md.disasm(data[offset:offset + 4], offset))
            except StopIteration:
                break
            seq.append(inst)
            offset += inst.size
            if is_return(inst):
                if all(not (is_branch(s) and not is_return(s))
                       for s in seq[:-1]):
                    gadgets.append({
                        'addr': start,
                        'len': sum(i.size for i in seq),
                        'insts': [(i.address, i.mnemonic + ' ' + i.op_str)
                                  for i in seq],
                        'score': usefulness_score(seq),
                    })
                break
            if is_branch(inst):
                break
    return gadgets


def main():
    p = argparse.ArgumentParser()
    p.add_argument('firmware', help='extracted firmware binary')
    p.add_argument('--max', type=int, default=6,
                   help='max instructions per gadget')
    p.add_argument('--code-start', type=lambda x: int(x, 0), default=0x2000)
    p.add_argument('--out', default=None)
    p.add_argument('--top', type=int, default=30)
    args = p.parse_args()

    data = open(args.firmware, 'rb').read()
    print(f"firmware: {args.firmware} ({len(data):,} bytes)", file=sys.stderr)
    print(f"scanning from 0x{args.code_start:x} ...", file=sys.stderr)
    gadgets = harvest(data, args.code_start, args.max)
    print(f"found {len(gadgets):,} candidate gadgets", file=sys.stderr)

    # Bucket by terminal-mnemonic for quick stats
    bucket = defaultdict(int)
    for g in gadgets:
        last = g['insts'][-1][1]
        # Categorise the terminator
        if last.startswith('pop'):
            tag = 'pop+pc'
            if 'r0' in last:
                tag = 'pop r0..pc'
        elif last.startswith('bx'):
            tag = last
        else:
            tag = 'other'
        bucket[tag] += 1
    print("by terminator:", file=sys.stderr)
    for k, v in sorted(bucket.items(), key=lambda x: -x[1]):
        print(f"  {k:20s}  {v:6d}", file=sys.stderr)

    if args.out:
        with open(args.out, 'w') as f:
            json.dump(gadgets, f, indent=1, default=str)
        print(f"wrote {args.out}", file=sys.stderr)

    # Print top-N highest-scoring
    gadgets.sort(key=lambda g: -g['score'])
    print(f"\ntop {args.top} highest-scored gadgets:")
    for g in gadgets[:args.top]:
        text = ' ; '.join(m for _, m in g['insts'])
        print(f"  0x{g['addr']:08x}  score={g['score']:2d}  {text}")


if __name__ == '__main__':
    main()
