# Performance Sessions — Status

Original plan dated 2026-03-23 (compile.rail at ~2,540 lines, 85/85 tests, fib(40) 4.6× C). Three sessions queued: per-function frame sizing, untagged integer locals, register allocation.

**As of 2026-04-08 — sessions 1 and 2 are done. Session 3 is partial.**

## Session 1: Per-Function Frame Sizing — DONE

- `max_sl` walks the AST to compute the actual stack high-water of each function body (compile.rail ~1844).
- Frame size = `((max(raw, 48) + 15) / 16) * 16`, threaded through codegen as the `fs` parameter.
- All `cg`/`cg_bi`/`cg_bi2`/`cg_bi3` paths emit prologue/epilogue/tail-call teardowns using `fs`, not a hardcoded 2048.
- Lambda frames computed independently in the `tg == "F"` branch (~line 1336).

## Session 2: Untagged Integer Locals — DONE

- Type checker output is consumed via `__int_<name>` env markers added at let-binding time (compile.rail ~line 1270).
- `is_int` propagates through let bindings + ifs + ops.
- `get_opc_noguard` (~line 798) emits raw `add`/`sub`/`mul` when both operands are provably int — no tag/untag round trip.
- Cross-function: `__float_ret_<fname>` markers identify float-returning user functions via two-pass detection (`collect_float_ret_fns`).

## Session 3: Register Allocation — PARTIAL

What landed:
- First 3 int parameters of a function live raw in x19/x20/x21 (callee-saved), gated by `all_params_int` and `body_has_float == false`.
- `save_params_reg` writes them to the stack frame for spill safety.
- Self-loop bottom-test optimization (`subs x19, x19, #N` + `b.gt`) uses these directly — 5 instructions/iteration matching C `-O2`.

What didn't land (the original Session 3 vision):
- Frequency-based allocation across **all** locals (the full x19–x28 plan).
- Reg-allocate let-bound variables (only function params get registers today).
- No usage-counting walk; assignment is positional (params 0/1/2 → x19/x20/x21), not hottest-first.

Whether to finish: the existing param-only register allocation already gets `fib(40)` to ~0.30s, matching `gcc -O2`. The original perf goal (1.6× of C) is met. The remaining register-allocation work is a 1.1–1.2× improvement at most, and adds significant complexity to closure save/restore and tail-call epilogues. Defer until we have a workload that actually benchmarks slower than C.

## What replaced this file as the queue

- `docs/PICKUP-2026-04-06.md` — most recent operational pickup.
- Live work tracked in MEMORY (`~/.claude/projects/-Users-ledaticempire/memory/MEMORY.md`).
