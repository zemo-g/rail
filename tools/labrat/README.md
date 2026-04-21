# labrat — autonomous kernel-optimizer agent

Master plan: `docs/plans/WEEK_PLAN_2026-04-20.md` Phase 5.0.
Inspiration: [duanebester/nnzap](https://github.com/duanebester/nnzap) (labrat + bonsai_agent + bonsai_researcher).
Author of this scaffold: 2026-04-20 PM session.

## Goal

Close the hand-port loop for Metal kernel variants. An LLM agent reads a
kernel source, proposes edits, compiles, runs a throughput+correctness
bench, and iterates — keeping only edits that pass the gate.

First application: **Phase 4a — fp16 Option A kernel port**. The fp16
probe measured 1.70× @ N=1024 on M1 Ultra, so the win is real; the
question is whether 26 kernels × 2 precisions can be ported without
dedicated hand-labor. Labrat is the attempt.

## Protocol (from nnzap)

```
snapshot → edit → compile → test → bench → keep/rollback
```

Applied per kernel variant. The outer loop is over (kernel, precision)
pairs; the inner loop is over edit attempts for a single variant.

## Architecture (mirrors nnzap's split)

- **Agent (outer loop).** Picks the next kernel to work on, formulates
  the edit prompt, accepts/rejects candidates, tracks state. Implemented
  in Rail, calls MLX via `stdlib/mlx_client.rail` (already in tree).
- **Researcher (inner toolbox).** Sandboxed primitives the agent drives:
  snapshot a file, apply an edit, compile the Metal library, run a
  correctness smoke, run a throughput bench, restore on failure. Also
  Rail, shells out for the compiler / bench.

The split keeps the agent's logic testable in isolation from the
shell-out side effects.

## Components (all stubs — Phase 5.0 is multi-session)

- `labrat.rail` — entry point, parses the task spec, calls the agent loop.
- `researcher.rail` — snapshot/edit/compile/bench/rollback primitives.
- `tasks/` — kernel-variant task specs (JSON-ish). First spec:
  `tasks/fp16_matmul.spec` — "port `matmul` from fp32 to fp16 with fp32
  accumulator, match fp32 output within 1e-3 max abs diff at N=1024,
  demonstrate ≥1.6× throughput vs fp32 baseline."
- `transcripts/` — append-only log of each iteration (prompt, patch,
  compile result, bench numbers, decision). Enables resumption + audit.

## Known constraints (Rail-specific)

- `stdlib/llm.rail` / `stdlib/mlx_client.rail` handle the LLM call. MLX
  on `:8080` serves `Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-6bit` —
  adequate for this task class (the paper equivalent used Claude).
- Concurrent Metal kernel work contends with live training; gate via a
  sentinel file or explicit queue.
- Compile + bench for one kernel variant is ~30 s on Studio. A single
  pass through 26 kernels at 3 iterations each = ~40 min wall. Viable.

## First-run gate (exit when hit)

Proceed to apply labrat to Phase 4a only after:

1. `labrat.rail` scaffold compiles.
2. One manual smoke through the researcher primitives (snapshot →
   hand-edit → compile → bench → rollback) works end-to-end on a
   throwaway kernel.
3. One agent-driven iteration on a trivial spec ("rename `matmul` to
   `matmul_v2` without changing semantics") round-trips cleanly.

Only then unleash on the fp16 spec.
