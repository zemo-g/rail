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

# Stage the bytes alongside their attestations so publish.rail ships
# both — attestation without the artifact is unverifiable.
cp "$bin" "$dest/$(basename "$bin")"
cp "$src" "$dest/$(basename "$src")"

# Build index.json via release_index.rail (compile once, exec direct so
# child stdout isn't captured by the `run` subcommand).
idx_bin=$(mktemp -t release_index.XXXXXX)
trap 'rm -f "$attest_bin" "$idx_bin"' EXIT
./rail_native tools/attest/release_index.rail >/dev/null
cp -p /tmp/rail_out "$idx_bin"
codesign --sign - --force "$idx_bin" >/dev/null 2>&1 || true
"$idx_bin" "$tag" "$commit" "$short" "$bin" "$bin_att" "$src" "$src_att" > "$dest/index.json"

echo "release attested: $dest/"
ls -la "$dest"
