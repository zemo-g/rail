# Verifying this repository

You cloned this repo; here is how to check what it claims. Commands run
from the clone root, offline except steps marked as network cross-checks.

## 1. Anatomy of an attestation

Signed artifacts carry a sidecar JSON. The real one for the v5.1.0
compiler source, `releases/v5.1.0/compile.rail.attestation.json`, in full:

```json
{
  "kind": "ledatic.attestation",
  "version": 1,
  "artifact": {
    "name": "compile.rail",
    "size_bytes": 415800,
    "sha256": "88f70263b240301841c56c80cd67d9ead4fe6ee92ba1ccf20a716662b5cc4614"
  },
  "beacon": {
    "url": "https://ledatic.org/entropy/pulse",
    "pulse_id": 1004626,
    "value_hex": "6df9485939ffae2112a5bc35a0aa4343e1811de8f32c9a537c27157f09bec1eb",
    "timestamp_utc": "2026-05-15T15:47:53Z"
  },
  "witness": {"kind":"attestation","version":1,"digest_sha256":"88f70263b240301841c56c80cd67d9ead4fe6ee92ba1ccf20a716662b5cc4614","pulse_id":1004626,"value_hex":"6df9485939ffae2112a5bc35a0aa4343e1811de8f32c9a537c27157f09bec1eb","witnessed_at":1778860074,"sig":"DwaaJrDP+I+a+t2x0lJI5qJweb35IPO9kalAYYBqKuguQ+Q/Yxk5YBCwkJaJQYkfj0YV3kH0T+rpXIXgL/N9Aw==","pk_fp":"cac5f21a70564aeb","witness":"fleet0"},
  "created_at": 1778860075
}
```

- `artifact.name` / `size_bytes` / `sha256` -- the file the attestation
  binds. Re-derive the digest yourself: `shasum -a 256 <file>`.
- `beacon` -- the public entropy beacon consulted (`url`), the pulse
  current at signing time (`pulse_id`), its value, and its UTC time.
- `witness` -- the witness's own signed record: `digest_sha256`,
  `pulse_id`, `value_hex` restate what the signature covers;
  `witnessed_at` = unix seconds at signing; `sig` = 64-byte Ed25519
  signature, base64; `pk_fp` = the signing key (section 3); `witness` = signer.
- `created_at` -- unix seconds when the sidecar file was assembled.

## 2. The canonical signed message

The witness signs exactly one line of ASCII, rebuilt from the witness
object's fields:

```
attest|v1|<digest_sha256>|<pulse_id>|<value_hex>|<witnessed_at>
```

For the file above, the exact signed bytes are:

```
attest|v1|88f70263b240301841c56c80cd67d9ead4fe6ee92ba1ccf20a716662b5cc4614|1004626|6df9485939ffae2112a5bc35a0aa4343e1811de8f32c9a537c27157f09bec1eb|1778860074
```

`witness.sig` is the Ed25519 signature over those bytes. Both verifiers
rebuild the string from the JSON and check it; nothing else is signed.

## 3. The pinned public key

`releases/witness-fleet0/fleet0.pub.pem` is the fleet0 witness's Ed25519
public key, checked into this tree. Its fingerprint is the first 16 hex
characters of the SHA-256 of its DER encoding:

```
openssl pkey -in releases/witness-fleet0/fleet0.pub.pem -pubin -outform DER | shasum -a 256 | cut -c1-16
# cac5f21a70564aeb
```

Every attestation in this tree carries `pk_fp: cac5f21a70564aeb`.
Optional network cross-check: diff the in-tree key against the published
copy at https://ledatic.org/attest/fleet0.pub.pem.

## 4. Two verifiers, independently implemented

verify.rail -- pure Rail; SHA-256, base64, and Ed25519 are the stdlib's own:

```
git show v5.1.0:tools/compile.rail > /tmp/rail_verify_src
./rail_native run tools/attest/verify.rail /tmp/rail_verify_src \
    releases/v5.1.0/compile.rail.attestation.json \
    releases/witness-fleet0/fleet0.pub.pem
# ok  artifact=compile.rail  pulse_id=1004626  pk_fp=cac5f21a70564aeb
```

verify.sh -- bash + openssl + python3 + shasum:

```
git show v5.1.0:rail_native > /tmp/rail_verify_bin
bash tools/attest/verify.sh /tmp/rail_verify_bin \
    releases/v5.1.0/rail_native.attestation.json \
    releases/witness-fleet0/fleet0.pub.pem
# ok  artifact=rail_native  pulse_id=1004625  pk_fp=cac5f21a70564aeb
```

Usage as implemented: `verify.rail <input> <attestation> [pubkey.pem]`
(via `./rail_native run`) and `verify.sh <input_path> <attestation_path>
[pubkey_pem]`. Both default to the tree-pinned key (verify.sh resolves
`releases/witness-fleet0/fleet0.pub.pem` relative to its own repo root),
so a bare clone verifies fully offline; passing the key explicitly, as
above, makes that pinning visible. They share no code -- one is Rail
end to end, the other is openssl. Run both on the same artifact; they
must agree. Faking a PASS would require the same bug implemented twice
in unrelated stacks.

## 5. Matching records to commits

Release and selfhost records join on the git short hash:

```
releases/v5.1.0/index.json     ->  "git": { "short": "94afdd1" }
selfhost/94afdd1/result.json   ->  the 2-pass fixed-point record at that commit
```

`releases/<tag>/index.json` pins the tag's commit plus per-artifact
SHA-256 and pulse_id; `selfhost/<short>/result.json` records the
fixed-point run at that commit. Recover any tag's exact bytes with
`git show <tag>:<path>`.

Never compare HEAD's `./rail_native self` output to a tagged record.
HEAD moves past tags; the seed in your clone hash-matches no release
attestation, and that is not a failure. HEAD's receipt is the fixed
point itself -- run `self` twice, `cmp` the outputs -- not a signature.

## 6. seed_match: false, explained

`selfhost/94afdd1/result.json` (the v5.1.0 record) says
`"fixed_point": true, "seed_match": false`. Expected, not a defect.
`seed_match` compares the shipped seed binary's hash to the fixed point
the run converged on. The seed (gen0) carries runtime assembly baked at
an earlier build; its first self-compile (gen1) emits the runtime its
source currently describes; gen2 onward is byte-stable. So the fixed
point can trail the seed by one generation of runtime drift while
pass1 == pass2 holds. Other records (e.g. `selfhost/433f208`) show
`seed_match: true`. Walk-through: `notes/bootstrap_convergence_audit_2026-05-13.md`.

## 7. What an attestation proves -- and does not

Proves: witness fleet0 signed a statement that it saw these exact bytes
(their SHA-256) while public beacon pulse N was current. The pulse value
is unpredictable before emission, so the statement cannot predate pulse
N. If you trust the witness key, the bytes existed by pulse N.

Does not prove: that the code is correct or was reviewed; that the
crypto is constant-time or side-channel-safe; how the signing key was
generated or stored (no key ceremony is claimed); who authored the bytes.
An attestation is a timestamped existence claim with a named signer.

## 8. Trust roots, stated plainly

The pinned key's own attestation,
`releases/witness-fleet0/fleet0.pub.pem.attestation.json`, is signed by
the same key it attests. On its own that is circular; it proves only
internal consistency. The real trust roots are:

1. Your clone's git history -- the key, attestations, and records
   entered the tree at specific commits; tampering after the fact means
   rewriting published history.
2. Optionally, the live beacon at https://ledatic.org/entropy -- check
   that cited pulse_id/value_hex pairs match the public pulse chain.

If you distrust both, the attestations are just JSON. That is the honest
boundary of the system.

## 9. The fixed point and Ken Thompson

`./rail_native self` run twice produces byte-identical binaries, and the
suite passes before and after. That proves the build is deterministic
and that shipped source and binary agree. It does not prove the binary
is honest: a trusting-trust compiler (Thompson, 1984) could in principle
reproduce itself byte-identically while carrying behavior its source
never shows. The defense is not the fixed point alone -- it is the
readable 8,049-line compiler source (`tools/compile.rail`) plus
cross-backend emission (the same source emits Linux ARM64, x86_64, and
other targets through visibly different code paths) that a hidden
payload would have to survive. The fixed point closes the loop; the
readable source makes the loop inspectable.

## 10. builds/ and selfhost/ -- the ledgers

`builds/` -- 13 entries. Twelve are keyed by git short hash and record
an attested test-suite run (pass count, total, binary SHA-256, pulse
range, status); one (`studio-bench-20260429`) is an attested GPU
benchmark record. A `-dirty` suffix means the working tree was not clean
at build time -- attested dev builds, labeled as such. Failing entries
are kept deliberately: `builds/30f424a` records 133/137, status "fail",
and stays. A ledger that only records successes is marketing.

`selfhost/` -- 12 entries, one per recorded 2-pass fixed-point run:
seed/pass1/pass2 SHA-256, pulse range, `fixed_point`, `seed_match`.
Each `result.json` in both ledgers has its own attestation sidecar,
verifiable with either verifier from section 4. Nothing under these
directories is ever edited, moved, or re-signed: signatures bind bytes.

## 11. Receipt IDs

Claims in README.md carry stable anchors `[R01]`..`[Rnn]`. Three classes:

- RUN -- a command executed from the bare clone; the gate is an
  expected-output match.
- SIGNED -- an in-tree Ed25519 attestation verified offline against the
  pinned key (sections 1-4).
- GATED -- needs network, an API key, a Metal GPU, a cross toolchain,
  or hardware; rendered as SKIP with the reason, never omitted.

Tiers: `fast` (default, seconds per receipt), `core` (adds the test
suite and fixed-point cycles, tens of minutes), then `net` / `gpu` /
`key` / `hw`. `bash tools/prove/prove.sh` replays the receipts and
prints each command before running it -- convenience, never authority:
every receipt is a command you can run yourself. Timing numbers print
but never gate; on a non-ARM64-macOS host, native receipts SKIP, not FAIL.

## Appendix: optional CI workflow (not landed)

An owner decision, deliberately not shipped as a workflow file:
`.github/workflows/prove.yml` -- macOS runner, fast tier only
(`bash tools/prove/prove.sh`), in-repo commands only, no network, no
secrets; the existing `ci.yml` already runs the full suite on macOS.
Known risks: runner cost, and a public red X from the /tmp flake class
(orphan processes holding compiled outputs) reading as a substrate
failure when it is a harness one. Until accepted, this is the workflow.
