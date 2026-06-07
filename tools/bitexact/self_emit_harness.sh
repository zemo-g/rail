#!/bin/bash
# ============================================================================
# SELF-EMISSION HARNESS  (Attested Language Ladder, rung 35 -- the teeth)
#
# The attested model emitted the EXACT source of a leaf of its own compiler
# (compile.rail:is_digit). This harness proves that emitted source is a
# load-bearing, verified piece of the compiler:
#   (1) installed, it preserves the self-hosting BYTE-IDENTICAL fixed point,
#   (2) the 141-test suite passes (the leaf is exercised), and
#   (3) MUTATING the emitted source BREAKS the self-compile (cmp diverges),
# All on a throwaway git worktree, so the reward artifacts stay untouched.
#
# Usage: self_emit_harness.sh <seed_rail_native> <emitted_source_file> [worktree] [cert_out]
# ============================================================================
set -u
export RAIL_ARENA_MB=8192   # CRITICAL: self-compiling the 9031-line compile.rail GC-thrashes on the 512MB default
SEED_BIN="${1:?seed rail_native}"
EMITTED="${2:?emitted source file (out/emitted_source.rail)}"
WT="${3:-/Users/ledaticempire/rail-selfemit}"
CERT="${4:-/Users/ledaticempire/rail-reward/out/selfemit_cert.txt}"
SRC=/Users/ledaticempire/projects/rail
BASE=e865138        # commit the emitted target was derived from (== reward worktree)
LINE=11             # compile.rail:11 == `is_digit c = has c digits`
log(){ echo "[harness] $*"; }

# --- 0. fresh throwaway worktree ---
git -C "$SRC" worktree remove --force "$WT" 2>/dev/null || true
git -C "$SRC" branch -D selfemit-harness 2>/dev/null || true
rm -rf "$WT"
git -C "$SRC" worktree add -b selfemit-harness "$WT" "$BASE" >/dev/null 2>&1 \
  || { echo "FATAL: worktree add failed"; exit 2; }
cp "$SEED_BIN" "$WT/rail_native"; chmod +x "$WT/rail_native"
cd "$WT" || exit 2

TARGET_LINE="$(sed -n "${LINE}p" tools/compile.rail)"
EMIT_LINE="$(cat "$EMITTED")"
log "target  compile.rail:$LINE = [$TARGET_LINE]"
log "emitted (model output)     = [$EMIT_LINE]"
[ "$TARGET_LINE" = "$EMIT_LINE" ] && EMIT_OK=1 || EMIT_OK=0
log "emitted == target          = $EMIT_OK"

install_line(){ # $1 = replacement source for compile.rail:LINE
  awk -v n="$LINE" -v repl="$1" 'NR==n{print repl; next}{print}' tools/compile.rail > /tmp/se_cr.$$ \
    && cp /tmp/se_cr.$$ tools/compile.rail && rm -f /tmp/se_cr.$$
}
selfcompile(){ ./rail_native self >/tmp/se_log.$$ 2>&1; grep -q "Binary: /tmp/rail_self" /tmp/se_log.$$; }

# --- 1. install the EMITTED source (== original) and reach the self-host fixed point ---
install_line "$EMIT_LINE"
PREV=""; FP=""
for i in 1 2 3 4 5; do
  if ! selfcompile; then log "self-compile FAILED at cycle $i"; break; fi
  cp /tmp/rail_self "gen_$i"
  H=$(shasum -a 256 "gen_$i" | awk '{print $1}')
  log "cycle $i  gen sha=$H"
  if [ -n "$PREV" ] && [ "$PREV" = "$H" ]; then FP="$H"; log "FIXED POINT reached at cycle $i"; break; fi
  cp "gen_$i" rail_native; chmod +x rail_native
  PREV="$H"
done
[ -n "$FP" ] && HONEST_FP=1 || HONEST_FP=0

# --- 2. exercising test: the 141-suite must pass with the fixed-point binary ---
./rail_native test >/tmp/se_test.$$ 2>&1
NFAIL=$(grep -c "  FAIL:" /tmp/se_test.$$)
NPASS=$(grep -c "  PASS:" /tmp/se_test.$$)
log "test suite: PASS=$NPASS FAIL=$NFAIL"
if [ "$NFAIL" -eq 0 ] && [ "$NPASS" -ge 140 ]; then TESTS_OK=1; else TESTS_OK=0; fi

# --- 3. mutation falsifier: a behavior-changing mutation must diverge the self-compile ---
# swap the digit list for the hex-letter list (both defined): is_digit stops recognizing 0-9,
# so the compiler mis-lexes its OWN integer literals -> different/broken self-compile output.
MUT='is_digit c = has c hex_letters'
install_line "$MUT"
if selfcompile; then
  cp /tmp/rail_self gen_mut
  HMUT=$(shasum -a 256 gen_mut | awk '{print $1}')
else
  HMUT="SELFCOMPILE_BROKE"
fi
log "mutation self-compile sha=$HMUT   (honest FP=$FP)"
if [ -n "$FP" ] && [ "$HMUT" != "$FP" ]; then MUT_BREAKS=1; else MUT_BREAKS=0; fi
install_line "$EMIT_LINE"   # restore honest

# --- 4. certificate ---
SRC_HEX=$(shasum -a 256 "$EMITTED" | awk '{print $1}')
PASS=$(( EMIT_OK * HONEST_FP * TESTS_OK * MUT_BREAKS ))
{
  echo "# SELFEMIT-CERT v1   (rung 35 self-emission harness)"
  echo "target              compile.rail:$LINE  (is_digit lexer leaf)"
  echo "emitted_source      $EMIT_LINE"
  echo "emitted_src_sha256  $SRC_HEX"
  echo "emitted_eq_target   $EMIT_OK"
  echo "honest_fixed_point  $HONEST_FP   sha256=$FP"
  echo "tests               $TESTS_OK    (PASS=$NPASS FAIL=$NFAIL)"
  echo "mutation            $MUT"
  echo "mutation_breaks     $MUT_BREAKS  (mutated self-compile sha256=$HMUT)"
  echo "RUNG35_HARNESS      $([ $PASS -eq 1 ] && echo PASS || echo FAIL)"
} > "$CERT"
cat "$CERT"
# cleanup worktree (keep cert)
cd "$SRC" && git worktree remove --force "$WT" 2>/dev/null; git branch -D selfemit-harness 2>/dev/null
[ $PASS -eq 1 ] && exit 0 || exit 1
