# Rail v3.6.0 Handoff — 2026-04-20

You are the Rail chief engineer. Previous session shipped v3.5.0
("hardened HTTPS client + http_server path guard") and rewrote the
commit narrative after user feedback. Public repo is clean.
Underneath, **the actual TLS posture is embarrassing**: the default
driver does not walk the certificate chain to a trust-store root,
and the `_strict` wrapper that does exist rejects one of the three
root authorities Rail's own live callers hit every day.

This session is about tearing the HTTPS facade down to the studs
and rebuilding it so the default call path is chain-rooted, the
live API clients actually verify, and every commonly-deployed root
(DigiCert, Let's Encrypt / ISRG, Google Trust Services) validates
cleanly. When you're done, the default should be the secure path
and the escape hatch should be loud about what it is.

Call this target **Greek perfection**: symmetrical naming, a single
blessed call path, no bolted-on "strict" variant pretending to be
optional. The current shape is Byzantine — two parallel API
surfaces, one secure, one not, and production accidentally picked
the wrong one.

## Orientation (5 min)

```bash
cd ~/projects/rail
git branch --show-current                # expect: next
git log --oneline -6                     # expect 1b153b4 at or near top
git tag -l | tail -6                     # expect v3.0.0..v3.5.0
./rail_native test 2>&1 | tail -3        # expect "137/137 tests passed"
ls stdlib/ | grep -E "https|cert|tls13|x25519|ecdsa"
```

Read before writing code:

- `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-5-0-shipped.md`
  — what landed + the sanitization note (don't re-leak narrative).
- `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-3-0-shipped.md`
  — keep-alive + P-521 context, plus the rule-set about concurrent
  sessions and amazon.com flakiness.
- `HANDOFF_v3_4.md` in this directory — orientation template +
  invariants.

## What's broken (the "destroy" targets)

### 1. Two parallel API surfaces, default is insecure

`stdlib/https_client.rail` exports `https_get_url` / `https_post_url`
that perform TLS 1.3 + CertificateVerify-against-leaf-pubkey. That
check passes for any valid leaf — including a self-signed cert
with the right SAN. These are the functions `stdlib/anthropic_client.rail`
and `stdlib/slack_client.rail` still call in production.

`stdlib/https_strict.rail` exports `https_get_url_strict` /
`https_post_url_strict` that additionally call
`cc_walk_chain` in `stdlib/cert_chain.rail`, walking from leaf up
through each intermediate until it terminates in a cert whose
pubkey matches a root in `/etc/ssl/cert.pem`.

**Greek-perfection plan:** collapse this into one API.

- `https_get_url` and `https_post_url` ARE the strict/chain-walking
  drivers. No `_strict` suffix — secure is the default, always.
- The leaf-only path gets an explicit escape-hatch name
  (`https_get_url_unsafe_noverify` or similar) loud enough that no
  reviewer or LLM misses it.
- Any test that genuinely wants to exercise the FSM without a
  trust store uses the unsafe variant explicitly.
- `anthropic_client.rail` + `slack_client.rail` keep calling
  `https_post_url` — and now they chain-walk.

### 2. `cc_walk_chain` rejects Google Trust Services R4

Last session's verification:

- `https_get_url_strict "https://www.amazon.com/"` → HTTP 200 ✓
  (DigiCert Global Root G2 chain).
- `https_get_url_strict "https://api.anthropic.com/"` → status=0 ✗
  (GTS R4 chain).

The likely root cause (educated guess, not confirmed) is
cross-signed-root handling. `api.anthropic.com` presents:

```
depth=0  CN=api.anthropic.com               signed-by WE1
depth=1  GTS CA 1P5 (WE1 variant)           signed-by GTS Root R4
depth=2  GTS Root R4                        signed-by GlobalSign Root CA
```

GTS R4 appears as a self-signed root in `/etc/ssl/cert.pem`. But
the server also presents a cross-signed variant of GTS R4 whose
`issuer` field names GlobalSign. A walker that keeps chasing
`issuer`-by-name without checking "is this SPKI in the trust store
already?" will walk past GTS R4, look for GlobalSign's cert in the
presented chain (not there), and fail.

The fix is SPKI-keyed trust-store termination: at every link in
the walk, hash the candidate cert's SPKI and check it against every
trust-store root's SPKI. If match, accept and stop — regardless of
who the candidate's own `issuer` field names.

**Test this hypothesis first.** Write a standalone probe:

```rail
import "stdlib/https_strict.rail"
import "stdlib/cert_chain.rail"

main =
  let store = pem_load_trust_store "/etc/ssl/cert.pem"
  -- ...open TCP to api.anthropic.com:443, do partial handshake to
  -- get the server's Cert message, extract the chain, call
  -- cc_walk_chain, print which step fails.
```

If SPKI match against root is the missing piece, the diff is ~30
lines inside `cc_walk_chain`. If it's something else (sig-alg
mismatch on the intermediate, parsing issue on a specific OID,
validity-window off-by-one), the probe tells you where.

### 3. The rename (the "destroy" of the old API surface)

Once the walker validates all three roots (DigiCert, LE/ISRG, GTS),
rename:

| Old name                  | New name                         |
|---------------------------|----------------------------------|
| `https_get` (non-strict)  | `https_get_unsafe_noverify`      |
| `https_post` (non-strict) | `https_post_unsafe_noverify`     |
| `https_get_url`           | **becomes the chain-walking default** (absorb current `_strict` body) |
| `https_post_url`          | **becomes the chain-walking default** |
| `https_get_url_strict`    | alias for `https_get_url`, then deprecate in v3.7.0 |
| `https_post_url_strict`   | alias for `https_post_url`, then deprecate in v3.7.0 |
| `https_get_strict`        | becomes `https_get` (by host/ip) |
| `https_post_strict`       | becomes `https_post` (by host/ip) |

Keep the `_strict` aliases for one release to ease any external
consumers' migration, then rip in v3.7.0.

Callers to update:

- `stdlib/anthropic_client.rail`: already calls `https_post_url` —
  no edit needed after the semantics swap. It just starts being
  safe.
- `stdlib/slack_client.rail`: same.
- Any test file that relied on leaf-only verification has to
  switch to the `_unsafe_noverify` variant. Grep for
  `https_get_url\|https_post_url` in `tools/tls/` and see which
  tests need the opt-out.

## Code map

```
stdlib/
├── https_client.rail       ← current non-strict drivers (rename target)
├── https_strict.rail       ← current strict wrapper (absorb into https_client)
├── https_session.rail      ← keep-alive, also calls non-strict internals
├── tls13_client.rail       ← TLS 1.3 FSM; reads CertificateVerify
├── tls13_cert_verify.rail  ← sig-alg dispatch (P-256 / P-384 / P-521 / RSA-PSS / RSA-PKCS1 / Ed25519)
├── tls13_record.rail       ← record-layer encrypt/decrypt
├── cert_chain.rail         ← cc_walk_chain — THIS IS THE SUSPECT
├── cert_p384.rail
├── cert_p521.rail
├── asn1.rail               ← OIDs, DER parsing
├── pem.rail                ← trust-store loader (pem_load_trust_store)
├── ed25519.rail            ← shipped v3.4.0, not wired into cert_verify yet
└── x25519.rail             ← ECDHE key exchange
```

Callers of the HTTPS API:

```
stdlib/anthropic_client.rail
stdlib/slack_client.rail
tools/tls/https_strict_test.rail
tools/tls/https_url_test.rail
tools/tls/https_session_test.rail
```

## Debugging plan

### Step 1: reproduce the GTS rejection and find the failure step (30 min)

Write `tools/tls/cc_walk_probe.rail`:

1. Open TCP to `api.anthropic.com:443`.
2. Do a ClientHello + read ServerHello + decrypt to get the
   server's `Certificate` handshake message.
3. Parse the chain (`tls13_parse_cert_chain`).
4. Call `cc_walk_chain` with `/etc/ssl/cert.pem` as the store.
5. If it returns 0, walk MANUALLY through each intermediate
   printing: cert subject, cert issuer, SPKI SHA-256, whether
   that SPKI exists in the trust store, whether the parent sig
   verifies against the next cert in the chain.
6. The step that fails is your bug.

### Step 2: fix the walker

Most likely fix sketch:

```rail
cc_walk_chain store certs lens count =
  cc_walk_iter store certs lens count 0

cc_walk_iter store certs lens count i =
  if i >= count then 0          -- ran off the end without hitting a trusted root
  else
    let cert = arr_get certs i
    let cert_len = arr_get lens i
    let spki = cc_extract_spki cert cert_len
    if pem_store_has_spki store spki then 1   -- ✓ terminated at a trusted root
    else if i + 1 >= count then 0             -- no issuer in chain and not trusted
    else
      let parent = arr_get certs (i + 1)
      let parent_len = arr_get lens (i + 1)
      if cc_verify_sig cert cert_len parent parent_len == 0 then 0
      else cc_walk_iter store certs lens count (i + 1)
```

The critical additions vs the probable current code: (a) SPKI
trust-store check at EVERY link, not just the topmost one, and (b)
termination by SPKI match, not by `issuer`-field traversal.

Requires a new helper in `pem.rail`:

```rail
pem_store_has_spki store spki_hash =
  -- Iterate roots in store, SHA-256 each root's SPKI, compare
  -- against spki_hash. Return 1 on match.
```

And extract SPKI hash from a cert:

```rail
cc_extract_spki cert_bytes cert_len =
  -- Parse the X.509 TBSCertificate, pull the subjectPublicKeyInfo
  -- SEQUENCE, SHA-256 its DER bytes, return 32-byte hash.
```

### Step 3: make strict the default

Once the walker validates GTS, DigiCert, and LE/ISRG chains:

1. Move the bodies of `https_get_url_strict` / `https_post_url_strict`
   into `https_get_url` / `https_post_url` in `https_client.rail`.
2. Rename the old bodies to `https_get_url_unsafe_noverify` /
   `https_post_url_unsafe_noverify`.
3. Delete or alias `https_get_url_strict` / `https_post_url_strict`.
4. Update `tools/tls/*` tests to point at the right variant.
5. `./rail_native test` — 137/137 must stay.
6. Live-test: `anthropic_chat` + `slack_post_text` both return
   non-zero-status responses with real content. Those were
   previously MITM-able. After this session they validate the
   chain.

### Step 4: ship v3.6.0

Commit, tag, push. **Do not** re-introduce the vulnerability
narrative into the public CHANGELOG or commit message. Neutral
language only:

> v3.6.0 — 2026-04-20 — Unified HTTPS client
>
> Chain-walked verification is now the default for
> `https_get_url` / `https_post_url`. The previous leaf-only path
> is retained as `https_*_unsafe_noverify` for tests that need it.
> Chain walker now terminates at SPKI trust-store match, enabling
> cross-signed root chains (GTS R4, etc.).

## Rules earned the hard way — READ BEFORE WRITING CODE

1. **`&&` / `||` do NOT short-circuit in Rail.** Guard with
   `if/else`, not boolean chains.

2. **Imports don't dedupe.** `import "stdlib/X"` twice = symbol
   redefinition link error. Trace the transitive graph.

3. **Mutual recursion doesn't TCO.** Self-recursive tail calls
   do. Any loop longer than ~100 iterations must be flattened to
   a single self-recursive driver (see `ed_sm_iter` pattern in
   `stdlib/ed25519.rail`).

4. **Top-level `name = int` constants in the TLS/socket import
   chain have caused unexplained runtime regressions.** If you
   add one and suddenly `https_strict_test` segfaults, try
   inlining the magic number at the call site.

5. **Rail's `shell()` does not inherit env vars or PATH.** Config
   must be file-based.

6. **Transient HTTPS test failures against amazon.com, anthropic,
   slack are often external.** `curl -I` the target before
   assuming your code regressed. Amazon served 503s for ~15
   minutes mid-v3.3.0 session and ~15 minutes mid-v3.5.0 session.

7. **Concurrent-session `/tmp/rail_out` collisions.** Another
   Claude session running `./rail_native run tools/train/...`
   will corrupt your test runs. Check `ps aux | grep rail_native`
   before `./rail_native test`. `./rail_native self` uses
   `/tmp/rail_self` and is collision-safe.

8. **Don't push without explicit approval.** The branch is
   `next`, target is `zemo-g/rail:master`. User has approved
   pushes explicitly every release so far.

9. **Explicit `git add <files>`, never `git add -A`.** Working
   tree usually has un-owned changes from other sessions
   (training runs, site tweaks, checkpoint snapshots).

10. **Don't narrate external criticism in commit messages,
    CHANGELOG entries, tag annotations, or README.** The user
    explicitly force-pushed v3.5.0's tag once in this history to
    scrub a too-apologetic narrative. Neutral technical language
    only on the public surface. Internal memory notes can be
    detailed.

11. **Force-push a public tag only if the user explicitly asks.**
    v3.5.0's tag was rewritten ~7 minutes after its first push.
    Do not make this a habit.

12. **A re-tag followed by a force-push is NOT a way to sneak
    fixes in without a version bump.** If the behavior changes
    meaningfully after initial push, cut a new version.

## Validation gates for v3.6.0

Every commit on this track must hold:

1. `./rail_native test` — 137/137 (or +N if you add tests, no
   regression).
2. `./rail_native self` 2-pass → `cmp` empty → byte-identical
   fixed point.
3. `https_get_url "https://www.amazon.com/"` → status 200,
   chain-validated against DigiCert root.
4. `https_get_url "https://api.anthropic.com/"` → status 200 or
   expected 404, chain-validated against GTS root.
5. `https_get_url "https://slack.com/"` → status 200 or expected
   404, chain-validated against LE/ISRG root.
6. **New regression test**: mint a local self-signed cert with
   CN=`api.anthropic.com`, serve it on 127.0.0.1:8443 via
   openssl s_server, attempt `https_get_url` at the faked
   endpoint, verify we get status=0 with a "chain does not
   validate" error. This is the MITM check. If this passes
   (i.e., the client ACCEPTS the fake cert), you've regressed.
7. `anthropic_chat` end-to-end with a real prompt → HTTP 200 +
   non-empty response content. Confirms strict-by-default
   doesn't break the dogfood loop.
8. `slack_post_text` end-to-end posting "rail v3.6.0 live" to
   `brockbro2` DM → `ok:true`. Same confirmation for Slack.

If gate #6 cannot be set up this session, at minimum manually
construct a test harness where you modify `/etc/ssl/cert.pem` to
REMOVE GTS R4 and confirm that `https_get_url "https://api.anthropic.com/"`
then fails. Prove the trust store is actually being enforced.

## What "Greek perfection" looks like when it's done

- One blessed API: `https_get_url` and `https_post_url`. Always
  safe. No suffix.
- The insecure escape hatch exists under a name that looks
  dangerous (`_unsafe_noverify`). It is used nowhere in
  production code — only in tests that explicitly need it.
- `anthropic_client.rail` and `slack_client.rail` are unchanged
  from v3.5.0: they still call `https_post_url`. But the
  semantics underneath shifted.
- Chain walker terminates at SPKI trust-store match, not at
  issuer-name traversal. Cross-signed roots Just Work.
- `/etc/ssl/cert.pem` is the trust store. SPKI hashes of its
  roots are computed once at load and cached in the store
  structure (if not already).
- All three major root authorities (DigiCert, ISRG/LE, GTS) have
  a verified live-endpoint test on the suite.
- A MITM-with-self-signed-cert regression test is in the suite
  and passes (correctly rejects the fake).
- Public CHANGELOG + commit message for v3.6.0 describe what the
  new API is, not what was broken before.
- Non-strict drivers inside `https_client.rail` still exist
  under their renamed `_unsafe_noverify` form for test use, with
  a docblock that names the specific threat model they do not
  defend against.

## What to leave alone

- Keep-alive (`https_session.rail`) — rebuild the strict path
  through it so `https_session_open` validates, but don't
  restructure the keep-alive state machine.
- Ed25519 (`stdlib/ed25519.rail`) — still unwired into
  `cert_verify`, still correct. Wire-in is a follow-up.
- Metal backend, training paths, plasma demos, site generator —
  not this track.

## Pitfalls to dodge

- **Don't silently loosen chain validation to pass a test.** If
  the walker rejects a chain that _should_ validate, fix the
  walker. If it accepts one that shouldn't, the regression test
  will catch you — don't ship.
- **Don't confuse trust-store SPKI with trust-store subject
  name.** Names can collide; public keys don't.
- **Don't assume `/etc/ssl/cert.pem` is PEM-formatted on every
  OS.** On macOS it is (via homebrew openssl or system OpenSSL
  compat shim). On Linux Pi, it may be a symlink to
  `/etc/ssl/certs/ca-certificates.crt`. Verify before assuming.
- **Don't cache-bust yourself on test runs.** If you change
  `pem_load_trust_store`, run `./rail_native self` first to
  rebuild, then `./rail_native test`, then the live HTTPS probes.

## The opening move when you start

```bash
cd ~/projects/rail
cat HANDOFF_v3_6.md                                   # this file
less ~/.claude/projects/-Users-ledaticempire/memory/rail-v3-5-0-shipped.md
./rail_native test 2>&1 | tail -3                     # confirm 137/137 baseline
./rail_native run tools/tls/https_strict_test.rail    # confirm amazon still 200
```

Then write the GTS probe (`tools/tls/cc_walk_probe.rail`).
Everything downstream is implied by what the probe tells you.

Good luck. The public surface is clean. The code underneath is
Greek marble waiting to be carved.
