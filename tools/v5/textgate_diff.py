#!/usr/bin/env python3
# Whole-program text differential: assemble /tmp/textgate_src.s with system `as`,
# extract the __text section bytes, and byte-diff against /tmp/rail_text.bin (the
# Rail assembler's output). Ground truth = `as`. First divergence is pinpointed.
import subprocess, sys

src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/textgate_src.s"
subprocess.run(["cp", src, "/tmp/textgate_src.s"], check=True)
subprocess.run(["as", "/tmp/textgate_src.s", "-o", "/tmp/textgate_as.o"], check=True)
out = subprocess.run(["otool", "-t", "/tmp/textgate_as.o"], capture_output=True, text=True).stdout

# otool -t prints instruction WORDS in order; convert each to 4 little-endian bytes
as_bytes = bytearray()
for line in out.splitlines():
    for t in line.split():
        if len(t) == 8 and all(c in "0123456789abcdef" for c in t):
            w = int(t, 16)
            as_bytes += bytes([w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff, (w >> 24) & 0xff])

rail_bytes = open("/tmp/rail_text.bin", "rb").read()

print(f"  as __text = {len(as_bytes)} bytes   rail = {len(rail_bytes)} bytes")
n = min(len(as_bytes), len(rail_bytes))
firstdiff = -1
ndiff = 0
for i in range(n):
    if as_bytes[i] != rail_bytes[i]:
        ndiff += 1
        if firstdiff < 0:
            firstdiff = i
            insn = i // 4
            aw = int.from_bytes(as_bytes[insn*4:insn*4+4], "little")
            rw = int.from_bytes(rail_bytes[insn*4:insn*4+4], "little")
            print(f"  FIRST DIFF byte {i} (insn #{insn} @ text+0x{insn*4:x}):")
            print(f"    as=0x{aw:08x}  rail=0x{rw:08x}")
print(f"  byte mismatches={ndiff}  (of {n} compared)")
if len(as_bytes) != len(rail_bytes):
    print(f"  !! SIZE MISMATCH")
ok = (ndiff == 0 and len(as_bytes) == len(rail_bytes))
print("  RESULT:", "CLEAN — Rail __text == as __text" if ok else "DIVERGENT")
sys.exit(0 if ok else 1)
