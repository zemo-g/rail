<h1 align="center">Rail</h1>

<p align="center">
  <em>A self-hosting systems language that speaks TLS alone.</em><br>
  <sub>Zero C dependencies. GC in ARM64 assembly. HTTPS, compile-time autodiff, and Merkle provers in pure Rail.</sub>
</p>

<p align="center">
  <b>The binary at the root of this repo compiled itself. Every claim below carries a receipt you can run from this clone.</b>
</p>

<p align="center">
  <a href="docs/VERIFY.md"><img src="https://img.shields.io/badge/tests-170%2F170-brightgreen" alt="tests 170/170"></a>
  <a href="docs/VERIFY.md"><img src="https://img.shields.io/badge/self--hosting-fixed%20point-blue" alt="self-hosting fixed point"></a>
  <a href="docs/VERIFY.md"><img src="https://img.shields.io/badge/C%20dependencies-0-brightgreen" alt="0 C dependencies"></a>
  <a href="docs/VERIFY.md"><img src="https://img.shields.io/badge/releases-Ed25519--signed-ff5500" alt="releases Ed25519-signed"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSL%201.1-green" alt="BSL 1.1"></a>
</p>

<p align="center">
  <sub>Runs from the clone on Apple Silicon macOS; five other targets cross-compile — see <a href="docs/site/backends.md">backends</a>.
  On any other host, the receipts below SKIP honestly rather than fail.</sub>
</p>

<p align="center">
  <b><a href="#sixty-seconds">Sixty seconds</a></b> ·
  <b><a href="#act-i--the-loop">The loop</a></b> ·
  <b><a href="#act-ii--what-the-loop-carries">What the loop carries</a></b> ·
  <b><a href="#why-rail">Why Rail</a></b> ·
  <b><a href="docs/VERIFY.md">Verify</a></b> ·
  <b><a href="PROOFS.md">Proofs</a></b> ·
  <b><a href="CHANGELOG.md">Changelog</a></b> ·
  <b><a href="https://github.com/zemo-g/rail/releases">Releases</a></b>
</p>

---

## Sixty seconds

Run the seed binary that ships in this repo: [R04]

```bash
git clone https://github.com/zemo-g/rail
cd rail
./rail_native run examples/hello.rail
# hello, rail
# 3628800
# 42            (~0.4 s)
```

Write a program:

```bash
cat > /tmp/first.rail << 'EOF'
add a b = a + b
greet name = cat ["hello, ", name]

main =
  let _ = print (greet "stranger")
  let _ = print (show (fold add 0 (range 11)))
  0
EOF
./rail_native run /tmp/first.rail
# hello, stranger
# 55
```

Now perform a receipt. Rail hashes a string with its own pure-Rail SHA-256; your system cross-checks it: [R18]

```bash
./rail_native run examples/readme/snippet_sha256.rail
# 3fcdc35f78b2da1500110b01109beee0022e2df7e138135cc3a0a5341c529dd1
echo -n 'the loop is the proof' | shasum -a 256
# 3fcdc35f78b2da1500110b01109beee0022e2df7e138135cc3a0a5341c529dd1
```

The digests agree. The full suite is `./rail_native test` — 170/170, ~17 min [R02]. Start it later; first, start the loop.

## Act I — the loop

Rail's compiler is 8,049 lines of Rail (`wc -l tools/compile.rail`). The 1.2 MB ARM64 seed binary checked into this repo compiles that source, and the binary it produces compiles it again, byte-identically: [R01]

```
./rail_native self && cp /tmp/rail_self ./rail_native  # cycle 1
./rail_native self && cmp rail_native /tmp/rail_self   # cycle 2 — byte-identical
./rail_native test                                     # 170/170
```

Each cycle takes ~5.5 minutes (Apple M-series). Start it now; this README verifies while it runs. When `cmp` returns, it prints nothing — exit 0. That silence is the proof.

For readers who won't wait, the fixed point is also a signed artifact in the tree: `selfhost/94afdd1/result.json` records `pass1_sha256 == pass2_sha256` (`66a57a8e…`, `fixed_point: true`) for v5.1.0, Ed25519-signed by the fleet0 witness and verified offline by a Rail program against the key pinned in this tree: [R01s]

```bash
./rail_native run tools/attest/verify.rail \
    selfhost/94afdd1/result.json \
    selfhost/94afdd1/result.json.attestation.json \
    releases/witness-fleet0/fleet0.pub.pem
# ok  artifact=result.json  pulse_id=1004798  pk_fp=cac5f21a70564aeb
```

That record's `seed_match: false` is expected and honest — the seed binary that *starts* a cycle does not have to byte-match what its own source emits (gen0 runtime drift); convergence happens at cycle 2. Details: `notes/bootstrap_convergence_audit_2026-05-13.md`. One rule to avoid a classic trap: today's working tree is post-v5.1.0 master — never compare HEAD's `self` output against a tagged record. The full trust model lives in [`docs/VERIFY.md`](docs/VERIFY.md).

## Five minutes of receipts

While the loop turns, cash these. Counts cited in this README are linted against the live tree — drift fails the receipt run: [R05]

```bash
wc -l tools/compile.rail        # 8049
ls stdlib/*.rail | wc -l        # 94
```

Zero C, stated precisely: [R03]

```bash
otool -L rail_native            # exactly one dylib: /usr/lib/libSystem.B.dylib
nm -u rail_native               # exactly 8 undefined symbols:
# _fmod _getenv _memcpy _pthread_create _pthread_join _pthread_mutex_init _snprintf _strtol
```

No C is compiled into Rail — the GC, allocator, and string runtime are in-binary ARM64 assembly. These 8 libSystem imports are the entire OS edge on macOS; the Rail-emitted Linux ELF path binds none.

The climax one-liner — Rail verifies, offline, an Ed25519 signature (implemented in Rail) over its own source, against a key pinned in this tree: [R10]

```bash
git show v5.1.0:tools/compile.rail > /tmp/rail_v510_src.rail
./rail_native run tools/attest/verify.rail /tmp/rail_v510_src.rail \
    releases/v5.1.0/compile.rail.attestation.json \
    releases/witness-fleet0/fleet0.pub.pem
# ok  artifact=compile.rail  pulse_id=1004626  pk_fp=cac5f21a70564aeb      (~4 s)
```

(The verifier's compile prints two spurious typechecker warnings — `'malloc' is not defined`, `'free' is not defined` — before the `ok`. The type-checker's warning is itself running; fix tracked in [`docs/site/TODO.md`](docs/site/TODO.md).)

The released binary gets the same treatment from two unrelated stacks — `tools/attest/verify.sh` (openssl) and `tools/attest/verify.rail` (pure Rail) must agree on it, and a disagreement is itself a failure: [R10b]

## Act II — what the loop carries

### 1. Compiles itself, byte-identical

Act I [R01]. The GC, allocator, and runtime support are ARM64 assembly embedded in the compiler itself. No `gcc`, no linker scripts. The macOS seed binary leans on the system `as` + `ld`; the Linux ARM64 path needs neither since v5.0.0 — Rail writes the ELF itself.

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

Mark a float function `#grad` and the compiler synthesizes its derivatives at compile time: `f__grad` (forward) and `f__rgrad` (reverse, cost independent of input count — the gradient-descent workhorse). Coverage: `+ - * /`, six transcendentals, `let`-bound shared subexpressions, `if` (piecewise — relu differentiates correctly), and `match`. The derivative is emitted as ordinary Rail AST, not an opaque tape: the gradient is a Rail program you can read, hash, and attest. Anything outside the supported grammar punts to a conservative fallback — never a wrong nonzero gradient.

Receipt: every increment was gated by a three-witness oracle — synthesized gradient vs an independent symbolic differentiator (`tools/ad/diff.rail`) vs numeric finite differences. `./rail_native run tools/ad/grad_oracle_test.rail` prints `RESULT: 8/8 partials agree across all three witnesses` [R06]. `./rail_native run examples/mlp_natural.rail` runs an MLP with natural float params → `mlp(1.0, 2.0)  = 1.125` [R07].

### 3. Synthesizes provers and verifiers from one keyword ✨ *new on master*

```rail
type Tree = | Tip s | Bin auth Tree auth Tree

fetch t path = match unauth t
  | Tip s   -> s
  | Bin l r -> if head path == 0 then fetch l (tail path)
               else fetch r (tail path)
```

Declare a field `auth` and write the traversal once. The compiler derives the full lambda-auth construction: Merkle projections + digests (`digest_Tree`), a prover clone (`fetch__prove`) that emits a proof stream, and a verifier clone (`fetch__verify`) that holds only the 64-hex root digest and replays the proof, rejecting on any SHA-256 mismatch. An untrusted party can serve query results over your data structure; a client verifies them against a single root hash with constant-size state. Forging an answer requires a SHA-256 collision. Inert by construction: `auth`-free programs — including the compiler itself — compile byte-identically.

Receipt: `./rail_native run tools/auth/authkit.rail` (Merkle membership — prints its root, accepts the clean proof, rejects tampered and wrong-root) and `./rail_native run tools/auth/authdict.rail` (authenticated key→value BST, including the wrong-key-binding rejection) [R08]. Tamper rejection is locked in the embedded suite, tests t141–t152 [R02].

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

Receipts: the live strict-chain GET needs network [R13] and the live API call needs a key [R14] — both labeled, neither run by default. The offline receipt is in-tree: 22 RFC/NIST-vector TLS tests inside the 170 suite [R02].

### 5. Trains its own AI, verified by the compiler

The compiler is the fitness function: an LLM generates Rail, `rail_native` compiles it (the oracle), programs that compile become training data, programs that don't are the gradient. The curriculum loop is in-tree: `tools/train/self_train.rail`. Running it needs an API key [R15]; with `#grad` on master, the loss-to-gradient path now lives inside the language too.

## Why Rail

- **Zero C transitive dependency.** No glibc, no OpenSSL, no runtime C at all — the GC is ~300 lines of ARM64 assembly inside the compiler. The whole OS edge is 8 libSystem imports, enumerable from the clone [R03].
- **Byte-identical self-compile.** `./rail_native self` produces output identical to the binary that produced it. The compiler's own source is the regression suite [R01].
- **The compiler is the source of truth.** Training loops, tests, HTTPS clients, gradient synthesis — all compiled by the same binary you cloned. If it compiles, it runs.
- **94 stdlib modules** (`ls stdlib/*.rail | wc -l`) — json, http, TLS 1.3, sqlite, regex, tensor, autograd, transformer, ed25519, and the v3.0.0 crypto stack [R05]. Every primitive NIST- or RFC-vector-validated.
- **Six backends travel with the language.** macOS ARM64, Linux ARM64 (Pi Zero 2 W), Linux x86_64, WebAssembly, Cortex-M4 (Thumb-2), and RISC-V rv32imc — the same compiler cross-compiles to all of them; artifact receipts run from this clone [R12].

## The language

<!-- snippet:adt -->
```rail
-- Functions, pattern matching, ADTs
type Expr = | Num x | Add a b | Mul a b

eval e = match e
  | Num x   -> x
  | Add a b -> eval a + eval b
  | Mul a b -> eval a * eval b

main = let _ = print (show (eval (Add (Num 3) (Mul (Num 4) (Num 5))))) in 0
-- -> 23
```

<!-- snippet:hof -->
```rail
-- Higher-order, pipes, real I/O
add a b = a + b
gt3 x = x > 3

main =
  let _ = print (show (fold add 0 (range 101)))              -- 5050
  let _ = print (show (length (filter gt3 [1,2,3,4,5,6])))   -- 3
  let _ = write_file "/tmp/out.txt" "hello"
  let _ = print (read_file "/tmp/out.txt")                   -- hello
  0
```

<!-- snippet:float -->
```rail
-- Natural float scalars (unboxed IEEE 754 in ARM64 d-registers)
relu x = if x > 0.0 then x else 0.0

neuron w1 x1 w2 x2 b = relu (w1 * x1 + w2 * x2 + b)

main =
  let _ = print (show_float (neuron 0.5 1.0 0.25 2.0 0.125))  -- 1.125
  let _ = print (show_float (relu (0.0 - 3.0)))               -- 0
  0
```

These three blocks are real files — `examples/readme/snippet_{adt,hof,float}.rail` — and the receipt run diffs the blocks against the files byte-for-byte, then compiles and runs them against pinned output [R16]. README code cannot rot silently.

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

Tail-recursive loops compile to tight bottom-test loops (self-loop optimization, untagged register params, `subs`). Receipt: `./rail_native run examples/tco_test.rail` prints `0` then `500000500000` — two million-deep recursions with no stack growth, in well under a second [R09]. The receipt run also shows the `objdump` disassembly of the loop; the instructions-per-iteration comparison against C `-O2` is displayed for a human to judge, never gated on. The full architecture is documented in [`CHANGELOG.md`](CHANGELOG.md) — see v2.0.0 for the compiler/runtime; v3.0.0 for the TLS stack.

## Act III — the ledger

The newest work lands on master between tags — the `#grad` and `auth` arcs above are post-v5.1.0 (`git log v5.1.0..HEAD --oneline`). [`CHANGELOG.md`](CHANGELOG.md) is the canonical release record.

Every attested tag has a `releases/<tag>/` directory holding three receipt JSONs: `index.json` (artifact hashes + commit) and an Ed25519 attestation per artifact. The bytes live in git history; the generalized offline verify is always the same three steps — `git show <tag>:<artifact>`, `shasum` against `index.json`, `verify.rail` against the tree-pinned key. The trust model and nuances are in [`docs/VERIFY.md`](docs/VERIFY.md); the all-tags table, regenerated from the records themselves, is [`docs/RELEASE_LEDGER.md`](docs/RELEASE_LEDGER.md) [R20].

### v5.1.0 — 2026-05-15 — *Rail emits its own GPU kernels*

Rail's JIT generates Metal Shading Language from its own op-DAG, compiles it at runtime via `newLibraryWithSource:`, and dispatches the kernel — so every GPU kernel the training stack runs is emitted by an attested Rail binary.

- **Self-emitted GPU kernels.** A DAG matcher walks the op tape, an MSL emitter writes the kernel source, and the JIT compiles + caches it. Two hand-fused kernels land alongside: rmsnorm+QKV (**35×** over the per-op chain) and silu+hadamard (**18×**) as measured at release — harness in-tree at `tools/bench/jit_fused_qkv_bench.rail` (Metal GPU required; perf numbers display-only) [R21].
- **bf16 numerics regime.** bf16 keeps f32's exponent range, sidestepping fp16's NaN cliff on long training runs. Details in [CHANGELOG.md](CHANGELOG.md).
- **Compiler core untouched.** The release adds stdlib + foreign decls + Metal sources; the 2-pass byte-identical self-bootstrap is unchanged.

The v5 line opens with **v5.0.0** (2026-05-14) — the self-hosted toolchain: Rail emits aarch64 Linux ELF via a pure-Rail encoder + assembler + static linker + ELF writer, with no `as` or `ld` in the path for the supported subset. **v5.0.1** and **v5.0.2** (both 2026-05-15) follow as patches — codegen tightening + attestation backfill, then the first release attested end-to-end through the Rail substrate (no `curl`, `shasum`, or Python).

### v4.0.0 — 2026-05-13 — *Substrate maturity*

A major-version bump positioning Rail as a substrate, not a model. 217 commits since v3.11.0 (`git rev-list v3.11.0..v4.0.0 --count`) across concurrency, JIT, dual-backend parity, and attested provenance.

- **30/30 hard-bench at release.** A frontier model + a 1 KB Rail spec compiled 30/30 of a held-out hard-bench. Harness in-tree: `tools/bench/repro_30of30.sh` — re-running needs a frontier-model API key (gated, like [R14]).
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

### History *(abridged — 45 tags total, `git tag | wc -l`; every release in [CHANGELOG.md](CHANGELOG.md); every attested tag in [docs/RELEASE_LEDGER.md](docs/RELEASE_LEDGER.md))*

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

## Receipts we can't give you (yet)

Things Rail **doesn't** do, so you don't hit them as surprises:

- TLS ships one cipher suite (`TLS_CHACHA20_POLY1305_SHA256`), one ECDHE group (`x25519`), and three sig-algs (`rsa_pss_rsae_sha256 | ecdsa_secp256r1_sha256 | rsa_pkcs1_sha256`). Modern CDN fronts work; legacy servers may not.
- No TLS session resumption, no 0-RTT, no client certificates. No constant-time or side-channel resistance guarantees. This is not OpenSSL; don't ship it to a Defense customer.
- Each HTTPS connection is seconds, not milliseconds (public-key verify dominates). Great for one-shot API calls, not for an HTTP proxy.
- HTTP response bodies cap around 64 KB (`join ""` is O(N²)) — a documented gap, streaming is future work.
- `#grad` covers a float-scalar grammar (arithmetic, six transcendentals, `let`, `if`, `match`); anything outside punts to a conservative fallback rather than emitting a wrong derivative.
- Rail is not ANSI-standardised. There is no formal type system or soundness proof. Use it because it's fast, small, and honest — not because it's Haskell.

And the bugs come with reproduce commands:

- `examples/native_closures.rail` — named-function application works (prints `10`, `15`), then the first partial application segfaults. Reproduce: `./rail_native run examples/native_closures.rail` shows `Segmentation fault: 11` in the run output [R19].
- `examples/tail_calls.rail` — the first two demos print correctly, then the `gcd` demo never terminates: division inside a tail-recursive self-call argument re-enters the loop tagged (minimal repro and verified workaround in the file's header comment). The working TCO receipt is `examples/tco_test.rail` [R09]. Fix tracked in [`docs/site/TODO.md`](docs/site/TODO.md).

A limits section you can run is the only kind worth reading.

## Prove this repo

Every receipt above replays from one command:

```bash
bash tools/prove/prove.sh          # fast tier — every receipt above, seconds each
bash tools/prove/prove.sh --core   # + the fixed point (~11 min) + the suite (~17 min)
bash tools/prove/prove.sh R10      # a single claim
bash tools/prove/prove.sh --list   # the claim table (= PROOFS.md)
```

Sample transcript (2026-06-10, Apple M-series):

```
R01s PASS (4s) - the v5.1.0 fixed point is recorded in selfhost/94afdd1 and Ed25519-verified offline
R03  PASS (0s) - zero C dependencies: one linked dylib (libSystem) and exactly 8 undefined symbols
R10  PASS (4s) - v5.1.0 compile.rail matches index.json sha256 and its attestation verifies offline in Rail
R13  SKIP (gated: net - live HTTPS GET needs network; run with --net)
...
16/16 receipts verified, 6 skipped (gated)
```

GATED receipts (network, API key, Metal GPU) print SKIP with the reason — never silently omitted, never faked. Timing never gates. An anchor lint keeps this README and the receipt registry bidirectionally consistent [R17]. The generated claim table is [`PROOFS.md`](PROOFS.md); the trust manual is [`docs/VERIFY.md`](docs/VERIFY.md).

## License

[Business Source License 1.1](LICENSE). Free to copy, modify, and use for non-production purposes; the Additional Use Grant permits production use as long as it doesn't include offering Rail to third parties on a hosted or embedded basis competitive with the Licensor's products. Converts to the MIT License on 2030-03-14. The LICENSE file is authoritative.

## Notes

> GitHub's language bar shows this repo as Haskell because `github-linguist` doesn't know Rail exists yet (an upstream PR was closed unmerged). This is a Rail codebase.
