# HTTPS in Rail — Design Debate

**Branch:** `track-h-https`
**Worktree:** `/Users/ledaticempire/projects/rail-https`
**Parent:** `next-v2.10` (includes `char_from_int`, `stdlib/http_client.rail`, chunked-transfer decoder)
**Status:** SCAFFOLD — no implementation yet. Debate first, then build.

## The goal

Remove the `socat OPENSSL:...` dependency from `stdlib/http_client.rail` so
any Rail program can hit an HTTPS endpoint (Anthropic, Slack, Cloudflare,
GitHub, etc.) directly. Close the biggest credibility drag on a public
v2.23.0 release: "zero C dependencies *except you need brew install socat*."

## The constraint

Rail has NO bit-operation primitives. Confirmed 2026-04-17:

| Operation | Status |
|---|---|
| `xor`, `bit_xor` | not recognized |
| `bit_and`, `bit_or` | runtime segfault when invoked |
| `shr`, `shl`, `lshift`, `rshift` | not recognized |
| `rotr`, `rotl` | not recognized |

All modern crypto — SHA-256, HMAC, HKDF, AES, ChaCha20, X25519, Curve25519,
Poly1305 — is built on XOR, shift, rotate, and modular arithmetic. Without
these primitives, pure-Rail TLS is a non-starter.

This blocks Option A (pure Rail) until compile.rail is extended.

## The three paths

### Option A — Pure Rail (add compiler primitives, implement all crypto)

1. Extend `tools/compile.rail` with primitives: `bit_and`, `bit_or`, `bit_xor`, `shl`, `shr`, `rotr`, `rotl`. ARM64 codegen via `and`/`orr`/`eor`/`lsl`/`lsr`/`ror`. Register in `infer_is_heap_builtin` with type signature `(int, int) -> int`. ~80 lines.
2. Rebuild + 2-pass self-compile + verify fixed point + 116/116.
3. Implement SHA-256 in `stdlib/crypto/sha256.rail` — ~80 lines, testable against RFC 6234 vectors.
4. Implement HMAC-SHA256 (~20 lines), HKDF (~30 lines).
5. Implement X25519 (~100 lines of modular arithmetic over GF(2^255-19)).
6. Implement ChaCha20-Poly1305 AEAD (~80 lines ChaCha20 + ~60 lines Poly1305).
7. Implement SHA-384 (required by some servers; easier as a pattern-extension of SHA-256).
8. Implement TLS 1.3 record layer, handshake state machine, certificate parsing (X.509 subset), signature verification (RSA-PSS or ECDSA-P256).
9. Wire into `http_client.rail` as `https_get`/`https_post_json` etc.

**Pro:** zero C deps. Narrative intact. Re-usable primitives (SHA-256, HMAC) have independent value (auth tokens, content hashing, checksums).

**Con:** 5-10 days of focused work. Crypto in a dynamic language is SLOW — tens to hundreds of ms per request vs AES-NI hardware acceleration. Amateur crypto is a side-channel hazard (constant-time primitives matter; timing attacks are real). Unlikely to be secure in the professional sense on day one.

**Effort:** ~2 weeks to audited-enough for pet use, never production-grade.

### Option B — FFI to OS crypto via `stdlib/dlopen.rail`

Already in stdlib: `dlopen`/`dlsym`/`dlclose` bindings. Both macOS (Security.framework/SecureTransport or CommonCrypto) and Linux (libcrypto) ship audited TLS stacks.

1. Wrap `libssl.dylib` (macOS) or `libssl.so.3` (Linux) — `SSL_new`, `SSL_connect`, `SSL_read`, `SSL_write`, `SSL_CTX_new`, etc. via dlsym.
2. Build `stdlib/tls.rail` on top: `tls_connect ip port sni -> handle`, `tls_send handle bytes -> int`, `tls_recv handle -> string`, `tls_close handle`.
3. Wire into `http_client.rail`: new entry points `https_get`/`https_post_json` that tunnel through the TLS handle instead of raw `socket.rail` send/recv.

**Pro:** 2-3 days to working HTTPS. Production-quality crypto (AES-NI, ChaCha20 SIMD, audited for decades). Cross-platform.

**Con:** Reintroduces C deps (`libssl`/`libcrypto`). The "zero C dependencies" line in Rail's marketing needs a carve-out footnote: "core compiler + runtime + stdlib algorithms are C-free; crypto FFI to the OS-provided TLS stack."

**Honest framing:** Go, Python, Rust, Swift, Zig — *every* production language delegates TLS to either the OS or a vetted C library. Writing your own TLS stack is widely considered a red flag (exception: BoringSSL, s2n, rustls — all multi-year team efforts). Rail would look principled, not gimmicky, with this approach.

**Effort:** ~3 days.

### Option C — Minimal pure Rail, scoped to known targets only

Implement the absolute minimum TLS 1.3 subset needed to hit *only* Anthropic + Slack + Cloudflare endpoints. Hardcode cipher suite (TLS_CHACHA20_POLY1305_SHA256). Skip cert validation (allow `--insecure` mode). Only support X25519 key exchange.

Same primitives work needed as Option A (ChaCha20, Poly1305, SHA-256, HMAC, HKDF, X25519) — so the compiler changes from Option A are still required first. But skips SHA-384, RSA, ECDSA, cert parsing, AES.

**Pro:** Smaller code footprint than Option A. Still pure Rail.

**Con:** Same 5+ days of crypto primitive work. "Insecure dev-mode only" TLS is arguably worse than socat — at least socat delegates to an audited library.

**Effort:** ~1 week.

## My recommendation: **Option B**

Three reasons:

1. **Truthful framing.** Rail's "zero C deps" claim already has carve-outs — `as`/`ld` are C-compiled, libSystem is linked. Adding libssl is a known quantity; nothing secret. The narrative becomes "Rail's compiler, runtime, GC, and algorithms are C-free. Crypto uses the OS's audited TLS stack via FFI, the same way every modern language does it." That's a defensible position, not a retreat.

2. **Safety.** Rolling your own TLS in any language is historically where CVEs come from (Heartbleed, Debian OpenSSL weak keys, every Java TLS CVE). Writing TLS in a language without constant-time arithmetic primitives and without a crypto audit budget would be irresponsible for any request path touching real user data.

3. **Scope matches the session.** Option B ships a real HTTPS GET this weekend. Option A doesn't ship for two weeks and ships with a "do not use for anything real" asterisk. Option C is the worst of both.

## If user picks Option B: the day-1 slice

Today's deliverable target, scoped to 3-4 hours:

- `stdlib/tls.rail` — FFI declarations for `libssl` (SSL_new, SSL_CTX_new, SSL_set_fd, SSL_connect, SSL_read, SSL_write, SSL_free, SSL_CTX_free, SSL_library_init)
- `tls_connect_fd fd sni -> handle` — wraps an existing socket.rail fd, drives the handshake
- `tls_send handle s -> int` and `tls_recv handle max -> string`
- Basic test: `tls_connect` to `api.anthropic.com:443`, `SSL_write` a GET /, `SSL_read` the response. Print status line.

Day 2: wire into `http_client.rail` as `https_get` / `https_post_json`. Day 3: connection reuse, error handling, real integration tests.

## If user picks Option A: the day-1 slice

Today's deliverable target, scoped to 3-4 hours:

- Extend `tools/compile.rail` with `bit_and`, `bit_or`, `bit_xor`, `shl`, `shr`, `rotr`, `rotl` primitives. ARM64 codegen.
- Run 116/116 + 2-pass self-compile fixed point. Commit.
- Implement SHA-256 in `stdlib/crypto/sha256.rail`. Test against NIST vectors (empty string, "abc", long).
- Commit. Defer HMAC + everything else to later sessions.

## If user picks Option C: see Option A day-1 (same compiler work), then narrower crypto set in later sessions.

## Non-goals for this branch

- Cipher suite negotiation beyond the one picked (whichever option)
- TLS 1.2 fallback
- Certificate revocation (OCSP, CRL)
- Session resumption / 0-RTT
- ALPN for HTTP/2
- Server-side TLS (this is a client-only branch)

These are post-merge concerns, if ever.

## Merge criteria (the "when is it safe to merge" gate)

Before this branch merges to `next-v2.10`:

- 116/116 core tests still pass
- 2-pass self-compile byte-identical (fixed point)
- `https_get` against api.anthropic.com returns a real 200 or 405 (MLX-style test)
- `http_client.rail`'s existing HTTP (non-S) API is 100% byte-compatible
- socat dependency is removed from `~/.fleet/tls_proxies.sh`'s critical path (or kept as a fallback, not required)
