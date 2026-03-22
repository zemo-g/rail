# Rail

[![tests: 67/67](https://img.shields.io/badge/tests-67%2F67-brightgreen)](#)
[![self-hosting](https://img.shields.io/badge/self--hosting-fixed%20point-blue)](#)
[![ARM64](https://img.shields.io/badge/target-ARM64-orange)](#)
[![dependencies: 0](https://img.shields.io/badge/dependencies-0-brightgreen)](#)
[![License: BSL 1.1](https://img.shields.io/badge/license-BSL%201.1-green)](LICENSE)

A programming language that deleted its own compiler.

```
-- Rail compiles itself. This is the entire bootstrap:
--   ./rail_native self && cp /tmp/rail_self ./rail_native
--
-- 1,774 lines of Rail replaced 21,086 lines of Rust.
-- The compiler is a fixed point of itself.

add a b = a + b

main =
  let _ = print (show (fold add 0 [1,2,3,4,5]))
  0
```

## What happened

Rail was originally written in Rust — 21K lines: interpreter, parser, type checker, LSP, formatter, Cranelift JIT backend, the works.

Then the ARM64 native compiler was rewritten in Rail itself (`tools/compile.rail`). On March 16, 2026:

1. The Rail compiler compiled itself to a native ARM64 binary
2. That binary compiled the compiler again
3. The output was byte-identical (fixed point)
4. The Rust was deleted

The language now bootstraps from a 297K seed binary. No Rust. No Cargo. No dependencies beyond macOS `as` + `ld`.

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
# Already built — the seed binary is in the repo:
./rail_native run examples/hello.rail
```

Apple Silicon only (ARM64 macOS). Linux ARM64 cross-compilation supported.

### Rebuild from source (optional)

```bash
./rail_native self                    # compiles itself → /tmp/rail_self
cp /tmp/rail_self ./rail_native       # install
./rail_native test                    # 67/67
```

## Usage

```bash
./rail_native <file.rail>             # compile to /tmp/rail_out
./rail_native run <file.rail>         # compile + execute
./rail_native test                    # run 67-test suite
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
-- Recursion
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

-- Higher-order functions (fold requires named function, not lambda)
sum_sq acc x = acc + x * x

main =
  let result = fold sum_sq 0 [1,2,3,4,5]
  let _ = print (show result)
  0
```

```
-- Lists, strings, I/O
main =
  let words = split " " "hello world"
  let reversed = join " " (reverse words)
  let _ = print reversed
  let _ = write_file "/tmp/test.txt" reversed
  0

-- Pipe operator
inc x = x + 1
main =
  let r = [1,2,3] |> reverse |> head |> inc
  let _ = print (show r)
  0

-- Shell integration
main =
  let date = shell "date +%Y-%m-%d"
  let _ = print date
  0
```

## How it works

The compiler (`tools/compile.rail`, 1,774 lines) does:

1. **Lexer** — tokenizes Rail source into a token stream
2. **Parser** — builds an AST from tokens (lists with tag strings)
3. **Codegen** — walks the AST, emits ARM64 assembly
4. **Build** — calls `as` + `ld` to produce a Mach-O binary

Key implementation details:
- **Tagged pointers** — integers: `(v << 1) | 1`, strings/heap objects: raw pointer (bit 0 = 0)
- **1GB bump allocator** — no GC, just allocate forward. Arena mark/reset for loops.
- **Tail-call optimization** — frame teardown + jump for constant-stack recursion
- **Closures** — inline lambda functions with captured variables
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
| **ADTs** | `type`, `match` with pattern matching |
| **Concurrency** | `spawn`, `channel`, `send`, `recv` |
| **Memory** | `arena_mark`, `arena_reset` |
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
- Quality scoring: binary size + execution time on every compile
- Dual-node: Mac Mini (inference) + RTX 3070 (CUDA QLoRA training)
- Thinking mode inference with robust response parsing
- GRPO reward function wired to compiler exit code

The model doesn't just learn to write valid code — it learns to write *fast* code. The compiler evolves the AI that writes the language the compiler is written in.

More: [ledatic.org](https://ledatic.org) | [ledatic.org/system](https://ledatic.org/system)

## Numbers

| | Before | After |
|---|--------|-------|
| **Compiler** | 21,086 lines (Rust) | 1,774 lines (Rail) |
| **Binary** | ~8MB (Rust + Cranelift) | 297K (pure ARM64) |
| **Dependencies** | Cargo, Cranelift, Rayon | `as` + `ld` |
| **Build time** | ~30s (cargo build) | ~5s (self-compile) |
| **Tests** | 141 (Rust) | 67 (self-testing) |

## License

BSL 1.1 — free for non-production and non-competitive use. Converts to MIT on 2030-03-14. See [LICENSE](LICENSE).
