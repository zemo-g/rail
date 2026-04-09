# Rail

[![Rail: 95%](https://img.shields.io/badge/Rail-95%25-ff5500?style=for-the-badge&logo=rust&logoColor=white)](#)

> GitHub's language bar shows this repo as Haskell because `github-linguist` doesn't know Rail exists yet. A [PR is in flight](https://github.com/github-linguist/linguist/pulls?q=rail) to fix that. In the meantime: this is a Rail codebase.

[![tests: 98/98](https://img.shields.io/badge/tests-98%2F98-brightgreen)](#)
[![self-hosting](https://img.shields.io/badge/self--hosting-fixed%20point-blue)](#)
[![bench: 14/30](https://img.shields.io/badge/RAILGPT%20bench-14%2F30-yellow)](#releases)
[![backends: 4](https://img.shields.io/badge/backends-4-orange)](#releases)
[![GC: ARM64 asm](https://img.shields.io/badge/GC-ARM64%20assembly-purple)](#how-it-works)
[![dependencies: 0](https://img.shields.io/badge/C%20dependencies-0-brightgreen)](#)
[![License: BSL 1.1](https://img.shields.io/badge/license-BSL%201.1-green)](LICENSE)

Rail compiles itself. Then it teaches machines to write Rail. Then it runs real-time GPU physics and trains neural networks to be the physics.

```
-- This is the entire bootstrap:
./rail_native self && cp /tmp/rail_self ./rail_native

-- 4,687 lines of Rail compile to a 729K ARM64 binary.
-- That binary compiles the compiler again.
-- The output is byte-identical. Fixed point.
-- Zero C dependencies. GC in assembly. Everything is Rail.
```

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
./rail_native run examples/hello.rail
```

Apple Silicon (ARM64 macOS). Linux ARM64 and x86_64 cross-compilation supported.

### Rebuild from source

```bash
./rail_native self                    # self-compile → /tmp/rail_self
cp /tmp/rail_self ./rail_native       # install
./rail_native self                    # compile again — must be byte-identical
./rail_native test                    # 98/98
```

## Usage

```bash
./rail_native <file.rail>             # compile to /tmp/rail_out
./rail_native run <file.rail>         # compile + execute
./rail_native test                    # 98/98 test suite
./rail_native self                    # self-compile (fixed point)
./rail_native x86 <file.rail>        # cross-compile to x86_64 Linux
./rail_native linux <file.rail>       # cross-compile to Linux ARM64
```

## The Language

```
-- Functions (defined before main)
double x = x * 2
add a b = a + b

-- Algebraic data types + pattern matching
type Option = | Some x | None

getOr opt = match opt
  | Some x -> x
  | None -> 0

-- Main returns an integer
main =
  let _ = print (show (getOr (Some 42)))
  0
```

```
-- Compiler patterns: expression evaluator
type Expr = | Num x | Add a b | Mul a b

eval e = match e
  | Num x -> x
  | Add a b -> eval a + eval b
  | Mul a b -> eval a * eval b

main =
  let _ = print (show (eval (Add (Num 3) (Mul (Num 4) (Num 5)))))
  0
-- Output: 23
```

```
-- Higher-order: fold, map, filter, pipes
gt3 x = if x > 3 then true else false
add a b = a + b
inc x = x + 1

main =
  let _ = print (show (fold add 0 (range 101)))       -- 5050
  let _ = print (show (length (filter gt3 [1,2,3,4,5,6])))  -- 3
  let r = 3 |> inc |> double                           -- 8
  let _ = print (show r)
  0
```

```
-- Real I/O: files, shell, string processing
find_key lines key = if length lines == 0 then ""
  else
    let parts = split "=" (head lines)
    if head parts == key then head (tail parts)
    else find_key (tail lines) key

main =
  let _ = write_file "/tmp/config.txt" "host=localhost\nport=8080"
  let lines = split "\n" (read_file "/tmp/config.txt")
  let _ = print (find_key lines "port")
  0
-- Output: 8080
```

## How It Works

The compiler (`tools/compile.rail`, 4,687 lines) does:

1. **Lexer** — tokenizes Rail source with position tracking
2. **Parser** — builds AST from tokens (tagged lists)
3. **Type checker** — forward inference, exhaustiveness warnings
4. **Codegen** — walks AST, emits ARM64/x86_64 assembly
5. **Build** — calls `as` + `ld` to produce native binary

### Runtime

| Component | Implementation | Detail |
|-----------|---------------|--------|
| **Allocator** | ARM64 assembly | 512MB bump arena + free list + malloc fallback |
| **GC** | ARM64 assembly | Conservative mark-sweep. Scans stack frames, traces tagged objects, sweeps into free list. |
| **Tagged pointers** | Inline | Integers: `(v << 1) \| 1`. Heap: raw pointer. Tag bit 0 distinguishes. |
| **Objects** | 8-byte size header | Tags: 1=Cons, 2=Nil, 3=Tuple, 4=Closure, 5=ADT, 6=Float. Mark bit at bit 63. |

Zero C runtime. The GC, allocator, and all runtime support are ARM64 assembly embedded in the compiler.

### Performance

Tail-recursive loops match C `-O2`: 5 instructions per iteration.

```
-- fib(40) = 0.30s (matches gcc -O2)
-- Optimizations: self-loop → bottom-test, untagged register params,
--   direct register arithmetic, auto-memoization, constant folding,
--   type guard elimination, fused compare-and-branch
```

## Builtins

| Category | Functions |
|----------|-----------|
| **I/O** | `print`, `show`, `read_file`, `write_file`, `shell`, `read_line` |
| **Lists** | `head`, `tail`, `cons`, `append`, `length`, `map`, `filter`, `fold`, `reverse`, `join`, `range` |
| **Strings** | `chars`, `split`, `str_split`, `str_find`, `str_contains`, `str_replace`, `str_sub` |
| **Math** | `not`, `to_float`, `to_int`, float arithmetic |
| **ADTs** | `type`, `match` with exhaustiveness warnings |
| **Concurrency** | `spawn`, `channel`, `send`, `recv`, `spawn_thread`, `join_thread` |
| **Memory** | `arena_mark`, `arena_reset`, `arr_new`, `arr_get`, `arr_set`, `arr_len` |
| **Errors** | `error`, `is_error`, `err_msg` |
| **FFI** | `foreign` declarations, `llm` builtin |
| **System** | `args`, `import`, pipe operator `|>` |

## Releases

### v2.0.0 — 2026-04-06

**The version where Rail stops being just a self-hosting compiler and becomes a self-improving system.**

121 commits since v1.4.0. Three independent training lineages now run on the same machine, all driven by the same compiler as the binary fitness function: a 4B-parameter LoRA on Gemma, a Metal-GPU MLP that learns to be a physics engine, and a 23-integer probabilistic context-free grammar trained by REINFORCE. The operational discipline to keep all three honest — intervention ledger, recovery chain, runtime overrides, forward regression bisector, domain plugin spine — is built in pure Rail with zero Python. The compiler that runs all of this is itself self-hosting at a byte-identical fixed point, with native floats, effect handlers, and a working garbage collector in ARM64 assembly.

#### Compiler & runtime

- **Native floats** — unboxed IEEE 754 in ARM64 d-registers. Foreign FFI for `sin`/`cos`/`sqrt`/`tanh`/`exp`/`log`/`pow`. Auto int→float promotion. ~10× speedup vs boxed.
- **Effect handlers** — `try body handler` via setjmp/longjmp. Deep unwinding, nested handlers, restartable error recovery.
- **GC bootstrapped** — conservative mark-sweep in ARM64 assembly. 256 MB bump arena + free list + malloc fallback. 10/10 stress self-compiles, byte-identical fixed point.
- **d8 callee-saved float register** — float operations inside recursive functions now get the fast self-loop optimization. Unblocked the neural plasma MLP training.
- **FFI strdup wrap** — string-returning foreign calls strdup-wrapped through the runtime. Fixed the memory bug holding tests at 91/92 → **92/92 for the first time.**
- **Polymorphic show**, **exhaustive match enforcement**, **parser `in` keyword**.
- Tail-recursive loops match C `-O2` (5 instructions per iteration).

#### Four stable backends

| Backend | Status | Target |
|---|---|---|
| **macOS ARM64** | primary, 92 tests, fixed point | M-series Macs |
| **Linux ARM64** | working | Pi Zero 2 W (fleet display) |
| **Linux x86_64** | working | Razer (WSL training node) |
| **WASM** | closures, ADTs, match, lists, strings | browser, edge — 6 demos at compile.ledatic.org |

#### The self-improving flywheel — three lineages

Rail now drives three independent training systems, each using the compiler as the binary fitness function:

1. **LLM-LoRA lineage** — Gemma 4 E4B with a Rail LoRA adapter reaches **14/30 on the README bench**, up from 1/30 baseline. Hyperagent makes bench-gated decisions: keep an adapter only if the bench improves, rollback otherwise. DNA harvester pulls 199 verified examples directly from `compile.rail` itself. The LLM trains on data the compiler has personally verified.

2. **Neural plasma lineage** — A 3D Metal MHD simulator generates training data for a neural surrogate. A pure-Rail linear model converges from loss 4.45 → 0.03 in 500 steps with single-step mass conservation error of 0.027%. A Metal GPU MLP (30→128→6) trains 85× faster than the CPU version using 10 custom Metal kernels. The neural renderer runs the trained MLP forward pass on every cell of a 64×64 grid each frame — **the neural network IS the physics engine**, no PDE solver at runtime. STABLE 200-step simulation via spectral normalization + conservation drift loss.

3. **PCFG-REINFORCE lineage** — `tools/domains/s0_pcfg/` is a 23-rule probabilistic context-free grammar trained by REINFORCE on compile-pass reward. The whole "model" is 23 integer weights, ~120 bytes. Reaches **92% lifetime strict pass rate** in 30 ticks. Generates 5 distinct program shapes (inline, named-binding, statement chain, function definition, ADT + match) — and discovered Rail's runtime tolerances by trial and error before the implementer knew them. **The compiler is the teacher in 720 lines of pure Rail.**

#### Operational discipline (pure Rail, zero Python)

Patterns from the paused Empire trading system, ported as Rail-native infrastructure:

- **Intervention ledger** (`flywheel/interventions.jsonl`) — append-only audit log. Every round_end, level transition, override write, MLX skip, and goal grind is one JSON record. Read with `flywheel/interventions_tail.rail`.
- **Recovery chain** (`flywheel/flush.rail`) — pure Rail rotator. Per protected file: cp src→tmp, mv backup→prev, mv tmp→backup. Three guards (source-empty, size-shrunk, line-collapse). Protects 5 files per round.
- **Domain plugin spine** (`tools/domains/`) — filesystem-as-registry. No dispatcher, no manifest, no registry file. Two domains live: `neural_plasma` and `s0_pcfg`. Discovered with `find`.
- **Runtime overrides** (`flywheel/overrides.txt`) — bounded tunables read fresh every round. Every override write logged to the same ledger. Closes the audit loop.

#### Loop closure

The flywheel runs continuously without human intervention. Each round:

```
LLM training round  →  rotate backups  →  PCFG REINFORCE round  →
  cross-feed PCFG-verified programs into LLM harvest  →  repeat
```

PCFG-verified programs get translated into the chat-completion format the LLM flywheel expects, with SHA-256 dedup against the LLM's existing harvest. **Two oracles, one corpus.**

#### Forward regression bisector

`flywheel/regress.rail` reads the intervention ledger and reports any pass-rate drop bigger than a threshold, plus the suspect events (override_write, level_fallback, server_skip, goal_grind) that occurred in the window before each drop. Threshold configurable. The level 25 → 6 historical regression that motivated the ledger is gone (pre-ledger), so this tool runs **forward**: it watches for the next drop and tells you what changed.

#### Public sandbox

- **[compile.ledatic.org](https://compile.ledatic.org)** — public sandboxed Rail compiler. AST whitelist, WASM import validation, 19-test adversarial suite, Cloudflare Tunnel.
- **[ledatic.org](https://ledatic.org)** v2.0 — main site redeployed with 6 in-browser WASM demos: hello, fib, math, lists, ADTs, closures, string ops.

#### By the numbers

| | v1.4 (2026-03-22) | **v2.0 (2026-04-06)** |
|---|---|---|
| Tests | 70 | **92** |
| Backends | 1 | **4** |
| Stdlib modules | ~22 | **38** |
| Compiler (lines of Rail) | 1,979 | **3,865** |
| Self-improving lineages | 1 (LLM-LoRA) | **3** (LoRA + Metal-MLP + PCFG-REINFORCE) |
| Domain plugins | 0 | **2** (neural_plasma, s0_pcfg) |
| Operational discipline | manual | **full** (ledger + recovery + spine + overrides + bisector) |
| Compiler-verified training corpus | small | 3.67 MB curated, deduped, quality-weighted |

Full release notes: **[CHANGELOG.md](CHANGELOG.md)**

### History

| Version | Date | What |
|---|---|---|
| **v2.0** | 2026-04-06 | See highlights above. **121 commits.** |
| **v1.5** | 2026-03-25 | 92 tests, C-matching performance, hyperagent, DNA training, 3 architectures |
| **v1.4** | 2026-03-22 | GC in assembly, nested lambdas, exhaustiveness, 70 tests |
| **v1.3** | 2026-03-21 | MCP server, 32-layer LoRA, open source |
| **v1.1** | 2026-03-20 | Metal GPU, WASM, x86_64, fibers, flywheel |
| **v1.0** | 2026-03-17 | Self-hosting. Rust deleted. 67 tests. |

## License

BSL 1.1 — free for non-production and non-competitive use. Converts to MIT on 2030-03-14. See [LICENSE](LICENSE).

---

[ledatic.org](https://ledatic.org) | [ledatic.org/system](https://ledatic.org/system)
