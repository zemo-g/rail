# Changelog

All notable changes to Rail are documented here.

## v1.4.0 (2026-03-22)

- **Garbage collector**: conservative mark-sweep GC in `runtime/gc.c`. Scans ARM64 stack frames via x29 chain, traces tagged objects, builds free list. Triggered when 1GB bump-alloc fails. Programs can now allocate well beyond 1GB total.
- **Nested lambdas**: `\a -> \b -> a + b` compiles correctly. Flattened to multi-param closures, with direct application beta-reduced at compile time.
- **Multi-capture closures**: closures capturing 2+ variables now load all captures (up to 4).
- **Exhaustiveness checking**: compiler warns on non-exhaustive ADT pattern matches, listing missing constructors.
- **70 tests** (up from 67), stable with GC + 1GB allocator.
- Compiler grown to 1,979 lines.

## v1.3.0 (2026-03-21)

- **Flywheel self-training**: 25-level curriculum, compiler-verified training data, auto-advance at 80%+ for 3 consecutive rounds.
- **MCP server**: Rail exposed as a Model Context Protocol tool server.
- **32-layer LoRA training**: targets both self-attention and Gated DeltaNet layers in Qwen3.5-4B.
- **Fleet tools**: distributed node management (`tools/fleet/`), fleet agents for ARM64 and x86_64.
- **Thinking mode**: robust response parsing for thinking-mode LLM inference in `runtime/llm.c`.
- Closure label counter fix in compiler.

## v1.2.1 (2026-03-21)

- Quality scoring layer for training data.
- v5 adapter deployed (PEFT-to-MLX converted, more data).
- Razer sparkline in fleet dashboard.

## v1.2.0 (2026-03-21)

- **`cat` builtin** for file concatenation.
- Linux cross-compiler fixes.
- Pi Zero fleet display in dashboard.

## v1.1.0 (2026-03-18 -- 2026-03-20)

- **Metal GPU backend**: Rail compiles to Apple Silicon compute shaders (`tools/gpu.rail`).
- **WASM backend**: compiles Rail to WebAssembly (`tools/wasm.rail`). Runtime WIP.
- **x86_64 backend**: sandboxed subset in `tools/x86_codegen.rail`.
- **Concurrency**: `spawn`, `channel`, `send`, `recv` for fiber-based concurrency.
- **Flywheel framework**: `flywheel/waterfall.rail` orchestrator, `flywheel/bench.rail` 30-task benchmark.
- **`#generate` directive**: compile-time AI code generation.
- **Map fusion**: `map f (map g data)` optimized to single-pass `map (f . g) data`.
- **Tree-sitter grammar** for syntax highlighting.
- **22 stdlib modules**: json, http, sqlite, regex, base64, socket, crypto, csv, datetime, env, fs, hash, math, net, os, path, process, random, sort, string, test, toml.
- Reorganized `tools/` directory structure.
- Arena mark/reset fix -- 67/67 tests stable.
- Flywheel data pipeline audit + 49-issue fix cycle.

## v1.0.0 (2026-03-17)

- **Self-hosting achieved**: Rail compiler (`tools/compile.rail`) compiles itself to ARM64. Output is byte-identical on re-compilation (fixed point).
- **Rust deleted**: 21,086 lines of Rust replaced by 1,774 lines of Rail.
- **329K seed binary**: no external dependencies beyond macOS `as` + `ld`.
- 67 tests passing.
- Pattern matching + algebraic data types.
- Tail-call optimization.
- Tagged pointer runtime (integers shifted, heap objects raw).
- 1GB bump arena allocator.
- CLI interface: `rail_native run`, `rail_native test`, `rail_native self`.
- Linux ARM64 cross-compilation support.

## Pre-1.0 (2026-03-14 -- 2026-03-16)

- ARM64 native code generation from Rail AST.
- Self-compilation achieved, then reached fixed point.
- TCO for constant-stack recursion.
- ADTs and pattern matching.
- Floats, FFI, imports, list operations.
- Async fibers, literal patterns, guards in match.
- `rail generate` -- AI code generation via local LLM.
- Channels and float FFI returns.
- GPU auto-dispatch for pure arithmetic.
- Original Rust implementation (interpreter, parser, type checker, LSP, Cranelift JIT).
