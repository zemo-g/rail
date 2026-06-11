#!/usr/bin/env bash
# tools/prove/prove.sh - the claim ledger runner. Every public claim in this
# repo carries a receipt ID (R01..R21); this script replays them.
#
#   bash tools/prove/prove.sh           # fast tier (default)
#   bash tools/prove/prove.sh --core    # + R01 fixed point + R02 full suite
#   bash tools/prove/prove.sh R10       # single claim (forces its tier)
#   bash tools/prove/prove.sh --list    # emit the claim table (= PROOFS.md)
#
# Class rules (docs/VERIFY.md): timing never gates; `./rail_native run`
# swallows the child exit code, so run-receipts gate on OUTPUT TEXT only;
# exit codes gate only for cmp/shasum/git/verify.sh/test -s. Non-ARM64-macOS
# hosts SKIP native receipts, never FAIL. prove.sh prints every underlying
# command before running it - prove is convenience, never authority.
set -uo pipefail
cd "$(dirname "$0")/../.."

# ---- pinned constants (SINGLE SOURCE - R05 lints prose against these) ----
PIN_COMPILE_LINES=8049
PIN_STDLIB_MODULES=94
PIN_TEST_COUNT=170
PIN_V510_COMPILE_SHA=88f70263b240301841c56c80cd67d9ead4fe6ee92ba1ccf20a716662b5cc4614
PIN_V510_BINARY_SHA=3b89d0f5dc65d21e5c25b2c8cd10780472dd87496d58da65449da7d0240eab7d
PIN_PK_FP=cac5f21a70564aeb
PIN_PUBKEY=releases/witness-fleet0/fleet0.pub.pem

# ---- pinned expected outputs (captured live 2026-06-10, W3 capture pass) ----
CAPT_R06="RESULT: 8/8 partials agree across all three witnesses"
CAPT_R08_AUTHKIT="merkle root = afc59941de7c976817a9101ca0301139fca9a8fb844d4ccfbca8facbce8b9b5c"
CAPT_R08_AUTHDICT="dict root = 55b324dc6d390734a44b292f17c254febcc5f575b556a978926e721bd40d1767"
CAPT_R09="500000500000"                   # sum 1..1e6 via 1M-deep tail recursion
CAPT_R16_ADT="23"                         # eval (Add (Num 3) (Mul (Num 4) (Num 5)))
CAPT_R16_HOF="5050"                       # fold add 0 (range 101)
CAPT_R16_FLOAT="1.125"                    # neuron 0.5 1.0 0.25 2.0 0.125
CAPT_R18_STRING="the loop is the proof"   # the string snippet_sha256.rail hashes
CAPT_R19="Segmentation fault: 11"         # native_closures crash text (run-mode)

# ---- registry: claim <id> <tier> <class> <native?> <est-sec> <text> ----
CLAIMS=""
claim() {
  local id=$1; CLAIMS="$CLAIMS $id"
  eval "TIER_$id=\"\$2\"; CLASS_$id=\"\$3\"; NATIVE_$id=\"\$4\"; EST_$id=\"\$5\"; TEXT_$id=\"\$6\""
}
greason() { eval "GREASON_$1=\"\$2\""; }
getv() { eval "printf '%s' \"\${$1}\""; }

claim R01  core RUN    yes 660  "self-hosting fixed point: two self-compile cycles produce byte-identical binaries"
claim R01s fast SIGNED yes 8    "the v5.1.0 fixed point is recorded in selfhost/94afdd1 and Ed25519-verified offline"
claim R02  core RUN    yes 1020 "the full test suite passes $PIN_TEST_COUNT/$PIN_TEST_COUNT"
claim R03  fast RUN    yes 1    "zero C dependencies: one linked dylib (libSystem) and exactly 8 undefined symbols"
claim R04  fast RUN    yes 3    "examples/hello.rail compiles and runs from the bare clone"
claim R05  fast RUN    no  1    "counts cited in README.md/STRUCTURE.md match the live tree (numeric-drift lint)"
claim R06  fast RUN    yes 5    "#grad autodiff agrees with the three-witness gradient oracle"
claim R07  fast RUN    yes 3    "mlp_natural.rail: the #grad-trained MLP computes mlp(1.0,2.0)=1.125"
claim R08  fast RUN    yes 8    "auth types: compiler-synthesized Merkle prover/verifier run (authkit + authdict)"
claim R09  fast RUN    yes 6    "tail calls compile to loops: tco_test runs 2M-deep recursion (disassembly display-only)"
claim R10  fast SIGNED yes 8    "v5.1.0 compile.rail matches index.json sha256 and its attestation verifies offline in Rail"
claim R10b fast SIGNED yes 30   "v5.1.0 rail_native binary verified by BOTH verify.sh and verify.rail (cross-witness)"
claim R12  fast RUN    yes 15   "cross backends emit artifacts from this clone (linux ELF + x86_64 asm gated; others reported)"
claim R13  net  GATED  yes 15   "pure-Rail TLS 1.3 performs a live strict-chain HTTPS GET"
claim R14  key  GATED  yes 15   "anthropic_chat reaches a live API over pure-Rail TLS"
claim R15  key  GATED  yes 10   "the self-training loop source compiles in-tree (running the loop needs a key)"
claim R16  fast RUN    yes 10   "README language snippets are byte-identical to examples/readme/ files and run with pinned output"
claim R17  fast RUN    no  1    "every [Rnn] anchor in README.md/docs/VERIFY.md maps to a prove.sh claim, and vice versa"
claim R18  fast RUN    yes 4    "Rail's sha256 agrees with system shasum on the same string"
claim R19  fast RUN    yes 4    "bug receipt: examples/native_closures.rail segfaults exactly as documented"
claim R20  fast RUN    no  2    "docs/RELEASE_LEDGER.md regenerates identically (gen_release_ledger.sh --check)"
claim R21  gpu  GATED  yes 20   "self-emitted JIT-fused Metal kernels run (perf numbers display-only)"

greason R13 "gated: net - live HTTPS GET needs network; run with --net"
greason R14 "gated: key - needs a reader-supplied API key; run with --key"
greason R15 "gated: key - the training loop needs an API key; --key runs the compile receipt"
greason R21 "gated: gpu - Metal GPU required; run with --gpu"

# ---- helpers ----
say()  { printf '%s\n' "$*"; }
show() { printf '$ %s\n' "$*"; }
cap() { # print command, run it via bash -c, capture combined output in CAP, rc in RC
  show "$1"
  CAP=$(bash -c "$1" 2>&1); RC=$?
  [ -n "$CAP" ] && printf '%s\n' "$CAP"
}
cap_log() { # like cap, but stream to a log file and echo only the tail (long runs)
  show "$1"
  bash -c "$1" >"$2" 2>&1; RC=$?
  say "(full output: $2; last 3 lines)"
  tail -n 3 "$2"
  CAP=$(tail -n 50 "$2")
}
hasf() { printf '%s\n' "$CAP" | grep -Fq "$1"; }  # fixed-string output gate
hase() { printf '%s\n' "$CAP" | grep -Eq "$1"; }  # regex output gate
commafy() { # 8049 -> 8,049 (pure bash; BSD sed BRE has no alternation)
  local n=$1 out=""
  while [ "${#n}" -gt 3 ]; do out=",${n:${#n}-3}$out"; n=${n:0:${#n}-3}; done
  printf '%s%s' "$n" "$out"
}
verify_ok() { hase '^ok[[:space:]]' && hasf "pk_fp=$PIN_PK_FP"; }

# ---- one function per claim ----
r01() {
  say "warning: est ~11 min - two full self-compile cycles (Apple M-series)"
  cap_log "./rail_native self" /tmp/rail_prove_R01_cycle1.log
  cap "cp /tmp/rail_self /tmp/rail_prove_R01_gen1"
  [ -s /tmp/rail_prove_R01_gen1 ] || { MSG="cycle 1 left no binary at /tmp/rail_self"; return 1; }
  cap_log "/tmp/rail_prove_R01_gen1 self" /tmp/rail_prove_R01_cycle2.log
  cap "cp /tmp/rail_self /tmp/rail_prove_R01_gen2"
  [ -s /tmp/rail_prove_R01_gen2 ] || { MSG="cycle 2 left no binary at /tmp/rail_self"; return 1; }
  cap "cmp /tmp/rail_prove_R01_gen1 /tmp/rail_prove_R01_gen2"
  [ "$RC" -eq 0 ] || { MSG="cmp: gen1 and gen2 differ - no fixed point"; return 1; }
}

r01s() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R01s_v run tools/attest/verify.rail selfhost/94afdd1/result.json selfhost/94afdd1/result.json.attestation.json $PIN_PUBKEY"
  verify_ok || { MSG="verify.rail did not print ok + pk_fp=$PIN_PK_FP"; return 1; }
}

r02() {
  say "warning: est ~17 min - full $PIN_TEST_COUNT-test suite (Apple M-series)"
  cap_log "./rail_native test" /tmp/rail_prove_R02.log
  local last; last=$(tail -n 1 /tmp/rail_prove_R02.log)
  if ! printf '%s' "$last" | grep -q "$PIN_TEST_COUNT/$PIN_TEST_COUNT tests passed"; then
    say "summary was: $last"
    say "hint: ps aux | grep rail_native - orphan processes from concurrent sessions cause transient collisions"
    say "retrying once..."
    cap_log "./rail_native test" /tmp/rail_prove_R02_retry.log
    last=$(tail -n 1 /tmp/rail_prove_R02_retry.log)
    printf '%s' "$last" | grep -q "$PIN_TEST_COUNT/$PIN_TEST_COUNT tests passed" \
      || { MSG="suite summary after retry: $last"; return 1; }
  fi
}

r03() {
  cap "otool -L rail_native"
  local n; n=$(printf '%s\n' "$CAP" | sed 1d | grep -c .)
  printf '%s\n' "$CAP" | sed 1d | grep -q "libSystem.B.dylib" || { MSG="linked dylib is not libSystem.B.dylib"; return 1; }
  [ "$n" -eq 1 ] || { MSG="expected exactly 1 linked dylib, got $n"; return 1; }
  cap "nm -u rail_native"
  local c; c=$(printf '%s\n' "$CAP" | grep -c .)
  [ "$c" -eq 8 ] || { MSG="expected exactly 8 undefined symbols, got $c"; return 1; }
}

r04() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R04 run examples/hello.rail"
  hasf "hello, rail" || { MSG="output missing 'hello, rail'"; return 1; }
  hasf "3628800"     || { MSG="output missing factorial 10 = 3628800"; return 1; }
}

r05() {
  local live clpat
  cap "wc -l < tools/compile.rail"
  live=$(printf '%s' "$CAP" | tr -d ' \t')
  [ "$live" = "$PIN_COMPILE_LINES" ] || { MSG="compile.rail is $live lines, pinned $PIN_COMPILE_LINES"; return 1; }
  cap "ls stdlib/*.rail | wc -l"
  live=$(printf '%s' "$CAP" | tr -d ' \t')
  [ "$live" = "$PIN_STDLIB_MODULES" ] || { MSG="stdlib has $live modules, pinned $PIN_STDLIB_MODULES"; return 1; }
  clpat="($PIN_COMPILE_LINES|$(commafy "$PIN_COMPILE_LINES"))"
  cap "grep -cE '$clpat' README.md";    [ "$RC" -eq 0 ] || { MSG="README.md does not cite $PIN_COMPILE_LINES compile.rail lines"; return 1; }
  cap "grep -cE '$clpat' STRUCTURE.md"; [ "$RC" -eq 0 ] || { MSG="STRUCTURE.md does not cite $PIN_COMPILE_LINES compile.rail lines"; return 1; }
  cap "grep -cE '$PIN_STDLIB_MODULES (stdlib )?modules|$PIN_STDLIB_MODULES stdlib' README.md"
  [ "$RC" -eq 0 ] || { MSG="README.md does not cite $PIN_STDLIB_MODULES stdlib modules"; return 1; }
  cap "grep -cE '$PIN_STDLIB_MODULES modules' STRUCTURE.md"
  [ "$RC" -eq 0 ] || { MSG="STRUCTURE.md does not cite $PIN_STDLIB_MODULES modules"; return 1; }
  cap "grep -c '$PIN_TEST_COUNT/$PIN_TEST_COUNT' README.md"
  [ "$RC" -eq 0 ] || { MSG="README.md does not cite $PIN_TEST_COUNT/$PIN_TEST_COUNT tests"; return 1; }
}

r06() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R06 run tools/ad/grad_oracle_test.rail"
  hasf "$CAPT_R06" || { MSG="output missing pinned oracle token: $CAPT_R06"; return 1; }
}

r07() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R07 run examples/mlp_natural.rail"
  hasf "1.125" || { MSG="output missing mlp(1.0,2.0)=1.125"; return 1; }
}

r08() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R08_kit run tools/auth/authkit.rail"
  hasf "$CAPT_R08_AUTHKIT" || { MSG="authkit output missing pinned token: $CAPT_R08_AUTHKIT"; return 1; }
  cap "./rail_native --out-prefix /tmp/rail_prove_R08_dict run tools/auth/authdict.rail"
  hasf "$CAPT_R08_AUTHDICT" || { MSG="authdict output missing pinned token: $CAPT_R08_AUTHDICT"; return 1; }
}

r09() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R09_run run examples/tco_test.rail"
  hasf "$CAPT_R09" || { MSG="output missing pinned functional token: $CAPT_R09"; return 1; }
  cap "./rail_native --out-prefix /tmp/rail_prove_R09_bin examples/tco_test.rail"
  if [ -s /tmp/rail_prove_R09_bin ]; then
    cap "objdump -d /tmp/rail_prove_R09_bin | sed -n '/count_down/,/ret/p' | head -20"
  fi
  say "note: the disassembly and any insn-count/perf comparison are display-only - timing never gates"
}

r10() {
  cap "git show v5.1.0:tools/compile.rail > /tmp/rail_prove_R10.rail"
  [ "$RC" -eq 0 ] || { MSG="git show v5.1.0:tools/compile.rail failed"; return 1; }
  cap "shasum -a 256 /tmp/rail_prove_R10.rail"
  local sha; sha=$(printf '%s' "$CAP" | awk '{print $1}')
  [ "$sha" = "$PIN_V510_COMPILE_SHA" ] || { MSG="sha256 $sha != index.json $PIN_V510_COMPILE_SHA"; return 1; }
  cap "./rail_native --out-prefix /tmp/rail_prove_R10_v run tools/attest/verify.rail /tmp/rail_prove_R10.rail releases/v5.1.0/compile.rail.attestation.json $PIN_PUBKEY"
  verify_ok || { MSG="verify.rail did not print ok + pk_fp=$PIN_PK_FP"; return 1; }
}

r10b() {
  cap "git show v5.1.0:rail_native > /tmp/rail_prove_R10b"
  [ "$RC" -eq 0 ] || { MSG="git show v5.1.0:rail_native failed"; return 1; }
  cap "shasum -a 256 /tmp/rail_prove_R10b"
  local sha sh_ok=no rl_ok=no
  sha=$(printf '%s' "$CAP" | awk '{print $1}')
  [ "$sha" = "$PIN_V510_BINARY_SHA" ] || { MSG="sha256 $sha != index.json $PIN_V510_BINARY_SHA"; return 1; }
  cap "bash tools/attest/verify.sh /tmp/rail_prove_R10b releases/v5.1.0/rail_native.attestation.json $PIN_PUBKEY"
  if [ "$RC" -eq 0 ] && verify_ok; then sh_ok=yes; fi
  cap "./rail_native --out-prefix /tmp/rail_prove_R10b_v run tools/attest/verify.rail /tmp/rail_prove_R10b releases/v5.1.0/rail_native.attestation.json $PIN_PUBKEY"
  if verify_ok; then rl_ok=yes; fi
  [ "$sh_ok" = "$rl_ok" ] || { MSG="CROSS-WITNESS DISAGREEMENT: verify.sh=$sh_ok verify.rail=$rl_ok"; return 1; }
  [ "$sh_ok" = yes ] || { MSG="both verifiers rejected the artifact"; return 1; }
}

r12() {
  rm -f /tmp/rail_linux /tmp/rail_x86.s
  cap "./rail_native linux examples/hello.rail"
  cap "test -s /tmp/rail_linux"
  [ "$RC" -eq 0 ] || { MSG="no Linux ELF artifact at /tmp/rail_linux"; return 1; }
  cp /tmp/rail_linux /tmp/rail_prove_R12_linux
  cap "./rail_native x86 examples/hello.rail"
  cap "test -s /tmp/rail_x86.s"
  [ "$RC" -eq 0 ] || { MSG="no x86_64 asm artifact at /tmp/rail_x86.s"; return 1; }
  cp /tmp/rail_x86.s /tmp/rail_prove_R12_x86.s
  # TODO(capture): promote any backend below to a gate once the W3 sweep pins it.
  say "display-only (artifact reported, not gated, pending capture sweep):"
  local b name art
  for b in "cortexm:/tmp/rail_m4.s" "riscv32:/tmp/rail_rv32.s" "wasm:/tmp/rail_out.wat"; do
    name=${b%%:*}; art=${b#*:}
    rm -f "$art"
    cap "./rail_native $name examples/hello.rail"
    if [ -s "$art" ]; then say "  $name: artifact $art present ($(wc -c < "$art" | tr -d ' ') bytes)"
    else say "  $name: no artifact at $art (reported, not gated)"; fi
  done
}

r13() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R13 run tools/tls/https_strict_test.rail"
  hasf "PASS" || { MSG="strict-chain HTTPS GET did not print PASS"; return 1; }
}

r14() {
  [ -f anthropic_key.txt ] || { MSG="no anthropic_key.txt in repo root - reader supplies their own key"; return 2; }
  cap "./rail_native --out-prefix /tmp/rail_prove_R14 run tools/tls/anthropic_live_test.rail"
  hasf "PASS" || { MSG="anthropic_chat did not print PASS"; return 1; }
}

r15() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R15 tools/train/self_train.rail"
  cap "test -s /tmp/rail_prove_R15"
  [ "$RC" -eq 0 ] || { MSG="self_train.rail did not compile to a nonzero binary"; return 1; }
  say "note: the training loop itself needs an API key and hours of wall clock; only the compile is gated"
}

extract_snippet() { # $1 = name; prints the fenced block after <!-- snippet:$1 --> in README.md
  awk -v m="<!-- snippet:$1 -->" '
    $0 == m { want = 1; next }
    want == 1 && /^```/ { if (inb) exit; inb = 1; next }
    inb { print }
  ' README.md
}

r16() {
  local name f tok
  for name in adt hof float; do
    f="examples/readme/snippet_${name}.rail"
    [ -f "$f" ] || { MSG="missing $f - README snippet files not landed yet"; return 1; }
    show "extract README.md block after '<!-- snippet:$name -->' and byte-diff against $f"
    extract_snippet "$name" > "/tmp/rail_prove_R16_${name}.block"
    [ -s "/tmp/rail_prove_R16_${name}.block" ] || { MSG="marker '<!-- snippet:$name -->' not found in README.md"; return 1; }
    cap "diff -u /tmp/rail_prove_R16_${name}.block $f"
    [ "$RC" -eq 0 ] || { MSG="README block snippet:$name is not byte-identical to $f"; return 1; }
    tok=$(getv "CAPT_R16_$(printf '%s' "$name" | tr 'a-z' 'A-Z')")
    cap "./rail_native --out-prefix /tmp/rail_prove_R16_${name}_bin run $f"
    hasf "$tok" || { MSG="$f output missing pinned token: $tok"; return 1; }
  done
}

r17() {
  local files="README.md" miss=0 a id known
  if [ -f docs/VERIFY.md ]; then files="$files docs/VERIFY.md"
  else say "note: docs/VERIFY.md not present - linting README.md only"; fi
  show "grep -ohE '\[R[0-9]+[a-z]?\]' $files | sort -u"
  local anchors; anchors=$(grep -ohE '\[R[0-9]+[a-z]?\]' $files 2>/dev/null | tr -d '[]' | sort -u)
  for a in $anchors; do
    known=no
    for id in $CLAIMS; do [ "$a" = "$id" ] && known=yes; done
    [ "$known" = yes ] || { say "  unresolved anchor [$a]: no matching prove.sh claim"; miss=$((miss + 1)); }
  done
  for id in $CLAIMS; do
    grep -q "\[$id\]" $files 2>/dev/null || { say "  claim $id: no [$id] anchor found in: $files"; miss=$((miss + 1)); }
  done
  [ "$miss" -eq 0 ] || { MSG="$miss unresolved anchor(s) between prose and prove.sh"; return 1; }
}

r18() {
  local f=examples/readme/snippet_sha256.rail rail_hex sys_hex
  [ -f "$f" ] || { MSG="missing $f - README snippet files not landed yet"; return 1; }
  cap "./rail_native --out-prefix /tmp/rail_prove_R18 run $f"
  rail_hex=$(printf '%s\n' "$CAP" | grep -oE '[0-9a-f]{64}' | tail -n 1)
  [ -n "$rail_hex" ] || { MSG="no 64-hex digest in snippet output"; return 1; }
  cap "echo -n '$CAPT_R18_STRING' | shasum -a 256"
  sys_hex=$(printf '%s' "$CAP" | awk '{print $1}')
  [ "$rail_hex" = "$sys_hex" ] || { MSG="digests disagree: rail=$rail_hex shasum=$sys_hex"; return 1; }
}

r19() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R19 run examples/native_closures.rail"
  # gate on TEXT: `run` swallows the child exit code, so $? cannot see the crash
  hasf "$CAPT_R19" || { MSG="expected segfault text not found (pinned token: $CAPT_R19)"; return 1; }
}

r20() {
  [ -f tools/attest/gen_release_ledger.sh ] || { MSG="tools/attest/gen_release_ledger.sh not found - ledger generator not landed yet"; return 1; }
  cap "bash tools/attest/gen_release_ledger.sh --check"
  [ "$RC" -eq 0 ] || { MSG="--check failed: regenerated table differs from committed docs/RELEASE_LEDGER.md"; return 1; }
}

r21() {
  cap "./rail_native --out-prefix /tmp/rail_prove_R21 run tools/bench/jit_fused_qkv_bench.rail"
  [ -n "$CAP" ] || { MSG="GPU bench produced no output"; return 1; }
  say "note: the perf numbers above are display-only - timing never gates"
}

# ---- driver ----
RUN_CORE=no RUN_NET=no RUN_GPU=no RUN_KEY=no RUN_HW=no
MODE=run SELECT="" FORCE=no
for arg in "$@"; do
  case "$arg" in
    --list) MODE=list ;;
    --core) RUN_CORE=yes ;;
    --net)  RUN_NET=yes ;;
    --gpu)  RUN_GPU=yes ;;
    --key)  RUN_KEY=yes ;;
    --hw)   RUN_HW=yes ;;
    --all)  RUN_CORE=yes; RUN_NET=yes; RUN_GPU=yes; RUN_KEY=yes; RUN_HW=yes ;;
    -h|--help) say "usage: prove.sh [--core|--net|--gpu|--key|--hw|--all] [Rnn] [--list]"; exit 0 ;;
    -*) say "unknown flag: $arg"; exit 2 ;;
    *)  SELECT="$arg" ;;
  esac
done

tier_on() {
  case "$1" in
    fast) return 0 ;;
    core) [ "$RUN_CORE" = yes ] ;;
    net)  [ "$RUN_NET" = yes ] ;;
    gpu)  [ "$RUN_GPU" = yes ] ;;
    key)  [ "$RUN_KEY" = yes ] ;;
    hw)   [ "$RUN_HW" = yes ] ;;
    *) return 1 ;;
  esac
}

list_claims() {
  say "<!-- generated by tools/prove/prove.sh --list - do not hand-edit -->"
  say ""
  say "# PROOFS - the claim ledger"
  say ""
  say "Every public claim in this repo carries a receipt ID. Replay them from the repo root:"
  say ""
  say '```'
  say "bash tools/prove/prove.sh          # fast tier (default, seconds)"
  say "bash tools/prove/prove.sh --core   # + R01 fixed point (~11 min) + R02 suite (~17 min)"
  say "bash tools/prove/prove.sh R10      # a single claim"
  say "bash tools/prove/prove.sh --all    # everything, including gated tiers"
  say '```'
  say ""
  say "Tiers: fast (default) / core / net / gpu / key / hw. GATED claims print SKIP with the"
  say "reason unless their tier flag is passed. Est times are estimates and never gate."
  say ""
  say "| ID | Tier | Class | Est | Claim |"
  say "|---|---|---|---|---|"
  local id
  for id in $CLAIMS; do
    say "| $id | $(getv "TIER_$id") | $(getv "CLASS_$id") | ~$(getv "EST_$id")s | $(getv "TEXT_$id") |"
  done
}

NPASS=0 NFAIL=0 NSKIP=0 NRUN=0
HOSTOK=no; [ "$(uname -sm)" = "Darwin arm64" ] && HOSTOK=yes

run_one() {
  local id=$1 tier class text fn rc dt t0
  tier=$(getv "TIER_$id"); class=$(getv "CLASS_$id"); text=$(getv "TEXT_$id")
  fn=$(printf '%s' "$id" | tr 'A-Z' 'a-z')
  say ""
  say "--- $id [$tier/$class] ---"
  if [ "$FORCE" != yes ]; then
    if [ "$class" = GATED ] && ! tier_on "$tier"; then
      say "$id SKIP ($(getv "GREASON_$id")) - $text"; NSKIP=$((NSKIP + 1)); return 0
    fi
    if ! tier_on "$tier"; then
      say "$id SKIP (tier $tier: enable with --$tier) - $text"; NSKIP=$((NSKIP + 1)); return 0
    fi
  fi
  if [ "$(getv "NATIVE_$id")" = yes ] && [ "$HOSTOK" != yes ]; then
    say "$id SKIP (host: ARM64 macOS required) - $text"; NSKIP=$((NSKIP + 1)); return 0
  fi
  rm -f "/tmp/rail_prove_${id}"* 2>/dev/null
  MSG=""
  t0=$SECONDS
  "$fn"; rc=$?
  dt=$((SECONDS - t0))
  if [ "$rc" -eq 0 ]; then
    say "$id PASS (${dt}s) - $text"; NPASS=$((NPASS + 1)); NRUN=$((NRUN + 1))
  elif [ "$rc" -eq 2 ]; then
    say "$id SKIP ($MSG) - $text"; NSKIP=$((NSKIP + 1))
  else
    say "$id FAIL (${dt}s) - $text"
    [ -n "$MSG" ] && say "    reason: $MSG"
    NFAIL=$((NFAIL + 1)); NRUN=$((NRUN + 1))
  fi
}

if [ "$MODE" = list ]; then list_claims; exit 0; fi

if [ -n "$SELECT" ]; then
  up=$(printf '%s' "$SELECT" | tr 'a-z' 'A-Z'); found=""
  for id in $CLAIMS; do
    [ "$(printf '%s' "$id" | tr 'a-z' 'A-Z')" = "$up" ] && found=$id
  done
  [ -n "$found" ] || { say "unknown claim id: $SELECT (see --list)"; exit 2; }
  FORCE=yes
  run_one "$found"
else
  for id in $CLAIMS; do run_one "$id"; done
fi

say ""
say "$NPASS/$NRUN receipts verified, $NSKIP skipped (gated)"
[ "$NFAIL" -eq 0 ] && exit 0 || exit 1
