# Grammar-walk climb — 2026-05-05 session report

**Audience:** A Claude Code agent picking up this branch with no prior context.
**Status:** Ten commits shipped. Verifier-augmented sampling now lifts parse-pass rate from 0/5 → 5/5 on Spur-v54's prompt 3 at N=5 seeds. Compile-pass gate remains 0/5 — a real wall, not a bug. Spec-in-context probe queued for user-triggered execution.

---

## 1. Mission framing

Rail-on-Rail (RoR) is the only goal. The Spur model line is the
flagship demonstration that Rail's compiler-as-open-substrate is a
structural advantage over training without a verifier in the loop.
Today's session was not a training session. It was an inference-time
substrate session: take Spur-v54 (the current single-best ckpt at
10/30 strip-graded) and add the compiler into the sampling loop, so
every emitted token is constrained to keep the program parseable.

The structural-advantage thesis: if you own the verifier, you can
reject token candidates that produce broken Rail at decode time, and
this should lift the bench's compile-pass rate above what the model
alone can manage. Today proved this works at the **parse tier** but
not yet at the **compile tier**. The reason is informative.

---

## 2. Where things stood at session start (2026-05-05 morning)

- **Best single ckpt:** `spur_v54_BQ2_s77_best` = 10/30 (33%)
  strip-graded.
- **Best portfolio:** 24/30 (80%) ensemble across 46 + 9
  strip-graded ckpts via per-prompt max-pass routing
  (`tools/train/ensemble_ceiling.sh`).
- **Compile-zero wall** confirmed: every architecture/recipe lever
  exhausted. ANY corpus mix or finetune from v54_best destroys
  compile.rail's lever.
- **Inference path:** `tools/train/lm_infer_cpu.rail` with a known
  `inference_seed_segfault.md` confounder on certain (seed, prompt_len)
  combinations.
- **No verifier in the inference loop.** Bench harness used
  N=20 compile-rerank externally — pick a passer from 20 attempts.

---

## 3. What shipped today (commits in order)

All on branch `next`. Every commit pushed to origin (`mini.tb:projects/rail`).

| Commit | Subject | Why |
|---|---|---|
| `b8ca8cd` | Spur-v54 floor + .gitignore whitelist | Anchored the 10/30 single + 24/30 ensemble on a real git ref. 7 inference tarballs + 7 model cards now in `training/checkpoints_published/` and `models/spur/`. |
| `eb8cccd` | `tools/train/probe_verify.rail` — standalone verifier (6/6 sanity) | Smallest possible test that "compile prefix + sentinel" pattern works as a parse oracle. |
| `02316bc` | `tools/train/lm_infer_v2b_probe.rail` — verifier in inference loop, filter fires | Forks `lm_infer_cpu.rail`. Adds `verify_prefix_str` + `verify_pick_loop` + `topk_verify_pick` + `gen_loop_verify`. Filter fires; output bytes diverge. |
| `2ea5706` | `parse-check` subcommand to `rail_native` | **44× speedup** (132ms → 3ms per verify call). Skips codegen + as + ld; runs only `tokenize_with_pos + pprog + ce_decls + report_errors`. Also baked in pre-existing exit-code propagation fix. |
| `4914827` | V-from-shape fix in v2b fork — segfault unblock | argmax_row/topk_sample now read V from `probs.shape[1]`, not the gen_loop arg. Prev: V=130 (corpus build_vocab) vs V_ckpt=93 (manifest) caused row-stride OOB → SIGSEGV on long prompts, garbage logits on short ones. |
| `8ef1618` | Weighted-sample verify (rerank-friendly), restores diversity | Replaced deterministic `verify_pick_loop` (which returned the same byte sequence across all seeds — killing rerank diversity) with `verify_filter_loop` that zeroes ws[i] for failing candidates and reuses `sample_walk_loop` for weighted-multinomial sampling within the verified subset. Parse 0/5 → 5/5; outputs now seed-distinct. |
| `2604e97` | Canonical V-fix in `lm_infer_cpu.rail` | Same fix as v2b; this is the file every flywheel bench defaults to. Implication: **all spur measurements pre-fix were confounded by OOB-garbage logits.** The 10/30 + 24/30 are floors not ceilings. |
| `6001cf1` | Bulk V-fix to `lm_infer_v3_half.rail` + `lm_infer_v3_mixed.rail` | Tracked siblings of canonical, same mechanical-fork bug. |
| `c1a0eb4` | Smarter sentinel — `\n` suffix when prefix has `main =` | Forces the prefix's main expression to be syntactically complete at every step instead of accepting any prefix + freshly-injected `main = 0`. Empirically didn't crack compile (still 0/5) but tightens rejection signal. |
| `609c010` | `tools/train/grammar_walk_probe.sh` + `spec_in_context_probe.py` + .gitignore whitelist | Consolidated probe driver; spec-in-context experiment harness queued for user-triggered run. |
| `4dff83c` | Track 14 lm_infer_cpu_* forks (all V-from-shape patched) | Future sessions get the fix automatically. |

---

## 4. Key findings (with evidence)

### 4.1 Verifier mechanically integrates at zero cost

Per-token verify cost is **lost in inference noise** thanks to
`parse-check`. At max=64, verify mode adds ~1s of wall clock to a
~70-100s inference. For comparison, the original shell-out to full
`rail_native FILE` would have added ~9s/token = 600s for the same gen.

**File:** `tools/compile.rail:3979` (`dispatch_parse_check`)
**Test:** Step 3f result on prompt 3, N=5 seeds 100-104:
- Baseline: parse 0/5, compile 0/5 — model collapses to letter-repetition gibberish
- Verified: parse 5/5, compile 0/5, **5 distinct outputs** (diversity preserved)

### 4.2 Compile-pass wall is parse-check's permissiveness

The verifier accepts `main = anyValidIdentifier` — it cannot tell that
`anyValidIdentifier` won't resolve at link time. Sample verified
outputs:

```
seed 100: main = diFNbdiNF...        — diFNbdiNF undefined → ld fails
seed 101: main = FjIl..llIbjIbjeFjE  — same
seed 102: main = bdje..bd            — same
seed 103: main = d                   — d undefined
seed 104: main = FdddjF              — same
```

All five parse cleanly. None compile. The model's top-K candidates in
the no-ws-first window are letter-collapse, and any letter-chain forms
a syntactically valid identifier name.

K-sweep (3g salvage data, K=10 vs K=30) shows broader candidate pool
brings digits (`0`,`1`,`2`) into reach but verifier still accepts
identifier-chains regardless. **K is not the lever.** Compile-pass
needs name resolution.

### 4.3 V-stride OOB confounded all post-corpus-update spur measurements

`build_vocab` on `training/rail_corpus_stdlib.txt` returns V=130. The
v54_BQ2_s77 manifest is V_ckpt=93. Pre-fix, `gen_loop` passed V=130 to
`argmax_row`/`topk_sample`, which strided `pd[row * 130]` across a
[active, 93] tensor. For long prompts, the OOB read landed in
unmapped memory → SIGSEGV. For short prompts, OOB landed in allocator
slack → garbage logits.

This means **every bench score on the v54-family ckpts was measured
on a partially-broken inference path.** The 10/30 single + 24/30
ensemble are floors, not ceilings. A re-bench with the V-fix in
place could move them in either direction (most plausibly *up*,
because OOB-garbage logits were biasing toward collapse).

**Memory entry:** `~/.claude/projects/-Users-user/memory/grammar_walk_climb_2026-05-05.md`
**Diagnosis credit:** parallel session same day; their 4-line summary
was the unblock.

### 4.4 Argv mangling in `./rail_native run`

`compile_and_run` at `tools/compile.rail:3974` does `join " " lst` over
argv, then re-passes through `shell`. Quoting is destroyed; multi-line
`--prompt` values get split on whitespace and truncated at `\n`.

**Workaround:** compile to `/tmp/rail_out`, copy, exec the binary
directly. This is what `bench_strip.rail` already does.

**Implication:** any tool using `./rail_native run` with multi-word
args is silently passing wrong arguments. Worth a separate climb to
fix.

---

## 5. Open questions, ranked by importance

### Q1: Does spec-in-context bypass the compile gate?

The structural-advantage thesis says the compiler is open. But the
**language is also open** — all of `compile.rail` (~360KB) defines
Rail's syntax + semantics. With a long-context teacher, you don't
have to *learn* Rail from a sliced training corpus; you can *read*
it. Combined with grammar-walked sampling at decode, any long-context
model becomes a Rail-compile-passing model at first contact.

**Probe queued:** `tools/train/spec_in_context_probe.py`. 5 prompts ×
2 arms (naked vs ~1KB Rail self-spec prefix) × N=3 seeds = 30 calls
to Studio's local Qwen-122B-A10B at `10.42.0.2:8088`. Pass criterion:
spec arm beats naked by ≥10pp on compile-pass rate. **User wants
this on user trigger only.**

### Q2: What is v54_BQ2_s77's bench score POST V-fix?

The 10/30 single + 24/30 ensemble were measured pre-fix. With
`2604e97` in place, the canonical inference path is no longer
OOB-corrupted. A re-bench would tell us:
- Whether spur's "compile-zero wall" was partly an inference bug
- Whether the floor moves enough to deserve re-shipping the v54 model card

Cost: ~25 min wall (parallel rerank, 30 prompts × N=20).
Command: `./rail_native run flywheel-local/bench_strip.rail --prefix
training/rail_native/checkpoints/spur_v54_BQ2_s77_best --rerank-N 20`

### Q3: Can we add name resolution to parse-check cheaply?

Right now `parse-check` runs `tokenize + pprog + ce_decls`. Adding a
"build symbol table + check every reference resolves" pass would
catch undefined-identifier errors that today only ld catches.

This would let the verifier reject `main = diFNbdiNF` at decode
time, lifting compile-pass rate.

Cost: compiler surgery in `tools/compile.rail`. Possibly 50-100
lines + bootstrap. Risk: breaks existing tests if name resolution
is too strict (e.g., on partial prefixes). 1-2 hour climb.

### Q4: Is the 40-min beacon hang a real bug?

Mini's beacon (PID 26765) was killed mid-session. It had pinned 100%
CPU for 40 minutes — abnormal vs typical few-second per-frame loop.
Could recur. Worth investigating if it does.

**File:** `~/projects/rail-https/tools/plasma/mhd_beacon.rail`
**Wrapper:** `~/projects/rail-https/tools/plasma/mhd_beacon.sh`
(no per-frame timeout; relies on launchd to restart on crash, but
live-but-stuck doesn't trigger restart)

---

## 6. Suggested next moves (smallest first)

The user's pacing rule (`feedback_endurance_climb.md`): tiny verifiable
steps, not big swings. Falling = run over. Save and ship intermediate
wins. Don't bypass safety checks as shortcuts.

The user's compute rule (`feedback_local_no_budget.md`): on Studio,
the only cost of a 60-min run is 60 min of wall clock. Don't shrink
to a 1-seed smoke when N=5 answers the question.

### Move 1 (2 min, no compute): clear pre-existing uncommitted state

7 modified files (`mutate.rail` +302L, `self_train.rail`,
`lm_v3_chunked.rail`, `gen_triples.rail`, etc.) and 4 untracked files
(`grammar_walk.rail`, `grammar_walk_massive.rail`, etc.) have been
sitting in working tree across multiple sessions. Investigate
ownership before commit/discard. **Do not unilaterally commit;
investigate first** (per `executing actions with care`).

### Move 2 (25 min, low risk): re-bench v54 with V-fix

`./rail_native run flywheel-local/bench_strip.rail --prefix
training/rail_native/checkpoints/spur_v54_BQ2_s77_best --rerank-N 20`
Compare to historical 10/30. If it moved up, re-ship the model card
and update memory entries.

### Move 3 (30-60 min, queued): fire spec-in-context probe

`python3 tools/train/spec_in_context_probe.py` once teacher is loaded
(`http://10.42.0.2:8088/v1/models` returns 200). The teacher is
`Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq` via `mlx_lm.server`.
Cold-load takes 5-15 min.

### Move 4 (1-2 hr, surgery): add name-resolution to parse-check

If Move 3 doesn't crack compile, this is the path. Edit
`tools/compile.rail`'s `dispatch_parse_check` to also build a symbol
table and check references resolve. Bootstrap, run 137-test suite,
check fixed point. Re-run `tools/train/grammar_walk_probe.sh
PROMPT='type Opt = ... main = ' SEEDS='100 101 102 103 104'` to see
if compile-pass moves.

### Move 5 (ongoing): full-bench run with verifier

Once verifier is solid: `./rail_native run flywheel-local/bench_strip.rail
--prefix training/rail_native/checkpoints/spur_v54_BQ2_s77_best
--rerank-N 20 --gen-source tools/train/lm_infer_v2b_probe.rail`.
This requires the bench harness to support passing `--verify 1` to
the gen-source binary; may need a small bench harness patch first.
~1.5-2.5 hr wall.

---

## 7. References

### Commits (chronological, all on `next`, all pushed)

```
b8ca8cd  spur: whitelist + ship Spur-v54 BQ2 (10/30 strip-graded)
eb8cccd  spur: probe_verify.rail — step 2a anchor
02316bc  spur: lm_infer_v2b_probe.rail — step 2b filter fires
2ea5706  compile: parse-check subcommand + exit-code propagation
4914827  spur: lm_infer_v2b_probe.rail — V-from-shape fix
8ef1618  spur: weighted-sample verify, diversity restored
2604e97  infer: canonical lm_infer_cpu.rail — V-from-shape fix
6001cf1  infer: V-from-shape fix bulk-applied to v3_half + v3_mixed
c1a0eb4  spur: smarter sentinel — complete-able exprs
609c010  spur: grammar_walk_probe.sh + spec_in_context_probe.py
4dff83c  infer: track 14 lm_infer_cpu_* forks (all V-fixed)
```

### Memory entries (read for context)

- `~/.claude/projects/-Users-user/memory/grammar_walk_climb_2026-05-05.md` — full climb log with all step-by-step results
- `~/.claude/projects/-Users-user/memory/feedback_endurance_climb.md` — pacing rule
- `~/.claude/projects/-Users-user/memory/feedback_local_no_budget.md` — compute rule
- `~/.claude/projects/-Users-user/memory/next_session_pointer.md` — top-level handoff
- `~/.claude/projects/-Users-user/memory/spur_v48_back_quarter_peak.md` — back-quarter recipe context
- `~/.claude/projects/-Users-user/memory/inference_seed_segfault.md` — pre-existing bug now mostly fixed
- `~/.claude/projects/-Users-user/memory/structural_advantage_thesis.md` — the why behind today's work

### Key files

- `tools/compile.rail` — added `dispatch_parse_check` at line 3979
- `tools/train/lm_infer_cpu.rail` — V-from-shape fix at lines 146 and 202
- `tools/train/lm_infer_v2b_probe.rail` — fork with verifier in gen loop
- `tools/train/probe_verify.rail` — standalone verifier sanity test
- `tools/train/grammar_walk_probe.sh` — env-driven sweep driver
- `tools/train/spec_in_context_probe.py` — queued spec-in-context experiment
- `flywheel-local/bench_strip.rail` — canonical bench harness, defaults to lm_infer_cpu.rail

### Specific file:line citations

- Argv mangling: `tools/compile.rail:3974` (`compile_and_run` does `join " " lst`)
- parse-check dispatcher: `tools/compile.rail:3979` (`dispatch_parse_check`)
- canonical V-fix sites: `tools/train/lm_infer_cpu.rail:146` and `:202`
- v2b fork verify entry: `tools/train/lm_infer_v2b_probe.rail` (search `verify_filter_loop`)

---

## 8. What didn't happen (and why)

- **No new training.** Today was substrate-only. Nothing kicked off
  training because we didn't think a recipe lever existed; we were
  testing inference levers instead. Memory `compile_zero_wall.md` and
  `compile_rail_alone_is_lever.md` document why no recipe lever has
  worked.
- **No re-bench of v54 with the V-fix yet.** Should happen before any
  claim that 10/30 is the real number. Move 2 above.
- **Spec-in-context probe NOT fired.** User explicitly queued for
  later. Don't fire without user signal.
- **V-fix not fully tested across all 16 forks.** Only canonical and 3
  samples were sanity-compiled. The 14 untracked forks compile but
  haven't been runtime-tested. Worth a sweep when one of them gets
  used.

---

## 9. The story in one paragraph

We anchored Spur's current floor (10/30 + 24/30) on git, then built a
verifier into Rail's inference loop, made the verifier 44× cheaper via
a `parse-check` subcommand, fixed an OOB-stride bug that had been
silently corrupting all spur measurements, restored sampling diversity
under verify, and demonstrated that grammar-walked sampling lifts
parse-pass rate from 0/5 → 5/5 on a representative prompt at constant
compute. The compile-pass gate stayed at 0/5 because parse-check is
structurally too permissive — it accepts any well-formed identifier
even if undefined. Cracking compile-pass requires either name
resolution in parse-check, full-compile verify, or the spec-in-context
shortcut (queued). The structural-advantage thesis is no longer just
plausible; it's mechanically realized at the parse tier inside Rail's
own inference loop, with all artifacts on git.
