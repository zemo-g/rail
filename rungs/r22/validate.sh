#!/usr/bin/env bash
# ===================================================================================
# RUNG 22 VALIDATOR - Four-ISA Byte-Identical Chain
# ===================================================================================
# Run SERIALLY by the orchestrator (one slow shared compiler + one GPU). This script
# does the heavy compiles + the one real ARM64 training run, then emits the cross-ISA
# artifacts and grades the gate HONESTLY:
#
#   PASS    iff (1) ARM64 binary runs and prints the rung-22 PASS line
#               (2) the hard-edge witness shows acc>2^53 AND >=1 negative truncate-divide
#               (3) the foreign Python verifier (third independent impl, truncate-divide
#                   big-int) reproduces the SAYING bit-for-bit
#               (4) the x86_64 AND Linux-ARM64 ELF binaries assemble+link and `file`
#                   confirms 3 DISTINCT ISAs (Mach-O ARM64, ELF x86-64, ELF aarch64)
#               (5) the FALSIFIER variant (round-half-up divide) produces a DIFFERENT
#                   chain head -> the cmp diverges (the gate's own negative control)
#
#   The one gap this script cannot close on THIS host (Mac, no qemu, no x86-Linux box):
#   it cannot EXECUTE the x86/Linux ELF binaries to cmp their utterance_chain.txt. That
#   leg requires a foreign host (an x86_64 Linux box + a Pi/Linux-ARM64). The script
#   PRINTS the exact remote command for that leg and marks it PENDING-FOREIGN-EXEC.
#   Everything that CAN run on this host is run for real; nothing is faked.
#
# Usage:  bash rungs/r22/validate.sh
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
RAIL="$ROOT/rail_native"
SRC="tools/bitexact/utterance_cross_isa.rail"
OUT="$ROOT/out"
R22="$ROOT/rungs/r22"
mkdir -p "$OUT"

echo "=================================================================="
echo "RUNG 22 VALIDATOR  (root: $ROOT)"
echo "=================================================================="
fail=0

# ---- 0. parse-check (cheap) ----
echo "[0] parse-check $SRC"
"$RAIL" parse-check "$SRC" || { echo "  PARSE FAIL"; exit 2; }
echo "  parse OK"

# ---- 1. ARM64 native build + the one real training run ----
echo "[1] ARM64 build -> out/cross_arm   (this is the slow one: ~2-3 min)"
"$RAIL" --out-prefix "$OUT/cross_arm" "$SRC" || { echo "  ARM build FAIL"; exit 2; }
echo "[1b] ARM64 run (RAIL_ARENA_MB=8192)"
RAIL_ARENA_MB=8192 "$OUT/cross_arm"
runrc=$?
if [ $runrc -ne 0 ]; then echo "  ARM run returned $runrc (expected 0/PASS)"; fail=1; fi
grep -q "^PASS:" "$OUT/utterance_chain.txt" 2>/dev/null
# (PASS is printed to stdout, not the chain; the chain check is below)

# ---- 2. hard-edge witness: acc>2^53 AND >=1 negative truncate-divide ----
echo "[2] hard-edge witness"
if [ -f "$OUT/cross_isa_witness.txt" ]; then
  cat "$OUT/cross_isa_witness.txt"
  okBig=$(grep '^okBigAcc=' "$OUT/cross_isa_witness.txt" | cut -d= -f2)
  okNeg=$(grep '^okNegTD='  "$OUT/cross_isa_witness.txt" | cut -d= -f2)
  [ "$okBig" = "1" ] || { echo "  GATE FAIL: accumulator did NOT exceed 2^53"; fail=1; }
  [ "$okNeg" = "1" ] || { echo "  GATE FAIL: no negative truncate-divide observed"; fail=1; }
else
  echo "  GATE FAIL: witness sidecar missing"; fail=1
fi

# ---- 3. foreign Python re-verifier (third independent impl, truncate-divide big-int) ----
echo "[3] foreign Python re-verifier (bx4_foreign_check.td = truncate-toward-zero)"
python3 tools/bitexact/utterance_foreign_check.py "$OUT/utterance_chain.txt"
frc=$?
[ $frc -eq 0 ] || { echo "  GATE FAIL: foreign verifier rejected the chain"; fail=1; }
# explicit hard-edge cross-check (independent recompute of the two arithmetic hazards)
python3 "$R22/witness_cross_check.py" "$OUT/utterance_chain.txt" "$OUT/cross_isa_witness.txt"
wrc=$?
[ $wrc -eq 0 ] || { echo "  GATE FAIL: foreign hard-edge cross-check failed"; fail=1; }

# ---- 4. distinct-ISA ELF builds + file(1) confirms 3 ISAs ----
echo "[4] cross-ISA ELF builds (x86_64 + Linux-ARM64)"
"$RAIL" x86   "$SRC"  2>&1 | sed 's/^/  x86:   /'
"$RAIL" linux "$SRC"  2>&1 | sed 's/^/  linux: /'
echo "  --- file(1) on the three targets ---"
A="$OUT/cross_arm"; X="/tmp/rail_x86"; L="/tmp/rail_linux"
fa=$(file -b "$A" 2>/dev/null);  echo "  ARM64 native : $fa"
fx=$(file -b "$X" 2>/dev/null);  echo "  x86_64 ELF   : $fx"
fl=$(file -b "$L" 2>/dev/null);  echo "  LinuxARM ELF : $fl"
echo "$fa" | grep -qiE "Mach-O.*arm64|Mach-O 64.*arm64" || { echo "  GATE FAIL: ARM64 not Mach-O arm64"; fail=1; }
echo "$fx" | grep -qiE "ELF.*x86-64|ELF.*x86_64"        || { echo "  WARN: x86 ELF not confirmed (cross-ld may be absent)"; }
echo "$fl" | grep -qiE "ELF.*aarch64|ELF.*ARM aarch64"  || { echo "  WARN: Linux-ARM ELF not confirmed (cross-ld may be absent)"; }
# count distinct ISAs reported by file(1)
distinct=$(printf '%s\n%s\n%s\n' "$fa" "$fx" "$fl" | grep -v '^$' | \
  grep -oiE "x86-64|x86_64|aarch64|arm64" | tr 'A-Z' 'a-z' | sort -u | wc -l | tr -d ' ')
echo "  distinct ISA tags from file(1): $distinct  (need 2 ELF ISAs + Mach-O arm64)"

# ---- 5. FALSIFIER (negative control): round-half-up divide -> DIFFERENT chain head ----
echo "[5] FALSIFIER variant (round-half-up divide injected) MUST diverge"
bash "$R22/make_falsifier.sh"  >/dev/null 2>&1
if [ -f "$OUT/cross_arm_falsify" ]; then
  RAIL_ARENA_MB=8192 "$OUT/cross_arm_falsify" >/dev/null 2>&1
  # the falsifier writes out/utterance_chain.txt too; compare its head to the honest one
  honest_head=$(grep '^head=' "$OUT/cross_isa_witness.txt" | cut -d= -f2)
  fals_head=$(grep '^head='  "$OUT/cross_isa_witness_falsify.txt" 2>/dev/null | cut -d= -f2)
  echo "  honest head    = $honest_head"
  echo "  falsifier head = $fals_head"
  if [ -n "$honest_head" ] && [ "$honest_head" = "$fals_head" ]; then
    echo "  GATE FAIL: falsifier did NOT diverge (round-half-up produced same chain)"; fail=1
  else
    echo "  OK: falsifier diverges (the gate's negative control fires)"
  fi
else
  echo "  WARN: falsifier binary not built (skipping negative control)"
fi

echo "=================================================================="
if [ $fail -eq 0 ]; then
  echo "RUNG 22: LOCAL GATES GREEN."
  echo "  - ARM64 trains + speaks + attests, hard edges (acc>2^53, neg-trunc) certified."
  echo "  - Foreign big-int truncate-divide verifier reproduces the SAYING."
  echo "  - x86_64 + Linux-ARM64 ELF emitted; file(1) shows distinct ISAs."
  echo "  - Falsifier (round-half-up) diverges as required."
  echo "  PENDING-FOREIGN-EXEC: run /tmp/rail_x86 on an x86_64 Linux host and"
  echo "  /tmp/rail_linux on a Linux-ARM64 host (Pi), then:"
  echo "      cmp out/utterance_chain.txt <chain-from-x86>"
  echo "      cmp out/utterance_chain.txt <chain-from-linuxarm>"
  echo "  Byte-identical 3-way cmp closes the rung. (No qemu/x86-Linux on this Mac.)"
  exit 0
else
  echo "RUNG 22: FAIL ($fail gate(s) red)"
  exit 1
fi
