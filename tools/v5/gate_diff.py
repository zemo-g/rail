#!/usr/bin/env python3
# Acceptance gate: assemble /tmp/gate_insns.txt with system `as`, dump words via
# otool, diff against /tmp/gate_rail.txt (decimal words from asm.rail). Ground
# truth = `as`. Any mismatch is a real assembler bug.
import subprocess, sys

insns = [l.rstrip("\n") for l in open("/tmp/gate_insns.txt")]
insns = [l for l in insns if l.strip()]

with open("/tmp/gate_as.s", "w") as f:
    f.write(".text\n.global _t\n_t:\n")
    for l in insns:
        f.write("    " + l.strip() + "\n")

subprocess.run(["as", "/tmp/gate_as.s", "-o", "/tmp/gate_as.o"], check=True)
out = subprocess.run(["otool", "-t", "/tmp/gate_as.o"], capture_output=True, text=True).stdout

words = []
for line in out.splitlines():
    toks = line.split()
    for t in toks:
        if len(t) == 8 and all(c in "0123456789abcdef" for c in t):
            words.append(int(t, 16))
        # len-16 hex = address column; section header etc skipped

rail = [int(x) for x in open("/tmp/gate_rail.txt").read().split()]

n = min(len(words), len(rail))
mismatch = 0
for i in range(n):
    if words[i] != rail[i]:
        mismatch += 1
        if mismatch <= 30:
            print(f"  MISMATCH line {i+1}: {insns[i]!r}")
            print(f"    as=0x{words[i]:08x}  rail=0x{rail[i]:08x}")

print(f"\n  as words={len(words)}  rail words={len(rail)}  compared={n}  mismatches={mismatch}")
if len(words) != len(rail):
    print(f"  !! COUNT MISMATCH (as {len(words)} vs rail {len(rail)})")
sys.exit(1 if mismatch or len(words) != len(rail) else 0)
