<h1 align="center">Rail</h1>

<p align="center">
  <em>A self-hosting systems language that speaks TLS alone.</em><br>
  <sub>Zero C dependencies. GC in ARM64 assembly. HTTPS in pure Rail.</sub>
</p>

<p align="center">
  <a href="#releases"><img src="https://img.shields.io/badge/v5.1.0-Emits%20its%20own%20GPU%20kernels-ff5500?style=for-the-badge" alt="v5.1.0"></a>
</p>

<p align="center">
  <a href="#install"><img src="https://img.shields.io/badge/tests-141%2F141-brightgreen" alt="tests 141/141"></a>
  <a href="#why-rail"><img src="https://img.shields.io/badge/self--hosting-fixed%20point-blue" alt="self-hosting"></a>
  <a href="#what-rail-does"><img src="https://img.shields.io/badge/HTTPS-pure%20Rail-ff5500" alt="pure-Rail HTTPS"></a>
  <a href="#how-it-works"><img src="https://img.shields.io/badge/GC-ARM64%20assembly-purple" alt="GC in ARM64 asm"></a>
  <a href="#why-rail"><img src="https://img.shields.io/badge/C%20dependencies-0-brightgreen" alt="0 C dependencies"></a>
  <a href="#releases"><img src="https://img.shields.io/badge/backends-6-orange" alt="6 backends"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSL%201.1-green" alt="BSL 1.1"></a>
</p>

<p align="center">
  <b><a href="#quick-start">Quick start</a></b> ·
  <b><a href="#what-rail-does">What Rail does</a></b> ·
  <b><a href="#why-rail">Why Rail</a></b> ·
  <b><a href="CHANGELOG.md">Changelog</a></b> ·
  <b><a href="https://github.com/zemo-g/rail/releases">Releases</a></b>
</p>

---

Rail compiles itself. The compiler — ~6,000+ lines of Rail — produces a ~1.0 MB ARM64 binary that compiles the compiler again and reaches a byte-identical fixed point in 2 cycles. There is no C in the runtime, no libc in the binary. The garbage collector is ARM64 assembly. The TLS 1.3 client is also Rail: `import "stdlib/anthropic_client.rail"` and your program talks HTTPS to `api.anthropic.com` with zero OpenSSL, zero curl, zero socat. As of **v5.1.0**, the toolchain is self-hosted to the metal: Rail emits its own aarch64 Linux ELF binaries — no `as`, no `ld` in the path — and emits its own GPU kernels, generating Metal Shading Language from an op-DAG and JIT-compiling it at runtime (35× fused rmsnorm+QKV, 18× fused silu+hadamard). A frontier model + 1 KB Rail spec still compiles 30/30 on a held-out hard-bench — publicly reproducible.

```
./rail_native self && cp /tmp/rail_self ./rail_native  # cycle 1
./rail_native self && cmp rail_native /tmp/rail_self   # cycle 2 — byte-identical
./rail_native test                                     # 141/141
```

## Quick start

```bash
git clone https://github.com/zemo-g/rail
cd rail
./rail_native run examples/hello.rail
```

Apple Silicon (ARM64 macOS) is the primary target; Linux ARM64, Linux x86_64, WebAssembly, Cortex-M4, and RISC-V rv32imc backends are supported.

```bash
./rail_native <file.rail>        # compile to /tmp/rail_out
./rail_native run <file.rail>    # compile + execute
./rail_native test               # run the 140-test suite
./rail_native self               # self-compile, fixed point at gen2
./rail_native x86 <file.rail>    # cross-compile to Linux x86_64
./rail_native linux <file.rail>  # cross-compile to Linux ARM64
./rail_native wasm <file.rail>   # compile to WebAssembly
./rail_native cortexm <file.rail># compile to Cortex-M4 (Thumb-2)
./rail_native riscv32 <file.rail># compile to RISC-V rv32imc
```

## What Rail does

### 1. Compiles itself, byte-identical

```
./rail_native self                    -- ~6,719 lines of Rail →
                                      --   a ~1.0 MB ARM64 binary
cp /tmp/rail_self ./rail_native       -- cycle 1: install gen1
./rail_native self                    -- cycle 2: that binary compiles
                                      --   the compiler again (gen2)
cmp rail_native /tmp/rail_self        -- and the output is identical
                                      --   (byte-identical fixed point)
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

The compiler is the fitness function. Programs that compile become training data; programs that don't are the gradient. Three independent lineages (LoRA on Gemma, Metal-GPU MLP, PCFG-REINFORCE) all use the same compiler as the binary verifier. 92 % strict pass rate on the PCFG lineage in 30 ticks.

## Why Rail

- **Zero C transitive dependency.** The seed binary needs only `as` + `ld` + the kernel. No glibc. No OpenSSL. No runtime C at all — the GC is 300 lines of ARM64 assembly inside the compiler.
- **Byte-identical self-compile.** `./rail_native self` produces output identical to the binary that produced it. The compiler's own source is the regression suite.
- **The compiler is the source of truth.** Training loops, tests, site generation, HTTPS clients — they all get compiled by the same binary you cloned. If it compiles, it runs.
- **Production surface is narrow and honest.** Rail v3.0.0 ships the crypto it uses (ChaCha20-Poly1305, x25519, SHA-256/384/512, ECDSA-P256/P384, RSA-PSS/PKCS1) and nothing more. Every primitive is NIST- or RFC-vector-validated.
- **Six backends travel with the language.** macOS ARM64, Linux ARM64 (Pi Zero 2 W), Linux x86_64, WebAssembly, Cortex-M4 (Thumb-2), and RISC-V rv32imc — the same compiler cross-compiles to all of them.

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

### v5.1.0 — 2026-05-15 — *Rail emits its own GPU kernels*

Rail's JIT generates Metal Shading Language from its own op-DAG, compiles it at runtime via `newLibraryWithSource:`, and dispatches the kernel — so every GPU kernel the training stack runs is emitted by an attested Rail binary.

- **Self-emitted GPU kernels.** A DAG matcher walks the op tape, an MSL emitter writes the kernel source, and the JIT compiles + caches it. Two hand-fused kernels land alongside: rmsnorm+QKV (**35×** over the per-op chain) and silu+hadamard (**18×**).
- **bf16 numerics regime.** bf16 has f32's exponent range, sidestepping fp16's step-2759 NaN cliff — unlocking stable 10k-step training at ~40% under the f64 baseline.
- **Compiler core untouched.** The release adds stdlib + foreign decls + Metal sources; the 2-pass byte-identical self-bootstrap is unchanged.

The v5 line opens with **v5.0.0** (2026-05-14) — the self-hosted toolchain: Rail emits aarch64 Linux ELF via a pure-Rail encoder + assembler + static linker + ELF writer, with no `as` or `ld` in the path for the supported subset. **v5.0.1** and **v5.0.2** (both 2026-05-15) follow as patches — codegen tightening + attestation backfill, then the first release attested end-to-end through the Rail substrate (no `curl`, `shasum`, or Python).

### v4.0.0 — 2026-05-13 — *Substrate maturity*

A major-version bump positioning Rail as a substrate, not a model. 216 commits since v3.11.0 across concurrency, JIT, dual-backend parity, attested provenance, and 30/30 hard-bench reproducibility.

- **30/30 hard-bench, publicly reproducible.** A frontier model + a 1 KB Rail spec compiles 30/30 of a held-out hard-bench. Anyone with an API key can re-run.
- **Self-hosted on two backends with full parity.** ARM64 140/140 and x86_64 136/136. The same compiler runs both; same-bug-class sweep closed for all 9 binary ops across both operand orderings.
- **Concurrency v1.** Typed channels + select over a pthread-backed runtime. `import "stdlib/concurrent.rail"`.
- **JIT in pure Rail.** `import "jit/grade.rail"` — a Rail program can compile + execute new Rail at runtime in the same process. Found a 17-day silent-corruption auto-memo bug by dual-implementing the compile path.
- **Multi-witness Ed25519 attestation.** Browser-verifiable provenance with pulse_id binding. Standalone single-file verifier ships at deterministic SHA.

v4.0.1 (2026-05-13) is a public-surface sanitization patch over v4.0.0 — see [CHANGELOG.md](CHANGELOG.md). The compiled binary is identical.

### v3.0.0 — 2026-04-18 — *Rail speaks TLS*

A complete pure-Rail TLS 1.3 stack + X.509 chain validation + HTTPS client. The `~/.fleet/tls_proxies.sh` socat daemons are no longer on any critical path.

**Live on release day, in production:**

```
anthropic_chat "claude-haiku-4-5-20251001" "Reply with exactly: hello from pure rail"
  → HTTP 200, "hello from pure rail"       (6.9 s, pure Rail → Anthropic)

slack_post_text "<DM_CHANNEL_ID>" "v3.0.0 smoke: pure-Rail TLS"
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
| **v5.1.0** | 2026-05-15 | Rail emits its own GPU kernels — MSL from op-DAG, JIT-compiled fused Metal (35× rmsnorm+QKV, 18× silu+hadamard) + bf16 regime |
| **v5.0.2** | 2026-05-15 | First release attested end-to-end through Rail — shell escape hatches retired |
| **v5.0.1** | 2026-05-15 | Attestation hygiene + ARM64 codegen tightening |
| **v5.0.0** | 2026-05-14 | Self-hosted toolchain — Rail emits aarch64 Linux ELF binaries via pure-Rail encoder + assembler + static linker + ELF writer. `as` / `ld` no longer in the build path for the supported subset. |
| **v4.1.0** | 2026-05-13 | Repo hygiene + leak-guard CI |
| **v4.0.1** | 2026-05-13 | Public-surface sanitization (no behavior change) |
| **v4.0.0** | 2026-05-13 | Substrate maturity — 30/30 hard-bench, JIT, dual-backend parity, multi-witness attest |
| **v3.11.0** | 2026-05-02 | Pi self-hosts (98/137 on aarch64 Linux); attest fully Rail-native |
| **v3.10.0** | 2026-05-02 | Pi signer in pure Rail; Linux backend gains atof + snprintf + print_float |
| **v3.9.0** | 2026-05-02 | Linux cross-compile fixed (`./rail_native linux foo.rail` → working ELF) |
| **v3.8.0** | 2026-05-01 | Releases physicified — every binary attested against a live entropy beacon |
| **v3.7.0** | 2026-04-30 | Float-TCO root fix, mixed-precision inference, parallel rerank |
| **v3.0.0** | 2026-04-18 | Rail speaks TLS — pure-Rail HTTPS, chain validation to macOS trust store |
| **v2.23.0** | 2026-04-17 | Pure-Rail HTTP/1.1 client + `char_from_int` |
| **v2.0.0** | 2026-04-06 | Self-improving flywheel, native floats, effect handlers, GC in asm |
| **v1.5** | 2026-03-25 | C-matching performance, hyperagent, DNA training |
| **v1.4** | 2026-03-22 | GC in assembly, nested lambdas, exhaustiveness |
| **v1.3** | 2026-03-21 | MCP server, 32-layer LoRA, open source |
| **v1.1** | 2026-03-20 | Metal GPU, WASM, x86_64, fibers, flywheel |
| **v1.0** | 2026-03-17 | Self-hosting. Rust deleted. 67 tests. |

## Honest limits

Things Rail v3.0.0 **doesn't** do, so you don't hit them as surprises:

- TLS ships one cipher suite (`TLS_CHACHA20_POLY1305_SHA256`), one ECDHE group (`x25519`), and three sig-algs (`rsa_pss_rsae_sha256 | ecdsa_secp256r1_sha256 | rsa_pkcs1_sha256`). Modern CDN fronts work; legacy servers may not.
- No TLS session resumption, no 0-RTT, no client certificates.
- No constant-time or side-channel resistance guarantees. This is not OpenSSL; don't ship it to a Defense customer.
- Each HTTPS connection is 5–8 seconds wall time (public-key verify dominates). Great for one-shot API calls, not for an HTTP proxy.
- Response body is assembled via `join ""` — O(N²), caps cleanly around 64 KB. Streaming is a v3.1 item.
- Rail is not ANSI-standardised. There is no formal type system or soundness proof. Use it because it's fast, small, and honest — not because it's Haskell.

## License

[Business Source License 1.1](LICENSE). Free for non-production use; the Additional Use Grant covers research, education, and personal projects. Converts to Apache 2.0 on 2030-04-06.

## Notes

> GitHub's language bar shows this repo as Haskell because `github-linguist` doesn't know Rail exists yet. A [PR is in flight](https://github.com/github-linguist/linguist/pulls?q=rail) to fix that. This is a Rail codebase.
