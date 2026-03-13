# Rail

A pure functional, AI-native programming language.

Rail programs orchestrate local LLMs with the same ease that shell scripts orchestrate unix tools. The language is the agent runtime.

```
-- factorial in Rail
factorial : i32 -> i32
factorial n =
  if n <= 1 then 1 else n * factorial (n - 1)

main =
  let _ = print (factorial 10)
  0
```

## Why Rail

Every AI agent framework bolts LLM calls onto an imperative language and hopes for the best. Rail starts from the other direction: a pure functional language where AI is a first-class builtin, not a library.

- **Pure functions + AI builtins** — `prompt`, `prompt_with`, `prompt_json`, `embed` are language primitives
- **Sandboxed by default** — programs run in a capability sandbox. The conductor (you) decides what the AI can touch
- **Local-first** — auto-detects Anthropic, OpenAI, or local models (Ollama, MLX). No API key required for local
- **Self-evolving** — Rail programs can generate, validate, and compose other Rail programs

## Install

Build from source:

```bash
git clone https://github.com/zemo-g/rail
cd rail
cargo build --release
# binary at target/release/rail
```

Add to your PATH:

```bash
cp target/release/rail ~/.local/bin/
# or
sudo cp target/release/rail /usr/local/bin/
```

## Quick start

```bash
# Run a program
rail run examples/hello.rail

# With AI capabilities enabled
rail run examples/conductor.rail --allow ai --allow shell --allow fs:.

# Full access (development mode)
rail run examples/self_evolve.rail --open

# Native compilation (ARM64/x86_64 via Cranelift)
rail compile examples/hello.rail

# Interactive REPL
rail repl
```

## The conductor pattern

Rail's thesis: the program is the conductor, the LLM is the orchestra. You write deterministic logic that decides *when* and *how* to call AI, not the other way around.

```
-- Rail reads files, processes data, calls LLM, uses the result
summarize : String -> String
summarize content =
  prompt_with "Summarize this in one sentence." content

main =
  let files = shell_lines "ls src/"
  let code = read_file "src/main.rs"
  let summary = summarize code
  let _ = print summary
  0
```

No framework. No agent class. No tool registration. Just functions.

## Self-evolution

Rail can write Rail. This is the demo no other language can do natively:

```
generate_program : String -> String
generate_program task =
  prompt_with "You generate Rail code. Output ONLY code." task

validate : String -> String
validate code =
  let _ = write_file "/tmp/_rail_test.rail" code
  trim (shell "rail run /tmp/_rail_test.rail --open 2>/dev/null")

main =
  let code = generate_program "Write a Rail program that prints factorial of 6"
  let result = validate code
  let _ = print result
  0
```

The LLM generates a Rail program. Rail runs it. The output is checked. All in 10 lines. Proven working with Qwen 9B locally — zero training data, zero fine-tuning.

## Route system (capabilities)

Programs are sandboxed by default. You grant capabilities explicitly:

```bash
rail run app.rail                                  # sandbox — pure computation only
rail run app.rail --allow ai                       # LLM calls permitted
rail run app.rail --allow shell --allow fs:/data   # shell + scoped filesystem
rail run app.rail --allow net:api.example.com      # network to specific host
rail run app.rail --open                           # full access
```

Available capabilities: `fs:/path`, `net:host`, `shell`, `ai`, `env:VAR`, `all`.

Every system builtin checks the route before executing. Violations produce clear errors with hints:

```
error: shell access denied
hint: rail run file.rail --allow shell
```

## Language features

```
-- Type signatures (optional, Hindley-Milner inference)
add : i32 -> i32 -> i32
add x y = x + y

-- Curried functions
inc : i32 -> i32
inc = add 1

-- Algebraic data types
type Option T =
  | Some T
  | None

-- Records
type Point =
  x: f64
  y: f64

-- Pattern matching
describe : i32 -> String
describe n =
  match n
    0 -> "zero"
    1 -> "one"
    _ -> "many"

-- Pipes
main =
  let result = "hello world" |> split " " |> length
  let _ = print result
  0

-- Lambdas (single and multi-line)
transform = \x ->
  let doubled = x * 2
  doubled + 1

-- Tail-call optimization
loop : i32 -> i32 -> i32
loop n acc =
  if n <= 0 then acc else loop (n - 1) (acc + n)
```

Types: `i32`, `f64`, `String`, `Bool`, `[T]` (lists), `(A, B)` (tuples), ADTs, records.

Operators: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`

## System builtins

| Builtin | Description |
|---------|-------------|
| `print` | Print to stdout |
| `prompt msg` | Ask the LLM |
| `prompt_with system msg` | Ask with system prompt |
| `prompt_json system msg` | Parse LLM response as JSON |
| `embed text` | Get embedding vector |
| `shell cmd` | Execute shell command |
| `shell_lines cmd` | Shell output as list of lines |
| `read_file path` | Read file contents |
| `write_file path content` | Write file |
| `http_get url` | HTTP GET |
| `http_post url body` | HTTP POST |
| `json_parse str` | Parse JSON string |
| `json_get key obj` | Extract JSON field |
| `env var` | Read environment variable |
| `timestamp` | Unix timestamp |
| `sleep_ms n` | Sleep milliseconds |

All system builtins are gated by the route capability system.

## Module system

```
import Math (square, gcd, factorial)

main =
  let _ = print (square 7)
  let _ = print (gcd 12 8)
  0
```

Stdlib modules: `Math`, `String`, `Prelude` (auto-imported). Custom modules resolved from source directory.

Math exports: `square`, `cube`, `is_even`, `is_odd`, `gcd`, `lcm`, `factorial`, `fib`, `clamp`, `lerp`

String exports: `words`, `unwords`, `lines`, `unlines`, `is_empty`, `repeat_str`

## Two backends

- **Interpreter**: tree-walking with trampoline TCO. Runs everything including AI builtins.
- **Native compiler**: Cranelift JIT targeting ARM64/x86_64. Fast numeric computation.

```bash
rail run program.rail      # interpreter
rail compile program.rail  # native
```

## AI provider detection

Rail auto-detects your LLM setup:

| Environment | Provider |
|------------|----------|
| `ANTHROPIC_API_KEY` set | Anthropic (Claude) |
| `OPENAI_API_KEY` set | OpenAI |
| Local server on :8080 | MLX / Ollama / llama.cpp |
| `RAIL_AI_MOCK=1` | Mock (for testing) |

No configuration files. No YAML. It just works.

## Project setup

```bash
rail init my-project
cd my-project
rail run src/main.rail
```

Creates `rail.toml` manifest and `src/main.rail` entry point.

## Testing

```bash
cargo test
```

109 tests covering the full pipeline: lexer, parser, interpreter, type checker, route system, and all example programs.

## Status

Rail is v0.2.0. The language, interpreter, type checker, native compiler, module system, AI builtins, and capability system all work. It has been proven to bootstrap itself — a local 9B parameter model generates correct Rail programs zero-shot from the language grammar alone.

Known limitations:
- Tuple destructuring in `let` bindings not yet supported — use `match`
- No recursion depth limit — non-terminating recursion will hang
- Operator sections like `(* 2)` not supported — use lambdas: `\x -> x * 2`

What's coming: crates.io publishing, package manager, LSP, more stdlib.

## License

MIT
