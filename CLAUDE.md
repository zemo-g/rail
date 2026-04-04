# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Rail Compiler

Self-hosting programming language. Compiler written in Rail, compiles itself to ARM64, x86_64, and Linux ARM64.

- **Compiler source**: `tools/compile.rail` (~4,200 lines, 335 functions)
- **Seed binary**: `rail_native` (686K ARM64) — checked into repo, self-compile produces byte-identical output (fixed point)
- **Native floats (v2.0)**: unboxed IEEE 754 doubles in ARM64 d-registers. No heap allocation. `fadd`/`fmul`/`fdiv`/`fcmp` directly. Float arrays, foreign float calls (`sin`/`cos`/`tanh`/`sqrt`), auto int→float promotion.
- **REPL**: `./rail_native run tools/repl.rail` — interactive, persistent definitions
- **HTTP server**: `stdlib/http_server.rail` + `tools/http_demo.rail` — compile handler binary, serve via `tools/http_server.py`
- **Error messages**: `file:line:col: error: message` — parse errors halt cleanly instead of segfaulting.
- **Runtime**: Zero C dependencies. GC is ARM64 assembly embedded in the compiler. Only needs `as` + `ld`.
- **GC**: Conservative mark-sweep garbage collector in ARM64 assembly. Scans stack frames, marks reachable tagged objects, sweeps into free list. Triggered when 256MB arena bump-alloc fails.
- **Allocator**: 1GB bump arena + GC free list + malloc fallback. 256MB thread stack. `arena_mark`/`arena_reset` still work.
- **Effect handlers**: `try body handler` — setjmp/longjmp non-local error recovery. Deep unwinding, nested handlers.
- **Type checker**: Forward inference pass emits warnings (not errors) for: head/tail on non-list, arithmetic on non-numeric, wrong arity, calling non-functions.
- **Package manager**: `import math` (bare imports), `rail get github.com/...`, `rail pkg` reads `rail.toml`.
- **Tests**: `./rail_native test` — 92 tests, should be 92/92.
- **Performance**: Tail-recursive loops match C -O2 (5 instructions/iteration). Self-loop optimization, untagged register params, bottom-test with `subs`.
- **Targets**: macOS ARM64 (native), Linux ARM64 (Pi Zero), Linux x86_64 (Razer WSL)

### Key Commands

```bash
./rail_native test                    # run 92-test suite
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
  0                                       -- newline-based let
double x = let y = x * 2 in y            -- explicit 'in' also works

type Option = | Some x | None         -- ADT definition
getOrDefault opt = match opt           -- pattern match (NO 'with' keyword)
  | Some x -> x
  | None -> 0

fold add 0 [1,2,3,4,5]               -- fold (use named 2-arg functions, NOT nested lambdas)
map f list, filter f list             -- list ops
head xs, tail xs, length xs, reverse xs, cons x xs
range N                               -- [0..N-1]
\x -> x + 1                          -- single lambda OK
\a -> \b -> a + b                    -- nested lambdas work (flattened to multi-param)
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
- **Polymorphic show**: `show` works on ints, floats, strings, lists (including nested), and nil. Tuples/closures not yet supported.
- **WASM backend**: closures, ADTs, pattern matching, string ops (append/join/show/reverse) all work. 1MB memory, 7 playground demos live. Missing: filter/map/fold/chars/split as WASM builtins.
- **Exhaustive match**: Non-exhaustive `match` is a compile-time error (not warning). Runtime trap on fallthrough.
- **`read_line` zero-arg**: Use `read_line 0` (pass dummy arg) — zero-arg dispatch has a codegen quirk in the V-handler.
- **Cross-function float return inference**: Works via `__fret_` markers, but `show(user_func(1.0))` won't auto-detect float return. Use `show_float` explicitly.
- **Float self-loop TCO**: Deferred — `body_has_float` guard prevents int-TCO corruption but float-specific d8-d15 TCO not yet implemented.

### Performance Optimizations (in compile.rail)

- **Self-loop → bottom-test**: Tail-recursive self-calls become tight loops with `subs + b.gt`
- **Untagged register params**: First 3 int params stored raw in x19/x20/x21, untagged on entry
- **Direct register arithmetic**: Self-loop args computed with raw `add`/`sub`/`mul` on registers
- **Dependency-aware write scheduling**: Minimizes temp registers in self-loop arg writes
- **Auto-memoization**: Pure self-recursive single-arg int functions get transparent memo tables
- **Per-function frame sizing**: Stack frames sized to actual need (not fixed 2048)
- **Constant folding**: `3 + 4` → `7` at compile time
- **Type guard elimination**: Skip runtime type checks when operands are provably int
- **Fused compare-and-branch**: Direct `cmp + b.cc` without intermediate booleans
- **Native float arithmetic**: Float ops via `fadd`/`fmul` in d-registers, no heap boxing (~10x vs boxed)
- **Float type inference**: `is_float` + `__float_` env markers propagate through let bindings
- **Int→float auto-promotion**: Mixed int/float ops: `asr + scvtf` for int operand, `fmov` for float
- **Cross-function float return**: `__fret_` markers in arity map for float-returning user functions

### Modifying the Compiler

After editing `tools/compile.rail`:
1. `./rail_native self` — self-compile
2. `cp /tmp/rail_self rail_native` — install new binary
3. `./rail_native test` — verify 92/92
4. `./rail_native self && cmp rail_native /tmp/rail_self` — verify fixed point (may need 2-3 rounds)

**NOTE**: Self-compile works cleanly since the 256MB stack fix. No gen2_head bootstrap needed.

**IMPORTANT**: If you change the runtime (`rt_core`, `rt_list`, `rt_string`, etc.), the old binary generates the old runtime. You must bootstrap: compile → install → compile again with new binary.

**DATA SECTION BUG**: Changes to the `data` string literal in `compile_program` may not propagate. If you need new data section labels, construct strings at runtime via `malloc` + byte stores in the ARM64 assembly instead. See polymorphic show implementation in `rshow` for the pattern.

## Flywheel (Self-Training System)

Compiler-verified self-training loop. The compiler is the oracle — generate code, compile to verify, harvest successes as training data.

### Architecture

```
self_train.rail (orchestrator)
  → LLM generates Rail code (via llm builtin → MLX server on :8080)
  → rail_native compiles it (oracle verification)
  → Passes get harvested to training/self_train/harvest.jsonl
  → 25 levels, auto-advance at 80%+ for 3 consecutive rounds
  → Falls back on 2 consecutive 0% rounds

dataset.rail (data pipeline)
  → Merges 10 JSONL sources → SHA-256 dedup → 90/5/5 split
  → Output: /tmp/rail_flywheel_data/{train,valid,test}.jsonl

train_cuda.py (CUDA trainer on Razer)
  → QLoRA on Qwen3.5-4B, BitsAndBytes 4-bit
  → Targets self_attn + DeltaNet layers (Qwen3.5 hybrid architecture)
  → device_map="auto" (NOT {"": 0} — that OOMs)

bench.rail (benchmark)
  → 30 tasks, 6 bands, output-verified where possible
  → Logged to flywheel/bench_log.txt

waterfall.rail (cross-node orchestrator)
  → Coordinates Mini (inference) + Razer (training)
```

### Flywheel Commands

```bash
./rail_native run tools/train/self_train.rail        # compile self-train binary
./tools/train/run_training.sh                         # immortal training loop (one round per process)
./rail_native run flywheel/dataset.rail prepare       # full data pipeline: dedup → merge → split
./rail_native run flywheel/bench.rail                 # 30-task benchmark
cat training/self_train/progress.txt                  # check training state
tail -20 /tmp/rail_training.log                       # recent round results
```

### MLX Server (Inference)

```bash
# Current: 4B + v5 adapter
/Users/ledaticempire/homebrew/bin/python3.11 -m mlx_lm.server \
  --model /Users/ledaticempire/models/Qwen3.5-4B-4bit \
  --adapter-path training/adapters_4b_v5_mlx \
  --host 0.0.0.0 --port 8080 --trust-remote-code --max-tokens 2048

# Watchdog (auto-restart + proactive restart every 30min):
./tools/train/mlx_watchdog.sh
```

## Compute Fleet

| Node | Role | Access |
|------|------|--------|
| Mac Mini M4 Pro (24GB) | Inference, compilation, orchestration | local |
| Razer3070 (RTX 3070 8GB) | CUDA QLoRA training | `ssh Detro@100.109.63.37` (Tailscale) |
| Pi Zero 2 W (416MB) | Fleet display, Rail execution | `ssh zemog@100.87.231.45` (Tailscale) |

### Pi Zero Notes

- Rail compiler deployed at `~/rail_native` (532K static ELF)
- Runtime libs at `~/tools/linux_libc.s`, `~/tools/linux_data.s`
- Fleet display: `fleet-rail.service` (Rail binary, SPI LCD)
- Cross-compile from Mini: `./rail_native linux tools/compile.rail && scp /tmp/rail_linux zemog@100.87.231.45:~/rail_native`

## Site Generation

```bash
./rail_native run tools/deploy/gen_site.rail              # regenerate ledatic.org (auto-deploys)
./rail_native run tools/deploy/gen_mission_control.rail    # mission control page
./rail_native run tools/deploy/cf_deploy.rail FILE KEY     # deploy specific file to Cloudflare KV
```
