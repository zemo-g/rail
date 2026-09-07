#!/usr/bin/env bash
# tools/verify/check_selftest.sh: the umbrella script's own negative controls.
#
# Builds a throwaway fixture repo around a COPY of tools/verify/check.sh with a
# stub rail_native, and asserts the umbrella says NO when:
#   A. the test process exits 139 without printing anything (found 2026-09-06:
#      the old script inferred success from the absence of the word FAIL);
#   B. the release verifier prints `ok` and then exits 139 (found 2026-09-07:
#      the verdict line was read through a pipe and the exit status lost).
# Positive control C: a stub that behaves (N/N + exit 0, ok + exit 0) passes
# sections 2 and 5, so the NOs above are not just a broken fixture.
#
# Usage: tools/verify/check_selftest.sh        exit 0 iff all three outcomes hold
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
fx=$(mktemp -d /tmp/check_selftest_XXXXXX); trap 'rm -rf "$fx"' EXIT

# Fixture: enough tree for sections 3, 4, 5, 6 to run, with 6 and 7 stubbed to
# pass so the verdict under test is isolated to the stubbed rail_native.
mkdir -p "$fx/tools/verify" "$fx/tools/attest" "$fx/tools/deploy" "$fx/grammar" "$fx/docs" "$fx/releases/v0.0.1"
cp tools/verify/check.sh "$fx/tools/verify/check.sh"
: > "$fx/grammar/rail.ebnf"; : > "$fx/docs/STATUS.md"; : > "$fx/tools/attest/verify.rail"; : > "$fx/tools/deploy/gen_status.rail"
printf '#!/bin/bash\nexit 0\n' > "$fx/tools/attest/verify_selftest.sh"
printf '#!/bin/bash\nexit 0\n' > "$fx/tools/verify/check_selftest.sh"
chmod +x "$fx/tools/attest/verify_selftest.sh" "$fx/tools/verify/check_selftest.sh"
: > "$fx/releases/v0.0.1/compile.rail.attestation.json"
printf 'stub pubkey\n' > "$fx/pub.pem"
git -C "$fx" init -q && git -C "$fx" -c user.name=fx -c user.email=fx@fx add -A \
  && git -C "$fx" -c user.name=fx -c user.email=fx@fx commit -q -m fixture
commit=$(git -C "$fx" rev-parse HEAD)
printf '{"tag":"v0.0.1","git":{"commit":"%s"}}\n' "$commit" > "$fx/releases/v0.0.1/index.json"
git -C "$fx" -c user.name=fx -c user.email=fx@fx add -A && git -C "$fx" -c user.name=fx -c user.email=fx@fx commit -q -m index

# stub <test_exit> <test_output> <verifier_exit> <verifier_output>
stub() {
  cat > "$fx/rail_native" <<STUB
#!/bin/bash
case "\$1" in
  quick|test) printf '%s\n' '$2'; exit $1;;
  --out-prefix) shift 2; [ "\$1" = run ] && case "\$2" in *verify.rail) printf '%s\n' '$4'; exit $3;; esac; exit 0;;
esac
exit 0
STUB
  chmod +x "$fx/rail_native"
}
run() { (cd "$fx" && RAIL_WITNESS_PUB="$fx/pub.pem" bash tools/verify/check.sh --quick 2>&1); }
fail=0
expect() {  # <label> <want: 0|nonzero> <got>
  if { [ "$2" = 0 ] && [ "$3" = 0 ]; } || { [ "$2" = nonzero ] && [ "$3" != 0 ]; }; then printf '  ok  %s (exit %s)\n' "$1" "$3"
  else printf '  NO  %s (exit %s, wanted %s)\n' "$1" "$3" "$2"; fail=1; fi
}

stub 0 "15/15 quick tests passed" 0 "ok  artifact=compile.rail  pulse_id=1  pk_fp=stub"
out=$(run); rc=$?; expect "C. well-behaved stub passes the umbrella" 0 $rc
[ $rc = 0 ] || printf '%s\n' "$out" | sed 's/^/     /'

stub 139 "" 0 "ok  artifact=compile.rail  pulse_id=1  pk_fp=stub"
out=$(run); rc=$?; expect "A. test process exit 139, no output: umbrella fails" nonzero $rc
printf '%s\n' "$out" | grep -q 'quick suite: exit 139' || { echo "  NO  A. section 2 did not name exit 139"; fail=1; }

stub 0 "15/15 quick tests passed" 139 "ok  artifact=compile.rail  pulse_id=1  pk_fp=stub"
out=$(run); rc=$?; expect "B. verifier prints ok then exits 139: umbrella fails" nonzero $rc
printf '%s\n' "$out" | grep -q "compile.rail: exit 139" || { echo "  NO  B. section 5 did not name exit 139"; fail=1; }
exit $fail
