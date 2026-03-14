# Rail

R Artifical Intellgence Language.

```
-- 6 parallel LLM calls. 8 lines. No framework.
main =
  let topic = trim (read_file "topic.txt")
  let angles = ["{topic} — foundational", "{topic} — contrarian", "{topic} — applied"]
  let questions = par_prompt "Ask a research question." angles
  let answers = par_prompt "Answer concisely." questions
  let u = llm_usage ()
  print "Done: {u.calls} calls, {u.total_tokens} tokens"
```

## What this is

Rail is a pure functional language where LLM calls are builtins, not libraries. You write the logic. The LLM does the work. The language is the agent runtime.

- **Agent loops** — multi-turn tool use is a language primitive, not a framework
- **Parallel by default** — `par_prompt` fans out LLM calls in batches. Write sequential code, get concurrent execution
- **Sandboxed** — programs run in a capability sandbox. You decide what AI can touch
- **Local-first** — auto-detects Anthropic, OpenAI, or local models (MLX, Ollama, llama.cpp)
- **Self-evolving** — Rail programs generate, validate, and run other Rail programs. Proven with a 9B model at 92% accuracy
- **Algebraic effects** — `perform`/`handle`/`resume` for composable, testable side effects
- **10K lines of Rust** — 141 tests, LSP, formatter, test runner, two compilation backends

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
cargo build --release
cp target/release/rail ~/.local/bin/   # or anywhere on PATH
```

Requires Rust 1.85+ (2024 edition). Two dependencies: Cranelift, Rayon.

## 30-second tour

```bash
rail run examples/hello.rail                           # pure computation, sandboxed
rail run examples/researcher.rail --allow ai           # with LLM access
rail run examples/self_evolve.rail --open              # full access
rail repl                                              # interactive mode
```

```
-- Functions
add : i32 -> i32 -> i32
add x y = x + y

-- Pattern matching
describe n =
  match n
    0 -> "zero"
    1 -> "one"
    _ -> "many"

-- Pipes, lambdas, string interpolation
main =
  let result = [1, 2, 3] |> map (\x -> x * 2) |> length
  print "got {result} items"
```

## Agent primitives

Multi-turn tool-use agents are a language construct:

```
search query = prompt_with "You are a search engine." query
calculate expr = prompt_with "Evaluate this expression." expr

main =
  let tools = [("search", "Look up facts"), ("calculate", "Do math")]
  let fns = [search, calculate]
  let result = agent_loop "You are a research assistant." tools fns "What is 7 * the population of Tokyo?"
  print result.answer
```

Conversations with memory:

```
main =
  let ctx = context_new "You are a patient tutor."
  let (ctx, r1) = context_prompt ctx "What is recursion?"
  let (ctx, r2) = context_prompt ctx "Give me a simple example"
  print r2
```

Structured output with automatic retry:

```
let person = prompt_typed "Extract info" '{"name": "str", "age": "int"}' text
print person.name
```

## Capability sandbox

Programs can't do anything by default. You grant access explicitly:

```bash
rail run app.rail                        # pure computation only
rail run app.rail --allow ai             # LLM calls
rail run app.rail --allow shell          # shell commands
rail run app.rail --allow fs:/data       # filesystem under /data
rail run app.rail --allow net:api.com    # network to specific host
rail run app.rail --open                 # everything (development)
```

Violations produce clear errors with fix hints:

```
error: shell access denied
hint: rail run file.rail --allow shell
```

## Self-evolution

Rail can write Rail — the demo no other language does natively:

```
generate task = prompt_with "Generate Rail code. Output ONLY code." task

validate code =
  let _ = write_file "/tmp/_test.rail" code
  trim (shell "rail run /tmp/_test.rail --open 2>/dev/null")

main =
  let code = generate "Write a Rail program that prints fibonacci of 10"
  print (validate code)
```

LLM generates a program. Rail runs it. Output verified. 10 lines. Works with local 9B models, zero fine-tuning.

## Algebraic effects

First-class `perform`/`handle`/`resume` — pure, composable, testable:

```
effect Ask
  ask : String -> String

interview _ =
  let name = perform ask "name"
  let color = perform ask "color"
  "{name} likes {color}"

main =
  let r = handle (interview ()) with
    ask q -> if q == "name" then resume "Alice" else resume "blue"
  print r   -- "Alice likes blue"
```

## Developer tools

```bash
rail fmt file.rail            # format source
rail fmt file.rail --check    # check formatting (CI)
rail test file.rail           # run test_ functions
rail lsp                      # language server (VSCode extension in editors/vscode/)
rail repl                     # interactive mode with :help, history
rail check file.rail          # type-check without running
rail init my-project          # scaffold a new project
```

Write tests as `test_` functions:

```
test_math _ = 1 + 1 == 2
test_strings _ = append "a" "b" == "ab"
test_lists _ = length [1, 2, 3] == 3
```

```bash
$ rail test my_tests.rail
running 3 test(s)...
  ✓ test_math
  ✓ test_strings
  ✓ test_lists
3 passed
```

## Builtins

**AI**: `prompt`, `prompt_with`, `prompt_model`, `prompt_json`, `prompt_typed`, `prompt_stream`, `par_prompt`, `agent_loop`, `context_new`, `context_push`, `context_prompt`, `embed`, `llm_usage`, `llm_reset`

**Collections**: `map`, `filter`, `fold`, `head`, `tail`, `length`, `range`, `cons`, `append`, `reverse`, `sort`, `zip`, `enumerate`, `par_map`, `par_filter`

**Strings**: `split`, `join`, `trim`, `chars`, `contains`, `starts_with`, `ends_with`, `to_upper`, `to_lower`, `replace`, `substring`

**System**: `shell`, `shell_lines`, `read_file`, `write_file`, `http_get`, `http_post`, `json_parse`, `json_get`, `env`, `timestamp`, `sleep_ms`

**Math**: `sqrt`, `pow`, `log`, `sin`, `cos`, `tan`, `abs`, `max`, `min`, `pi`, `e`

All system builtins are gated by the capability sandbox.

## Language

- **Types**: `i32`, `f64`, `String`, `Bool`, `[T]`, `(A, B)`, ADTs, records
- **Inference**: full Hindley-Milner — type signatures are optional
- **TCO**: trampoline-based tail call optimization (100K+ recursive calls, constant stack)
- **Modules**: `import Math (square, gcd)` — stdlib: Math, String, Prelude
- **Two backends**: interpreter (full features) + Cranelift JIT (ARM64/x86_64, numeric subset)
- **Hot reload**: `rail serve file.rail --watch` — state survives reloads
- **Operators**: `+` `-` `*` `/` `%` `==` `!=` `<` `>` `<=` `>=` `&&` `||` `|>`

## AI provider detection

No configuration files. Rail checks in order:

1. `RAIL_AI_PROVIDER` env var (anthropic / openai / local / mock)
2. `ANTHROPIC_API_KEY` → Anthropic
3. `OPENAI_API_KEY` → OpenAI
4. Default → mock provider (for testing without API keys)

Local endpoint: `http://localhost:8080/v1/chat/completions` (works with MLX, Ollama, llama.cpp, vLLM).

## Status

v0.6.0 — 10,145 lines of Rust, 141 tests, 23 examples.

Built and tested on macOS (ARM64). CI runs on macOS + Linux.

## License

BSL 1.1 — free for non-production and non-competitive use. Converts to MIT on 2030-03-14. See [LICENSE](LICENSE).
