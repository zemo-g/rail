# Rail v3.4.0 Handoff — 2026-04-19

You are the Rail chief engineer. Rail is a self-hosting language with
zero C dependencies, four backends, and as of v3.3.0 (2026-04-19,
local-only) a working HTTPS keep-alive session layer + ECDSA-P521
curve + chain-walk wiring.

## Orientation (5 min)

```bash
cd ~/projects/rail
git branch --show-current                # expect: next
git log --oneline -5                     # expect HEAD = 4b2acbc (P-521), 8652df5 (keep-alive)
git tag -l | tail -6                     # expect v3.0.0 v3.1.0 v3.2.0 v3.3.0
./rail_native test 2>&1 | tail -3        # expect "137/137 tests passed" (~2-3 min)
ls stdlib/ | grep -E "ecdsa|ed25519|cert_p|https_session"
```

Then read `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-3-0-shipped.md`
for the post-mortem of what landed last session + concrete rules
earned the hard way.

## Current state at start of v3.4.0

**Shipped + tagged locally on `next` branch (NOT pushed):**
- `v3.1.0` @ `ab13216` — streaming HTTPS response body.
- `v3.2.0` @ `1ef6faa` — compile.rail quadratic fixes + strict HTTPS.
- `v3.3.0` @ `4b2acbc` — keep-alive sessions + ECDSA-P521.

**Live in production** (verified at end of session):
- `https_get_url_strict "https://www.amazon.com/"` → HTTP 200 chain-walked.
- `https_session_open_strict` + 3 GETs on one fd → 200/200/200.
- `ecdsa_p521_verify` test vector → valid=1, bad_hash=0, bad_s=0.
- `./rail_native self` 2-pass → byte-identical fixed point.

**Parked WIP, NOT imported anywhere:**
- `stdlib/ed25519.rail` — verify skeleton (~400 lines). Module
  header documents the two concrete fixes needed before wire-up.

**Uncommitted in working tree from other sessions** (do NOT touch):
- `rail_native` binary rebuild + `tools/compile.rail` path tweaks +
  `tools/train/lm_transformer.rail` train-loop tweaks — another
  session's in-flight work.
- `rail_diag.rail`, `tools/plasma/live_3d.html`, `rail_native.new`,
  `training/rail_native/checkpoints_apr15_backup/` — not mine to move.

**Branch topology:**
- `next` @ `4b2acbc` — active.
- `master` still at origin `98e85cc` — unchanged.
- Interloper commits may land on `next` from concurrent sessions
  (saw `0c96b57 site: Atom feed from CHANGELOG.md` mid-session); just
  stack cleanly on top, no rebase needed when there's no conflict.

## Rules earned the hard way — READ BEFORE WRITING CODE

1. **`&&` / `||` do NOT short-circuit in Rail.** Both sides always
   evaluate. Guard with nested `if/else`, not `a && b`.

2. **Imports don't dedupe.** `import "stdlib/X"` twice = `symbol ...
   is already defined` link error. Check the transitive graph before
   adding any import.

3. **Mutual recursion doesn't TCO.** Only self-recursive tail calls
   get loop-optimized. A → B → A grows the stack per call. For 256+
   iteration loops this WILL blow up. Flatten to a single
   self-recursive driver.

4. **Top-level `name = int_lit` in stdlib socket/TLS chain can
   produce runtime regressions** in unrelated code paths (observed
   with `ipproto_tcp = 6` / `tcp_nodelay = 1` in `stdlib/socket.rail`
   segfaulting `https_strict_test`). Root cause not fully
   understood. **Workaround: inline magic numbers at the single call
   site with a short comment explaining the gotcha.**

5. **Rail's `shell()` does NOT inherit parent env vars or PATH.**
   Config must be file-based.

6. **Transient segfaults in live TLS tests — check the endpoint
   first.** Amazon served intermittent 503s mid-session; both strict
   and keep-alive tests segfaulted for ~15 minutes then spontaneously
   recovered. Run `curl -I` against the target before assuming a code
   regression.

7. **Concurrent-session `/tmp/rail_out` collision.** Another Claude
   session running `./rail_native run tools/train/...` will silently
   corrupt your test runs (saw 136/137 instead of 137/137). Run rail
   tests sequentially, never in parallel with other rail work. Check
   `ps aux | grep rail_native` before `./rail_native test`.
   `./rail_native self` uses `/tmp/rail_self` and is collision-safe.

8. **Don't push without explicit approval.** `git push origin
   next:master v3.1.0 v3.2.0 v3.3.0` is Reilly's call, not yours.

9. **Explicit `git add <files>` — never `git add -A`.** Working tree
   almost always has un-owned changes from other sessions.

## v3.4.0 Queue — in priority order

### 1. Ed25519 — finish the WIP (HIGH VALUE, MEDIUM DIFFICULTY)

`stdlib/ed25519.rail` exists with the full verify skeleton: point
decompression, extended-coords unified add, scalar mult, verify main
function. Built on top of `x25519.rail` field arithmetic (same
p = 2^255 - 19). But it won't work as-is. Two concrete fixes:

**Fix A — stale `ed_d_bytes` constant.** The canonical d in LE hex
is `a3785913ca4deb75abd841414d0a700098e879777940c78c73fe6f2bee6c0352`
(verified via Python:
`(-121665 * pow(121666, -1, 2**255-19)) % (2**255-19)` → LE 32
bytes). The current `ed_d_bytes` body has a typo and uses a
`|> ed_strip_ws` band-aid — rip both out, just return the clean
`hex_to_bytes "..."`.

**Fix B — flatten mutual recursion.** `ed_pow_bytes_loop`/`_next`
and `ed_sm_loop`/`_next` are A→B→A mutual-recursive drivers. Rail
does NOT TCO these (see rule 3). Scalar mult for the 512-bit SHA-512
hash runs 512 iterations — mutual recursion will blow the stack.
Rewrite each pair as a single self-tail-recursive driver using
`bit_total = byte_idx * 8 + bit_idx` as the decremented counter:

```rail
ed_sm out k n_bytes P =
  let _ = ed_point_identity out
  let bit_total = n_bytes * 8 - 1
  ed_sm_iter out k P bit_total

ed_sm_iter out k P bit_total =
  if bit_total < 0 then out
  else
    let byte_idx = shr bit_total 3
    let bit_idx = bit_and bit_total 7
    ... (double, conditional add, tail-call with bit_total - 1)
```

**Test:** add `tools/tls/ed25519_test.rail` with RFC 8032 TEST 1:
- pub = `d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a`
- msg = empty
- sig = `e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b`
- expect: valid = 1

Add a flipped-byte negative control. If it verifies clean, wire into
`tls13_cert_verify.rail` for sig_alg `0x0807` = 2055 (ed25519) + add
`cert_ed25519.rail` chain-edge driver. No live endpoint in our caller
set uses Ed25519 certs; ships for completeness.

### 2. Push to public (Reilly's call only)

When Reilly says go:
```bash
cd ~/projects/rail
git push origin next:master v3.1.0 v3.2.0 v3.3.0
# and v3.4.0 if Ed25519 ships first
```

### 3. ledatic.org update for v3.3.0

The public site currently reflects v3.2.0 (strict HTTPS). v3.3.0
adds keep-alive sessions + P-521 — worth a feature banner update.
The `rail-https` worktree has uncommitted site-generator edits from
a separate line of work; coordinate with Reilly before merging any
site changes.

### 4. Optional: explicit chunked-response smoke

`tools/tls/https_session_test.rail` exercises the chunked path
implicitly (amazon.com uses `Transfer-Encoding: chunked` per curl
check). An explicit JSON roundtrip against an Anthropic or Slack
endpoint would be a stronger signal that the chunked de-framing is
actually correct. Currently we're returning the chunked-encoded body
as-is (not de-chunked) — that works for "did we get any response"
but would break JSON parsers expecting clean payload.

## Validation gates for any v3.4.0 commit

1. `./rail_native test` — must stay 137/137.
2. `./rail_native self` → `cp /tmp/rail_self rail_native` → re-run
   → `cmp` → byte-identical 2-pass fixed point.
3. `https_get_url_strict "https://www.amazon.com/"` → HTTP 200.
4. `https_session_open_strict` + 2+ GETs → all 200 on same fd.
5. `ecdsa_p521_verify` test → valid=1, bad_hash=0, bad_s=0.
6. If Ed25519 ships: RFC 8032 TEST 1 verifies clean.

## Context files worth reading

- `CHANGELOG.md` — top entry is v3.3.0; structure of the track.
- `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-3-0-shipped.md` —
  full session post-mortem.
- `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-2-0-shipped.md` —
  prior session context, reference for quadratic fixes.
- `stdlib/ecdsa_p384.rail` — structural template for any new curve
  module (P-521 is the exact clone pattern; Ed25519 is different,
  Edwards form, but the testing + wire-up pattern is the same).

Good luck. Aim for Ed25519 first — the user-facing value is
completeness (EdDSA is the most-deployed modern TLS sig outside
ECDSA-P256). Push to public is a one-line operation once Reilly
greenlights.
