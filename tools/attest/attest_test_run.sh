#!/usr/bin/env bash
# attest_test_run.sh — physicify a test-suite pass
#
# Runs `./rail_native test`, brackets it with two beacon pulse_ids, and
# emits a build record:
#   {commit, binary_sha256, pass, total, pulse_start, pulse_end, log_sha256}
# That JSON is itself attested (sha256 ⊗ pulse_id ⊗ Ed25519), giving a
# verifiable claim of the form "this commit's binary passed N of M tests
# during the real-time window [pulse_start, pulse_end]."
#
# Output: builds/<commit_short>/{run.log, result.json, result.json.attestation.json}
#
# Usage: attest_test_run.sh

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

bin=rail_native
[ -x "$bin" ] || { echo "no $bin" >&2; exit 3; }

commit=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
dirty=""
git diff --quiet 2>/dev/null || dirty="-dirty"
short="${short}${dirty}"

dest="builds/$short"
mkdir -p "$dest"
log="$dest/run.log"
result="$dest/result.json"

BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
get_pulse() {
  curl -sf --max-time 5 "$BEACON_URL" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])"
}

bin_sha=$(shasum -a 256 "$bin" | awk '{print $1}')
pulse_start=$(get_pulse)
echo "test run: commit=$short binary=${bin_sha:0:16} pulse_start=$pulse_start"

set +e
./"$bin" test >"$log" 2>&1
exit_code=$?
set -e

pulse_end=$(get_pulse)

# Parse "passed: N/M" or "N/M tests" lines emitted by the test harness.
parsed=$(python3 - "$log" <<'PY'
import re, sys
text = open(sys.argv[1], errors='replace').read()
m = re.search(r'(\d+)\s*/\s*(\d+)', text[-2000:])
if not m:
    print("0 0")
else:
    print(f"{m.group(1)} {m.group(2)}")
PY
)
passed=${parsed%% *}
total=${parsed##* }

log_sha=$(shasum -a 256 "$log" | awk '{print $1}')

python3 - "$commit" "$short" "$bin_sha" "$passed" "$total" \
  "$pulse_start" "$pulse_end" "$log_sha" "$exit_code" > "$result" <<'PY'
import json, sys
keys = ["commit","short","binary_sha256","pass","total",
        "pulse_start","pulse_end","log_sha256","exit_code"]
out = dict(zip(keys, sys.argv[1:]))
for k in ("pass","total","pulse_start","pulse_end","exit_code"):
    out[k] = int(out[k])
out["kind"] = "ledatic.build"
out["version"] = 1
out["status"] = "ok" if (out["exit_code"] == 0 and out["pass"] == out["total"] and out["total"] > 0) else "fail"
print(json.dumps(out, indent=2))
PY

./tools/attest/attest.sh "$result" "$result.attestation.json"

echo "----"
cat "$result"
echo "----"
echo "build attested: $dest/"
