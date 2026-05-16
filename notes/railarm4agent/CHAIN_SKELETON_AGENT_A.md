# Chain entry skeleton -- Agent A (corpus)

Authored 2026-05-16 BEFORE Agent A swings, per memory
`chain_caught_five_wrong_leverage_swings`: propose chain entry FIRST,
build SECOND. This file is the falsification contract Agent A is held to.

ASCII only (no em-dashes, no curly quotes). R-ASCII gate is strict.

---

## goal

Spur-arm corpus v0 built: at least 30000 (NL, Rail-DSL) pairs across
VirtualHome + ALFRED + SayCan + substrate-synthesized + seed, three-way
pretrain / sft / eval split, leakage-checked against bench_v0.txt.

## hypothesis

Mixing MIT-licensed paraphrase coverage (VH/ALFRED) with grader-filtered
substrate synthesis produces a corpus that supports a 6L/d=384/15M
student model in clearing bench_v0 single-shot >= 16/20 after SFT.
The corpus is the single bottleneck; quality dominates raw count.

## kill_target

Pipeline produces fewer than 30000 pairs OR random 50-pair sample has
fewer than 45/50 (90%) pass at grader stage >= 3 OR eval_bench_overlap_count
> 0 OR by-source distribution has any single source above 70% of total.

(Any of these closes the entry as FALSIFIED. Build is not allowed to
land below this floor.)

## counters

- pretrain_pairs            -- target >= 23000
- sft_pairs                 -- target >= 4500
- eval_pairs                -- target == 200
- eval_bench_overlap_count  -- MUST be 0
- random_sample_grader_pass_rate_pct  -- target >= 90
- by_source_max_share_pct   -- MUST be <= 70

## cmd

bash tools/lab/watchers/spurarm_corpus_a.sh

(Agent A must author this watcher. It must emit the canonical sentinel
block per the existing robot_arm_baseline_*.sh format and exit 0 on
PASS, non-zero on FALSIFIED / INCONCLUSIVE.)

## parent

66bb63f9  -- substrate-thesis robot-arm N=20 rerank 20/20 baseline

## verdict resolution

- PASS         -- all kill_target floors held, all counter targets met.
- INCONCLUSIVE -- VH or ALFRED downloads blocked; partial corpus shipped
                  with named blocker. Agent A must say which source is
                  missing and what fraction of the target was reached.
                  Downstream agents may consume the partial corpus.
- FALSIFIED    -- any kill_target line tripped. Do NOT merge a falsified
                  corpus to next. Escalate.
