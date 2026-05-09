# Spur — session handoff 2026-05-01

## The headline

**Spur-v3 (`spur_v13_d256_compile_self_best`) hits 6/30 (20%) on the canonical bench.** Trained on `tools/compile.rail` ALONE (362 KB ASCII-cleaned) for 3,000 steps at d=256. **3× the prior best Spur ckpt (v0.9-ascii at 1-2/30).** Honest grading. Reproducible.

## Best ckpt

```
training/rail_native/checkpoints/spur_v13_d256_compile_self_best.*
```

Inference binary: `tools/train/lm_infer_cpu_v13.rail` (vocab built from same compile.rail).

## What worked vs what didn't (4-arm ablation)

| Corpus | Bench | Verdict |
|---|---:|---|
| **compile.rail alone (Arm 1)** | **6/30** | **WINNER** |
| ascii + curriculum (Arm 2) | 1/30 | curriculum hurts |
| compile.rail + curriculum (Arm 3) | 1/30 | curriculum poisons compile.rail |
| ascii + compile.rail (Arm 4) | 0/30 | ASCII also dilutes |

**Single coherent self-hosting source is the lever. Mixing destroys it.**

## Top priority next session

### P0 — capacity scaling on compile.rail-only
- d=384 (vs current d=256): does it push beyond 6/30?
- 6,000-step training (vs current 3,000): does longer training lift?

Both are 1-line trainer-fork changes. Each takes ~2-3 hr to train+bench.

### P1 — multi-coherent-source test
Concatenate `compile.rail + stdlib/transformer.rail + stdlib/bpe.rail` as one stream (each is a single coherent program). Does coherent-mix compound, or does any addition dilute? Tests whether the lever is "compile.rail specifically" or "any one coherent source."

### P2 — fix `rail_native` exit-code bug
`_rail_main` should propagate `ld` failures via non-zero exit. Currently silent-zero on undefined-symbol errors. ~30 min compile.rail patch + 2-cycle bootstrap. Avoids future false-positive measurement bugs (see `strip_grade_was_false_positive.md` for the cost).

### P3 — half-of-compile.rail test (cheaper)
Train on lines 1-2345 vs lines 2346-4690 of compile.rail separately. If both achieve ~6/30, the lever is "any single coherent ~180 KB program," not specifically compile.rail. If one half wins, the lever is "structural complexity / specific patterns in compile.rail."

## What's deferred / lower priority

- 16 model-side scaffolds from earlier overnight (parse-trace two-channel, compile-loss with teacher cold-start, MCTS sampler, type-conditioned, etc.) — all still on disk in `tools/train/`, lower priority now that corpus-quality dominates.
- Two-channel parse-trace (proper Tier-A2): untried, may still lift further.
- Compile-loss-during-training: blocked by cold-start problem; harvest from 1-2/30 ckpts produces 0 survivors. Bootstrap requires teacher.
- Bigger model (d=512, 3+ blocks): defer until P0/P1 tell us if d=256 has more headroom.

## Substrate state

- TCO fix from 2026-04-30 holds.
- Inference seed-segfault workaround holds (~50% seeds segfault at --max 64; rerank picks best of 20).
- Bench harness: original `rn_oracle_stats` `ld: OK` check is correct. **Do NOT add strip post-process** — that was a measurement bug from earlier in the session.
- `rail_native` exits 0 on `ld` failure (open bug).

## Gotchas discovered today

1. **`rail_native` exit-code bug** — exits 0 even when ld fails. Any tool using `&& echo PASS` semantics is broken. Use `grep -q '^  ld: OK$'` pattern instead.
2. **val_loss does NOT predict bench at this scale.** Arm 3 had val_loss 3.22 (lowest) and bench 1/30. Arm 1 had val_loss 3.29 and bench 6/30.
3. **Curriculum at template-density POISONS the model.** Don't generate corpus from grammar-walk templates and mix it in. The model overfits to narrow patterns.
4. **ASCII baseline corpus dilutes compile.rail.** Even though it's "more data," the heterogeneity hurts.
5. **Bench-process watcher false-positives** between parallel_rerank batches (documented in `bench_watcher_gotcha.md`) — use file-size-stability + log-grew checks.
6. **`set -e` + `[ ] && cmd`** is a silent-exit pitfall in bash. Use `if [ ]; then cmd; fi`.

## Reproducer (verified)

```bash
# Substrate sanity
./rail_native quick                              # 15/15
./rail_native run /tmp/tco_test.rail | tail -1   # 100

# Phase 0 winning recipe — compile.rail-as-corpus
python3 -c "
with open('tools/compile.rail','rb') as f: d=f.read()
ascii=bytes(b for b in d if b<128)
with open('training/corpora/spur_v3_compile_self.txt','wb') as f: f.write(ascii)
print(f'wrote {len(ascii)} bytes')"

# Train (~85 min wall)
./rail_native run tools/train/lm_v13_d256_compile_self.rail

# Bench (~25 min wall, N=20 parallel rerank)
./rail_native run flywheel-local/bench_railnative_rerank.rail \
  --gen-source tools/train/lm_infer_cpu_v13.rail \
  --prefix training/rail_native/checkpoints/spur_v13_d256_compile_self_best \
  --max 64 --k 10 --temp 0.8 --tag v13_repro

# Expected: 6/30, q≈74k
```

## Memory entries — final state

- `compile_rail_alone_is_lever.md` — THE finding
- `strip_grade_was_false_positive.md` — retraction of mid-session false claims
- `utf8_lever_quantified.md` — UTF-8 cleanup as +1-2 pass lever (still real)
- `next_session_pointer.md` — pointer to v13 baseline + next priorities
- `bench_watcher_gotcha.md` — operational
- `feedback_bench_window_pattern.md` — operational
- `inline_parse_trace_falsified.md` — Tier-A2 simple form falsified
- `structural_advantage_thesis.md` — meta framing
- `scaffolded_overnight_2026-05-01.md` — 16-scaffold inventory (still useful for future)

Plus ~5 entries from earlier in the session retracted/superseded.
