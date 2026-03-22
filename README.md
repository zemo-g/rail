# Rail

[![tests: 70/70](https://img.shields.io/badge/tests-70%2F70-brightgreen)](#)
[![self-hosting](https://img.shields.io/badge/self--hosting-fixed%20point-blue)](#)
[![ARM64](https://img.shields.io/badge/target-ARM64-orange)](#)
[![GC](https://img.shields.io/badge/GC-mark%20%26%20sweep-purple)](#)
[![dependencies: 0](https://img.shields.io/badge/dependencies-0-brightgreen)](#)
[![License: BSL 1.1](https://img.shields.io/badge/license-BSL%201.1-green)](LICENSE)

A programming language that deleted its own compiler.

```
-- Rail compiles itself. This is the entire bootstrap:
--   ./rail_native self && cp /tmp/rail_self ./rail_native
--
-- 1,979 lines of Rail replaced 21,086 lines of Rust.
-- The compiler is a fixed point of itself.
-- The garbage collector is written in C. Everything else is Rail.

add a b = a + b

main =
  let f = \a -> \b -> a + b
  let _ = print (show (f 3 4))
  0
```

## What happened

Rail was originally written in Rust — 21K lines: interpreter, parser, type checker, LSP, formatter, Cranelift JIT backend, the works.

Then the ARM64 native compiler was rewritten in Rail itself (`tools/compile.rail`). On March 16, 2026:

1. The Rail compiler compiled itself to a native ARM64 binary
2. That binary compiled the compiler again
3. The output was byte-identical (fixed point)
4. The Rust was deleted

The language now bootstraps from a ~329K seed binary. No Rust. No Cargo. No dependencies beyond macOS `as` + `ld`.

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
# Already built — the seed binary is in the repo:
./rail_native run examples/hello.rail
```

Apple Silicon only (ARM64 macOS). Linux ARM64 cross-compilation supported.

### Rebuild from source

```bash
./rail_native self                    # compiles itself → /tmp/rail_self
cp /tmp/rail_self ./rail_native       # install
./rail_native test                    # 70/70
```

## Usage

```bash
./rail_native <file.rail>             # compile to /tmp/rail_out
./rail_native run <file.rail>         # compile + execute
./rail_native test                    # run 70-test suite
./rail_native self                    # self-compile (bootstrap)
```

## The language

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
-- Nested lambdas + closures
main =
  let f = \a -> \b -> a * b
  let offset = 100
  let g = \x -> \y -> x + y + offset
  let _ = print (show (f 6 7))
  let _ = print (show (g 10 3))
  0
-- Output: 42, 113
```

```
-- Higher-order functions
factorial n = if n <= 1 then 1 else n * factorial (n - 1)
add a b = a + b

main =
  let result = fold add 0 (range 101)
  let _ = print (show result)
  0
-- Output: 5050
```

```
-- Lists, strings, I/O, shell, pipes
inc x = x + 1

main =
  let words = split " " "hello world"
  let _ = print (join " " (reverse words))
  let r = [1,2,3] |> reverse |> head |> inc
  let _ = print (show r)
  let _ = write_file "/tmp/test.txt" "done"
  let date = shell "date +%Y-%m-%d"
  let _ = print date
  0
```

## How it works

The compiler (`tools/compile.rail`, 1,979 lines) does:

1. **Lexer** — tokenizes Rail source into a token stream
2. **Parser** — builds an AST from tokens (lists with tag strings)
3. **Exhaustiveness checker** — warns on non-exhaustive ADT pattern matches
4. **Codegen** — walks the AST, emits ARM64 assembly
5. **Build** — calls `as` + `ld` to produce a Mach-O binary

### Runtime

| Component | Implementation | What |
|-----------|---------------|------|
| **Allocator** | ARM64 assembly (inline) | 1GB bump arena + free list + malloc fallback |
| **Garbage collector** | C (`runtime/gc.c`, 295 lines) | Conservative mark-sweep. Scans stack via x29 frame chain, traces tagged objects, builds free list. No cycle detection needed — Rail is pure functional. |
| **LLM builtin** | C (`runtime/llm.c`, 121 lines) | `llm(port, sys, user)` → string via local inference server |

### Key design decisions

- **Tagged pointers** — integers: `(v << 1) | 1`, heap objects: raw pointer (bit 0 = 0)
- **Object tags** — 1=Cons, 2=Nil, 3=Tuple, 4=Closure, 5=ADT, 6=Float. Mark bit at bit 63 for GC.
- **Size headers** — 8 bytes before every arena object. Enables GC sweep and free-list management.
- **Nested lambda flattening** — `\a -> \b -> body` compiles to a single multi-param closure. Direct application beta-reduces at compile time.
- **Tail-call optimization** — frame teardown + jump for constant-stack recursion
- **Self-hosting** — the compiler compiles itself and reaches a fixed point

## Backends

| Backend | Status | Target |
|---------|--------|--------|
| **ARM64 native** | Stable | macOS, Linux (cross-compile) |
| **Metal GPU** | Working | Apple Silicon compute shaders |
| **x86_64** | Sandboxed subset | Linux/Windows (experimental) |
| **WASM** | Compiles, runtime WIP | Browser/edge |

## Builtins

| Category | Functions |
|----------|-----------|
| **I/O** | `print`, `show`, `read_file`, `write_file`, `shell`, `cat` |
| **Lists** | `head`, `tail`, `cons`, `append`, `length`, `map`, `filter`, `fold`, `reverse`, `join`, `range` |
| **Strings** | `chars`, `split`, `append`, `trim` |
| **Math** | `not`, `to_float`, float arithmetic |
| **ADTs** | `type`, `match` with exhaustiveness warnings |
| **Concurrency** | `spawn`, `channel`, `send`, `recv` |
| **Memory** | `arena_mark`, `arena_reset` (GC handles the rest) |
| **FFI** | `foreign` declarations, `llm` builtin |
| **System** | `args`, `import` |

## Stdlib

22 modules in `stdlib/`:

`json` `http` `sqlite` `regex` `base64` `socket` `crypto` `csv` `datetime` `env` `fs` `hash` `math` `net` `os` `path` `process` `random` `sort` `string` `test` `toml`

## The Flywheel

Rail has a self-training loop: generate Rail code with an LLM, compile it to verify, harvest what works, train a better model. The compiler is the oracle.

```
Generate → Compile → Harvest → Train → Repeat
              ↑                    |
              └────────────────────┘
```

- 25-level curriculum with auto-advancement
- 4,500+ compiler-verified training examples
- Dual-node: Mac Mini M4 Pro (inference) + RTX 3070 (CUDA QLoRA training)
- Thinking mode inference with robust response parsing
- Trains on Qwen3.5-4B with LoRA targeting both self-attention and DeltaNet layers

The model doesn't just learn to write valid code — it learns to write code verified by the compiler that it's being trained to write for.

More: [ledatic.org](https://ledatic.org) | [ledatic.org/system](https://ledatic.org/system)

## Evolution

| Version | Date | What |
|---------|------|------|
| **v1.0.0** | 2026-03-17 | Self-hosting. Rust deleted. 67 tests. |
| **v1.1.0** | 2026-03-20 | Metal GPU backend, WASM, x86_64 sandbox, fibers |
| **v1.3.0** | 2026-03-21 | Flywheel, MCP server, 32-layer LoRA, open source |
| **v1.4.0** | 2026-03-22 | **GC, nested lambdas, exhaustiveness checking, 70 tests** |

## Numbers

| | Before | After |
|---|--------|-------|
| **Compiler** | 21,086 lines (Rust) | 1,979 lines (Rail) |
| **Binary** | ~8MB (Rust + Cranelift) | 329K (pure ARM64) |
| **Dependencies** | Cargo, Cranelift, Rayon | `as` + `ld` |
| **Build time** | ~30s (cargo build) | ~5s (self-compile) |
| **Tests** | 141 (Rust) | 70 (self-testing) |
| **Memory** | Rust runtime | 1GB arena + GC + malloc |

## License

BSL 1.1 — free for non-production and non-competitive use. Converts to MIT on 2030-03-14. See [LICENSE](LICENSE).
