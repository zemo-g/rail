# Deferred backlog items — design notes for next session

This file collects design notes for backlog items that are well-defined but exceed a single-session implementation budget. Each is ready to pick up by a contributor familiar with `tools/compile.rail`.

## A3 — Untagged-register ABI guard

### Problem

`use_regs` (compile.rail:2459) stores the first 3 int parameters raw in `x19/x20/x21` (untagged) on entry to functions where the optimizer determined the params are int. If any caller's arity inference disagrees with the callee's, the callee reads tagged values where it expects raw → silent data corruption.

### Why it's hard

There's no runtime check today. The arity-map (built during codegen) is the single source of truth for "this fn's first N params are raw." Adding a runtime guard hurts every entry to use_regs functions — that's the hot path for tail loops.

### Recommended fix (D3, ~4–6 hr)

**Option A (compile-time IR pass)** — preferred:

1. Add an arity-validation pass between type-check and codegen.
2. Walk all `cg_app` sites in the AST. For each call site, look up the callee's arity in the arity-map. If site disagrees (caller passes 4 args to a 3-arg callee, etc.), emit a fatal error with file:line:col before any code is emitted.
3. New file `tools/test/arity_guard_test.rail` with a compile-time-failure case + an explicit pass case.

This is purely additive and never affects runtime perf.

**Option B (debug-only runtime guard)** — supplement, not replacement:

1. Add codegen flag `--debug-abi`. When set, `use_regs` function entry gets a `tst x19, #1` check (and similar for x20/x21). If any tagged value is detected, branch to a panic that prints `ABI VIOLATION at <fname>` and exits.
2. Used during compiler bring-up + diagnostics. Off in production.

### Files touched

- `tools/compile.rail`: new `arity_check` function called in `compile_program` after `tc_infer`. ~50–100 lines.
- New test in `test_main`.

### Bootstrap

Self-compile fixed-point must hold after the validation pass — verify it doesn't reject any current call site. If it does, fix the inference (the guard is correct; the bug is real).

---

## A6 — Float-specific TCO

### Problem

`body_has_float` guard (compile.rail:2470) prevents int-TCO on float-touching functions. Tail-recursive float loops fall back to call/ret per iteration. Slow.

### Why it's hard

The current TCO transform (compile.rail:2486–2530) only restores integer registers (x19/x20/x21) at the self-loop branch. Float-bearing tail calls would need d8–d15 saved/restored — but float register allocation across call sites isn't tracked the same way as int.

### Recommended fix (D3, ~3–5 hr)

1. In `is_self_rec`, identify the subset of float params/locals that need preservation across the `.Lself` jump.
2. Extend the prologue to save `d8–d15` to caller-frame slots if the body uses them.
3. At each tail-recursive call site, emit `fmov` from the call's float-arg register (likely `d0`) to `d8` (the param register) before the `b.gt .Lself`.
4. Update `mark_float_params` (analogous to `mark_int_params`) to note which float regs are loop-stable.

### Files touched

- `tools/compile.rail`: codegen surgery in cg_self_loop and prologue/epilogue. ~50–100 lines.
- New test: `t107_float_tco.rail` exercising a tail-recursive float fn (e.g., compute pi via Leibniz with N=1M iterations). Runtime should be near-C `-O2`, not 10× slower.

### Risk

`body_has_float` was added as a *correctness* guard against int-TCO corruption. Removing the guard requires making float-TCO actually correct first, then removing the guard. Test must include adversarial cases (float fn calling int fn calling float fn in tail position).

### Bootstrap

Self-compile fixed-point. Most stdlib code is int-only; float-TCO unlocks training perf without breaking the compiler itself.

---

## A10 — Carry source positions through AST

### Problem

Parse errors reconstruct line/col from remaining-token-count via `report_errors` (compile.rail:3494). Fragile when multiple errors are in the same statement. Diagnostics like "expected decl" point at imprecise locations.

### Why it's hard

The AST node format is positional — each tag (`I`, `FL`, `S`, `V`, `O`, etc.) defines what fields follow. Adding source-position fields means changing every constructor and every consumer. The compiler has dozens of consumers across `tc_infer*`, `cg*`, and `pe*`.

### Recommended fix (D3, ~6–10 hr)

**Strategy A (parallel positions, minimum invasive):**

1. Maintain a parallel `positions` table keyed by AST-node identity (use `mem` address or a counter assigned at parse time).
2. `report_errors` looks up the table instead of reconstructing.
3. AST format unchanged.

Pro: minimal change. Con: needs identity-stable handles; Rail's heap nodes are GC'd.

**Strategy B (pos-prefixed AST nodes):**

1. Every parser constructor prefixes with `[pos, ...rest]`.
2. Update every consumer that destructures (`head node` → `head (tail node)`, etc.).
3. Add `node_pos n = head n` and `node_tag n = head (tail n)` helpers.

Pro: clean. Con: touches every consumer (~30+ sites). Each is a one-line edit but they're scattered.

**Strategy C (pos at end, optional):**

1. Parser appends `pos` only on error sites or selected node types.
2. `report_errors` looks for trailing pos, falls back to reconstruction if absent.

Pro: incremental. Con: split-brain — two error-message paths.

Recommended: **Strategy B**, done in two passes. Pass 1: change parser to emit pos-prefixed nodes; consumers all use new helpers. Pass 2: rewrite `report_errors` to use the prefix. Each pass is its own commit.

### Files touched

- `tools/compile.rail`: parser (lines ~176–410), all `tc_infer*`, all `cg*`, `report_errors`. ~30–50 line edits but spread across the file.

### Bootstrap

High risk during transition — old binary parses old format, new binary expects new format. Standard self-host bootstrap dance applies. Add a feature flag during transition: `--positional-errors` toggles old behavior.

---

## D6 — Pure-Rail auto-cycler

### Problem

`tools/garmin/auto_cycler_p{5,6,7}.sh` duplicate ~80 lines of state-machine shell. Each new pass forks a copy. Bit-rot risk.

### Recommended fix (D3, ~3–4 hr)

Single `tools/garmin/auto_cycler.rail` taking flags:

```
./rail_native run tools/garmin/auto_cycler.rail \
    --queue ~/garmin_recon/fuzz/auto_cycler_queue_p7.txt \
    --label-prefix p7
```

Replicate the state machine from `auto_cycler_p5.sh`:
- Resume detection (look for cycle dirs without verdict files)
- USB state polling (libusb FFI? or `shell` to python helper)
- Phase A staging via existing shells
- Phase B verification via existing shells
- Queue advancement

Pure Rail brings a few wins:
- Single source of truth for the state machine
- Easier to add new states (e.g., "watch in firmware-update mode")
- Compiles, so syntax errors caught at compile time vs. runtime

### Files touched

- New `tools/garmin/auto_cycler.rail`
- Optionally remove `auto_cycler_p{5,6,7}.sh` after verification

### Risk

Low. The shell scripts work; this is consolidation. Keep one shell as a fallback during transition.

---

## Status

All four items are well-scoped D3 work with clear acceptance criteria. None block each other. Pick whichever the project needs most.
