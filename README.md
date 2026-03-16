# Rail

A programming language that deleted its own compiler.

```
-- Rail compiles itself. This is the entire bootstrap:
--   ./rail_native self && cp /tmp/rail_self ./rail_native
--
-- 950 lines of Rail replaced 21,086 lines of Rust.
-- The compiler is a fixed point of itself.

main =
  let src = read_file "tools/compile.rail"
  let asm = compile_program src
  let _ = build asm
  print "Self-compilation complete."
```

## What happened

Rail was originally written in Rust — 21K lines: interpreter, parser, type checker, LSP, formatter, Cranelift JIT backend, the works.

Then the ARM64 native compiler was rewritten in Rail itself (`tools/compile.rail`). On March 16, 2026:

1. The Rail compiler compiled itself to a native ARM64 binary
2. That binary compiled the compiler again
3. The output was byte-identical (fixed point)
4. The Rust was deleted

The language now bootstraps from a 186K seed binary. No Rust. No Cargo. No dependencies beyond macOS `as` + `ld`.

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
# Already built — the seed binary is in the repo:
./rail_native run examples/hello.rail
```

Apple Silicon only (ARM64 macOS). No build step needed.

### Rebuild from source (optional)

```bash
./rail_native self           # compiles itself → /tmp/rail_self
cp /tmp/rail_self ./rail_native   # install
./rail_native test           # 34/34
```

## Usage

```bash
./rail_native <file.rail>           # compile to /tmp/rail_out
./rail_native run <file.rail>       # compile + execute
./rail_native test                  # run 34-test suite
./rail_native self                  # self-compile (bootstrap)
```

## The language

```
-- Functions
double x = x * 2
add x y = x + y

-- Recursion with tail-call optimization
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

-- Let bindings
main =
  let a = 7
  let b = a * a
  b - 1

-- Strings
greet name = print (append "hello, " name)

-- Lists
main = head (map double [3, 5, 7])

-- Tuples
swap a b = (b, a)
main =
  let (x, y) = swap 1 2
  x * 10 + y

-- Lambdas with closures
main =
  let n = 100
  head (map (\x -> x + n) [1, 2, 3])

-- File I/O, shell
main =
  let _ = write_file "/tmp/out.txt" "hello"
  let s = read_file "/tmp/out.txt"
  let _ = print s
  0
```

## How it works

The compiler (`tools/compile.rail`, ~950 lines) does:

1. **Lexer** — tokenizes Rail source into a token stream
2. **Parser** — builds an AST from tokens (lists with tag strings)
3. **Codegen** — walks the AST, emits ARM64 assembly
4. **Build** — calls `as` + `ld` to produce a Mach-O binary

Key implementation details:
- **Tagged pointers** — integers: `(v << 1) | 1`, strings/heap objects: raw pointer (bit 0 = 0)
- **256MB bump allocator** — no GC, just allocate forward
- **Tail-call optimization** — frame teardown + jump for constant-stack recursion
- **2048-byte stack frames** — fits functions with 250+ local variables
- **Closures** — inline lambda functions with captured variables
- **Self-hosting** — the compiler compiles itself and reaches a fixed point

## Builtins

| Category | Functions |
|----------|-----------|
| **I/O** | `print`, `show`, `read_file`, `write_file`, `shell` |
| **Lists** | `head`, `tail`, `cons`, `append`, `length`, `map`, `join` |
| **Strings** | `chars`, `split`, `append` |
| **System** | `args` |

## What's not here (yet)

The self-hosting compiler handles the subset of Rail needed to compile itself. These features existed in the Rust implementation and can be re-added incrementally:

- Pattern matching / ADTs
- Floats
- Records
- Algebraic effects
- Modules / imports
- Type checker
- LSP / formatter / REPL
- AI builtins

The Rust code is preserved in git history if needed.

## Numbers

| | Before | After |
|---|--------|-------|
| **Compiler** | 21,086 lines (Rust) | 950 lines (Rail) |
| **Binary** | ~8MB (Rust + Cranelift) | 186K (pure ARM64) |
| **Dependencies** | Cargo, Cranelift, Rayon | `as` + `ld` |
| **Build time** | ~30s (cargo build) | ~5s (self-compile) |
| **Tests** | 141 (Rust) | 34 (self-testing) |

## License

BSL 1.1 — free for non-production and non-competitive use. Converts to MIT on 2030-03-14. See [LICENSE](LICENSE).
