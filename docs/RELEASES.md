# Releases — operational runbook

Every Rail release is signed against a live entropy beacon by the
fleet0 witness. This page is the recipe — read it before cutting a
release, and especially before cutting one from a fresh worktree.

## What a release looks like

For a tag `vX.Y.Z`:

```
releases/vX.Y.Z/
  rail_native                          ← the ARM64 substrate binary
  rail_native.attestation.json         ← Ed25519 sig + pulse_id + sha
  tools/compile.rail → compile.rail    ← the source
  compile.rail.attestation.json
  index.json                           ← pins git commit + per-artifact pulse_id
```

Five files. They're all published to `https://ledatic.org/releases/vX.Y.Z/<file>`
via Cloudflare KV.

## Cutting a release

Assumes you're on the tag commit (or the working tree matches it byte-for-byte
for both `rail_native` and `tools/compile.rail`). Set `SIGNER_IP` to your
fleet0 witness's address first — it's a private fleet host, not committed here:

```bash
export SIGNER_IP=<your-fleet0-witness-ip>

# 1. Pi witness must be live
curl -sf --max-time 5 "http://$SIGNER_IP:9102/health"
# → {"ok": true, "name": "fleet0"}

# 2. Attest + emit index
bash tools/attest/attest_release.sh vX.Y.Z

# 3. Verify locally before shipping anything
bash tools/attest/verify.sh releases/vX.Y.Z/rail_native        releases/vX.Y.Z/rail_native.attestation.json
bash tools/attest/verify.sh releases/vX.Y.Z/compile.rail       releases/vX.Y.Z/compile.rail.attestation.json
# → ok  artifact=<n>  pulse_id=<N>  pk_fp=cac5f21a70564aeb  (×2)

# 4. Publish to ledatic.org
bash tools/attest/publish.sh releases/vX.Y.Z
# → 5 ok, 0 fail

# 5. Commit + push (gotcha #1: verify the attestation JSON was picked up)
git add releases/vX.Y.Z
git status releases/vX.Y.Z    # confirm rail_native.attestation.json is staged
git commit -m "attest: vX.Y.Z release artifacts + attestations"
git push origin master
```

## Gotchas earned over multiple releases

### #1 — `.gitignore` swallows `rail_native.attestation.json`

`.gitignore` has `rail_native.*` (intended to ignore backup binaries like
`rail_native.bak`). The glob also matches `rail_native.attestation.json`.

**Symptom:** `git add releases/vX.Y.Z` silently drops the rail_native
attestation. Existing tracked attestations are grandfathered, so prior
releases look fine — but the new release ships without its rail_native
attestation file in-tree.

**Fixed in v5.0.1:** `.gitignore` now whitelists
`!releases/**/rail_native.attestation.json`, so a plain
`git add releases/vX.Y.Z` picks the file up. Still worth a
`git status releases/vX.Y.Z` after adding to confirm the attestation
JSON is staged — if it isn't, the whitelist has regressed.

### #2 — `~/.ledatic/witness/signer_url` format

The file contains a full URL (`http://$SIGNER_IP:9102/sign`).
`attest.rail` expects a bare IP — `hc_connect_tcp` can't parse a URL as
IPv4 dotted-quad — and silently fails when the file holds a URL.

**Workaround:** `SIGNER_IP=<your-fleet0-witness-ip> bash tools/attest/attest_release.sh vX.Y.Z`.

**Real fix (TODO):** either standardize the file to bare IP, or teach
attest.rail to parse URLs.

### #3 — `runtime/llm.o` is git-ignored

`.gitignore` excludes `runtime/`. The compile.rail linker step needs
`runtime/llm.o` (the LLM trampoline object); it must exist on disk for
ld to succeed.

**Symptom:** fresh worktree off master gives `ld: file cannot be open()ed,
errno=2 path=runtime/llm.o`.

**Workaround:** seed from any working worktree or clone:
```bash
mkdir -p runtime && cp <existing-worktree>/runtime/llm.o runtime/
```

(The .o is built from `tools/llm_runtime.c` somewhere — find and
canonicalize that build step in a follow-up.)

### #4 — A local process may own `/tmp/rail_out`

A long-running local process may be executing a binary previously
compiled to `/tmp/rail_out` (the default output path). Any subsequent
compile that also writes to `/tmp/rail_out` works (macOS unlinks +
creates), but you **cannot** `./rail_native run /tmp/rail_out` against
the existing binary — that re-execs whatever daemon owns it. Compile
with a distinct output path when smoke-testing.

### #5 — `./rail_native run` captures stdout

The `run` subcommand captures child stdout in memory and only flushes at
the end. For tests that should stream output, compile separately and
exec the binary directly:
```bash
./rail_native my_test.rail   # compiles to /tmp/rail_out
/tmp/rail_out                 # streams normally
```

### #6 — Annotated tags vs commit hashes

`git rev-parse vX.Y.Z` returns the **tag object** hash (annotated tag),
not the commit. Use `git rev-parse vX.Y.Z^{commit}` to dereference.
`attest_release.sh` uses `git describe --tags HEAD` which gives the
tag name, fine for the directory; but if you build `index.json` by
hand make sure `git.commit` is the commit hash, not the tag object.

## Backfilling missed releases

If a tag was pushed without going through this flow:

```bash
TAG=vX.Y.Z
mkdir -p releases/$TAG
git show "$TAG":rail_native        > releases/$TAG/rail_native
chmod +x releases/$TAG/rail_native
git show "$TAG":tools/compile.rail > releases/$TAG/compile.rail
SIGNER_IP=<your-fleet0-witness-ip> ./rail_native run tools/attest/attest.rail \
  releases/$TAG/rail_native      releases/$TAG/rail_native.attestation.json
SIGNER_IP=<your-fleet0-witness-ip> ./rail_native run tools/attest/attest.rail \
  releases/$TAG/compile.rail     releases/$TAG/compile.rail.attestation.json
COMMIT=$(git rev-parse "$TAG^{commit}")
SHORT=$(git rev-parse --short "$TAG^{commit}")
./rail_native run tools/attest/release_index.rail "$TAG" "$COMMIT" "$SHORT" \
  rail_native releases/$TAG/rail_native.attestation.json \
  tools/compile.rail releases/$TAG/compile.rail.attestation.json \
  > releases/$TAG/index.json
```

The pulse_id will be from "now" — the backfilled attestation proves
*the bytes existed before pulse N*, which for the original release is
trivially true.

Backfilled in May 2026: v4.0.0 (pulse 987510), v4.0.1 (pulse 987510),
v4.1.0 (pulse 987511).
