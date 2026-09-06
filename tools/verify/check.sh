#!/usr/bin/env bash
# tools/verify/check.sh: one command to check Rail's core claims yourself.
# "Check me, don't trust me." Each section is an independent, verifiable claim;
# a third party can run any one on its own. See VERIFY.md for what each proves.
#
# Usage:
#   tools/verify/check.sh           full self-audit (~25 min: source rebuild + full tests)
#   tools/verify/check.sh --quick   fast pass (~2 min: skip rebuild, run the quick suite)
# Exit 0 iff every run check passed.
#
# Discipline (after the 2026-09-06 outside review): a check passes on positive
# evidence it captured itself (an exit status, a count that matches, a verifier
# that said ok), never on the absence of a word in a log.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2          # repo root

QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
ARENA="${RAIL_ARENA_MB:-6000}"
PUB="${RAIL_WITNESS_PUB:-$HOME/.ledatic/witness/fleet0.pub.pem}"
pass=0; fail=0
ok(){ printf '  \033[32mok\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mNO\033[0m  %s\n' "$1"; fail=$((fail+1)); }
tmp=$(mktemp -d /tmp/rail_verify_XXXXXX); trap 'rm -rf "$tmp"' EXIT

echo "== 1. Reproducible seed (binary == what the source rebuilds) =="
if [ "$QUICK" = 1 ]; then
  echo "  -- skipped in --quick; run ./verify_reproducible.sh for the byte-identity proof"
elif RAIL_ARENA_MB="$ARENA" ./verify_reproducible.sh; then ok "reproducible from source"
else no "NOT reproducible (or env: needs Apple Silicon + RAIL_ARENA_MB>=6000)"; fi

echo "== 2. Tests (runner exits 0 AND its own summary line reads N/N) =="
tcmd=$([ "$QUICK" = 1 ] && echo quick || echo test)
RAIL_ARENA_MB=4096 ./rail_native "$tcmd" >"$tmp/test.log" 2>&1; trc=$?
summary=$(grep -oE '^[0-9]+/[0-9]+ (quick )?tests passed' "$tmp/test.log" | tail -1)
got=${summary%%/*}; want=$(printf '%s' "$summary" | sed -E 's|^[0-9]+/([0-9]+).*|\1|')
if [ "$trc" = 0 ] && [ -n "$summary" ] && [ "$got" = "$want" ]; then ok "$tcmd suite: $summary, exit 0"
else
  no "$tcmd suite: exit $trc, summary '${summary:-none}' (log: $tmp/test.log kept as /tmp/_verify_test.log)"
  cp "$tmp/test.log" /tmp/_verify_test.log; grep -E 'FAIL|^  --- ' "$tmp/test.log" | grep -B1 FAIL | head -20
fi

echo "== 3. Grammar present (the language surface, readable) =="
if [ -f grammar/rail.ebnf ]; then ok "grammar/rail.ebnf ($(wc -l < grammar/rail.ebnf | tr -d ' ') lines)"
else no "grammar/rail.ebnf missing"; fi

echo "== 4. Status matrix regenerates live (cannot drift) =="
if [ -f docs/STATUS.md ] \
   && RAIL_ARENA_MB=4096 ./rail_native --out-prefix "$tmp/gen_status" run tools/deploy/gen_status.rail >"$tmp/status.log" 2>&1 \
   && git diff --exit-code --quiet -- docs/STATUS.md; then ok "docs/STATUS.md regenerated and matches the committed copy"
else no "gen_status failed or docs/STATUS.md has drifted (git diff docs/STATUS.md)"; cp "$tmp/status.log" /tmp/_verify_status.log; fi

echo "== 5. Release attestation (the Rail verifier checks the tagged source against its signed witness) =="
idx=$(ls -d releases/v*/ 2>/dev/null | sort -V | tail -1)
if [ -z "$idx" ] || [ ! -f "$idx/index.json" ]; then no "no releases/v*/index.json"
else
  tag=$(python3 -c "import json;print(json.load(open('$idx/index.json'))['tag'])")
  commit=$(python3 -c "import json;print(json.load(open('$idx/index.json'))['git']['commit'])")
  git cat-file -e "$commit^{commit}" 2>/dev/null || git fetch -q --depth=1 origin "$commit" 2>/dev/null
  if ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
    no "$tag: commit $commit not reachable from this clone (shallow?), cannot verify"
  elif [ ! -f "$PUB" ]; then
    no "$tag: no witness pubkey at $PUB (set RAIL_WITNESS_PUB or fetch https://ledatic.org/attest/fleet0.pub.pem)"
  else
    git show "$commit:tools/compile.rail" > "$tmp/compile.rail"
    v=$(RAIL_ARENA_MB=2000 ./rail_native --out-prefix "$tmp/verify" run tools/attest/verify.rail \
          "$tmp/compile.rail" "$idx/compile.rail.attestation.json" "$PUB" 2>&1 | grep -E '^(ok|BAD)' | tail -1)
    case "$v" in ok*) ok "$tag compile.rail @ ${commit:0:7}: $v";; *) no "$tag compile.rail: ${v:-verifier produced no verdict}";; esac
  fi
fi

echo "== 6. The verifier binds the file to the signature (rejects a replacement artifact) =="
if tools/attest/verify_selftest.sh "$PUB" >"$tmp/selftest.log" 2>&1; then ok "positive and replacement-artifact controls behave (tools/attest/verify_selftest.sh)"
else no "verify_selftest failed:"; sed 's/^/     /' "$tmp/selftest.log"; fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" = 0 ]
