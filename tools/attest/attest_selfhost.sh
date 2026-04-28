#!/usr/bin/env bash
# attest_selfhost.sh — physicify the self-hosting fixed point
#
# Runs `./rail_native self` twice and asserts that pass-2 reproduces
# pass-1 byte for byte (and that pass-1 reproduces the seed binary
# itself).  This is the physical proof that the compiler is at a
# fixed point: the bits encode a function whose action on its own
# source is the identity.
#
# Output: selfhost/<commit_short>/{result.json, result.json.attestation.json}
#
# A passing run is a load-bearing claim about the codebase.  An attested
# passing run is a citable historical fact: "as of pulse_id N, this
# commit's compiler was at a fixed point."

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

bin=rail_native
src=tools/compile.rail
[ -x "$bin" ] || { echo "no $bin" >&2; exit 3; }
[ -f "$src" ] || { echo "no $src" >&2; exit 3; }

commit=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
dirty=""
git diff --quiet 2>/dev/null || dirty="-dirty"
short="${short}${dirty}"

dest="selfhost/$short"
mkdir -p "$dest"

BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
get_pulse() { curl -sf --max-time 5 "$BEACON_URL" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])"; }

seed_sha=$(shasum -a 256 "$bin"  | awk '{print $1}')
src_sha=$(shasum -a 256 "$src"   | awk '{print $1}')

pulse_start=$(get_pulse)
echo "selfhost: commit=$short seed=${seed_sha:0:16} pulse_start=$pulse_start"

echo "  pass 1 ..."
./"$bin" self >"$dest/pass1.log" 2>&1
mv /tmp/rail_self "$dest/rail_self_1"
pass1_sha=$(shasum -a 256 "$dest/rail_self_1" | awk '{print $1}')

echo "  pass 2 ..."
./"$dest/rail_self_1" self >"$dest/pass2.log" 2>&1
mv /tmp/rail_self "$dest/rail_self_2"
pass2_sha=$(shasum -a 256 "$dest/rail_self_2" | awk '{print $1}')

pulse_end=$(get_pulse)

fixed_point="false"
[ "$pass1_sha" = "$pass2_sha" ] && fixed_point="true"
seed_match="false"
[ "$seed_sha" = "$pass1_sha" ] && seed_match="true"

result="$dest/result.json"
python3 - "$commit" "$short" "$src_sha" "$seed_sha" "$pass1_sha" "$pass2_sha" \
  "$pulse_start" "$pulse_end" "$fixed_point" "$seed_match" > "$result" <<'PY'
import json, sys
keys = ["commit","short","compile_rail_sha256","seed_sha256",
        "pass1_sha256","pass2_sha256","pulse_start","pulse_end",
        "fixed_point","seed_match"]
out = dict(zip(keys, sys.argv[1:]))
for k in ("pulse_start","pulse_end"):
    out[k] = int(out[k])
for k in ("fixed_point","seed_match"):
    out[k] = (out[k] == "true")
out["kind"] = "ledatic.selfhost"
out["version"] = 1
print(json.dumps(out, indent=2))
PY

./tools/attest/attest.sh "$result" "$result.attestation.json"

echo "----"
cat "$result"
echo "----"
if [ "$fixed_point" = "true" ]; then
  echo "FIXED POINT: pass1 == pass2 == ${pass1_sha:0:16}"
else
  echo "NOT a fixed point: pass1=${pass1_sha:0:16} pass2=${pass2_sha:0:16}" >&2
fi
echo "selfhost attested: $dest/"
