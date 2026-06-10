<h1 align="center">Rail</h1>

<p align="center">
  <em>A self-hosting systems language that speaks TLS alone.</em><br>
  <sub>Zero C dependencies. GC in ARM64 assembly. HTTPS, compile-time autodiff, and Merkle provers in pure Rail.</sub>
</p>

<p align="center">
  <a href="#releases"><img src="https://img.shields.io/badge/v5.1.0-Emits%20its%20own%20GPU%20kernels-ff5500?style=for-the-badge" alt="v5.1.0"></a>
</p>

<p align="center">
  <a href="#quick-start"><img src="https://img.shields.io/badge/tests-170%2F170-brightgreen" alt="tests 170/170"></a>
  <a href="#why-rail"><img src="https://img.shields.io/badge/self--hosting-fixed%20point-blue" alt="self-hosting"></a>
  <a href="#what-rail-does"><img src="https://img.shields.io/badge/%23grad%20%2B%20auth-compiler--synthesized-ff5500" alt="#grad AD + auth types"></a>
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

Rail compiles itself. The compiler — 8,049 lines of Rail (`wc -l tools/compile.rail`) — produces a 1.2 MB ARM64 binary (`ls -l rail_native`) that compiles the compiler again and reaches a byte-identical fixed point in 2 cycles. There is no C in the runtime, no libc in the binary. The garbage collector is ARM64 assembly. The TLS 1.3 client is also Rail: `import "stdlib/anthropic_client.rail"` and your program talks HTTPS to `api.anthropic.com` with zero OpenSSL, zero curl. Since **v5.0.0** the toolchain is self-hosted to the metal — Rail emits its own aarch64 Linux ELF binaries, no `as`, no `ld` in that path — and since **v5.1.0** it emits its own GPU kernels, generating Metal Shading Language from an op-DAG and JIT-compiling it at runtime. On master since v5.1.0, two language-level features you won't find in another self-hosted zero-dependency toolchain: **`#grad`**, compile-time automatic differentiation that emits gradients as ordinary re-attestable Rail source, and **`auth`** types, one keyword that turns an ADT into an authenticated data structure with a compiler-synthesized Merkle prover and verifier.

```
./rail_native self && cp /tmp/rail_self ./rail_native  # cycle 1
./rail_native self && cmp rail_native /tmp/rail_self   # cycle 2 — byte-identical
./rail_native test                                     # 170/170
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
./rail_native test               # run the 170-test suite
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
./rail_native self                    -- 8,049 lines of Rail →
                                      --   a 1.2 MB ARM64 binary
cp /tmp/rail_self ./rail_native       -- cycle 1: install gen1
./rail_native self                    -- cycle 2: that binary compiles
                                      --   the compiler again (gen2)
cmp rail_native /tmp/rail_self        -- and the output is identical
                                      --   (byte-identical fixed point)
```

The GC, allocator, and runtime support are ARM64 assembly embedded in the compiler itself. No `gcc`, no `libc`, no linker scripts. The macOS seed binary leans on the system `as` + `ld`; the Linux ARM64 path needs neither since v5.0.0 — Rail writes the ELF itself.

### 2. Differentiates your code at compile time ✨ *new on master*

```rail
#grad f
f x y = (x *. y) +. (3.0 *. x)

-- forward: one partial per call
--   f__grad 2.0 5.0 0 → df/dx at (2,5) = 8;  f__grad 2.0 5.0 1 → df/dy = 2
-- reverse: ALL partials in one backward sweep
--   let go = float_arr_new 2 0.0
--   let _ = f__rgrad 2.0 5.0 go    → go[0]=8, go[1]=2
```

Mark a float function `#grad` and the compiler synthesizes its derivatives at compile time: `f__grad` (forward, one partial per call) and `f__rgrad` (reverse, cost independent of input count — the gradient-descent workhorse). Coverage: `+ - * /`, six transcendentals, `let`-bound shared subexpressions, `if` (piecewise — relu differentiates correctly), and `match`, in both modes. The derivative is emitted as ordinary Rail AST, not an opaque tape: the gradient is a Rail program you can read, hash, and attest. Anything outside the supported grammar punts to a conservative fallback — never a wrong nonzero gradient. Every increment was gated by a three-witness oracle: synthesized gradient vs an independent symbolic differentiator (`tools/ad/diff.rail`) vs numeric finite differences. Reproduce: `./rail_native run tools/ad/grad_oracle_test.rail` (oracle) · `./rail_native run examples/mlp_natural.rail` (MLP with natural float params → `mlp(1.0,2.0)=1.125`).

### 3. Synthesizes provers and verifiers from one keyword ✨ *new on master*

```rail
type Tree = | Tip s | Bin auth Tree auth Tree

fetch t path = match unauth t
  | Tip s   -> s
  | Bin l r -> if head path == 0 then fetch l (tail path)
               else fetch r (tail path)
```

Declare a field `auth` and write the traversal once. The compiler derives the full lambda-auth construction: Merkle projections + digests (`digest_Tree`), a prover clone (`fetch__prove`) that emits a proof stream, and a verifier clone (`fetch__verify`) that holds only the 64-hex root digest and replays the proof, rejecting on any SHA-256 mismatch. An untrusted party can serve query results over your data structure; a client verifies them against a single root hash with constant-size state. Forging an answer requires a SHA-256 collision. Inert by construction: `auth`-free programs — including the compiler itself — compile byte-identically. Tamper rejection (forged leaf, bad root, forged internal node, wrong-key binding) is locked in the embedded suite, tests t141–t152 in `tools/compile.rail`. Reproduce: `./rail_native run tools/auth/authkit.rail` (Merkle membership) · `./rail_native run tools/auth/authdict.rail` (authenticated key→value BST).

### 4. Speaks HTTPS, natively *(since v3.0.0)*

```rail
import "stdlib/anthropic_client.rail"

main =
  let (status, reply) = anthropic_chat
                          "claude-haiku-4-5-20251001"
                          "Reply with exactly: hello from pure rail"
                          40
                          "/path/to/anthropic_key"
  let _ = print reply
  0

-- → "hello from pure rail"
-- Full TLS 1.3: x25519 ECDHE, ECDSA-P256 cert verify, SAN hostname
-- match, validity period, ChaCha20-Poly1305 record layer.
-- Zero OpenSSL, zero curl, zero socat.
```

The full X.509 chain for `api.anthropic.com` (leaf → WE1 intermediate → GTS Root R4) validates end-to-end to the macOS `/etc/ssl/cert.pem` trust store — ECDSA-P256-SHA256 at the leaf, ECDSA-P384-SHA384 at the root edge, all verified in Rail.

### 5. Trains its own AI, verified by the compiler

The compiler is the fitness function: an LLM generates Rail, `rail_native` compiles it (the oracle), programs that compile become training data, programs that don't are the gradient. The curriculum loop is in-tree: `./rail_native run tools/train/self_train.rail`. With `#grad` on master, the loss-to-gradient path now lives inside the language too.

## Why Rail

- **Zero C transitive dependency.** The seed binary needs only `as` + `ld` + the kernel. No glibc. No OpenSSL. No runtime C at all — the GC is ~300 lines of ARM64 assembly inside the compiler.
- **Byte-identical self-compile.** `./rail_native self` produces output identical to the binary that produced it. The compiler's own source is the regression suite.
- **The compiler is the source of truth.** Training loops, tests, HTTPS clients, gradient synthesis — all compiled by the same binary you cloned. If it compiles, it runs.
- **94 stdlib modules** (`ls stdlib/*.rail | wc -l`) — json, http, TLS 1.3, sqlite, regex, tensor, autograd, transformer, ed25519, and the v3.0.0 crypto stack. Every primitive NIST- or RFC-vector-validated.
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

main =
  let _ = print (show (fold (\a b -> a + b) 0 (range 101)))  -- 5050
  let _ = print (show (length (filter gt3 [1,2,3,4,5,6])))   -- 3
  let _ = write_file "/tmp/out.txt" "hello"
  let _ = print (read_file "/tmp/out.txt")                   -- hello
  0
```

```rail
-- Natural float scalars (unboxed IEEE 754 in ARM64 d-registers)
neuron w1 x1 w2 x2 b = relu (w1 * x1 + w2 * x2 + b)
-- Effect handlers, WASM closures + ADTs, Metal GPU IR, #grad, auth types
```

## How it works

| Component | Implementation | Detail |
|---|---|---|
| **Lexer + parser** | Rail | Tokenizer + recursive-descent AST builder |
| **Type checker** | Rail | Forward inference, whole-program float-param agreement, exhaustiveness warnings |
| **Derivative + prover synthesis** | Rail | `#grad` and `auth` desugar to ordinary Rail AST before codegen — gradients and verifiers are readable, hashable Rail |
| **Codegen** | Rail | Walks AST, emits ARM64 / x86_64 / WASM directly |
| **Allocator** | ARM64 assembly | 512 MB bump arena + free list + malloc fallback |
| **GC** | ARM64 assembly | Conservative mark-sweep. Scans stack frames, traces tagged objects, sweeps into free list. |
| **Tagged pointers** | Inline | Integers: `(v << 1) \| 1`. Heap: raw pointer. Tag bit 0 distinguishes. |
| **Runtime float** | d-registers | Unboxed IEEE 754. `fadd`/`fmul` direct, no heap boxing. |

Tail-recursive loops match C `-O2` — 5 instructions per iteration, checkable from source: `./rail_native examples/tail_calls.rail && objdump -d /tmp/rail_out | less` (self-loop → bottom-test, untagged register params, `subs`). The full architecture is documented in [`CHANGELOG.md`](CHANGELOG.md) — see v2.0.0 for the compiler/runtime; v3.0.0 for the TLS stack.

## Releases

The newest work lands on master between tags — the `#grad` and `auth` arcs above are post-v5.1.0 (`git log v5.1.0..HEAD --oneline`). [`CHANGELOG.md`](CHANGELOG.md) is the canonical release record.

### v5.1.0 — 2026-05-15 — *Rail emits its own GPU kernels*

Rail's JIT generates Metal Shading Language from its own op-DAG, compiles it at runtime via `newLibraryWithSource:`, and dispatches the kernel — so every GPU kernel the training stack runs is emitted by an attested Rail binary.

- **Self-emitted GPU kernels.** A DAG matcher walks the op tape, an MSL emitter writes the kernel source, and the JIT compiles + caches it. Two hand-fused kernels land alongside: rmsnorm+QKV (**35×** over the per-op chain) and silu+hadamard (**18×**) as measured at release — harness in-tree at `tools/bench/jit_fused_qkv_bench.rail` (Metal GPU required).
- **bf16 numerics regime.** bf16 keeps f32's exponent range, sidestepping fp16's NaN cliff on long training runs. Details in [CHANGELOG.md](CHANGELOG.md).
- **Compiler core untouched.** The release adds stdlib + foreign decls + Metal sources; the 2-pass byte-identical self-bootstrap is unchanged.

The v5 line opens with **v5.0.0** (2026-05-14) — the self-hosted toolchain: Rail emits aarch64 Linux ELF via a pure-Rail encoder + assembler + static linker + ELF writer, with no `as` or `ld` in the path for the supported subset. **v5.0.1** and **v5.0.2** (both 2026-05-15) follow as patches — codegen tightening + attestation backfill, then the first release attested end-to-end through the Rail substrate (no `curl`, `shasum`, or Python).

### v4.0.0 — 2026-05-13 — *Substrate maturity*

A major-version bump positioning Rail as a substrate, not a model. 217 commits since v3.11.0 (`git rev-list v3.11.0..v4.0.0 --count`) across concurrency, JIT, dual-backend parity, and attested provenance.

- **30/30 hard-bench at release.** A frontier model + a 1 KB Rail spec compiled 30/30 of a held-out hard-bench. Harness in-tree: `tools/bench/repro_30of30.sh` — re-running needs a frontier-model API key.
- **Self-hosted on two backends.** ARM64 140/140 at the tag (`git show v4.0.0:tools/compile.rail` prints the denominator); x86_64 136/136 per the release notes.
- **Concurrency v1 + JIT in pure Rail.** Typed channels + select over a pthread-backed runtime (`stdlib/concurrent.rail`); `jit/grade.rail` lets a Rail program compile + execute new Rail at runtime in the same process.
- **Multi-witness Ed25519 attestation.** Browser-verifiable provenance with pulse_id binding. Standalone single-file verifier ships at deterministic SHA.

v4.0.1 (2026-05-13) is a public-surface sanitization patch over v4.0.0 — see [CHANGELOG.md](CHANGELOG.md). The compiled binary is identical.

### v3.0.0 — 2026-04-18 — *Rail speaks TLS*

A complete pure-Rail TLS 1.3 stack + X.509 chain validation + HTTPS client. External TLS proxy daemons are no longer on any critical path.

**Live on release day, in production:**

```
anthropic_chat "claude-haiku-4-5-20251001" "Reply with exactly: hello from pure rail"
  → HTTP 200, "hello from pure rail"   (6.9 s, pure Rail → Anthropic)
https_get_url "https://www.amazon.com/"
  → HTTP 200                           (4.0 s, RSA chain validated to DigiCert Global Root G2)
```

~3,800 lines of new pure-Rail crypto + TLS across 16 new stdlib modules — `sha256` `sha512` `hmac` `hkdf` · `chacha20` `poly1305` `aead` · `x25519` `ecdsa_p256` `ecdsa_p384` `rsa_pss` · `bignum_n` · `asn1` `b64` `pem` (128 roots from `/etc/ssl/cert.pem`) · the `tls13*` family + `cert_chain` — plus `https_client`, `dns`, `anthropic_client`, `slack_client` on top. Every primitive NIST- or RFC-vector validated. 22 pure-Rail TLS tests, all green. Self-compile 2-pass byte-identical preserved. Full release notes: [**CHANGELOG.md**](CHANGELOG.md).

### v2.0.0 — 2026-04-06 — *Rail becomes a self-improving system*

Native floats in ARM64 d-registers, effect handlers via setjmp/longjmp, GC in assembly, four backends (macOS ARM64 / Linux ARM64 / Linux x86_64 / WASM), and three independent training lineages — all driven by the same compiler as the binary fitness function. 121 commits. 92/92 tests. [**Full details in CHANGELOG.md →**](CHANGELOG.md).

### History *(abridged — 45 tags total, `git tag | wc -l`; every release in [CHANGELOG.md](CHANGELOG.md))*

| Version | Date | Headline |
|---|---|---|
| **v5.1.0** | 2026-05-15 | Rail emits its own GPU kernels — MSL from op-DAG, JIT-compiled fused Metal kernels + bf16 regime |
| **v5.0.2** | 2026-05-15 | First release attested end-to-end through Rail — shell escape hatches retired |
| **v5.0.0** | 2026-05-14 | Self-hosted toolchain — Rail emits aarch64 Linux ELF binaries via pure-Rail encoder + assembler + static linker + ELF writer. `as` / `ld` no longer in the build path for the supported subset. |
| **v4.0.0** | 2026-05-13 | Substrate maturity — 30/30 hard-bench, JIT, dual-backend parity, multi-witness attest |
| **v3.11.0** | 2026-05-02 | Pi self-hosts (98/137 on aarch64 Linux); attest fully Rail-native |
| **v3.8.0** | 2026-05-01 | Releases physicified — every binary attested against a live entropy beacon |
| **v3.0.0** | 2026-04-18 | Rail speaks TLS — pure-Rail HTTPS, chain validation to macOS trust store |
| **v2.0.0** | 2026-04-06 | Self-improving flywheel, native floats, effect handlers, GC in asm |
| **v1.0** | 2026-03-17 | Self-hosting. Rust deleted. 67 tests. |

## Honest limits

Things Rail **doesn't** do, so you don't hit them as surprises:

- TLS ships one cipher suite (`TLS_CHACHA20_POLY1305_SHA256`), one ECDHE group (`x25519`), and three sig-algs (`rsa_pss_rsae_sha256 | ecdsa_secp256r1_sha256 | rsa_pkcs1_sha256`). Modern CDN fronts work; legacy servers may not.
- No TLS session resumption, no 0-RTT, no client certificates. No constant-time or side-channel resistance guarantees. This is not OpenSSL; don't ship it to a Defense customer.
- Each HTTPS connection is seconds, not milliseconds (public-key verify dominates). Great for one-shot API calls, not for an HTTP proxy.
- HTTP response bodies cap around 64 KB (`join ""` is O(N²)) — a documented gap, streaming is future work.
- `#grad` covers a float-scalar grammar (arithmetic, six transcendentals, `let`, `if`, `match`); anything outside punts to a conservative fallback rather than emitting a wrong derivative.
- Rail is not ANSI-standardised. There is no formal type system or soundness proof. Use it because it's fast, small, and honest — not because it's Haskell.

## License

[Business Source License 1.1](LICENSE). Free for non-production use; the Additional Use Grant covers research, education, and personal projects. Converts to Apache 2.0 on 2030-04-06.

## Notes

> GitHub's language bar shows this repo as Haskell because `github-linguist` doesn't know Rail exists yet (an upstream PR was closed unmerged). This is a Rail codebase.
