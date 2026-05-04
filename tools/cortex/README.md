# Cortex (v2 — pure Rail)

The empire's cortex. A 5-minute LLM tool-loop in pure Rail with cortex_v1's safety scaffolding.

## Lineage

Spiritual successor to `~/empire/legacy/cortex_v1/` (Python, retired 2026-02-26). v1 was a rule-based fix engine for the trading system. v2 is an LLM tool-loop wrapped in v1's safety scaffolding (4 SafetyTiers, cooldowns, rate limits, kill switch, audit trail, escalation files). Same vocabulary, broader scope (the whole Ledatic stack, not just trading).

## Where it lives

| | |
|---|---|
| Source | `tools/cortex/cortex.rail` (this dir) |
| Goals (leader-editable) | `~/.ledatic/cortex/goals.md` |
| LaunchAgent | `~/Library/LaunchAgents/com.ledatic.cortex.plist` |
| Cadence | every 300 s |
| State | `~/.ledatic/cortex/` (decisions.jsonl, state.json, escalations/) |
| Kill switch | `touch ~/.ledatic/cortex/kill` |

## What one tick does

1. Read perception bus: heal events, last drift audit, beacon, witness, fleet status, leader's `goals.md`.
2. Build a prompt that lists the perception bus + the tool whitelist + the strict output format.
3. Call Claude Haiku 4.5 via `stdlib/anthropic_client.rail` (pure-Rail TLS 1.3, direct to api.anthropic.com).
4. Parse the response — first line `TOOL: <name>`, second line `REASON: <one sentence>`.
5. Look up the tool. If not whitelisted → audit "unknown_tool" + exit.
6. Check cooldown + hourly cap. If on cooldown → audit "cooldown" + exit.
7. Otherwise: execute the tool's command, capture output, append to `decisions.jsonl`, update `state.json`, post to Slack iff non-`wait`.

## Safety scaffolding inherited from v1

| Tier | Cooldown | Max/hr |
|---|---|---|
| AlwaysSafe | 120 s | 10 |
| Reversible | 600 s | 3 |
| Money | 1800 s | 2 |
| Human | 3600 s | 1 |

## Tool whitelist (v1 — read-only-ish)

| Tool | Tier | What |
|---|---|---|
| `wait` | AlwaysSafe | Pass. Most ticks should land here. |
| `audit_dry` | AlwaysSafe | drift_audit --dry (no Slack/publish/PR) |
| `audit` | AlwaysSafe | full drift_audit (auto-publishes missing manifests, opens site-bump PR on banner drift) |
| `verify` | AlwaysSafe | walk every published binary, verify signed-manifest integrity |
| `tail_heal` | AlwaysSafe | last 20 lines of heal.log |
| `tail_drift` | AlwaysSafe | last 30 lines of audit.log |
| `tail_attest` | AlwaysSafe | last 20 lines of daily attest |

Write actions (`bump`, `kill`, `restart`) are **not** in this whitelist. Those go through the leader (via `ears` / `slack_listener`). Cortex is *eyes + judgment + idempotent reads + audit/verify*. The leader is the *hands for change*.

## Extending

Add a new tool: append a `Tool` to the `available_tools` list in `cortex.rail`, recompile (`./rail_native run tools/cortex/cortex.rail` does fresh-compile each tick anyway). Match an existing SafetyTier to keep the cooldown/rate-limit story consistent.

To pause cortex temporarily: `touch ~/.ledatic/cortex/kill`. To resume: `rm ~/.ledatic/cortex/kill`.

## Observability

```bash
tail -f ~/.ledatic/cortex/decisions.jsonl   # every choice + verdict
ls    ~/.ledatic/cortex/escalations/         # things cortex couldn't handle
cat   ~/.ledatic/cortex/state.json           # cooldown state
cat   ~/.ledatic/cortex/launchd.err          # crash output, if any
```

Slack: every non-`wait` decision lands in `brockbro2`.
