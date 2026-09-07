#!/usr/bin/env bash
# tools/attest/verify_selftest.sh: prove the verifiers bind the file to the signature.
#
# Positive control: a committed self-host attestation verifies with both the
# shell verifier and the Rail verifier.
# Negative control: a replacement artifact whose sidecar carries the
# replacement's hash in the UNSIGNED artifact.sha256 field, with the signed
# witness block copied verbatim. Both verifiers must reject it.
#
# This exists because on 2026-09-06 the shell verifier accepted exactly that
# fixture (it compared the file to the unsigned field and the signature to the
# signed field, and never compared those two to each other).
#
# Usage: tools/attest/verify_selftest.sh [pubkey_pem]      exit 0 iff all four outcomes hold
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
pub=${1:-$HOME/.ledatic/witness/fleet0.pub.pem}
ctl_in=selfhost/30f424a/result.json
ctl_att=$ctl_in.attestation.json
[ -f "$ctl_in" ] && [ -f "$ctl_att" ] || { echo "selftest: control fixture missing ($ctl_in)"; exit 2; }
if [ ! -f "$pub" ]; then
  mkdir -p "$(dirname "$pub")"
  curl -sf --max-time 10 "${PUBKEY_URL:-https://ledatic.org/attest/fleet0.pub.pem}" -o "$pub" \
    || { echo "selftest: no pubkey at $pub and could not fetch one"; exit 2; }
fi

tmp=$(mktemp -d /tmp/attest_selftest_XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf 'not the attested artifact\n' > "$tmp/replacement.json"
rep_sha=$(shasum -a 256 "$tmp/replacement.json" | awk '{print $1}')
python3 - "$ctl_att" "$tmp/tampered.attestation.json" "$rep_sha" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
a["artifact"]["sha256"] = sys.argv[3]          # unsigned field only; witness untouched
json.dump(a, open(sys.argv[2], "w"), indent=2)
PY

rail_verify() {  # <input> <attestation> -> prints the verdict line; its own exit is not the signal
  RAIL_ARENA_MB="${RAIL_ARENA_MB:-2000}" ./rail_native --out-prefix "$tmp/rv" run tools/attest/verify.rail "$1" "$2" "$pub" > "$tmp/rv.log" 2>&1
  grep -E '^(ok|BAD)' "$tmp/rv.log"
}

fail=0
expect() {  # <label> <want: 0|nonzero> <got>
  if { [ "$2" = 0 ] && [ "$3" = 0 ]; } || { [ "$2" = nonzero ] && [ "$3" != 0 ]; }; then
    printf '  ok  %s (exit %s)\n' "$1" "$3"
  else printf '  NO  %s (exit %s, wanted %s)\n' "$1" "$3" "$2"; fail=1; fi
}

tools/attest/verify.sh "$ctl_in" "$ctl_att" "$pub" >/dev/null 2>&1; expect "shell verifier accepts the control" 0 $?
rail_verify "$ctl_in" "$ctl_att" | grep -q '^ok'; expect "Rail verifier accepts the control" 0 $?
tools/attest/verify.sh "$tmp/replacement.json" "$tmp/tampered.attestation.json" "$pub" >/dev/null 2>&1; expect "shell verifier rejects a replacement artifact" nonzero $?
rail_verify "$tmp/replacement.json" "$tmp/tampered.attestation.json" | grep -q '^BAD'; expect "Rail verifier rejects a replacement artifact" 0 $?
exit $fail
