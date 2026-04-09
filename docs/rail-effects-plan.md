---
name: Rail Effects Implementation Plan
description: Complete implementation plan for algebraic effect handlers, auto-parallelization, and hot code reloading in Rail. Includes architectural analysis, code locations, Rust diffs needed, and Grok's refinements.
type: project
---

## Rail — Three Feature Implementation Plan (2026-03-14)

### Execution Order
Effects (foundation) → Auto-Parallel (uses effects) → Hot Reload (uses effects + modules)

---

## FEATURE 1: Algebraic Effect Handlers

### What It Does
Effects (`IO`, `State`, `Async`, `LLM`, `Shell`) become first-class composable values. The existing route/capability system becomes effect *handlers* instead of permission flags. `--allow shell` installs the real `Shell` handler; without it, default handler raises error.

### Rail Syntax

```rail
-- Declare an effect
effect LLM
  ask : String -> String

effect Log
  log : String -> ()

-- Use effects (perform triggers the handler)
analyze : String -> String ! {LLM, Log}
analyze input =
  let _ = perform log "Starting analysis"
  perform ask (append "Analyze: " input)

-- Handle effects (install handlers that intercept perform)
handle (analyze "data") with
  ask prompt -> resume (prompt_with "You are an analyst" prompt)
  log msg -> let _ = print_err msg in resume ()
```

### Implementation Steps

#### Step 1: New AST Nodes (`src/ast.rs`)
Add to `Decl` enum:
```rust
EffectDecl {
    name: String,
    operations: Vec<(String, TypeExpr)>,  // [(op_name, signature)]
}
```

Add to `ExprKind` enum:
```rust
Perform {
    effect_op: String,          // "ask", "log"
    args: Vec<Expr>,
}
Handle {
    body: Box<Expr>,
    handlers: Vec<EffectHandler>,  // one per operation
    return_handler: Option<Box<Expr>>,  // optional: transform final value
}
Resume {
    value: Box<Expr>,           // value to feed back to perform site
}
```

New struct:
```rust
struct EffectHandler {
    op_name: String,
    params: Vec<Pattern>,       // args from perform
    body: Expr,                 // handler body (must call resume exactly once)
}
```

#### Step 2: Lexer Changes (`src/lexer.rs`)
New keywords: `effect`, `perform`, `handle`, `with`, `resume`
- `effect` and `with` may already be reserved — check token list
- `perform`, `handle`, `resume` are new

#### Step 3: Parser Changes (`src/parser.rs`)
- `parse_effect_decl()` — after seeing `effect` keyword at top level
- `parse_perform_expr()` — `perform <op> <args...>`
- `parse_handle_expr()` — `handle <expr> with <newline> <indent> <handlers> <dedent>`
- Each handler line: `<op_name> <params> -> <body>`
- `parse_resume_expr()` — `resume <expr>`

#### Step 4: Interpreter Changes (`src/interpreter.rs`) — THE CORE

**New Value variant:**
```rust
Value::Continuation {
    saved_env: Env,
    saved_computation: Box<Expr>,  // remaining computation after perform
    handler_stack: Vec<HandlerFrame>,  // stack above the perform point
}
```

Make continuation exactly-once:
```rust
// Internally wrap in Option, panic on double-use
Value::Continuation(Option<ContinuationInner>)
// When resume is called, .take() the inner — second call gets None → runtime error
```

**Handler stack:** Add to Interpreter struct:
```rust
struct Interpreter {
    // ... existing fields ...
    handler_stack: Vec<HandlerFrame>,
}

struct HandlerFrame {
    effect_name: String,
    handlers: HashMap<String, (Vec<Pattern>, Expr, Env)>,  // op → (params, body, captured_env)
}
```

**Eval changes:**
- `ExprKind::Perform` → walk handler_stack top-down looking for matching op
  - When found: capture continuation (current env + remaining computation)
  - Call handler body with args + continuation as `resume`
  - If no handler found → runtime error: "unhandled effect: LLM.ask"
- `ExprKind::Handle` → push HandlerFrame onto stack, eval body, pop frame
- `ExprKind::Resume` → restore continuation: set env, eval saved computation with the resume value as the result of the original perform

**Continuation capture strategy (interpreter-first, simple):**
Rather than capturing the actual call stack, use CPS (continuation-passing style) transformation at eval time:
- When `perform` is hit, the "rest of the computation" is whatever expression would have used the perform's return value
- In a let binding: `let x = perform ask "hi" in f x` → continuation is `\x -> f x`
- In a pipe: `perform ask "hi" |> process` → continuation is `\v -> process v`
- This avoids stack copying entirely — continuations are just closures

#### Step 5: Type Checker Changes (`src/typechecker.rs`)
- Register effect declarations (name → operations with types)
- `perform` infers return type from effect operation signature
- Effect rows: `Type::Fun` gains optional effect set `! {E1, E2}`
  - Start simple: just check that perform'd effects have handlers
  - Full effect polymorphism can come later
- `handle` discharges effects from the row

#### Step 6: Route Integration
- Define built-in effects: `effect IO`, `effect Shell`, `effect AI`, `effect Net`
- `--allow shell` → installs default Shell handler that delegates to `std::process::Command`
- `--allow ai` → installs default AI handler that delegates to `ai::call_llm()`
- Without flag → default handler that returns error with hint message
- This replaces the current `route.check_*()` calls in builtins with effect performs
- **Migration path**: keep old builtins working (backward compat), add effect versions alongside

### Grok's Refinements (incorporated)
1. **Exactly-once resume**: `Option<ContinuationInner>` — `.take()` on use, runtime error on double-use. MUST DO in v1.
2. **Handler cache**: Cache handler pointer in thread-local after first lookup. DO LATER — only if profiling shows O(depth) handler search is bottleneck.
3. **Segmented stacks**: Switch from full stack copy to 8KB segments. DO LATER — CPS approach avoids stack copying entirely.

### Tests to Write
- Basic perform/handle/resume round-trip
- Nested handlers (inner shadows outer)
- Effect not handled → clear error
- Double resume → runtime error
- Resume with wrong type → type error
- Multiple effects composed
- Route-as-handler backward compat

---

## FEATURE 2: Auto-Parallelization — PHASE A+C DONE (2026-03-14)

### What It Does
`map prompt_with tasks` automatically fans out across cores/LLM instances. Pure functions parallelize via Rayon. Effectful code (LLM calls) gets safe concurrent fan-out via Parallel effect handler.

### DONE
- `par_map`, `par_filter` builtins (Rayon, arity 2, sequential fallback for < 4 elements)
- Purity analysis: `purity.rs` with `is_pure_value()` runtime check
- Auto-promotion: `map`/`filter` auto-parallelize when pure + list >= 8 elements
- 7.3x speedup on M4 Pro (10x fib(35)), 92/92 tests pass
- Value is Send (Rc only in HandleContext, not in Value)

### Key Insight (from Grok)
LLM calls are *effectful* — pure-only auto-parallel misses the main use case. Solution: make Parallelism itself an effect.

### Rail Syntax

```rail
effect Parallel
  fork : (() -> a) -> a

-- Parallel LLM calls — handler decides how to fan out
handle (par_map (prompt_with system) inputs) with
  fork f -> rayon_spawn (fn () -> resume (f ()))

-- Or: LLM pool handler
handle (par_map (prompt_with system) inputs) with
  fork f -> llm_pool_submit (fn () -> resume (f ()))
```

### Implementation Steps

#### Step 1: Purity Analysis (`src/purity.rs` — NEW FILE)
```rust
enum Purity { Pure, Effectful(HashSet<String>) }

fn analyze_purity(decls: &[Decl]) -> HashMap<String, Purity> {
    // Walk AST, tag each function
    // Pure = no `perform`, no effectful builtins
    // Effectful = set of effects performed (transitively)
    // Propagate: if f calls g and g is Effectful, f is Effectful
}
```

#### Step 2: Explicit par_map Builtin (Phase A — immediate value)
- Add `par_map` builtin in `interpreter.rs`
- Implementation: `rayon::scope` + work-stealing
- Only for pure functions initially
- Add `rayon` to Cargo.toml

#### Step 3: Parallel Effect (Phase B+C — uses effect system)
- Define `effect Parallel { fork : (() -> a) -> a }`
- Default handler: sequential (safe fallback)
- Rayon handler: `fork f -> rayon::spawn(|| resume(f()))`
- Async handler: `fork f -> tokio::spawn(async { resume(f()) })` (for LLM I/O)

#### Step 4: Auto-Promotion
- If `map f xs` where `f` is Pure and `xs.len() > threshold` → use parallel path
- Compiler inserts `handle ... with parallel_handler` automatically
- User can override with explicit sequential `map`

### Rust Dependencies
- `rayon` — CPU work-stealing parallelism
- LLM fan-out uses `std::thread::scope` + blocking HTTP (already using curl via Command)

---

## FEATURE 3: Hot Code Reloading

### What It Does
Swap Rail modules while a conductor program runs 24/7. Update LLM prompts, processing logic, analysis pipelines — without killing live sessions.

### Rail Syntax

```rail
-- Version stamps on types
type State v1 = { count : i32 }
type State v2 = { count : i32, label : String }

-- Migration function (required if shape changes)
migrate v1 v2 old = { count = old.count, label = "default" }

-- React to reloads
effect HotReload
  on_reload : Module -> ()
```

### Implementation Steps

#### Step 1: Module Versioning (`src/modules.rs`)
- Each loaded module gets version stamp: `(file_path, mtime_or_hash)`
- Store in `Interpreter` struct: `loaded_modules: HashMap<String, ModuleVersion>`
- `watch_module` builtin: register file watcher (notify crate)
- On file change → re-lex, re-parse, re-typecheck the module

#### Step 2: Live Function Replacement (`src/interpreter.rs`)
- Module functions stored in `Env` as closures
- On reload: replace closure values in env with new versions
- Active calls to old version complete normally (old closure value still valid in local env)
- New calls get new version (next env lookup hits new closure)
- This is safe because closures are immutable values in Rail

#### Step 3: Registered State (`src/migration.rs` — NEW FILE)
- Top-level `State` records registered with runtime
- `register_state "name" initial_value` builtin
- `get_state "name"` / `set_state "name" value` builtins (effectful — requires State effect)
- On reload: runtime walks registered state values
- If record shape changed → look for `migrate` declaration → run it
- If no migration and shapes differ → error, refuse reload

#### Step 4: HotReload Effect
- `effect HotReload { on_reload : Module -> () }`
- When module reloads, runtime `perform on_reload new_module`
- User handler can: drain queues, flush caches, log, etc.

#### Step 5: CLI Support
- `rail serve program.rail --watch` — run program, watch imports, hot-reload on change
- `rail reload <module>` — manual trigger via Unix signal or IPC pipe

#### Step 6 (v2): Continuation Environment Migration
- Walk `Value::Continuation` captured envs for old-shape records
- Run same migration logic on captured values
- This handles closures that closed over old record shapes

### Rust Dependencies
- `notify` crate — cross-platform filesystem watching

---

## CRITICAL BUG FIX (2026-03-14): HandleContext Memory Explosion

The effects example crashed the Mac Mini due to exponential memory growth.

**Root cause**: `HandleContext` stored `body: Expr` — every `resume` deep-cloned the entire AST. With recursive handlers, each resume doubled the allocation, causing exponential memory growth.

**Fix applied** (4 changes):
1. `body: Expr` → `body: Rc<Expr>` in `HandleContext` — shared ownership instead of deep clone
2. `Rc::new((**body).clone())` at context creation — single clone, wrapped once
3. `Rc::clone(...)` in resume — refcount bump (O(1)) instead of deep copy (O(n))
4. Safety valve — 100-context recursion limit catches infinite resume loops before they eat memory

**Result**: Effects example runs instantly with zero memory growth.

---

## CURRENT RAIL ARCHITECTURE (for fresh session context)

### Codebase: `~/projects/rail/` — 7,044 lines across 13 Rust modules

```
src/
├── main.rs (395)       — CLI: run, repl, check, native subcommands
├── lexer.rs (543)      — Indentation-based tokenizer (Indent/Dedent tokens)
├── token.rs (81)       — 30 token types
├── parser.rs (953)     — Recursive descent, handles indentation
├── ast.rs (243)        — 10 Decl types, 12+ ExprKind variants
├── interpreter.rs (1285) — Tree-walking eval, TCO trampoline, 59 builtins
├── typechecker.rs (1265) — Hindley-Milner inference, let-polymorphism
├── codegen.rs (880)    — Cranelift JIT (ints, floats, strings, TCO — no closures)
├── ai.rs (544)         — LLM integration (Anthropic/OpenAI/local/mock auto-detect)
├── route.rs (351)      — Capability sandbox (fs, net, shell, ai, env)
├── modules.rs (216)    — 5-tier module resolution + embedded stdlib
├── repl.rs (266)       — Interactive interpreter
└── stdlib.rs (22)      — Embedded Math, String, Prelude
```

### Key Runtime Types

```rust
// Values
enum Value {
    Int(i64), Float(f64), Str(String), Bool(bool), Unit,
    Tuple(Vec<Value>), List(Vec<Value>),
    Record(Vec<(String, Value)>),           // linear field search
    Constructor { name: String, args: Vec<Value> },
    Closure { params: Vec<Pattern>, body: Expr, env: Env },
    BuiltIn(BuiltIn),
}

// Builtins — curried via partial application
enum BuiltIn {
    Fn { name: String, arity: usize, args: Vec<Value> },
    ConstructorFn { name: String, arity: usize, applied: Vec<Value> },
}

// TCO trampoline
enum EvalResult {
    Value(Value),
    TailCall { params: Vec<Pattern>, body: Expr, env: Env, arg: Value },
}

// Routes (capability sandbox)
struct Route {
    fs_paths: Vec<String>,    // prefix-matched
    net_hosts: Vec<String>,   // exact match
    shell: bool, ai: bool,
    env_vars: Vec<String>,    // or "*"
    allow_all: bool,
}
```

### Interpreter Flow
1. Builtins registered on creation (59 total, each with name + arity)
2. `apply_builtin()` accumulates args via partial application until arity met
3. `exec_builtin()` dispatches by name match — route-gated builtins check `self.route` first
4. TCO: `eval_tail()` detects tail position → returns `TailCall` → trampoline loop in `apply()`
5. Closures capture env (HashMap clone)

### Type Checker
- Hindley-Milner with unification via substitution array
- Let-polymorphism: quantified type vars → fresh instances on use
- No effect rows yet (this is what Feature 1 adds)
- Two-pass: register declarations, then check bodies

### Cranelift JIT (`codegen.rs`)
- Compiles: ints, floats, strings, arithmetic, comparisons, if/else, recursion+TCO
- Does NOT compile: closures, lambdas, ADTs, pattern matching, lists, records, builtins
- TCO via loop-header-jump (back-edge to loop block with new params)
- Run with `rail native program.rail`

### Module System
- 5-tier resolution: source-relative → embedded stdlib → project stdlib → ~/.rail/stdlib → exe-adjacent
- `import Math (square, gcd)` — loads module, extracts named functions
- Embedded: Math, String, Prelude via `include_str!()`

### AI Integration
- Provider detection priority: RAIL_AI_PROVIDER env > API key presence > localhost:8080 > mock
- `call_llm()` dispatches to anthropic/openai/local/mock
- No external HTTP crate — uses `curl` via `std::process::Command`
- Response parsing is hand-coded (no regex, no JSON crate)

---

## KNOWN BUGS TO FIX (from autoresearch 94.4% run)

### Bug 1: Multi-line if/else Parser Limitation
**Location**: `src/parser.rs` lines 363-380 (`parse_if_expr()`)
**Problem**: After `else` keyword, parser calls `parse_expr()` which cannot handle `Indent` tokens. Multi-line else blocks fail with "expected expression, got Indent".
**Impact**: count_down task fails (34/36 → could be 35/36)
**Fix**: Check for `Token::Indent` after `else`, if present call `parse_block()` instead of `parse_expr()`. Same fix needed for `then` branch. Pattern already exists in `parse_func_decl()` and `parse_lambda()`.

### Bug 2: Operator Precedence with && and Comparisons
**Location**: `src/interpreter.rs` line 1239
**Problem**: `n % 3 == 0 && n % 5 == 0` evaluates as `n % 3 == (0 && n) % 5 == 0` due to precedence. The `&&` receives Int operands instead of Bool.
**Impact**: fizzbuzz_15 task fails — runtime error "type error: 0 && 0"
**Fix**: Check parser precedence table — `&&` should bind looser than `==`. May need explicit parenthesization in generated code or parser precedence fix.

### Recommendation
Fix both bugs BEFORE starting effects work — they're small parser/precedence fixes that immediately improve autoresearch score to potentially 36/36. Good warmup for the parser changes effects will need.

---

## AUTORESEARCH STATUS

- **Best score**: 94.4% (34/36) — iteration 2
- **Best params**: grammar_style=example_heavy, num_examples=10, temp=0.5, builtins=true, gotchas=false
- **36 tasks**: 9 easy (100%), 15 medium (86.7%), 12 hard (100%)
- **2 failures**: fizzbuzz_15 (precedence bug), count_down (parser bug) — both language bugs, not model weakness
- **27B model** (Qwen3.5-27B-Claude-Opus-Distilled-4bit) hitting same ceiling as 9B — confirms these are language bugs
- **Autoresearch script**: `~/projects/rail/tools/autoresearch.py`
- **Results**: `~/projects/rail/tools/autoresearch_results/results.jsonl`
- **MLX 27B**: on :8082 (PID 97009), idle, ready for 50-100 iteration overnight run
- **Timing**: ~20 min/iteration on 27B, so 50 iterations ≈ 17 hours, 100 ≈ 33 hours
