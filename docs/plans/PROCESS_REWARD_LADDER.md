# Process reward 8-bin signal (Tier-A1)

**Hypothesis.** Standard RLVR / STaR papers treat the verifier as `bool execute(code)` because they're working with an opaque foreign runtime. The Rail compiler is hand-written, owned, fast, and exposes its full pipeline. Replace 1-bit `{pass, fail}` with an 8-bin staged reward so the model receives non-zero signal even when no rollout fully compiles. Solves the cold-start signal problem at low base rates.

## Stage ladder

| Stage | Name             | Compiler signal                                           | Reward weight |
|-------|------------------|-----------------------------------------------------------|---------------|
| 0     | (any output)     | Sample produced ≥1 token                                  | 0.05          |
| 1     | lexed            | All bytes consumed by lexer; no `unknown character`        | 0.10          |
| 2     | parsed           | Top-level decls parsed; no `expected decl/expr`            | 0.20          |
| 3     | type-checked     | Type checker emits no errors (warnings allowed)            | 0.30          |
| 4     | codegen-clean    | ARM64 emit completes; `as` step would succeed              | 0.45          |
| 5     | linked           | `as` + `ld` succeed; binary exists at `/tmp/rail_out`      | 0.65          |
| 6     | ran-no-trap      | Binary executes; exit code ≠ 138 (SIGSEGV) and ≠ 134 (abort) | 0.80          |
| 7     | produced-output  | stdout non-empty                                           | 0.90          |
| 8     | output-correct   | stdout matches expected (only when bench has expected)     | 1.00          |

Reward weights are monotone-superadditive: passing stage N is worth strictly more than partial credit for N-1. Designed so rollouts that "almost compile" are rewarded enough to not vanish in advantage normalization, but not enough to dominate true wins.

## Why monotone-superadditive

Standard RLVR pitfall (CodeRL): partial credit teaches reward hacking. The compiler emits syntactically-clean garbage that lexes and parses but does nothing useful. With weights `[0.05, 0.10, 0.20, 0.30, 0.45, 0.65, 0.80, 0.90, 1.00]`:
- A "lexes only" sample gets 0.10. A "compiles + runs but wrong output" gets 0.80. Gap of 0.70 dominates the gradient — the model still strongly prefers full compile.
- But cold-start where 0/30 samples reach stage 5: every sample gets 0.05–0.30 instead of 0. Gradient is non-zero. Bootstrap is possible.

## Compiler implementation (Task #13)

Add `--emit-stage` flag to `tools/compile.rail`. Pipeline:

```rail
compile_program src =
  let stage = ref 0
  -- stage 0 implicit: any compile attempt
  let tokens = lex src
  if length tokens > 0 then stage := 1 else exit_with_stage 0
  let ast = parse tokens
  if not is_error ast then stage := 2 else exit_with_stage 1
  let typed = type_check ast
  if no_type_errors typed then stage := 3 else exit_with_stage 2
  let asm = codegen typed
  if codegen_ok asm then stage := 4 else exit_with_stage 3
  let bin = assemble_link asm
  if linker_ok bin then stage := 5 else exit_with_stage 4
  emit_stage_json 5
  -- stages 6-8 emitted by run-and-grade harness, not compiler
```

Output format on stderr:
```json
{"stage": 4, "reached": "codegen-clean", "diag": "type error: ...", "file": "input.rail", "line": 42}
```

2-cycle bootstrap per CLAUDE.md.

## Run-and-grade extension

Compiler emits 0–5. Stages 6–8 require execution + output comparison; that lives in `tools/train/grade_rollout.rail`:

```rail
grade rollout expected_output =
  let stage = compile_with_stage rollout
  if stage < 5 then stage_reward stage
  else
    let exit = run_binary
    if exit == 139 || exit == 134 then 5 -- segfault/abort, didn't reach 6
    else
      let out = capture_stdout
      if length out == 0 then stage_reward 6
      else if expected_output != "" && out != expected_output then stage_reward 7
      else stage_reward 8
```

## Integration into trainer

Per-rollout reward replaces the current `{0.0, 1.0}` binary used in compile_loss harvesting. Used in:

1. **Process-reward auxiliary loss (Spur-v2):** every K=1000 steps, harvest M=20 rollouts, compute per-rollout staged reward, add `λ_aux · sum(reward × logπ(rollout|prompt))` REINFORCE-style aux term to the standard CE loss.

2. **DPO from rerank (C1):** chosen/rejected determined by stage difference, not just pass/fail. (rollout_A stage=5, rollout_B stage=2) is a valid DPO pair.

3. **Diversity-aware GRPO (C2):** advantage = (staged_reward - mean) / std − λ_div · KL_to_group. Continuous reward makes std meaningful even when no rollout reaches stage 8.

## Validation (Task #13)

10 hand-crafted broken samples, one per failure mode:
- empty file → stage 0
- `let x =` (incomplete) → stage 1 (lexes, parse fails)
- `add 1 "two"` → stage 2 (parses, type-fails)
- `unknown_fn 1 2` → stage 3 (typed-checked but unresolved at codegen)
- `head []` returning bad type → stage 4 (codegens but link fails — synthetic)
- recursion-no-base → stage 5 (compiles, segfaults)
- `print 0` → stage 6 (compiles, exits cleanly, no stdout)
- mismatched-expected → stage 7
- correct → stage 8

Compiler must emit the right stage code on each. Mismatch = bug to fix before training.

## Risk register

- **Risk:** Reward hacking — model finds outputs that hit stage 7 (non-empty stdout) without computing anything.
  **Mitigation:** Stage 8 (correct output) carries 1.0; gap from 7→8 is 0.10 — non-trivial. If observed, increase 8 weight to 1.5.
- **Risk:** Stage codes drift as compiler evolves.
  **Mitigation:** Pin stage definitions in `stdlib/stages.rail` constant map; compiler reads from there.
- **Risk:** Aux loss dominates surface CE early in training.
  **Mitigation:** Start λ_aux=0.1, anneal up to 0.3 only after step 1000.

## Success criterion

Spur-v2 with process reward vs Spur-v2 without (ablation):
- Lift on stage-distribution: % of rollouts at stage ≥ 4 should rise faster than baseline.
- Lift on bench: ≥ 2 passes/30 attributable to A1 alone (separating from A2/B2 effects).
- Honest read: this technique alone may not move pass-rate; its value is in keeping gradient alive during cold-start, not in late-game refinement.
