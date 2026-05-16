# Robot-arm flywheel session - 2026-05-16

## Headline

| Setting | Score | Wall clock |
|---|---|---|
| Single-shot (N=1, temp=0.3) - pre-Home-fix | 18/20 | 54 s |
| Single-shot (N=1, temp=0.3) - post-Home-fix | 19/20 | 56 s |
| N=20 rerank (temp=0.9, BATCH=4) | **20/20** | **13m 20s** |

Substrate: Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq on Studio :8082.
This is the substrate-thesis carried to a new downstream task:
natural-language -> Rail DSL script -> compile + sim-verify. No Spur
training needed to clear the kill_target (>= 10/20). The 20/20 result
mirrors the substrate_30_of_30_2026-05-09 result on a fresh bench.

## What's on chain

```
fccdb405  Training freeze genesis (prior session)              INCONCLUSIVE
  └─ 32487cda  Robot-arm flywheel genesis (this session)        INCONCLUSIVE
       └─ 74b0fd64  Single-shot baseline (Home auto-open)        PASS (18/20)
            └─ 90091a41  Single-shot post-Home-fix               PASS (19/20)
                 └─ 66bb63f9  N=20 rerank                        PASS (20/20)
```

The chain refused the first post-fix entry because of an em-dash in the
hypothesis text (R-ASCII gate working). Lesson: pre-normalize Unicode in
all chain entry text.

## Files landed

| File | Role |
|---|---|
| `stdlib/robot_arm.rail` | DSL: `type Cmd`, `MoveTo / SetGrip / Wait / Home`, named points A..D, ORIGIN. Library — no main. |
| `tools/robot/arm_sim.rail` | Sim: interprets a script, tracks effector + 1-object world, emits `SIM_RESULT ex=.. ey=.. ez=.. grip=.. held=.. ... fault=.. steps=..`. Library — no main. |
| `tools/robot/arm_sim_smoke.rail` | Sim smoke harness (6 scenarios). |
| `tools/robot/bench_v0.txt` | 20 (id, nl_prompt, world, expected_final_state) pipe-separated rows. |
| `tools/robot/dsl_spec.txt` | DSL spec used as system prompt for substrate calls. |
| `tools/robot/grader.rail` | 4-stage grader: compile / parse / run / goal-reach. Honors a1_grader_bug discipline (clears /tmp/rail_out, parses SIM_RESULT only). |
| `tools/robot/reference_scripts/b*.rail` | 20 reference scripts; ALL hit stage=4. Bench self-validates. |
| `tools/robot/grade_all.sh` | Runs grader over a directory of completions. |
| `tools/robot/call_substrate.sh` | jq-based substrate caller (bypasses broken stdlib/llm.rail escape pipeline). |
| `tools/robot/baseline_run.sh` | Single-shot baseline driver. |
| `tools/robot/baseline_rerank.sh` | N rerank driver with batching to avoid Metal OOM. |
| `tools/robot/substrate_driver.rail` | Pure-Rail driver (unused — stdlib/llm.rail's newline escape is broken; superseded by call_substrate.sh + baseline_run.sh). |
| `tools/lab/watchers/robot_arm_flywheel_genesis.sh` | Chain genesis sentinel. |
| `tools/lab/watchers/robot_arm_baseline_single_shot.sh` | 18/20 result sentinel. |
| `tools/lab/watchers/robot_arm_baseline_post_home_fix.sh` | 19/20 result sentinel. |
| `notes/robot_session/*.log` | Run logs for reproducibility. |

## Failure modes observed

| ID | Mode | Cause |
|---|---|---|
| b09 (pre-Home-fix) | fault=3 grip_already_open | Sim's `Home` auto-opened the grip, then substrate emitted explicit `SetGrip GripOpen` after Home. **Fixed**: Home is now pure navigation. |
| b14 | stage=3 wrong final pos | Substrate interprets "drop it at the same spot you started from" as the pickup point (A), not the arm's initial position (origin). Genuinely ambiguous English. May resolve at N>=20 rerank via diverse interpretations. |

## Spec-discovered Rail quirks (not new, but reconfirmed)

1. **Nested ADT match patterns mis-dispatch.** `match c | SetGrip GripOpen -> ... | SetGrip GripClose -> ...` routes both grip variants to one branch. Workaround: flatten via inner helper. Same family as [[jit_adt_match_dispatch_open]].
2. **Library files must not have `main`.** Importing a file with `main` collides on the importing program's `main` symbol. Split into `<lib>.rail` (library) + `<lib>_smoke.rail` (runnable smoke) pattern.
3. **Negative literals after spaces are subtraction.** `run_sim_with_world script -1 0 0` parses as `script - 1 0 0`. Emit `(0 - 1)` instead.
4. **`stdlib/llm.rail`'s `llm_esc_nl` produces `\<CR>n` instead of `\n`.** Broken JSON escape. Use jq for payload construction (see `tools/robot/call_substrate.sh`).
5. **Auto-import is per-symbol-not-per-file.** Some stdlib helpers (e.g. `cat` from string.rail) resolve without explicit import; others (`intercalate`, `all`) don't. Inline replacements when in doubt.

## Operational gotchas

- **MLX OOMs at N=20 concurrent on the 2.34-bit 122B model.** Metal command buffer Insufficient Memory. Batch to N=4 concurrent (see `BATCH=4` default in baseline_rerank.sh).
- **Substrate at temp=0.3 is near-deterministic** — same completion across reruns. For rerank diversity, bump to >=0.7. Default in baseline_rerank.sh is 0.9.

## Reproduce

```bash
# Start substrate (Studio :8082, ~30s to load)
nohup mlx_lm.server --host 127.0.0.1 --port 8082 \
  --model mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq &

# Validate bench (should hit 20/20)
sh tools/robot/grade_all.sh

# Substrate single-shot baseline (~55s, expects ~19/20)
sh tools/robot/baseline_run.sh

# N=20 rerank with batching (expects to close b14)
bash tools/robot/baseline_rerank.sh

# Conversational REPL (the "talk to Spur" interface)
bash tools/robot/talk.sh
```

## Conversational REPL (`tools/robot/talk.sh`)

Interactive terminal where you talk to the arm like a person. Engine is
the same substrate, wrapped with: stateful world tracking across turns,
pronoun resolution ("it", "this", "here"), conversation history in the
prompt, and an ASK protocol for genuinely-ambiguous commands.

```
$ bash tools/robot/talk.sh
Robot ready. Talk to me. /state /commands /history /reset /quit
[state]
  arm position : (0, 0, 0)
  grip         : open
  holding      : nothing
  ball         : at (10,0,5)
> grab the ball
[robot] Done. I'm at (10, 0, 5), grip closed, holding the ball.
> take it to B
[robot] Done. I'm at (10, 10, 5), grip closed, holding the ball.
> drop it
[robot] Done. I'm at (10, 10, 5), grip open, empty-handed.
> grab the cube
[robot] I don't see a cube, only a ball. Did you mean to grab the ball?
```

Slash commands: `/state` `/commands` `/history` `/reset` `/quit`.

**Smart-child interpretation**: silent best-guess for common pronoun cases;
the substrate emits `ASK: ...` only when context is genuinely empty.

**Cmd log mode**: every executed `Cmd` is appended to `/tmp/arm_commands.log`
with a timestamp. When the physical arm arrives, replaying this log
against a thin protocol driver is the smoke test. View with `/commands`.

**State persistence**: `/tmp/robot_world.txt` survives across REPL exits
within a session. `/reset` clears it.

Engine note: the prompt says "Robot" and the user calls it "Spur" - it's
actually the Qwen-122B substrate. Spur (the small owned model) is on
training freeze per `fccdb405`; rewiring talk.sh to use Spur later is a
one-line swap (point `call_substrate.sh` at a different endpoint).

## Next-session ranked

1. **Real arm wiring**: when the physical arm arrives, swap `arm_sim.rail` for a thin driver that sends MoveTo/SetGrip/Wait commands over the arm's protocol. The `/tmp/arm_commands.log` from any talk.sh session replays as a smoke test. Sim becomes the dry-run / validation environment.
2. **Bench v1**: harder prompts. Multi-object worlds, stacking, conditional language ("if grip is empty"), implicit goals ("clean up the desk"). Bench v0 was deliberately reachability-oriented.
3. **Voice input**: STT pipeline -> talk.sh stdin. Voice is the user-facing axis; the substrate-thesis already cleared the language-to-DSL gap.
4. **Spur distillation from substrate**: harvest (prompt, successful-script) pairs from talk.sh sessions and finetune a smaller model. Substrate at 20/20 is a good teacher; question is whether 27B or 8B distilled carries the capability. The structural-advantage thesis arc, now grounded in a real use case.
5. **Substrate-narrated mode**: instead of templated `narrate()` output, optionally pipe SIM_RESULT back to substrate for a friendly natural-language summary. Trades one extra LLM call per turn for better feel ("I picked up the ball gently and set it on point B.").

## Don't waste time re-deriving

- The 5 Rail quirks above all cost ~5-10 min each this session.
- MLX needs to be restarted between heavy concurrent loads; once it OOMs, no recovery short of restart.
- `stdlib/llm.rail` has the newline-escape bug; don't try to debug it in-session, just use `tools/robot/call_substrate.sh`.

## Related memory

[[lab_chain]] — chain framework. [[chain_caught_five_wrong_leverage_swings]] —
why we wrote the bench before training. [[substrate_30_of_30_2026-05-09]] —
prior substrate-thesis number on the hard bench. [[fleet]] — MLX server
location and start command. [[a1_grader_bug_2026-05-08]] — the grader bug
we deliberately avoided by writing a new grader.
