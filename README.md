# Rail

[![tests: 92/92](https://img.shields.io/badge/tests-92%2F92-brightgreen)](#)
[![self-hosting](https://img.shields.io/badge/self--hosting-fixed%20point-blue)](#)
[![bench: 43%](https://img.shields.io/badge/RAILGPT%20bench-43%25-yellow)](#the-flywheel)
[![ARM64 + x86_64](https://img.shields.io/badge/targets-ARM64%20%7C%20x86__64-orange)](#backends)
[![GC: ARM64 asm](https://img.shields.io/badge/GC-ARM64%20assembly-purple)](#runtime)
[![dependencies: 0](https://img.shields.io/badge/C%20dependencies-0-brightgreen)](#)
[![License: BSL 1.1](https://img.shields.io/badge/license-BSL%201.1-green)](LICENSE)

Rail compiles itself. Then it teaches machines to write Rail.

```
-- This is the entire bootstrap:
./rail_native self && cp /tmp/rail_self ./rail_native

-- 3,865 lines of Rail compile to a 646K ARM64 binary.
-- That binary compiles the compiler again.
-- The output is byte-identical. Fixed point.
-- Zero C dependencies. GC in assembly. Everything is Rail.
```

## The Flywheel

The compiler is the oracle. Generate code, compile to verify, harvest successes, retrain.

```
                    ┌─────────────┐
                    │  LLM Model  │
                    │  (Qwen 4B)  │
                    └──────┬──────┘
                           │ generate Rail code
                           v
                    ┌─────────────┐
                    │   Compiler  │◄── the oracle
                    │ rail_native │    (92 tests, fixed point)
                    └──────┬──────┘
                      ╱         ╲
                compile_fail    success
                  (discard)       │
                                  v
                          ┌──────────────┐
                          │   Harvester  │
                          │ 199 DNA + 10K│
                          └──────┬───────┘
                                 │ verified examples
                                 v
                          ┌──────────────┐
                          │    Trainer   │
                          │  LoRA QLoRA  │
                          └──────┬───────┘
                                 │ better model
                                 └──────► back to top
```

The model doesn't just learn to write valid code — it learns to write code verified by the compiler it's being trained to write for.

### Bench

30 fixed tasks across 6 bands. Scores comparable across models and time.

```
Band                  Base Qwen 4B     + Rail Adapter
─────────────────────────────────────────────────────
Fundamentals (1-4)       0/5              3/5
Practical I/O (5-6)      0/5              2/5
Real Tools (7-8)         0/5              1/5
Compiler (9-10)          0/5              3/5
Advanced (11+)           1/5              1/5
Comprehension            0/5              3/5
─────────────────────────────────────────────────────
TOTAL                    1/30 (3%)       13/30 (43%)
```

### DNA

Training data harvested from Rail's own codebase. Zero LLM involvement.

- **67 compiler tests** extracted from `compile.rail` — code + expected output
- **15 stdlib patterns** — real list/string/math idioms from `stdlib/`
- **117 compositions** — known-good patterns recombined and verified

Every example compiles. Every output is checked. Pure from birth.

### Hyperagent

Bench-gated evolution replaces blind grinding:

1. **Bench** — run 30 tasks, score per band
2. **Analyze** — find weak bands
3. **Generate** — targeted training data for weaknesses
4. **Train** — LoRA from best known adapter
5. **Re-bench** — score the new adapter
6. **Decide** — keep only if bench improves, rollback otherwise

```bash
python3 tools/train/hyperagent.py --cycles 5    # full loop
python3 tools/train/hyperagent.py --bench-only   # just score
python3 tools/train/harvest_dna.py               # regenerate DNA
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
./rail_native test                    # 92/92
```

## Usage

```bash
./rail_native <file.rail>             # compile to /tmp/rail_out
./rail_native run <file.rail>         # compile + execute
./rail_native test                    # 92-test suite
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

The compiler (`tools/compile.rail`, 3,865 lines) does:

1. **Lexer** — tokenizes Rail source with position tracking
2. **Parser** — builds AST from tokens (tagged lists)
3. **Type checker** — forward inference, exhaustiveness warnings
4. **Codegen** — walks AST, emits ARM64/x86_64 assembly
5. **Build** — calls `as` + `ld` to produce native binary

### Runtime

| Component | Implementation | Detail |
|-----------|---------------|--------|
| **Allocator** | ARM64 assembly | 256MB bump arena + free list + malloc fallback |
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

## Backends

| Backend | Status | Target |
|---------|--------|--------|
| **ARM64 native** | Stable, 92 tests | macOS, Linux (Pi Zero) |
| **x86_64** | Working | Linux via WSL |
| **Metal GPU** | Working | Apple Silicon compute shaders |
| **WASM** | Compiles, runtime WIP | Browser/edge |

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

## Stdlib

25 modules in `stdlib/`:

`json` `http` `sqlite` `regex` `base64` `socket` `crypto` `csv` `datetime` `env` `fs` `hash` `math` `net` `os` `path` `process` `random` `sort` `string` `test` `toml` `list` `strbuf` `fmt`

## Numbers

| | Before | After |
|---|--------|-------|
| **Compiler** | 21,086 lines (Rust) | 3,865 lines (Rail) |
| **Binary** | ~8MB (Rust + Cranelift) | 646K (pure ARM64) |
| **Dependencies** | Cargo, Cranelift, Rayon | `as` + `ld` |
| **Build time** | ~30s (cargo build) | ~5s (self-compile) |
| **Tests** | 141 (Rust) | 92 (self-testing) |
| **GC** | 295 lines of C | ARM64 assembly (zero C) |
| **Targets** | 1 (x86_64) | 3 (ARM64, x86_64, WASM) |
| **Self-training** | N/A | 10K+ verified examples, 43% bench |

## Evolution

| Version | Date | What |
|---------|------|------|
| **v1.0** | 2026-03-17 | Self-hosting. Rust deleted. 67 tests. |
| **v1.1** | 2026-03-20 | Metal GPU, WASM, x86_64, fibers, flywheel |
| **v1.3** | 2026-03-21 | MCP server, 32-layer LoRA, open source |
| **v1.4** | 2026-03-22 | GC in assembly, nested lambdas, exhaustiveness, 70 tests |
| **v1.5** | 2026-03-25 | 92 tests, C-matching performance, hyperagent, DNA training, 3 architectures |

## License

BSL 1.1 — free for non-production and non-competitive use. Converts to MIT on 2030-03-14. See [LICENSE](LICENSE).

---

[ledatic.org](https://ledatic.org) | [ledatic.org/system](https://ledatic.org/system)
