#!/usr/bin/env bash
# attest_release.sh — physicify a Rail release
#
# A "release" here is the (compiler binary, compiler source, test stamp)
# triple at a given git revision.  Each gets its own attestation.json
# (sha256 ⊗ pulse_id ⊗ Ed25519); they're collected into releases/<tag>/
# alongside an index.json that names them and pins the git revision.
#
# Anyone with fleet0's pubkey can verify the release end-to-end:
#   $ tools/attest/verify.sh rail_native releases/v3.6.0/rail_native.attestation.json
#   $ tools/attest/verify.sh compile.rail releases/v3.6.0/compile.rail.attestation.json
#
# Usage: attest_release.sh [tag]  (default: git describe --tags HEAD)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tag=${1:-$(git describe --tags --always HEAD)}
commit=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)

bin=rail_native
src=tools/compile.rail

[ -x "$bin" ] || { echo "no $bin in repo root" >&2; exit 3; }
[ -f "$src" ] || { echo "no $src" >&2; exit 3; }

dest="releases/$tag"
mkdir -p "$dest"

bin_att="$dest/$(basename "$bin").attestation.json"
src_att="$dest/$(basename "$src").attestation.json"

echo "attest_release: tag=$tag commit=$short"
# Compile attest.rail once, then run the binary twice. Each
# `./rail_native run` recompile costs ~20s; doing it once saves ~half
# the wall time on the release-attest pipeline.
attest_bin=$(mktemp -t attest.XXXXXX)
trap 'rm -f "$attest_bin"' EXIT
./rail_native tools/attest/attest.rail >/dev/null
cp -p /tmp/rail_out "$attest_bin"
codesign --sign - --force "$attest_bin" >/dev/null 2>&1 || true
"$attest_bin" "$bin" "$bin_att"
"$attest_bin" "$src" "$src_att"

# Stage the bytes alongside their attestations so publish.sh ships
# both — attestation without the artifact is unverifiable.
cp "$bin" "$dest/$(basename "$bin")"
cp "$src" "$dest/$(basename "$src")"

bin_pulse=$(python3 -c "import json;print(json.load(open('$bin_att'))['witness']['pulse_id'])")
src_pulse=$(python3 -c "import json;print(json.load(open('$src_att'))['witness']['pulse_id'])")
bin_sha=$(python3 -c "import json;print(json.load(open('$bin_att'))['artifact']['sha256'])")
src_sha=$(python3 -c "import json;print(json.load(open('$src_att'))['artifact']['sha256'])")

python3 - "$tag" "$commit" "$short" "$bin" "$bin_sha" "$bin_pulse" \
  "$src" "$src_sha" "$src_pulse" > "$dest/index.json" <<'PY'
import json, sys, os
tag, commit, short, bin_, bin_sha, bin_pulse, src, src_sha, src_pulse = sys.argv[1:]
out = {
  "kind": "ledatic.release",
  "version": 1,
  "tag": tag,
  "git": {"commit": commit, "short": short},
  "artifacts": [
    {"path": bin_, "sha256": bin_sha, "pulse_id": int(bin_pulse),
     "attestation": f"{os.path.basename(bin_)}.attestation.json"},
    {"path": src, "sha256": src_sha, "pulse_id": int(src_pulse),
     "attestation": f"{os.path.basename(src)}.attestation.json"},
  ],
}
print(json.dumps(out, indent=2))
PY

echo "release attested: $dest/"
ls -la "$dest"
