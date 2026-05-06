<h1 align="center">Rail</h1>

<p align="center">
  <em>A self-hosting systems language that speaks TLS alone.</em><br>
  <sub>Zero C dependencies. GC in ARM64 assembly. HTTPS in pure Rail.</sub>
</p>

<p align="center">
  <a href="#releases"><img src="https://img.shields.io/badge/v3.10.0-Path%20B%20%C2%B7%20rail--native%20Pi%20signer-ff5500?style=for-the-badge" alt="v3.10.0"></a>
</p>

<p align="center">
  <a href="https://ledatic.org/builds/latest/index.json"><img src="https://img.shields.io/endpoint?url=https://ledatic.org/attest/badge/builds.json" alt="build · attested live"></a>
  <a href="https://ledatic.org/selfhost/latest/index.json"><img src="https://img.shields.io/endpoint?url=https://ledatic.org/attest/badge/selfhost.json" alt="self-host · attested live"></a>
  <a href="#why-rail"><img src="https://img.shields.io/badge/HTTPS-pure%20Rail-ff5500" alt="pure-Rail HTTPS"></a>
  <a href="#how-it-works"><img src="https://img.shields.io/badge/GC-ARM64%20assembly-purple" alt="GC in ARM64 asm"></a>
  <a href="#why-rail"><img src="https://img.shields.io/badge/C%20dependencies-0-brightgreen" alt="0 C dependencies"></a>
  <a href="#releases"><img src="https://img.shields.io/badge/backends-3-orange" alt="3 backends"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSL%201.1-green" alt="BSL 1.1"></a>
</p>

<p align="center">
  <sub>Build + self-host badges are <em>live</em>: each refresh re-resolves
  <code>/&lt;kind&gt;/latest</code> against current production via the Pi-hosted
  Ed25519 witness chain. A red badge means production drift, attested.</sub>
</p>

<p align="center">
  <b><a href="#quick-start">Quick start</a></b> ·
  <b><a href="#what-rail-does">What Rail does</a></b> ·
  <b><a href="#why-rail">Why Rail</a></b> ·
  <b><a href="CHANGELOG.md">Changelog</a></b> ·
  <b><a href="https://github.com/zemo-g/rail/releases">Releases</a></b>
</p>

---

Rail compiles itself. The compiler — 6,039 lines of Rail — produces a 925 KB ARM64 binary that compiles the compiler again and reaches byte-identical fixed point. There is no C in the runtime, no libc in the binary. The garbage collector is ARM64 assembly. As of v3.0.0, the TLS 1.3 client is Rail too: `import "stdlib/anthropic_client.rail"` and your program talks HTTPS to `api.anthropic.com` with zero OpenSSL, zero curl, zero socat. Each tagged release is signed by the project's Pi-hosted Ed25519 witness key against a live entropy beacon — see [§ Provenance](#provenance) below.

```
./rail_native self && cp /tmp/rail_self ./rail_native
./rail_native self && cmp rail_native /tmp/rail_self  # byte-identical
./rail_native test                                     # 137/137
```

## Quick start

```bash
git clone https://github.com/zemo-g/rail
cd rail
./rail_native run examples/hello.rail
```

Apple Silicon (ARM64 macOS) is the primary target; Linux ARM64 and Linux x86_64 are also supported, with a WASM output for browser embedding.

```bash
./rail_native <file.rail>        # compile to /tmp/rail_out
./rail_native run <file.rail>    # compile + execute
./rail_native test               # run the 137-test suite
./rail_native self               # self-compile, fixed point
./rail_native x86 <file.rail>    # cross-compile to Linux x86_64
./rail_native linux <file.rail>  # cross-compile to Linux ARM64
```

## What Rail does

### 1. Compiles itself, byte-identical

```
./rail_native self                    -- 6,039 lines of Rail →
                                      --   a 925 KB ARM64 binary
cp /tmp/rail_self ./rail_native
./rail_native self                    -- that binary compiles the
                                      --   compiler again
cmp rail_native /tmp/rail_self        -- and the output is identical
```

The GC, allocator, and runtime support are ARM64 assembly embedded in the compiler itself. No `gcc`, no `libc`, no linker scripts — just `as` and `ld`.

### 2. Speaks HTTPS, natively ✨ *new in v3.0.0*

```rail
import "stdlib/anthropic_client.rail"

main =
  let (status, reply) = anthropic_chat
                          "claude-haiku-4-5-20251001"
                          "Reply with exactly: hello from pure rail"
                          40
                          "/Users/me/.fleet/anthropic_key"
  let _ = print reply
  0

-- → "hello from pure rail"
-- → 6.9 s wall. Full TLS 1.3: x25519 ECDHE, ECDSA-P256 cert verify,
--   SAN hostname match, validity period, ChaCha20-Poly1305 record
--   layer. Zero OpenSSL, zero curl, zero socat.
```

The full X.509 chain for `api.anthropic.com` (leaf → WE1 intermediate → GTS Root R4) validates end-to-end to the macOS `/etc/ssl/cert.pem` trust store — ECDSA-P256-SHA256 at the leaf, ECDSA-P384-SHA384 at the root edge, all verified in Rail.

### 3. Trains its own AI, verified by the compiler

```rail
-- The self-training loop, in one flow:
--   LLM generates Rail → rail_native compiles (the oracle) →
--   passes harvested → training data feeds next round
```

The compiler is the fitness function. Programs that compile become training data; programs that don't are the gradient. The runners (orchestrator + dataset pipeline + experiment configs) live in the private `Ledatic-Empire/rail-training` repo; this repo ships the library primitives those runners depend on — `stdlib/anthropic_client.rail`, `stdlib/mlx_client.rail`, `stdlib/checkpoint.rail`, `stdlib/autograd.rail`, `stdlib/transformer.rail`, `stdlib/optim.rail`, `stdlib/bpe.rail`, `stdlib/tokenizer.rail` — plus `tools/train/self_train.rail` as the canonical 25-level curriculum.

## Why Rail

- **Zero C transitive dependency.** The seed binary needs only `as` + `ld` + the kernel. No glibc. No OpenSSL. No runtime C at all — the GC is 300 lines of ARM64 assembly inside the compiler.
- **Byte-identical self-compile.** `./rail_native self` produces output identical to the binary that produced it. The compiler's own source is the regression suite.
- **The compiler is the source of truth.** Training loops, tests, site generation, HTTPS clients — they all get compiled by the same binary you cloned. If it compiles, it runs.
- **Production surface is narrow and honest.** Rail v3.0.0 ships the crypto it uses (ChaCha20-Poly1305, x25519, SHA-256/384/512, ECDSA-P256/P384, RSA-PSS/PKCS1) and nothing more. Every primitive is NIST- or RFC-vector-validated.
- **Three backends travel with the language.** macOS ARM64, Linux ARM64 (Pi Zero 2 W), and Linux x86_64 — the same compiler cross-compiles to all of them. A WASM output target is also bundled for browser embedding.

## The language

```rail
-- Functions, pattern matching, ADTs
type Expr = | Num x | Add a b | Mul a b

eval e = match e
  | Num x   -> x
  | Add a b -> eval a + eval b
  | Mul a b -> eval a * eval b

main = let _ = print (show (eval (Add (Num 3) (Mul (Num 4) (Num 5))))) in 0
-- → 23
```

```rail
-- Higher-order, pipes, real I/O
gt3 x = x > 3
inc x = x + 1

main =
  let _ = print (show (fold (\a b -> a + b) 0 (range 101)))  -- 5050
  let _ = print (show (length (filter gt3 [1,2,3,4,5,6])))   -- 3
  let _ = write_file "/tmp/out.txt" "hello"
  let _ = print (read_file "/tmp/out.txt")                   -- hello
  0
```

```rail
-- Native floats (unboxed IEEE 754 in ARM64 d-registers)
-- Effect handlers (setjmp/longjmp non-local error recovery)
-- WASM output (closures + ADTs + pattern matching in the browser)
-- Metal GPU IR (JIT-compiled GPU kernels from Rail AST)
```

## How it works

| Component | Implementation | Detail |
|---|---|---|
| **Lexer + parser** | Rail | Tokenizer + recursive-descent AST builder, ~900 lines |
| **Type checker** | Rail | Forward inference, exhaustiveness warnings |
| **Codegen** | Rail | Walks AST, emits ARM64 / x86_64 / WASM directly |
| **Allocator** | ARM64 assembly | 512 MB bump arena + free list + malloc fallback |
| **GC** | ARM64 assembly | Conservative mark-sweep. Scans stack frames, traces tagged objects, sweeps into free list. |
| **Tagged pointers** | Inline | Integers: `(v << 1) \| 1`. Heap: raw pointer. Tag bit 0 distinguishes. |
| **Runtime float** | d-registers | Unboxed IEEE 754. `fadd`/`fmul` direct, no heap boxing. ~10× vs boxed. |

Tail-recursive loops match C `-O2` (5 instructions per iteration). The full architecture is documented in [`CHANGELOG.md`](CHANGELOG.md) — see v2.0.0 for the compiler/runtime; v3.0.0 for the TLS stack.

## Releases

### v3.10.0 — 2026-05-02 — *Path B: Rail-native Pi signer + Linux backend complete*

The attestation pipeline is now Rail-native end-to-end *including* the Pi-side HTTP signer.  The hot path no longer touches Python at all.  `tools/attest/pi_sign_server.rail` is an HTTP signer on `fleet0:9102` that replaces the ~110 LOC Python `pi_sign_server.py` with a 118 KB ELF — same wire format (`X-Sign-Token` + JSON `{digest, pulse_id, value_hex}`), same backing shell signer, end-to-end verified.  Linux ARM64 cross-compile gains real implementations for three previously-stub'd primitives in `linux_libc.s`: `_atof` (real number parser; the previous stub returned `0.0` for every Rail float literal cross-compiled to Linux), `_snprintf` `%.15g` formatter (real digit-extract; the previous stub wrote literal `"0"` for any float), and `_rail_print_float` (Linux-ABI clone of the Mac stub).  137/137 green; byte-identical self-bootstrap verified.

### v3.9.0 — 2026-05-02 — *Ed25519 sign + Rail-native attest pipeline*

The attestation pipeline that v3.8.0 introduced is now Rail-native end-to-end.  `stdlib/ed25519_scalar.rail` implements `sc_reduce` (64-byte mod L) and `sc_muladd` ((a·b + c) mod L) in pure Rail; 8/8 vectors pass including SHA-512('') mod L matching the Python oracle byte-for-byte.  `stdlib/ed25519_sign.rail` implements full RFC 8032 §5.1.6 — RFC §A.4 vector 1 byte-identical for both pk and sig + round-trip verify=1, PASS on first compile.  `tools/attest/attest.rail` is the Rail-native attestation orchestrator (zero shell-out on the request path); `tools/attest/pi_sign_server.py` + `com.ledatic.attest_sign.service` replace the per-attest SSH dance with an HTTP `/sign` endpoint on `fleet0:9102` over Tailscale — release-attest wall time 49 s → 27 s.  Linux ARM64 cross-compile fixed: `./rail_native linux foo.rail` produces working ELF; hello/fact/fold run on Pi.  Plasma beacon RSS leak fixed: 5 GB / 31 GB swap → 21 MB / 90 s.  137/137 green; byte-identical self-bootstrap verified.

### v3.8.0 — 2026-05-01 — *Releases physicified*

Every tagged release, every `./rail_native test` pass, and every 2-pass byte-identical self-compile is now signed against a live entropy beacon `pulse_id` by the project's Pi-hosted `fleet0` Ed25519 witness key (`pk_fp = cac5f21a70564aeb`).  Verify any release in five lines — see [§ Provenance](#provenance).  Backfilled coverage: v2.0.0 → v3.7.0.  Live mission control at [ledatic.org/system](https://ledatic.org/system).  CI also restored: built `tools/metal/libtensor_gpu.dylib` before the test suite, ending 14 days of red on tensor link errors.

### v3.7.0 — 2026-04-30 — *Float-TCO root fix, mixed-precision inference, parallel rerank*

Float-TCO root fix re-instates the `body_has_float` guard in `all_params_int` (`tools/compile.rail:1992`), closing a 17-day silent wrong-result bug that reinterpreted float bits as ints in tail-recursive register-ABI calls (RMSNorm CPU path, AdamW weight decay, LayerNorm CPU backward).  Runtime-mmap arena via `RAIL_ARENA_MB` (default 1 GB, scales to 4 GB+).  17-counter `alloc_stats_snapshot` builtin + `RAIL_ARENA_TRACE`.  Parser accepts multi-line compound expressions.  `./rail_native quick` runs 15 critical tests in ~5 s.  New Rail-native fp32-acts × fp16-weights × fp32-accum GPU matmul (`stdlib/tensor.rail:matmul_mixed`) — 2× tighter than all-fp16.  `parallel_rerank.sh` validated 7.1× wall-clock at N=8.  137/137 green; byte-identical self-bootstrap verified.

### v3.6.1 — 2026-04-27 — *Compiler hardening*

Two codegen + parser fixes; both gated by 2-pass byte-identical self-bootstrap.  Undefined identifiers fail at link with a named symbol (`_RAIL_UNDEFINED_IDENT_<name>`) instead of a silent runtime SIGSEGV.  Parser accepts multi-line compound expressions inside unclosed brackets.  `returns_float` now tracks let-bound floats through V (variable) AST nodes, fixing two latent miscompile bugs.  137/137 green.

### v3.0.0 — 2026-04-18 — *Rail speaks TLS*

A complete pure-Rail TLS 1.3 stack + X.509 chain validation + HTTPS client. The `~/.fleet/tls_proxies.sh` socat daemons are no longer on any critical path.

**Live on release day, in production:**

```
anthropic_chat "claude-haiku-4-5-20251001" "Reply with exactly: hello from pure rail"
  → HTTP 200, "hello from pure rail"       (6.9 s, pure Rail → Anthropic)

slack_post_text "<channel-id>" "v3.0.0 smoke: pure-Rail TLS"
  → ok=true, HTTP 200                      (1.0 s, pure Rail → Slack)

https_get_url "https://www.amazon.com/"
  → HTTP 200 with set-cookie, x-amz-rid    (4.0 s, RSA chain validated
                                            to DigiCert Global Root G2)
```

~3,800 lines of new pure-Rail crypto + TLS across 16 new stdlib modules. Every primitive NIST- or RFC-vector validated. 22 pure-Rail TLS tests, all green. Self-compile 2-pass byte-identical preserved.

| Layer | Modules |
|---|---|
| Hash / MAC | `sha256`, `sha512` (SHA-384/512), `hmac`, `hkdf` |
| Symmetric | `chacha20`, `poly1305`, `aead` (ChaCha20-Poly1305) |
| Public key | `x25519`, `ecdsa_p256`, `ecdsa_p384`, `rsa_pss` (PSS + PKCS1) |
| Bignum | `bignum_n` — parameterised n-limb arithmetic |
| X.509 / PKI | `asn1`, `b64`, `pem` (128 roots from `/etc/ssl/cert.pem`) |
| TLS 1.3 | `tls13`, `tls13_hs`, `tls13_record`, `tls13_cert_verify`, `tls13_client`, `cert_chain`, `cert_p384` |
| Application | `https_client`, `dns`, `anthropic_client`, `slack_client` |

Full release notes: [**CHANGELOG.md**](CHANGELOG.md).

### v2.0.0 — 2026-04-06 — *Rail becomes a self-improving system*

Native floats in ARM64 d-registers, effect handlers via setjmp/longjmp, GC in assembly, four backends (macOS ARM64 / Linux ARM64 / Linux x86_64 / WASM), and three independent training lineages — all driven by the same compiler as the binary fitness function. 121 commits. 92/92 tests. [**Full details in CHANGELOG.md →**](CHANGELOG.md).

### History

| Version | Date | Headline |
|---|---|---|
| **v3.0.0** | 2026-04-18 | Rail speaks TLS — pure-Rail HTTPS, chain validation to macOS trust store |
| **v2.23.0** | 2026-04-17 | Pure-Rail HTTP/1.1 client + `char_from_int` |
| **v2.0.0** | 2026-04-06 | Self-improving flywheel, native floats, effect handlers, GC in asm |
| **v1.5** | 2026-03-25 | C-matching performance, hyperagent, DNA training |
| **v1.4** | 2026-03-22 | GC in assembly, nested lambdas, exhaustiveness |
| **v1.3** | 2026-03-21 | MCP server, 32-layer LoRA, open source |
| **v1.1** | 2026-03-20 | Metal GPU, WASM, x86_64, fibers, flywheel |
| **v1.0** | 2026-03-17 | Self-hosting. Rust deleted. 67 tests. |

## Provenance

Every tagged release binds `sha256(rail_native)` to a live entropy
beacon `pulse_id` and an Ed25519 signature from the project's
fleet0 Pi witness (`pk_fp = cac5f21a70564aeb`). Each `releases/<tag>/`
directory in this tree carries the raw artifact, its
`*.attestation.json`, and an `index.json` manifest. The same files
are mirrored at `https://ledatic.org/releases/<tag>/`.

Verify a release in five lines:

```bash
curl -sf https://ledatic.org/attest/verify.sh -o /tmp/v.sh && chmod +x /tmp/v.sh
curl -sf https://ledatic.org/releases/v3.10.0/rail_native             -o /tmp/rn
curl -sf https://ledatic.org/releases/v3.10.0/rail_native.attestation.json -o /tmp/rn.att.json
/tmp/v.sh /tmp/rn /tmp/rn.att.json
# → ok  artifact=rail_native  pulse_id=…  pk_fp=cac5f21a70564aeb
```

The same primitive (`tools/attest/`) attests the daily `./rail_native
test` pass and the 2-pass byte-identical self-compile. Live mission
control at [ledatic.org/system](https://ledatic.org/system).

## Honest limits

Things Rail v3.10.0 **doesn't** do, so you don't hit them as surprises:

- TLS ships one cipher suite (`TLS_CHACHA20_POLY1305_SHA256`), one ECDHE group (`x25519`), and a fixed sig-alg set: `rsa_pss_rsae_sha256 | rsa_pkcs1_sha256 | ecdsa_secp256r1_sha256 | ecdsa_secp384r1_sha384 | ecdsa_secp521r1_sha512` plus `ed25519` (verify-only, in stdlib). Modern CDN fronts work; legacy servers may not.
- No TLS session resumption, no 0-RTT, no client certificates. Keep-alive landed in v3.3.0 (multiple GETs over one socket).
- No constant-time or side-channel resistance guarantees. This is not OpenSSL; don't ship it to a Defense customer.
- HTTPS handshakes are public-key-verify dominated: ~4 s on RSA paths (Amazon DigiCert), ~17 s on RSA paths through ISRG (Slack), ~90 s on the GTS R4 P-384 chain (Anthropic). Great for one-shot API calls, not an HTTP proxy. The slow P-384 path is a scalar-multiplier issue, not an architectural limit.
- Streaming response bodies shipped in v3.2.0; the legacy `join ""` O(N²) accumulator is parked under the `_unsafe_noverify` names.
- Rail is not ANSI-standardised. There is no formal type system or soundness proof. Use it because it's fast, small, and honest — not because it's Haskell.

## License

[Business Source License 1.1](LICENSE). Free for non-production use; the Additional Use Grant covers research, education, and personal projects. Converts to Apache 2.0 on 2030-04-06.

## Notes

> GitHub's language bar shows this repo as Haskell because `github-linguist` doesn't know Rail exists yet. A [PR is in flight](https://github.com/github-linguist/linguist/pulls?q=rail) to fix that. This is a Rail codebase.
