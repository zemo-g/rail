#!/usr/bin/env bash
# backfill_releases.sh — physicify historical tags
#
# For each tag with a checked-in rail_native + tools/compile.rail, extract
# the blobs (no checkout — leaves working tree untouched), stage them
# under releases/<tag>/, attest, and write the release index.json.
#
# Usage: backfill_releases.sh [tag1 tag2 ...]
#        backfill_releases.sh             (defaults to ALL tags with bin+src)

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "$#" -ge 1 ]; then
  tags=("$@")
else
  tags=()
  while IFS= read -r t; do
    git cat-file -e "${t}:rail_native"        2>/dev/null || continue
    git cat-file -e "${t}:tools/compile.rail" 2>/dev/null || continue
    tags+=("$t")
  done < <(git tag | sort -V)
fi

echo "backfill: ${#tags[@]} candidate tags"

for tag in "${tags[@]}"; do
  dest="releases/$tag"
  if [ -f "$dest/index.json" ]; then
    echo "  skip $tag (already attested)"
    continue
  fi
  mkdir -p "$dest"
  echo "  $tag"

  # Extract artifacts at the tag — working tree untouched.
  git show "${tag}:rail_native"        > "$dest/rail_native"
  git show "${tag}:tools/compile.rail" > "$dest/compile.rail"
  chmod +x "$dest/rail_native"

  bin_att="$dest/rail_native.attestation.json"
  src_att="$dest/compile.rail.attestation.json"
  ./rail_native run tools/attest/attest.rail "$dest/rail_native"  "$bin_att"
  ./rail_native run tools/attest/attest.rail "$dest/compile.rail" "$src_att"

  bin_pulse=$(python3 -c "import json;print(json.load(open('$bin_att'))['witness']['pulse_id'])")
  src_pulse=$(python3 -c "import json;print(json.load(open('$src_att'))['witness']['pulse_id'])")
  bin_sha=$(python3 -c "import json;print(json.load(open('$bin_att'))['artifact']['sha256'])")
  src_sha=$(python3 -c "import json;print(json.load(open('$src_att'))['artifact']['sha256'])")
  commit=$(git rev-list -n1 "$tag")
  short=$(git rev-parse --short "$commit")

  python3 - "$tag" "$commit" "$short" "$bin_sha" "$bin_pulse" "$src_sha" "$src_pulse" \
    > "$dest/index.json" <<'PY'
import json, sys
tag, commit, short, bin_sha, bin_pulse, src_sha, src_pulse = sys.argv[1:]
out = {
  "kind": "ledatic.release",
  "version": 1,
  "tag": tag,
  "git": {"commit": commit, "short": short},
  "backfilled": True,
  "artifacts": [
    {"path": "rail_native",        "sha256": bin_sha, "pulse_id": int(bin_pulse),
     "attestation": "rail_native.attestation.json"},
    {"path": "tools/compile.rail", "sha256": src_sha, "pulse_id": int(src_pulse),
     "attestation": "compile.rail.attestation.json"},
  ],
}
print(json.dumps(out, indent=2))
PY
done

echo "done."
