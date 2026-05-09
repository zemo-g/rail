# 2026-05-09 — jit-tdd-engineer agent shipped, MLX local-embodiment dead-end, Studio recovered

## TL;DR

- **Shipped**: `~/.claude/agents/jit-tdd-engineer.md` — JIT TDD-loop engineer, gap-folded after a real dry run.
- **Staged on `next` (not pushed)**: `b87eb48` — caveat #6 closed, +2 regression-guard fixtures, +2 docs (SCRATCH.md, AGENT_DRY_RUN_2026-05-09.md).
- **Local-LLM agent embodiment**: ZAYA1 doubly blocked. Studio OOM'd mid-experiment.
- **Floor at handoff**: 137/137, lower 109, capture 60 (+2), parity OK.

---

## What shipped

### Agent: `jit-tdd-engineer`

Lives at `~/.claude/agents/jit-tdd-engineer.md` (started project-local at `rail/.claude/agents/`, promoted to global for cross-cwd visibility — Claude Code's agent registry only loads the cwd's project agents at session start, so global made sense).

Strict red-green TDD loop with autonomous build iteration, capped at 10 iters before surfacing. Owns `jit/` plus its drivers and docs. Carve-outs: `tools/compile.rail` (architect's lane), `EXPERIMENT_PLAN.md` (separate agent's territory), files dirty outside `jit/` at startup.

Dry-run validation against the spec **"add negative-int support to `op_print_int`"** (caveat #6) found that the feature was already shipped silently (`emit.rail:864-905` has sign detection + `-` prepend; existing `print_neg` fixture already passing). The agent correctly took the **no-impl exit lane**, added regression guards, retired the stale doc — instead of fabricating busy-work. That's the strongest possible validation.

Self-critique (`jit/AGENT_DRY_RUN_2026-05-09.md`) graded the contract **B+/A-** and surfaced 3 gaps. All folded in:

1. **Step 0.5 — Premise check** (new). Verify spec premise on tip-of-tree before red fixtures. Doc-disagreement tiebreaker: running code wins. No-impl exit lane explicit.
2. **Step 5 — explicit-path staging**. Never `git add -A` / `git add .`. Pre-existing dirty files outside `jit/` get noted at startup, never staged.
3. **Step 6 — handoff variants**. Mid-stage → CONTINUATION; stage closed → NEXT_SESSION; doc-only deliverable → CHANGELOG entry alone.

Plus token-limit trigger made concrete (turn count > 30 OR response > 6KB), final-report has 3 variants (impl shipped / no-impl-needed / checkpointed), Step 2 strengthened ("if the edit isn't a direct cause-of-green, it doesn't belong in this commit"), falsification rule promoted to override TDD-red-first when they conflict.

### rail commit `b87eb48` (staged on `next`, not pushed)

```
jit: caveat #6 retired (op_print_int negatives) — regression guards only

- emit_print_int_impl already handles negatives (emit.rail:864-905);
  existing print_neg fixture already passing pre-edit.
- fixtures: test_capture.rail +2 (print_neg_42, print_neg_1)
- README caveat #6 marked CLOSED
- baselines: lower 109, capture 58→60, enc 28, parity OK, 137/137
```

Plus `jit/SCRATCH.md` (falsification log) + `jit/AGENT_DRY_RUN_2026-05-09.md` (agent critique).

---

## ZAYA1 local-embodiment: blocked

Goal: have `kyr0/zaya1-base-8b-8bit-MLX` drive the `jit-tdd-engineer` loop locally instead of Anthropic API.

**Blockers (all real, none cheap to remove):**

1. **`mlx_lm` doesn't support `zaya` model_type.** Verified: `mlx_lm 0.31.2` registry has 118 architectures, none match. Per model README, requires [`ml-explore/mlx-lm` PR #1261](https://github.com/ml-explore/mlx-lm/pull/1261) merged, or install `kyr0/mlx-lm@feat/zaya-support` fork.
2. **No instruct-tuned ZAYA1 variant exists.** HF search returned: `ZAYA1-8B`, `ZAYA1-base`, `ZAYA1-reasoning-base`, `ZAYA1-VL-8B`, `ZAYA1-74B-preview`, plus quantized derivatives. **All base or reasoning-base; none chat/instruct.** Base models continue text rather than follow agent protocols. Structural mismatch.
3. **800M active params** (top-1 MoE of 8.3B total). Small for an agent driver even if (1) and (2) were fixed.

**Verdict:** revisit only when (a) an instruct-tuned ZAYA1 ships, AND (b) mlx-lm PR #1261 lands or you switch to the fork. Otherwise it's a research curiosity, not a path to embodiment.

**Cleanup**: 3.5GB partial download at `~/.cache/huggingface/hub/models--kyr0--zaya1-base-8b-8bit-MLX/`. Safe to `rm -rf` — it can't load anyway.

---

## Studio crash

Around the time I kicked off the ZAYA1 pull, Studio OOM'd. Pre-crash MLX server lineup (per `ps aux`):

- **8080**: `QwQ-32B-4bit` (~16GB)
- **8082**: `Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq` (~36GB)

I added a `mlx_lm.generate` for 8GB ZAYA1 on top of 64GB total RAM. ~60GB resident plus OS + my generate-trying-to-load = over the edge.

**Post-recovery lineup (current):**

- **8081**: `Qwen3.6-35B-A3B-UD-Q8_K_XL-mlx` (~26GB, MoE w/ 3B active, instruct-tuned)
- 8080 + 8082 not running

If you want to restore the 122B/8082 picture, kill 8081 first (it'll squeeze otherwise — 26GB + 36GB = 62GB before OS).

**Lesson worth saving as a memory entry** (your call): before pulling/loading any model on Studio, run `vm_stat` + `ps aux | grep mlx_lm.server` to verify headroom. The 64GB ceiling is real with concurrent big models. `mlx_lm.generate` triggers a load, not just a download.

---

## Open / pending

- **Push `b87eb48`** via Mini when you're ready (per CLAUDE.md push flow). Single staged commit on `next`.
- **Smoke-test the agent locally** if you still want to. Live candidate: 8081/Qwen3.6-35B-A3B (Qwen series has tool use, instruct-tuned, ~26GB resident). Skipped today after the crash.
- **Clean up partial ZAYA1 download** (3.5GB).
- **Revisit local-LLM embodiment strategy.** Realistic candidates already on disk: `Hermes-4-70B-4bit` (famous for tool use), `Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-6bit` (validated 47% on Rail per `teacher_distill_works.md`), `Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq` (the comprehension cracker, 29/30 on bench per memory).

---

## Next-session pickup options

1. **Push `b87eb48`** and call it done — agent ready for next real JIT feature, MLX embodiment parked.
2. **Smoke-test 8081/Qwen3.6-35B** — feed it the agent prompt + a small task, see if it produces sensible tool-call output. ~2 min, decides go/no-go for runner work.
3. **Restore 8082/122B**, smoke-test there — strongest available, validated on Rail. ~5 min for swap.
4. **Write the runner anyway** (`tools/agent/runner.rail`, ~300-600 lines): MLX client + tool-use loop + agent-md loader. Risky without first validating any local model can drive it.
5. **Pivot back to JIT feature work** — there's a real backlog in `jit/NEXT_STAGES.md` and `jit/CONTINUATION.md`. The agent now exists to land the next one.

---

## Files referenced

- `~/.claude/agents/jit-tdd-engineer.md` — agent definition (final, gap-folded)
- `~/projects/rail/.claude/agents/master-studio-architect.md` — sibling agent (architect lane), unchanged
- `~/projects/rail/jit/AGENT_DRY_RUN_2026-05-09.md` — dry-run self-critique
- `~/projects/rail/jit/SCRATCH.md` — falsification log
- `~/projects/rail/jit/test_capture.rail` — +2 fixtures
- `~/projects/rail/jit/CHANGELOG.md` — +1 line under new "Audit closure" heading
- `~/projects/rail/jit/README.md` — caveat #6 marked CLOSED

## State at end of session

```
HEAD                  b87eb48 (next, ahead of origin/next by 1)
./rail_native test    137/137
test_lower            109
test_capture          60 (+2 from 58)
test_enc              28
parity_check          PARITY OK
mlx_lm.server lineup  8081 only (Qwen3.6-35B-A3B Q8)
```
