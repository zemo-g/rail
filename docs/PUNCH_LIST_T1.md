# TERMINAL 1 — GPU Auto-Dispatch + Compile-Time AI

## Read first
- `~/projects/rail/tools/compile.rail` (1,493 lines, the self-hosting compiler)
- `~/projects/rail/tools/gpu.rail` (92 lines, existing Metal codegen)
- `~/projects/rail/tools/gpu_host.m` (Obj-C Metal host)
- `~/projects/rail/research/IMPLEMENTATION_PLAN.md` (Phase 7 + Phase 12)

## Task 1: GPU auto-dispatch (Phase 7)
Wire existing Metal codegen into the compiler. When `map f data` is called and data length >= threshold, emit Metal compute shader instead of CPU loop.

1. Read `tools/gpu.rail` — understand how it generates .metal shaders
2. Add GPU-safe function analysis to `compile.rail`: identify pure functions (no alloc, no I/O, no recursion)
3. Add `gpu_map` builtin that: generates Metal kernel, compiles with `xcrun metal`, dispatches via `gpu_host.m`
4. Add auto-dispatch: `map f data` checks `length data >= 50000`, routes to gpu_map or cpu_map
5. Calibrate crossover on M4 Pro
6. Add test: `gpu_map (\x -> x * 3 + 1) (range 100000)` matches CPU result

## Task 2: Map fusion (Phase 7.6)
Adjacent `map f (map g data)` → single pass `map (f . g) data`.

1. Add optimization pass after parsing, before codegen
2. Detect nested map applications in AST
3. Compose the functions: `["F", "x", ["A", f, ["A", g, ["V", "x"]]]]`
4. Test: `map double (map triple [1,2,3])` emits 1 kernel not 2

## Task 3: `#generate` compile-time AI (Phase 12)
```
#generate "a function that sorts a list"
sort : List -> List
```
At compile time: call LLM, validate, splice into AST.

1. Add `#generate` as a keyword/directive in the lexer
2. In `pprog`, when `#generate` is seen: read the description string, call LLM (reuse generate_code logic), parse the result, splice declarations
3. The generated code is baked into the binary — no AI dependency at runtime
4. Test: `#generate "factorial function"` followed by `main = fact 10`

## Exit criteria
- `map f data` auto-dispatches CPU/GPU based on data size
- `#generate` calls LLM at compile time, bakes result into binary
- All 63+ existing tests still pass
- Self-compilation verified
