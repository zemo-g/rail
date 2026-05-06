# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working with code in this repository.

## Output Length

Keep responses concise. Avoid verbose explanations and large code dumps in chat. When pasting prompt content or artifacts, write to a file rather than echoing in-chat.

## Verification Discipline

Before declaring a hypothesis confirmed, run the falsification test (e.g., for fp16/precision claims, compare bit-identical loss across runs; for parse-pass criteria, include adversarial garbage-continuation cases). Read runtime/asm before guessing at allocator or memory-pressure causes.

## Rail Compiler

Self-hosting programming language. Compiler written in Rail, compiles itself to ARM64, x86_64, and Linux ARM64.

- **Compiler source**: `tools/compile.rail`
- **Seed binary**: `rail_native` (ARM64) — checked into repo, self-compile produces byte-identical output (fixed point)
- **Native floats**: unboxed IEEE 754 doubles in ARM64 d-registers. No heap allocation. `fadd`/`fmul`/`fdiv`/`fcmp` directly. Float arrays, foreign float calls (`sin`/`cos`/`tanh`/`sqrt`), auto int→float promotion.
- **REPL**: `./rail_native run tools/repl.rail` — interactive, persistent definitions
- **HTTP server**: `stdlib/http_server.rail` + `tools/http_demo.rail`
- **Error messages**: `file:line:col: error: message` — parse errors halt cleanly instead of segfaulting.
- **Runtime**: Zero C dependencies. GC is ARM64 assembly embedded in the compiler. Only needs `as` + `ld`.
- **GC**: Conservative mark-sweep garbage collector in ARM64 assembly. Scans stack frames, marks reachable tagged objects, sweeps into free list. Triggered when 512MB arena bump-alloc fails.
- **Allocator**: 512MB bump arena + GC free list + malloc fallback. 256MB thread stack. `arena_mark`/`arena_reset` available for manual bulk free.
- **Effect handlers**: `try body handler` — setjmp/longjmp non-local error recovery. Deep unwinding, nested handlers.
- **Type checker**: Forward inference pass emits warnings (not errors) for: head/tail on non-list, arithmetic on non-numeric, wrong arity, calling non-functions.
- **Package manager**: `import math` (bare imports), `rail get github.com/...`, `rail pkg` reads `rail.toml`.
- **Tests**: `./rail_native test` — should be 137/137. Count fluctuates only when concurrent runs collide on `/tmp/rail_out` — rerun to confirm.
- **Checkpoints**: `stdlib/checkpoint.rail` — `save_checkpoint prefix weights adams step best_val` + `load_checkpoint` / in-place `load_model_into` / `load_adam_states_into`. Atomic via `<prefix>.committed` sentinel.
- **Performance**: Tail-recursive loops match C -O2 (5 instructions/iteration). Self-loop optimization, untagged register params, bottom-test with `subs`.
- **Targets**: macOS ARM64 (native), Linux ARM64, Linux x86_64

### Key Commands

```bash
./rail_native test                    # run test suite
./rail_native self                    # self-compile → /tmp/rail_self (must be byte-identical)
./rail_native run file.rail           # compile + execute
./rail_native file.rail               # compile only → /tmp/rail_out
./rail_native x86 file.rail           # compile to x86_64 Linux → /tmp/rail_x86.s
./rail_native linux file.rail         # cross-compile to Linux ARM64 → /tmp/rail_linux
./rail_native get <package>           # install package (stdlib name or github.com/user/pkg)
./rail_native pkg                     # install dependencies from rail.toml
```

### Rail Syntax Quick Reference

```rail
-- Comments start with --
add a b = a + b                       -- named function (BEFORE main)
main = let _ = print (show (add 3 4)) -- main returns int
  0                                   -- newline-based let
double x = let y = x * 2 in y         -- explicit 'in' also works

type Option = | Some x | None         -- ADT definition
getOrDefault opt = match opt          -- pattern match (NO 'with' keyword)
  | Some x -> x
  | None -> 0

fold add 0 [1,2,3,4,5]                -- fold (use named 2-arg functions)
map f list, filter f list             -- list ops
head xs, tail xs, length xs, reverse xs, cons x xs
range N                               -- [0..N-1]
\x -> x + 1                           -- single lambda OK
\a -> \b -> a + b                     -- nested lambdas work (flattened to multi-param)
write_file path content, read_file path
let _ = shell "command"
join sep list, split "c" str          -- split is per-character, NOT substring
str_split ", " str                    -- multi-char split
str_find "needle" "haystack"          -- returns index or -1
str_contains "needle" "haystack"      -- returns bool
str_replace "old" "new" str           -- replaces all occurrences
str_sub str start len                 -- substring extraction
read_line                             -- read line from stdin
show n                                -- int to string
int_to_float n                        -- tagged int → raw f64 bits (scvtf)
float_to_int x                        -- raw f64 → tagged int (fcvtzs, truncation)
x |> f                                -- pipe operator (f x)
error "msg", is_error x, err_msg x   -- error handling
arr_new size default, arr_get a i, arr_set a i v, arr_len a  -- mutable arrays
```

### Runtime Safety

- `head []` returns 0 (not segfault). `head` on non-list returns 0.
- `tail []` returns `[]`. `tail` on non-list returns `[]`.
- Type errors on head/tail are graceful. Other type errors (arithmetic on strings, calling non-functions) may still segfault.

### Known Compiler Limitations

- **`split` is single-character**: `split "abc" s` splits on `a`, `b`, and `c` individually. Use `str_split` for multi-char delimiters.
- **Polymorphic show**: works on ints, floats, strings, lists (including nested), and nil. Tuples/closures not yet supported.
- **WASM backend**: closures, ADTs, pattern matching, string ops (append/join/show/reverse) all work. 1MB memory. Missing: filter/map/fold/chars/split as WASM builtins.
- **Exhaustive match**: Non-exhaustive `match` is a compile-time error (not warning). Runtime trap on fallthrough.
- **`read_line` zero-arg**: Use `read_line 0` (pass dummy arg) — zero-arg dispatch has a codegen quirk in the V-handler.
- **Cross-function float return inference**: Works via `__fret_` markers in the arity map; let-bound float tracking via V (variable) AST nodes. Cross-function *parameter* inference still requires explicit annotations.
- **Float self-loop TCO**: Deferred — `body_has_float` guard prevents int-TCO corruption but float-specific d8-d15 TCO not yet implemented.
- **Deeply-nested `match` chains**: A `match | ADT -> match | ADT -> ...` chain 5+ levels deep inside a function body with side-effecting `let`s after it triggers "expected decl" parse errors. Workaround: flatten multiple `match`es into a single chained form.
- **Mixed float+int arithmetic**: `0.0 + int_expr` promotes correctly even when the int operand's type can't be statically inferred. The O-handler emits a runtime `tst x, #1` path that picks scvtf or fmov based on the tag bit.

### Performance Optimizations (in compile.rail)

- **Self-loop → bottom-test**: Tail-recursive self-calls become tight loops with `subs + b.gt`
- **Untagged register params**: First 3 int params stored raw in x19/x20/x21, untagged on entry
- **Direct register arithmetic**: Self-loop args computed with raw `add`/`sub`/`mul` on registers
- **Auto-memoization**: Pure self-recursive single-arg int functions get transparent memo tables
- **Per-function frame sizing**: Stack frames sized to actual need (not fixed 2048)
- **Constant folding**: `3 + 4` → `7` at compile time
- **Type guard elimination**: Skip runtime type checks when operands are provably int
- **Fused compare-and-branch**: Direct `cmp + b.cc` without intermediate booleans
- **Native float arithmetic**: Float ops via `fadd`/`fmul` in d-registers, no heap boxing (~10x vs boxed)
- **Float type inference**: `is_float` + `__float_` env markers propagate through let bindings
- **Int→float auto-promotion**: Mixed int/float ops: `asr + scvtf` for int operand, `fmov` for float

### Modifying the Compiler

After editing `tools/compile.rail`:
1. `./rail_native self` — self-compile
2. `cp /tmp/rail_self rail_native` — install new binary
3. `./rail_native test` — verify suite
4. `./rail_native self && cmp rail_native /tmp/rail_self` — verify fixed point (may need 2-3 rounds)

If you change the runtime (`rt_core`, `rt_list`, `rt_string`, etc.), the old binary generates the old runtime. Bootstrap: compile → install → compile again with new binary.

**ASCII-only inside string literals emitted to asm**: avoid em-dashes, curly quotes, etc. inside any string that flows into `.asciz` output. Use `-` (hyphen-minus) and `'` (apostrophe). Comments (outside string literals) can use any Unicode.

## Self-training (in tree)

`tools/train/self_train.rail` is a compiler-verified self-training loop: an LLM generates Rail, `rail_native` compiles it, passes get harvested. `stdlib/llm.rail` + `stdlib/anthropic_client.rail` + `stdlib/mlx_client.rail` provide LLM clients over pure-Rail TLS.

## Site generation (dynamic pages)

```bash
./rail_native run tools/deploy/gen_feed.rail               # Atom feed
./rail_native run tools/deploy/daily_deploy.rail           # cron orchestrator
```

## Attestation (release + build provenance)

`tools/attest/` signs every tagged release, every `./rail_native test` pass, and every 2-pass self-compile fixed point against a live entropy beacon `pulse_id` and an Ed25519 witness key.

```bash
tools/attest/attest.sh <input> <out>           # core primitive: sha256 ⊗ pulse ⊗ Ed25519
tools/attest/verify.sh <input> <attestation>   # re-derive, fetch pubkey, Ed25519 verify
tools/attest/attest_release.sh [tag]           # sign rail_native + tools/compile.rail at HEAD/tag
tools/attest/attest_test_run.sh                # bracket ./rail_native test with pulses, sign result
tools/attest/attest_selfhost.sh                # 2-pass byte-identical claim, signed
tools/attest/publish.sh [dirs…]                # push releases/, builds/, selfhost/ to ledatic.org
```

Output lives in `releases/<tag>/`, `builds/<short>/`, `selfhost/<short>/`. Public surfaces under `ledatic.org/releases`, `/builds`, `/selfhost`, `/attest/verify.sh`, `/attest/fleet0.pub.pem`.

## Cross-compile (Linux ARM64)

```bash
./rail_native linux tools/compile.rail
```

Runtime libs live at `tools/linux_libc.s` and `tools/linux_data.s`.
