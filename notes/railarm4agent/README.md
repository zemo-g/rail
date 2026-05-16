# RAILARM4AGENT — fresh-session plan

## Read this first

You are continuing work on **Spur-arm**: a small (~15M params), pure-Rail-trained,
owned model that drives a Hiwonder MaxArm via natural-language commands.
This directory contains everything you need to execute a 4-agent parallel
worktree build of that system. It was authored at the end of session
`83a8fbc2` on 2026-05-16 after that session built and validated the
substrate baseline.

**Quote this goal back to the user verbatim in your first response:**

> Build a pure-Rail-trained, ~15M-param Spur-arm model that drives the
> MaxArm from natural-language commands at precision and robustness
> sufficient for live demo. End-to-end owned: Rail compiler, Rail training,
> Rail inference, Rail-only protocol driver, no Python at runtime.

This is the cash-out of the Rail-on-Rail mission ([[mission]]) on a real
downstream task. The substrate baseline (`66bb63f9` on the lab chain) is
20/20 at N=20 rerank on the v0 bench — that's the bar to chase.

---

## What is in this directory

| File | Purpose |
|---|---|
| `README.md` (this) | Orientation, goal, status, integration plan, acceptance criteria |
| `RESEARCH.md` | Research synthesis: prior art, small-model SoTA, datasets, RLVR — with citations |
| `AGENT_A_corpus.md` | Self-contained brief for Agent A (corpus pipeline) — hand to worktree agent verbatim |
| `AGENT_B_train.md` | Self-contained brief for Agent B (tokenizer + base model + SFT) |
| `AGENT_C_decode_rl.md` | Self-contained brief for Agent C (constrained decode + DAPO RL) |
| `AGENT_D_maxarm.md` | Self-contained brief for Agent D (MaxArm protocol driver + integration) |

Read `RESEARCH.md` next, then orient yourself with `git log --oneline -20`,
then go to the agent prompts.

---

## What already exists (from session 83a8fbc2)

These files are LIVE and WORKING — do not re-build them. Build on top.

```
stdlib/robot_arm.rail               # DSL: type Cmd = MoveTo|SetGrip|Wait|Home, points A..D
tools/robot/arm_sim.rail            # sim, three entry points: run_sim, run_sim_with_world, run_sim_from_state
tools/robot/arm_sim_smoke.rail      # sim smoke
tools/robot/bench_v0.txt            # 20 (id, nl_prompt, world, expected_final) rows
tools/robot/dsl_spec.txt            # DSL spec used as bench system prompt
tools/robot/talk_spec_base.txt      # extended DSL spec with pronoun rules + ASK protocol
tools/robot/grader.rail             # 4-stage grader (compile/parse/run/goal-reach)
tools/robot/reference_scripts/      # 20 hand-written reference scripts; all hit stage=4
tools/robot/grade_all.sh            # runs grader over a completion directory
tools/robot/call_substrate.sh       # jq-based MLX caller (bypasses broken stdlib/llm.rail)
tools/robot/baseline_run.sh         # single-shot baseline driver
tools/robot/baseline_rerank.sh      # N=20 rerank driver, BATCH=4 to avoid Metal OOM
tools/robot/talk.sh                 # conversational REPL (uses substrate via call_substrate.sh)
tools/lab/watchers/robot_arm_*.sh   # chain entry sentinel watchers
notes/robot_session/HANDOFF.md      # session 83a8fbc2 handoff
notes/robot_session/baseline_*.log  # measurement logs
notes/robot_session/SPURARM_BUILD_PLAN.md  # earlier draft of this plan (superseded by railarm4agent/)
```

**Empirical baseline:**

| Setting | Score | Wall clock | Chain entry |
|---|---|---|---|
| Substrate single-shot N=1 (pre-Home-fix) | 18/20 | 54 s | `74b0fd64` |
| Substrate single-shot N=1 (post-Home-fix) | 19/20 | 56 s | `90091a41` |
| Substrate N=20 rerank, TEMPERATURE=0.9, BATCH=4 | **20/20** | **13m 20s** | `66bb63f9` |
| Reference scripts (hand-written) | 20/20 | < 1 min | n/a |

Substrate = `mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq` via MLX
on Studio :8082. Start it with:

```
nohup mlx_lm.server --host 127.0.0.1 --port 8082 \
  --model mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq &
```

You can run the substrate baseline yourself to confirm the prior session's
numbers reproduce before starting any agent.

---

## Hardware (your target — the MaxArm)

Hiwonder MaxArm Starter Kit (from the Amazon listing shared by the user).
This is what Spur-arm must drive.

| Spec | Value |
|---|---|
| DOF | 4 (3 arm + 1 gripper) |
| Controller | ESP32 |
| Communication | USB serial |
| Power | 12V 5A DC |
| Reach (radius) | 290 mm |
| Reach (vertical above base) | 187 mm |
| Reach (below base) | 111 mm |
| Rotation envelope | ±120 degrees |
| Base footprint | 4.7 inches |
| Gripper | Suction cup (vacuum on/off, not finger position) |
| Bundled targets | 3 cm wooden blocks (red/green/blue) |
| Weight | 1.3 kg |

Implications baked into the plan:
- **No wrist roll** — bench prompts implying orientation ("stack neatly") cannot
  be expressed. Bench v0 is reachability-only and is safe.
- **Suction gripper** — pickup is binary (vacuum on at correct position attaches).
  Mis-alignment > 1 cm means failure. Sim's 1 cm tolerance maps directly.
- **Workspace** — real arm reaches 29 cm radius; our DSL is a 30 cm cube.
  Close enough that the existing DSL coords map 1:1 cm. Calibration step
  validates each named point physically.
- **No vision needed** — input is text, world state is tracked in REPL.

---

## The 4 agents at a glance

```
A (corpus) ─┐
            ├─► B (tokenizer + SFT) ─► C (constrained decode + DAPO RL) ─┐
            │                                                            ├─► integrated demo
D (MaxArm protocol driver + integration) ───────────────────────────────┘
```

| Agent | Owns | Estimated time | Blocks | Blocked by |
|---|---|---|---|---|
| A | `tools/spurarm/corpus/`, `training/corpora/spurarm_v0.jsonl` | 6–8 h | B | nothing |
| B | `stdlib/spurarm_model.rail`, `tools/spurarm/train/` | 10–14 h | C | A |
| C | `tools/spurarm/decode/`, `tools/spurarm/rl/` | 8–10 h | integration | B |
| D | `tools/robot/arm_real.rail`, `tools/robot/talk_arm.sh` | 6–10 h | integration | nothing (parallel) |

Per `parallel_v0_workflow` memory entry: each agent runs in its own
worktree. A and D start immediately. B starts as soon as A's first
corpus pass is graded. C starts as soon as B's first SFT base lands.

**Compute contention:** B and C both need the Studio GPU heavily. Plan
to run them serially on Studio, not concurrently. A is light (parsing,
filtering). D is hardware-bound, no GPU.

---

## Integration plan (post-agent)

When agents A/B/C/D each report DONE on their acceptance test, the
integration session runs in this order:

1. **Merge A** into `next`. Verify `wc -l training/corpora/spurarm_v0.jsonl`
   matches Agent A's count. Spot-check 50 random pairs through the grader.

2. **Merge B** into `next`. Verify SFT checkpoint loads and bench v0
   single-shot gives the score Agent B reported. Fail-fast if it doesn't
   match within ±1 prompt — investigate before continuing.

3. **Merge C** into `next`. Verify constrained-decode keeps 100% compile
   rate. Verify DAPO checkpoint bench v0 single-shot ≥ SFT baseline.

4. **Merge D** into `next`. Verify `tools/robot/replay_cmd_log.sh
   /tmp/arm_commands.log` on the physical MaxArm reproduces the
   prior-substrate session's actions. If no physical arm yet, verify the
   driver compiles, the protocol layer passes its unit tests, and the
   `arm_real.rail` ↔ `arm_sim.rail` swap doesn't break `talk.sh`.

5. **End-to-end demo.** `bash tools/robot/talk_arm.sh` connected to MaxArm:
   - "grab the red block" → picks up
   - "put it on the green block" → stacks
   - "go home" → returns to origin

6. **Chain entry.** Append a result chain entry with kill_target +
   counters (parent: `66bb63f9`). Headline number: Spur-arm goal_reach
   on bench v0 at N=1 and N=20.

7. **Memory entry.** Add `spurarm_v0_shipped_2026-MM-DD.md` to memory
   capturing: final model size, training cost, bench numbers, what
   surprised us, named open questions.

---

## Acceptance criteria for the whole arc

The arc PASSES if all of these hold:

1. **Bench v0 with trained Spur-arm**: single-shot ≥ 16/20 (within 4 of
   substrate's 19/20 single-shot), N=20 rerank ≥ 18/20 (within 2 of
   substrate's 20/20).
2. **Real-arm pick-and-place**: `talk_arm.sh` executes `"grab the red
   block"` → suction picks up → user-confirmed.
3. **Owned end-to-end**: no Python at runtime. `talk_arm.sh` invokes only
   `rail_native`, the Spur-arm checkpoint, the trained tokenizer, and
   the MaxArm USB driver. `mlx_lm.server` is NOT in the runtime path
   (only used at train-time for substrate distillation).
4. **Latency**: typed-turn → arm-acks-cmd round-trip ≤ 2 seconds median.
5. **Chain receipt**: a PASS entry on the lab chain with reproducer
   cmd; replays clean from a fresh checkout.

The arc is INCONCLUSIVE (acceptable, named outcome) if:
- 1 holds but 2 fails because MaxArm hasn't shipped yet. Add a "real-arm
  acceptance pending" tag on the chain entry.
- 4 fails (Spur-arm too slow) but a fix path is named.

The arc is FALSIFIED if:
- 1 fails badly (single-shot below 10/20 after RL).
- The 15M architecture proves too small AND scaling to 30–50M doesn't
  close the gap.
- `inference_seed_segfault` blocks the inference path with no workaround.

---

## Risk register

| Risk | Mitigation | Kill criterion |
|---|---|---|
| 15M is too small for open-domain NL | Scale to d=512 then d=640 (still under 50M) | If d=640 doesn't hit 12/20 single-shot post-SFT, the recipe is wrong, not the size |
| VH/ALFRED domain gap (objects, verbs) | Slot-substitute object names with `<obj_N>` during pre-train | If SFT-only outperforms pretrain+SFT on bench v0, drop pre-train and SFT directly |
| `inference_seed_segfault` (memory: `inference_seed_segfault`) | Use `--k 1` argmax during demo; bisect bug as separate arc | If can't even argmax cleanly, escalate to user as a compiler-bug session |
| MaxArm protocol unknown until Agent D digs | Agent D's first deliverable is the protocol research report | If protocol turns out to be undocumented binary that needs reverse-engineering, scope D up |
| Suction-gripper 1 cm tolerance violated by real-world drift | Calibration routine (Agent D) | If even calibrated arm can't pickup reliably, narrow bench v0 to "drop near target" and document |
| RL doesn't lift over SFT (Yang et al. limit) | Don't oversell RL; SFT is the headline | If post-DAPO bench drops, ship SFT-only model, document RL as future work |
| Studio panics under stacked training + serving | Run B and C sequentially, not concurrently | Memory `studio_panic_pattern` |
| MLX OOM at high concurrency during distillation harvest | BATCH=4 cap | Memory `robot_arm_flywheel_2026-05-16` records the OOM |

---

## Out of scope for this arc (defer)

- **Voice STT.** Talk to typed input first. Add Whisper/local-STT wrapper later.
- **Multi-object worlds (bench v1).** Single ball / single block. Bench v1 is its own arc.
- **Mobile base.** MaxArm is a fixed-base arm.
- **Object detection / vision.** Spur-arm reads state from the REPL, not pixels.
- **General Spur (non-arm) training.** Per `fccdb405`, Spur-on-hard-bench is on freeze.
  This arc trains a SEPARATE specialized model and does not re-open the freeze.
- **Distillation to <1M params.** Research says 15M is the credible floor; do not
  chase smaller until the 15M version works.

---

## Reproducer commands (orient yourself)

Before starting agents, confirm the prior session's state reproduces:

```bash
# Where you are
cd /Users/user/projects/rail
hostname  # should be Studio
git log --oneline -10

# Substrate online?
curl -sS --max-time 3 http://localhost:8082/v1/models | head -c 200
# If down, start it:
# nohup mlx_lm.server --host 127.0.0.1 --port 8082 \
#   --model mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq &

# Reference scripts (bench self-validation; should be 20/20)
sh tools/robot/grade_all.sh | tail -1

# Substrate baseline single-shot (should be 19/20)
sh tools/robot/baseline_run.sh | tail -3

# Chain receipts present?
/tmp/rail_run_lab search "robot-arm" 2>&1 | head -5
```

Expected:
- 20/20 on grade_all
- 19/20 on baseline_run
- 4 chain entries matching `32487cda` → `66bb63f9`

If any of these doesn't reproduce, surface it to the user FIRST before
starting agents. The plan assumes the baseline is intact.

---

## Worktree commands per agent

Spawn each agent in its own worktree per `parallel_v0_workflow`. Suggested
pattern (adapt to your harness's worktree mechanism):

```bash
# Agent A
git worktree add ../rail-spurarm-A -b spurarm/A-corpus next
# in that worktree: cat notes/railarm4agent/AGENT_A_corpus.md and hand to the agent

# Agent B (start after Agent A's first corpus pass merges to next)
git worktree add ../rail-spurarm-B -b spurarm/B-train next

# Agent C (start after Agent B's first SFT checkpoint merges)
git worktree add ../rail-spurarm-C -b spurarm/C-decode-rl next

# Agent D (parallel from session start)
git worktree add ../rail-spurarm-D -b spurarm/D-maxarm next
```

Each agent's brief tells it which files to read first (this README,
RESEARCH.md, its own AGENT_X.md) and lists its acceptance test exactly.

---

## Chain discipline

Each agent appends ONE chain entry on completion (PASS / FAIL / INCONCLUSIVE
per its acceptance test). Lab CLI at `/tmp/rail_run_lab`. Signing key at
`~/.rail/lab/signing_key.pem`. Parent for all agent entries: `66bb63f9`
(the substrate-thesis baseline).

Each entry's `cmd` must point to a watcher in `tools/lab/watchers/` that
emits the canonical sentinel block (see existing
`tools/lab/watchers/robot_arm_baseline_*.sh` for the format).

Pre-normalize Unicode in chain entry text — the R-ASCII gate rejects
em-dashes and other non-0x20-0x7E bytes.

---

## Related memory (load these in your fresh session)

- `mission` — Rail-on-Rail is the only goal
- `structural_advantage_thesis` — why owned verifier matters
- `parallel_v0_workflow` — N-agent worktree discipline
- `robot_arm_flywheel_2026-05-16` — the prior session this builds on
- `lab_chain` — chain framework usage
- `chain_caught_five_wrong_leverage_swings` — discipline lesson: propose chain entry BEFORE swinging
- `feedback_blob_slice_fan_condense` — multi-seed fan training pattern Agent B should use
- `spur_lineage_archive` — what Spur recipes worked at what scale
- `feedback_endurance_climb` — small steps, not big swings; protect the 10/30 + 24/30 floor
- `feedback_diagnostics_first` — ship the counter before changing the thing
- `feedback_verify_removals` — when removing a guard, write the falsifying smoke test FIRST

---

## How to use this plan in the fresh session

1. **First response**: quote the goal line verbatim (the indented quote at the top of this file).
2. **Read RESEARCH.md** to load the research findings into your context.
3. **Verify baseline** with the reproducer commands above.
4. **Confirm with the user** before spawning agents — they may want to
   refine the plan or change priorities.
5. **Spawn the agents** in worktrees with their respective AGENT_X.md
   briefs.
6. **Monitor** without polling. Each agent reports back on its own.
7. **Integrate** in the order specified above.
8. **Ship** with a chain entry + memory update + handoff.

Stay disciplined: this is **precision and robustness focused** (the user's
words). Don't trade correctness for speed. Multi-seed fan over single-shot
heroics. Verify acceptance tests honestly. If an agent reports DONE but
the acceptance test fails on your machine, the agent failed — escalate.
