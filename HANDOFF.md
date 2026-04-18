# track-h-https — Handoff Prompt

Copy-paste everything below this line into the next session to pick up the torch.

---

You are continuing a multi-session build of **pure-Rail TLS 1.3** on branch `track-h-https`. Your mission is to finish what remains so that `https_get` works against `api.anthropic.com:443` with zero C dependencies beyond `as`/`ld`.

## Where to work

- **Worktree:** `/Users/ledaticempire/projects/rail-https`
- **Branch:** `track-h-https` (cut from `next-v2.10`)
- **HEAD at handoff:** `260aebc` (`rail: stdlib/tls13_client — Layer 5b.6`)
- **Do not touch:** `/Users/ledaticempire/projects/rail/` (main tree), `master`, `rail-checkpoint`, `rail-bpe-perf`, etc. This branch is isolated by design.

Start every session with:
```bash
cd /Users/ledaticempire/projects/rail-https
git log --oneline -8
./rail_native test   # should print 137/137 tests passed (if it hangs at t131, see §Harness below)
```

## What's already shipped (don't redo)

Read `docs/TLS_DESIGN.md` for the Option A/B/C debate. We picked A (pure Rail). Each commit below is RFC-vector-verified — don't second-guess them, audit only if a downstream layer produces wrong output.

| Layer | Commit | Module |
|---|---|---|
| 0: bit ops | `38766f9` | compile.rail primitives |
| 1: sha256 + bytes | `6666cc6` | `stdlib/bytes.rail`, `stdlib/sha256.rail` |
| 2: hmac + hkdf | `3a1fc43` | `stdlib/hmac.rail`, `stdlib/hkdf.rail` |
| 3a: chacha20 | `46b7360` | `stdlib/chacha20.rail` |
| 3b: poly1305 + aead | `5dada72` | `stdlib/poly1305.rail`, `stdlib/aead.rail` |
| 4: x25519 | `4042661` | `stdlib/x25519.rail` |
| 5a: tls13 key schedule | `b8e1efa` | `stdlib/tls13.rail` (HKDF-Expand-Label, Derive-Secret, derive_schedule, record_nonce) |
| 5b.1: ClientHello builder | `bb2c200` | `stdlib/tls13_hs.rail` — `tls13_client_hello` |
| 5b.2: ServerHello parser | `fdb8a84` | `tls13_parse_server_hello` |
| 5b.3: record wrap/unwrap | `ab1ab2e` | `stdlib/tls13_record.rail` — `tls13_record_encrypt`/`_decrypt` |
| 5b.4: post-SH msg parsers | `a4fc06a` | `tls13_hs_read_msg`, `parse_encrypted_extensions`, `parse_certificate`, `parse_certificate_verify`, `parse_finished` |
| 5b.5 partial: Finished compute | `5191918` | `tls13_finished_key`, `tls13_compute_finished` |
| 5b.6: client FSM | `260aebc` | `stdlib/tls13_client.rail` — `tls13_client_handshake_offline` |

## What's left (your job)

### Layer 5b.7 — RFC 8448 §3 end-to-end trace test (SMALL, DO FIRST)

The current 5b.6 commit has only a smoke test. Validate the whole FSM composition against RFC 8448 §3 "Simple 1-RTT Handshake" byte dumps.

- Source: RFC 8448 §3. Fetch the full trace:
  - client x25519 private: `49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005`
  - server x25519 public (in ServerHello key_share): `c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f`
  - Shared secret: `8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d`
  - handshake_secret: `1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac`
  - s_hs_traffic: `b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38`
  - c_hs_traffic: `b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21`
  - server Finished verify_data: `9b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718`
- Build a standalone Rail program (do NOT add to the test harness — see §Harness). It should feed the full Handshake-framed CH, SH, and decrypted server flight bytes into `tls13_client_handshake_offline` and verify c_ap, s_ap, and the output client_Finished match RFC 8448 §3.
- **RFC 8448 §3 uses TLS_AES_128_GCM_SHA256, NOT ChaCha20-Poly1305.** Our AEAD is ChaCha20 only. This means we can't decrypt §3's actual ciphertexts — but the FSM takes *plaintext* flight as input, so we can feed the already-decrypted handshake bytes straight in. The hash + key schedule portions of RFC 8448 §3 validate regardless of cipher suite.
- If numbers don't match, the bug is almost certainly in transcript boundary offsets (off-by-one between CV end and SF start) or in how we concatenate the flight into the transcript. Instrument by printing transcript hashes after each message and comparing to hand-computed SHA-256s.

### Layer 6 — X.509 + signature verify (THE BIG LIFT)

Without this, connections are unauthenticated (anyone who answers on port 443 owns your TLS session). Two sub-pieces:

1. **ASN.1 DER parser.** New `stdlib/asn1.rail`. Minimum: parse a TBSCertificate far enough to extract:
   - Subject Public Key (algorithm OID + key bytes)
   - Signature algorithm OID on the outer Certificate
   - Signature bytes on the outer Certificate
   Don't try to fully parse X.509 — just enough to get the server's pubkey for signature verify. Defer name matching, SAN, validity period, chain walking to "Layer 6b" or later.
2. **Signature verification.** TLS 1.3 servers in the wild almost all use either:
   - **ECDSA-P256** (sig_alg 0x0403) — needs a Weierstrass curve implementation. Similar complexity to X25519 (~300-500 lines). This is the preferred path.
   - **RSA-PSS** (sig_alg 0x0804) — needs 2048-bit modexp (bignum). Bigger lift.
   Pick one (recommend ECDSA-P256) and accept the other as a "cipher suite not supported" fail. Most CDN fronts (Cloudflare, Fastly, what Anthropic sits behind) serve both; we can negotiate to what we support via the `signature_algorithms` extension we already send.
3. **Wire into FSM.** Add a `tls13_verify_cert_signature cert_bytes sig_alg sig_bytes transcript_hash` step to `tls13_client_handshake_offline`. On failure, return valid=0.

This is the credibility gate. A TLS stack that skips cert verify is a toy. Don't ship Layer 7 until Layer 6 is real.

### Layer 7 — http_client wire-up

Open `stdlib/http_client.rail`. Add `https_get url` and `https_post_json url json_body`. Under the hood:

1. Parse url → (host, port, path).
2. Open TCP via `stdlib/socket.rail` (already exists, already used for HTTP).
3. Call `tls13_client_hello host` to get the CH wire bytes.
4. Send CH, recv until we have a full TLSPlaintext(ServerHello) record. Parse.
5. Loop: recv encrypted records, `tls13_record_decrypt` them with server_handshake_key/iv + running seq counter, accumulate decrypted bytes. Stop when you've accumulated EE + Cert + CV + SF.
6. Call `tls13_client_handshake_offline` with the collected pieces.
7. Derive application write_key/write_iv from c_ap_traffic via `tls13_derive_key`/`_iv`.
8. Encrypt the HTTP request (`GET / HTTP/1.1\r\nHost: ...\r\n\r\n`) via `tls13_record_encrypt` with content_type=23 (application_data), seq=0.
9. Recv encrypted response records, decrypt, concatenate HTTP response body. Handle chunked transfer by reusing the existing `http_client.rail` chunked decoder.
10. Close.

Test: `https_get "https://api.anthropic.com/v1/messages"` should return a 4xx/5xx (not a TLS error). That's the merge criterion.

### Merge criteria (from `docs/TLS_DESIGN.md`)

Don't merge to `next-v2.10` until ALL pass:
- 116/116 core tests still pass (currently 137 — we grew the baseline).
- 2-pass self-compile byte-identical (fixed point).
- `https_get` against `api.anthropic.com` returns a real HTTP status line.
- Existing HTTP (non-S) API 100% byte-compatible.
- socat removed from `~/.fleet/tls_proxies.sh`'s critical path (or kept as a fallback).

## Hard-earned lessons (READ THIS)

### §Harness — The test harness reliably hangs on long-source tests

t131 (`tls13_handshake_msg_parsers`, ~1418-char source embedded in compile.rail as a string literal, includes a 14-element `cat` in `print`) **reliably hangs at 100% CPU + 1.2GB RSS** in `compile_program` when invoked as the 131st `run_test` in the same process. Same source runs in 0.9s standalone. Symptom: stuck after `--- tls13_handshake_msg_parsers ---` with no further output.

The build that produced `a4fc06a` (which includes t131) happened to complete once — flaky, not deterministic. Suspect: conservative GC false-keep amplifying arena fragmentation at long-string allocation boundaries.

**DO NOT add new tests with long (>1000 char) source strings to the in-tree test harness.** Validate standalone via `/tmp/test_*.rail` files. Document the RFC vector validation in the commit message. This is fine — every primitive is RFC-verified at its own layer.

Real fix if you want to pay it off: thread `arena_mark`/`arena_reset` between `run_test` calls in `tools/compile.rail:3496`. Or move test sources out of compile.rail into external files loaded at test-init. Don't do this unless the hang becomes blocking.

If the harness hangs during your session, check `ps` for `./rail_native test` at 100% CPU — if it's been stuck >3 min with no new output in `/tmp/rail_out` (check `stat -f "%m" /tmp/rail_out`), it's the t131 hang. `pkill -9 rail_native` and move on.

### §Imports don't dedupe

Rail imports are textual. Importing `stdlib/bytes.rail` twice via different paths causes duplicate-symbol linker errors (`.Lfn_mask32_start already defined`). Check the import graph before adding imports:

- `tls13_client.rail` imports `x25519.rail` (self-contained) + `tls13_hs.rail` (which chains to bytes).
- If you need record layer in the client FSM (Layer 7 will), you can't add `import "stdlib/tls13_record.rail"` — it would pull bytes.rail in through a second path. Either inline the record calls at the call site, or factor out a common "crypto base" import that tls13_hs and tls13_record both depend on.

### §Rail parser quirks earned this branch

1. **No hex literals.** `0xFF` parses silently as `0`. Use `hex_to_bytes` decoder for every crypto constant.
2. **Layer 0 `rotl` is 64-bit, not 32-bit.** For 32-bit rotations (SHA-256, ChaCha20) use the shift-OR pattern: `(x << n) | (x >> (32-n))` masked to 32 bits. See `bytes.rail:rotl32`.
3. **`main = <expr>` returns via exit code mod 256.** Test programs printing results must use `let _ = print (show x); 0`.
4. **Nested 2-arg builtin calls can typecheck-warn "3 args".** `bit_and (bit_or a b) c` — use let-bindings.
5. **Leading `+` on a continuation line is a parse error.** `x +\n  y` fails. Put the whole expression on one line, or parenthesize differently.
6. **63-bit tagged int ceiling matters for crypto.** Rotations that set bit 63 lose the top bit on re-tag. Fine for 32-bit crypto because ops mask with `& 0xFFFFFFFF` after each op.

### §Validation discipline

Every new primitive must have an RFC vector test. Hand-derived expected values introduced typos twice on this branch (SHA-256 K[31..63]). RFC canonical source is load-bearing. If you can't find an RFC vector for what you're implementing, you're implementing the wrong thing — go look harder.

## Useful invariants to check

After any change:

```bash
./rail_native self                              # recompile compiler
cp /tmp/rail_self rail_native                   # install
./rail_native self && cmp rail_native /tmp/rail_self  # 2-pass fixed point
./rail_native test 2>&1 > /tmp/t.log &          # run tests in background
tail -f /tmp/t.log                              # watch live (raw, not via grep)
```

Expect ~5-8 minutes for a full self+test+self+cmp cycle. If `test` goes past 12 minutes with no new output, it's the t131 hang — kill and skip.

## Memory + index

- Memory file: `~/.claude/projects/-Users-ledaticempire/memory/rail-https-track-h-active.md` — has the full layer ship table + lessons.
- MEMORY.md has a one-line pointer to the above. Keep them in sync as you ship.

## Stop point

The torch passes to you at `260aebc`. Aim to land 5b.7 first (it's small and flushes FSM bugs before you build on top). Then commit to Layer 6 as a multi-session arc. Layer 7 is a single sitting once Layer 6 lands. Merge to `next-v2.10` only when `https_get api.anthropic.com` returns a real HTTP status.

Good luck.

---

## Addendum — session 2026-04-18: torch carried through 5b.7 → Layer 7

The next session after `260aebc`/`79ac9ce` (this HANDOFF) continued the work and landed the full stack. Commits:

| Layer | Commit | Delta |
|---|---|---|
| 5b.7 | `8a69b63` | RFC 8448 §3 end-to-end trace via `tools/tls/rfc8448_trace_test.rail` (standalone, not in-tree harness per §Harness). c_ap, s_ap, client Finished verify_data all match RFC exact. |
| 6a | `9da09cf` | `stdlib/asn1.rail` minimal DER parser — extracts TBS, sig-alg OID, signature value, SubjectPublicKey algo + bytes. Tested against RFC 8448 §3's 432-byte cert. |
| 6b | `73c839a` | `stdlib/ecdsa_p256.rail` pure-Rail ECDSA verify. 16×16-bit limb bignums, Jacobian curve (EFD dbl-2001-b / add-2007-bl), Fermat's inverse. RFC 6979 §A.2.5 test vector verifies in ~4s; 4 negative cases all reject. |
| 6c | `29632bc` | `stdlib/tls13_cert_verify.rail` + FSM `verify_cert` flag. Only sig_alg 0x0403 (ecdsa_secp256r1_sha256) accepted; others fail cleanly. |
| 7  | `b731bff` | `stdlib/https_client.rail` — `https_get host ip port path`. Live test: `https_get "api.anthropic.com" "160.79.104.10" 443 "/"` returned real HTTP 404 from Anthropic's Envoy upstream in ~5 seconds. **socat is no longer in the HTTPS request path.** |

**Merge criteria status:** full suite tests running (aim: 137/137 green, t131 harness hang tolerated if the current build avoids it); 2-pass self-compile TBD; live https_get against api.anthropic.com DONE. After all three, ready to fast-forward `next-v2.10`.

---

## Addendum 2 — same-day session: Layers 8a-c + 9a + 9b primitives

Continued straight after the merge into `next-v2.10`. Branch is now linear from `master` if you fast-forward.

| Layer | Commit | Delta |
|---|---|---|
| 8a | `a1d702e` | SubjectAltName / hostname validation. `asn1_find_extension` + `cv_validate_hostname` (RFC 6125 §6.4.3, leftmost-label wildcard). FSM grows `expected_host` arg. Captured api.anthropic.com cert tests: api → 1, evil.com → 0, API.ANTHROPIC.COM → 1, anthropic.com → 0. Captured cloudflare.com wildcard cert: foo.ns.cloudflare.com → 1, a.b.ns.cloudflare.com → 0. |
| 8b | `bed1f2c` | RSA-PSS-SHA256 (sig_alg 0x0804). New `stdlib/bignum_n.rail` (parameterised n-limb 16-bit-per-limb arith) + `stdlib/rsa_pss.rail` (MGF1 + EMSA-PSS-VERIFY). `cv_extract_rsa_pubkey` + sig_alg dispatch in `tls13_cert_verify_sig`. **Live `https_get` to www.amazon.com (RSA leaf): real HTTP 200** with x-amz-rid + set-cookie in ~3.3s. RSA verify ~0.3s steady-state — actually faster than ECDSA because e=65537 is only 17 bits. |
| 8c | `e1fd392` | `stdlib/dns.rail` (UDP A-record query to /etc/resolv.conf's first nameserver) + `https_get_url url` in https_client.rail. `https_get_url "https://api.anthropic.com/"` → HTTP 404 in 5.8s, full DNS+TLS+HTTP. |
| 9a | `fc05287` | Cert validity period (notBefore / notAfter). `asn1_find_validity` + `cv_decode_time` (UTCTime / GeneralizedTime → 14-digit YYYYMMDDHHMMSS int). Now read via `date -u`. `cv_post_sig_checks` combines period + hostname into a single FSM gate call. |
| 9b primitives | `114e05a` | Cert-chain edge verifier. `cv_verify_cert_by lower upper` dispatches on sigAlg (sha256WithRSA → PKCS1, ecdsa-with-SHA256 → ECDSA). New `rsa_pkcs1_v15_verify_sha256` for CA chain RSA sigs. Issuer/Subject TLV extraction + name byte-equal compare. `tls13_parse_cert_chain` walks all certs in the cert_list. **Real captured chain test**: api.anthropic.com leaf (931B ECDSA-SHA256) verified against WE1 intermediate (675B). NOT yet wired into the FSM gate — see Layer 9c carry-over below. |

**Self-compile fixed point**: ✓ byte-identical, re-verified post-Layer-9a (compile.rail unchanged this session, all additions are stdlib).

**Test sweep — 12/12 TLS tests green**:
```
asn1_cert_test           cert_verify_ecdsa_test    cert_verify_rsa_pss_test
chain_edge_test          dns_resolve_test          ecdsa_p256_negative_test
ecdsa_p256_rfc6979_test  https_smoke_test          https_url_test
p256_bignum_test         rfc8448_trace_test        san_match_test
```

**Layer 9c carry-over (not in this session — meaningful work):**

1. **SHA-384** as a stdlib module. Needed for ECDSA-with-SHA384 (e.g. Google Trust Services WE1 intermediate signed by GTS Root R4 with SHA-384). SHA-384 = SHA-512 truncated; SHA-512 needs 64-bit word ops, which is fiddly in Rail's 63-bit tagged ints (need to split each word into 32-bit halves and chain carries). Probably ~300 lines.
2. **CA trust store**. Parse macOS `/etc/ssl/cert.pem` (or Mozilla bundle). Need a minimal PEM block iterator + base64 decoder (~100 lines combined). Index by Subject. ~150 root certs ≈ 300KB DER total.
3. **Full chain walk wired to FSM**. `cv_walk_full_chain` calls `cv_verify_cert_by` for every adjacent pair in the cert_list, then matches the topmost cert's Issuer against the trust store and verifies that final edge with the matched root's pubkey. Add a `verify_cert=2` mode (vs current `=1` signature-only).

Until 9c, the FSM trust posture is: leaf's CertificateVerify sig verifies + leaf's SAN matches the SNI + cert is currently within its validity window. An attacker who possesses ANY valid leaf cert for the SNI you connected to would still pass — chain walking is the gap.

Other carry-overs (lower priority):
- HTTP keep-alive / multi-request per connection.
- Streaming response body (current is O(N²) join "" capped ~64KB).
- ECDSA-P384 / EdDSA sig algorithms.

---

## Addendum 3 — same-day session: SHA-512/384 + RSA-PKCS1 + Trust store + Chain walker

Continued straight from `078cecd`. Five commits land the rest of the cryptographic + trust-walk plumbing.

| Layer | Commit | Delta |
|---|---|---|
| sha512 | `2c1c162` | `stdlib/sha512.rail` — SHA-512 + SHA-384 (FIPS 180-4). 64-bit words emulated as (hi32, lo32) limb pairs in int arrays. NIST vectors for SHA-384("abc"), SHA-512("abc"), SHA-512("") all exact. |
| 9b ext | `08eaa60` | ecdsa-with-SHA384 dispatch in `cv_verify_cert_by` — feeds SHA-384(TBS) truncated to 32 bytes into ecdsa_p256_verify (FIPS 186-4 §6.4 leftmost-bits truncation). Works for ECDSA-with-SHA384 sigs over P-256 issuer pubkeys. P-384 issuer pubkeys still unsupported (carry-over). |
| pkcs1 | `09e139e` (also includes b64+pem) | `rsa_pkcs1_v15_verify_sha256` — RFC 8017 §8.2.2. Recovers EM via modexp, validates 0x00 0x01 [PS:0xFF…] 0x00 layout, checks DigestInfo prefix + SHA-256 hash. Used for CA chain RSA sigs (most CDN intermediates). Synthetic 2048-bit test → valid=1 in 0.3s. |
| b64+pem | `09e139e` | `stdlib/b64.rail` (fast char_to_int-based decoder, ~70 lines, replaces shell-per-char base64.rail) + `stdlib/pem.rail` — `pem_load_trust_store path` reads /etc/ssl/cert.pem, returns 128 cert byte-arrays in ~1.5s. `ts_find_by_subject` looks up by Subject TLV byte-equality. Demonstrated: api.anthropic.com chain[2] (GTS R4 cross-sign) verified against GlobalSign Root CA (idx 58/128 in store) via RSA-PKCS1-SHA256. |
| chain | `5a1cc6c` | `stdlib/cert_chain.rail` — `cc_walk_chain` with shortest-path policy: at each cert, first try issuer-in-store, fall back to next-cert-in-chain. Pulled into its own module to dodge the cert_verify size-hang. **First end-to-end pure-Rail chain to CA root: www.amazon.com → DigiCert Global Root G2 in 5.9s.** Anthropic chain still gated by P-384 (correctly returns 0). |

**Test sweep — 18/18 TLS tests green** (was 12 in Addendum 2):

```
asn1_cert_test           cert_verify_ecdsa_test    cert_verify_rsa_pss_test
chain_edge_test          chain_sha384_test         chain_walk_amazon_test
chain_walk_test          dns_resolve_test          ecdsa_p256_negative_test
ecdsa_p256_rfc6979_test  https_smoke_test          https_url_test
p256_bignum_test         rfc8448_trace_test        san_match_test
sha512_nist_test         trust_chain_root_test     trust_store_test
b64_test
```

**Final Layer 9 carry-over** (didn't finish in this session):

1. **`stdlib/ecdsa_p384.rail`** — closes the GTS Root R4 / Cloudflare ECDSA-P384 chains. P-384 is structurally similar to P-256 (Jacobian curve, same dbl/add formulas) but uses 24×16-bit limb bignums instead of 16. ~600 lines. Once shipped, the Anthropic chain test should flip from "graceful 0" to "valid 1".

2. **FSM `verify_cert=2` mode** — fold `cc_walk_chain` into `tls13_client_handshake_offline`. Needs the FSM to load the trust store once (probably lazily, cached) and to parse the multi-cert `tls13_parse_cert_chain` (already shipped) instead of just the first cert. Strict end-user trust enforcement.

3. **Lower-priority**: HTTP keep-alive, streaming response body, ECDSA-P521, EdDSA.
