# RAIL BUILD ORCHESTRATOR
**Created**: 2026-03-16 18:20 UTC
**State**: 70% of proposals complete. Three parallel work streams to finish.

## CURRENT STATE (read this first)

- **Compiler**: `tools/compile.rail` — 1,493 lines, 63/63 tests, self-hosting
- **Binary**: `rail_native` — 244KB macOS ARM64, 71KB Linux ELF cross-compile
- **CLI**: `test | self | run <file> | linux <file> | generate "desc"`
- **Self-compile**: `./rail_native self && cp /tmp/rail_self ./rail_native`
- **Test**: `./rail_native test` — must pass all tests after ANY change

## WHAT'S DONE (don't redo these)

| Feature | Status | Where |
|---------|--------|-------|
| f64 floats (boxed, tag=6) | ✓ | compile.rail codegen + runtime |
| FFI (foreign, int/ptr/float returns) | ✓ | compile.rail cg_bi3 + untag_args |
| Negative literals | ✓ | parser pa + emit_load_int |
| String escapes (\{ \}) | ✓ | lexer lx_str |
| Arena mark/reset | ✓ | builtins arena_mark/arena_reset |
| RC heap (alloc/retain/release) | ✓ | runtime _rail_rc_alloc/_rail_rc_release |
| Wildcard + literal + guard patterns | ✓ | cg_arms + pmarms |
| Module imports + qualified + exports | ✓ | pprog import handling |
| Async fibers (true stack-switch) | ✓ | runtime _rail_spawn/_rail_await |
| Channels (send/recv FIFO) | ✓ | runtime _rail_chan_send/_rail_chan_recv |
| Linux ARM64 cross-compile | ✓ | build_linux + sed transform |
| filter/fold/reverse/range | ✓ | runtime functions |
| to_float/to_int/not | ✓ | builtins |
| Grammar EBNF | ✓ | grammar/rail.ebnf |
| rail generate (LLM → compile → run) | ✓ | generate_code in compile.rail |
| stdlib (list,string,math,time,env) | ✓ | stdlib/*.rail |

## WHAT'S NOT DONE (the three punch lists)

### PUNCH_LIST_T1.md — GPU + Compile-Time AI
**Owner**: Terminal 1
**Files touched**: `tools/compile.rail`, `tools/gpu.rail`
**Key tasks**: GPU auto-dispatch, map fusion, `#generate` directive

### PUNCH_LIST_T2.md — Constrained Decoding + Training
**Owner**: Terminal 2
**Files touched**: `tools/build_training_data.rail`, `training/`, generate_code in compile.rail
**Key tasks**: Grammar constraint in LLM calls, 1000+ training examples, LoRA round 2

### PUNCH_LIST_T3.md — Ecosystem
**Owner**: Terminal 3
**Files touched**: `stdlib/*.rail`, `tree-sitter-rail/`, compile.rail (WASM backend + package mgr)
**Key tasks**: 17 FFI wrappers, tree-sitter grammar, WASM backend, package manager

## CONFLICT AVOIDANCE

- **T1 owns**: codegen in compile.rail (cg, cg_bi, runtime functions, compile_program)
- **T2 owns**: generate_code function in compile.rail + training/ directory
- **T3 owns**: stdlib/ directory, tree-sitter-rail/ directory, new CLI commands (wasm, get)
- **If T1 and T3 both need compile.rail**: T1 goes first (codegen), T3 adds CLI commands after T1 commits
- **Always run `./rail_native test` before committing**
- **Always self-compile after changes**: `./rail_native self && cp /tmp/rail_self ./rail_native`

## GIT PROTOCOL

```bash
# Before starting work, pull latest
cd ~/projects/rail && git log --oneline -3

# After each task, commit
git add <specific files> && git commit -m "description"

# NEVER amend — always new commits
# NEVER force push
```

## KEY ARCHITECTURE NOTES

- Tagged pointers: bit 0 = 1 for ints, 0 for heap ptrs
- Heap tags: 1=cons, 2=nil, 3=tuple, 4=closure, 5=ADT, 6=float
- Foreign arity encoding: 1000+n=int return, 2000+n=ptr return, 3000+n=float return
- Constructor encoding: -(100 + idx*100 + arity)
- Frame size: 2048 bytes per function
- Fiber stacks: 64KB each, bump-allocated
- LLM at :8080, model path: /Users/ledaticempire/models/Qwen3.5-9B-6bit
- Thinking mode disable: "chat_template_kwargs": {"enable_thinking": false}

## REFERENCE FILES

| File | Purpose |
|------|---------|
| `research/PROPOSAL.md` | Original vision |
| `research/PROPOSAL_v2.md` | Adversarial corrections |
| `research/IMPLEMENTATION_PLAN.md` | 13-phase plan with dependency graph |
| `research/META_BUILD_LOG.md` | Build phase analysis |
| `grammar/rail.ebnf` | Grammar for constrained generation |
| `PUNCH_LIST_T1.md` | GPU + compile-time AI tasks |
| `PUNCH_LIST_T2.md` | Training + constrained decoding tasks |
| `PUNCH_LIST_T3.md` | Ecosystem tasks |

## SUCCESS CRITERIA (from proposals)

When ALL of these are true, the proposals are 100% complete:
- [ ] `map f data` auto-dispatches CPU vs GPU based on data size
- [ ] `#generate "desc"` calls LLM at compile time, bakes result into binary
- [ ] Grammar-constrained decoding → 0% syntax errors in generated code
- [ ] 1,000+ training examples, held-out success >60%
- [ ] WASM backend produces valid .wasm
- [ ] 20 stdlib packages
- [ ] Tree-sitter grammar parses all .rail files
- [ ] Package manager: `rail get <name>`
- [ ] Map fusion: `map f (map g xs)` → single pass
