#!/usr/bin/env python3
# Extract every self-contained (encoder-testable) instruction form from a real
# compiler .s. Skips directives, labels, and operand-with-symbol forms (branches/
# adr/adrp to a named label + @PAGE relocations) — those are linker-layer (P3),
# not encoder. Dedups. Output = the gate corpus.
import re, sys
src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rail_self.s"
MNEM = re.compile(r"^\s+([a-z][a-z0-9.]*)\b")
# operand symbol = a bare identifier (label) or @PAGE relocation -> linker layer
SYMBOL = re.compile(r"@PAGE|\b[L_][A-Za-z0-9_$.]+")
seen = {}
order = []
for raw in open(src):
    line = raw.rstrip("\n")
    if not line.startswith((" ", "\t")):
        continue                      # label / global / non-indented
    s = line.strip()
    if not s or s.startswith((".", "//", ";")):
        continue                      # directive / comment
    m = MNEM.match(line)
    if not m:
        continue
    # split mnemonic + operands
    parts = s.split(None, 1)
    ops = parts[1] if len(parts) > 1 else ""
    if "@PAGE" in ops:
        continue
    # any operand token that is a bare label/symbol (not a register/imm/[mem]) -> skip
    if SYMBOL.search(ops):
        continue
    if s not in seen:
        seen[s] = 1
        order.append(s)
with open("/tmp/gate_insns.txt", "w") as f:
    for s in order:
        f.write(s + "\n")
print(f"extracted {len(order)} unique self-contained instructions from {src}")
