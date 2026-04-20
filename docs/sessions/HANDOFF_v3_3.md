# Rail v3.3.0 Handoff — 2026-04-19

You are the Rail chief engineer. Copy this whole document into your
context and start from here.

## Orientation (5 min)

```bash
cd ~/projects/rail
git branch --show-current                # expect: next
git log --oneline -5                     # expect a0e8bba at HEAD, v3.2.0 tag at 1ef6faa
git tag -l | tail -3                     # expect v3.0.0, v3.1.0, v3.2.0
head -10 CHANGELOG.md                    # confirms "v3.2.0 — 2026-04-19 — Strict HTTPS by default + compiler quadratic fix"
./rail_native test 2>&1 | tail -3        # expect "137/137 tests passed" (~2 min)
ls stdlib/ | grep -E "https|tls13|pem|cert_chain"
```

Read the memory file `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-2-0-shipped.md`
for the full context of what the previous session shipped and why.

## Current state at start of v3.3.0

**Shipped + tagged locally on `next` branch (NOT pushed):**
- `v3.1.0` — streaming HTTPS response body (O(n²) → O(n) in `hc_recv_response`).
- `v3.2.0` — two compile.rail quadratic fixes (`edit_dist` was O(3^n) → bounded; `compile_funcs` was O(N²) non-tail → tail-recursive cons accumulator) + `stdlib/https_strict.rail` (full chain-to-root HTTPS default).
- Post-v3.2.0: `a0e8bba` — test 130 `tls13_record_roundtrip` now has the right transitive imports, suite is 137/137 green with no hang.

**Self-compile byte-identical fixed point confirmed** across two passes.

**Live in production** (verified by previous session):
- `https_get_url_strict "https://www.amazon.com/"` → HTTP 200 with RSA chain leaf → DigiCert G2 → DigiCert Global Root G2.
- All of v3.0.0's Anthropic + Slack paths still work (leaf-only trust via `https_client.rail`).

**Branch topology:**
- `next` @ `a0e8bba` — active
- `master` still at origin `98e85cc` — unchanged
- `rail-https` worktree has uncommitted site-generator edits from a separate line of work — **don't touch, don't mix**

## Rules earned the hard way on this track

1. **`&&` / `||` do NOT short-circuit in Rail.** Both sides always evaluate. Guard with nested `if/else`, not `a && b`. Previous session's keep-alive segfaulted on exactly this: `store != 0 && sess_chain_ok store fb == 0` evaluated `sess_chain_ok 0 fb` when store was int 0, `arr_get 0 0` → segfault.
2. **Imports don't dedupe.** `import "stdlib/X"` twice = `symbol '.Lfn_..._start' is already defined` link error. Check the transitive graph before adding an import.
3. **Mutual recursion doesn't TCO.** Only self-recursive tail calls get loop-optimized. A → B → A never gets TCO'd — each recursion grows the stack.
4. **`hc_bytes_to_str_loop` is the OLD O(n²) shim.** Use `hc_bytes_to_str buf n` for new code.
5. **Don't push without explicit approval.** `git push origin next:master v3.1.0 v3.2.0` is Reilly's call, not yours.

## v3.3.0 Queue — in priority order

### 1. HTTP keep-alive (task #4, HARD but highest value)

Previous session attempted this, reverted both files. Design notes in `~/.claude/projects/-Users-ledaticempire/memory/rail-v3-2-0-shipped.md` under "Keep-alive (DEFERRED — reverted)".

**Symptom**: session opens, TLS handshake completes, chain validates, but the first request's response never arrives. Reader blocks in `recv` (0% CPU, 532MB RSS stable). No data from server.

**Suspected causes**:
1. **Nagle buffering** — ClientFinished is ~50 bytes. If sent in `session_open` without a follow-up, the kernel may hold it. By the time `session_get` sends the request, something's off.
2. **NewSessionTicket seq collision** — After Finished, server sends NST on s_ap_seq 0,1. Readers after that expect the response at seq 2+.
3. **Response framing** — HTTP/1.1 chunked was stubbed out. Needs to parse `Transfer-Encoding: chunked` for real or keep-alive is useless on most servers.

**Approach**:
- Start by flushing CF + first request in the *same* `send()` call (v3.0.0 one-shot flow does this — see `https_get_app_phase`). Only keep the session open for the *second* round-trip onwards.
- Or: enable TCP_NODELAY on the socket right after `connect`. `setsockopt(fd, IPPROTO_TCP=6, TCP_NODELAY=1, &one, 4)`.
- Wire both Content-Length AND chunked parsing before shipping. Otherwise the module fails silently on CDN responses.

**Session handle shape** (from reverted attempt):
```
[0] fd          int
[1] c_ap_key    bytes
[2] c_ap_iv     bytes
[3] s_ap_key    bytes
[4] s_ap_iv     bytes
[5] c_seq       int (next write seq)
[6] s_seq       int (next read seq)
[7] valid       int (1 = open, 0 = closed/failed)
[8] err_msg     string
```

Target API: `https_session_open`, `https_session_open_strict`, `https_session_get`, `https_session_post`, `https_session_close`, plus `session_valid`, `session_fd`, `session_err`. Mirror the strict-shipped API.

### 2. ECDSA-P521 (task #5, easy)

Structural clone of `stdlib/ecdsa_p384.rail`. Swap constants, loop bound goes from 383 → 521, limb count from 24 → 33 (or 34 for safety). Wire sig_alg `0x0603` into `cv_verify_cert_by`. Add `stdlib/ecdsa_p521.rail` + a negative + RFC 6979 vector test.

**No live endpoint in our caller set uses P-521.** Ship for completeness. ~600 lines, 1 session.

### 3. Ed25519 (task #6, medium)

New curve form (twisted Edwards, not Jacobian Weierstrass). Share the x25519 field arithmetic (same `p = 2^255 - 19`) but different curve equation. RFC 8032 verify. ~400 lines, 1-2 sessions.

**No live endpoint in our caller set uses Ed25519 certs either.** Ship for completeness.

### 4. Push v3.1.0 + v3.2.0 + whatever-3.3-ships to public

When Reilly says go:
```bash
cd ~/projects/rail
git push origin next:master v3.1.0 v3.2.0
# plus the v3.3.0 tag when you reach it
```

Then update `ledatic.org` to reflect v3.2.0 (strict HTTPS banner). Note: `rail-https` worktree has uncommitted site-generator edits from a separate line of work that landed AFTER v3.0.0's site redesign — coordinate with Reilly before merging any site changes.

## Validation gates for any v3.3.0 commit

1. `./rail_native test` — must stay 137/137.
2. `./rail_native self` + `cp /tmp/rail_self rail_native` + `./rail_native self` + `cmp rail_native /tmp/rail_self` — byte-identical fixed point across two passes.
3. Live https_get_url_strict amazon.com must still return HTTP 200.
4. Anthropic + Slack clients must still work (don't break v3.0.0 paths).

## Context you need if you go deep on compile.rail

- Hot labels in `/tmp/rail_self.s`: `.Lfn_<name>_start` is function entry; `.Lfn_<name>_end` is return.
- macOS `sample <pid> 10 -f /tmp/x.sample` works beautifully for finding hot loops. Match the label to `/tmp/rail_self.s` via `awk '/^\.Lfn_/{fn=$0} /^\.LABEL:$/{print fn}'`.
- `edit_dist` now returns early via gap check + `bound` decrement. If you touch it, preserve the `bound=3` at call site invariant.
- `compile_funcs_loop` is the new tail-recursive driver. Don't reintroduce `cat [fasm, rest]` on unwind patterns elsewhere.

Good luck. Aim for keep-alive first — the user-facing value is huge (multi-turn Anthropic agents go from ~5s/turn to ~0.5s/turn). P-521 + Ed25519 are completeness items that can come any time.
