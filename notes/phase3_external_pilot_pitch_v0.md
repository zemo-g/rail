# Rail external pilot — pitch v0

**Status:** draft. Phase 3 of the strategic arc. To be opened the moment phase-2 playground v0 lands (Session C complete).
**Audience:** organizations or individuals who would benefit from a substrate-anchored claim about AI-generated code.
**Date:** 2026-05-13.

---

## Headline

**A frontier model + a 1KB Rail spec compiles 30/30 on a held-out hard-bench, beating a fine-tuned ensemble. The verifier is open and signed. You can reproduce it from the browser.**

That sentence is the entire pitch. Everything else is evidence and ask.

## The thesis

The prevailing wisdom for "make AI write better code" is **train on more code**: bigger models, more SFT, more RLVR against opaque verifiers. The implicit assumption is that the model is the variable.

The substrate thesis says: **the verifier is the variable**. An AI model interacting with an open, correct, self-hosted compiler can outperform a model fine-tuned against a closed verifier — because the open substrate exposes its full grammar to the model's prompt, and every compile is an honest signal rather than a heuristic match.

**This is testable. We tested it.**

## Proof points (today, on `next`)

| Claim | Evidence | Reproducible by |
|---|---|---|
| Frontier model + 1KB Rail spec compiles 30/30 on held-out hard-bench | `[[substrate_30_of_30_2026-05-09]]` — every band 5/5, zero hard failures, 15.4 min wall-clock, beats Spur ensemble 24/30 | `bash tools/bench/repro_30of30.sh` (auto-detects local MLX vs Anthropic API; see `tools/bench/README.md` for both paths) |
| Compiler is genuinely self-hosted on two backends | ARM64 140/140 + x86_64 128/128 (representative subset), byte-identical self-compile fixed point at gen2 | `./rail_native test && ./rail_native self && cmp rail_native /tmp/rail_self` |
| Verifier is open and signed | Provenance tier v2 — multi-witness Ed25519 attestations binding `pulse_id`, browser-side verify at `/verify/<id>` | `https://ledatic.org/verify/<id>` — anyone with a browser |
| Compiler stack has zero C dependencies | Pure Rail + ARM64/x86 asm. Only requires `as` + `ld` | `nm rail_native | grep -c '^.* T '` — every text symbol traces to Rail or asm source in this repo |
| Browser playground proves the on-ramp works | Phase-2 Session B/C — *coming, expected EOM May* | `https://ledatic.org/playground` — paste Rail, click Run |

## What an external pilot looks like

**Three concrete shapes**, ranked from least to most committal. A partner picks one.

### Shape A — independent reproduction (smallest)

Partner runs the 30/30 hard-bench against their preferred frontier model from a clean environment (their hardware, their API key, our spec + bench harness). Publishes the result with a witness signature using the same provenance pipeline. Time: 1 day. Output: a second independent attestation that the substrate thesis isn't a single-author artifact.

**Reproduction:** `tools/bench/README.md` documents both paths. Path A (Anthropic API, ~$15-20 USD per full run, ~15-25 min) needs only an `ANTHROPIC_API_KEY` plus the public Rail compiler. Path B (local MLX/vLLM with a 100B+ open-weight) needs the model running on an OpenAI-compatible endpoint. The bench prompt list is grep-able at `tools/bench/substrate_hard_bench.rail`.

### Shape B — substrate-vs-fine-tune A/B (medium)

Partner has an existing fine-tuned coding model (or an SFT/RLVR pipeline). They run their model two ways: (a) against their existing closed verifier, (b) against Rail-as-substrate using only the 1KB spec. Compare compile rate, holdout generalization, and inference cost. Time: ~1-2 weeks. Output: a head-to-head benchmark that either confirms or falsifies the substrate-not-model framing on a different model than the one in our claim. **Falsification is a valid result and we'll publish it.**

### Shape C — production pilot (largest)

Partner integrates Rail-as-substrate into a real internal coding workflow (e.g., a code-review assistant, a config-DSL generator, an infra-as-code authoring tool). We help with stdlib coverage gaps and bench on their corpus. Time: 4-8 weeks. Output: a real-world utility data point + the gap inventory that drives Rail's stdlib roadmap.

## What is honestly NOT ready yet

- **Stdlib breadth.** Rail's stdlib covers what Rail itself needed (HTTP, JSON, crypto, tensor ops, channels). Your domain is probably not yet covered. We'd add what's blocking your pilot.
- **External-developer ergonomics.** Error messages are correct but terse. Editor support is `<textarea>` + the playground. No language server. You will be among the first non-author users — expect rough edges and short feedback loops.
- **Concurrency story.** v1 typed channels + select shipping in this same window. Earlier than v1 is `int64`-only.
- **Garbage collection across threads.** Channel sends of heap pointers are "shared-immutable only" until the GC is multithread-aware. Pilots involving heavy inter-thread heap traffic should wait.
- **Documented stable surface.** No semver guarantee. Stdlib symbols can move during the developer-surface phase. We commit to changelog discipline; we don't yet commit to non-breaking releases.

This list is the honest list. If you're betting on Rail today, you're betting on the substrate thesis, not on a polished SDK.

## Why Ledatic specifically

- The compiler, verifier, provenance pipeline, and playground are all one project under one author. **Decisions land in days, not quarters.** Your pilot's blockers are the highest-priority work the project takes on.
- Every published claim is signed and browser-verifiable. There's no marketing layer over an unaudited result.
- The structural advantage is genuinely architectural: **we own the verifier**. We can do things published RLVR work cannot — process reward at compile time, parse-trace aux loss, grammar-walked curriculum, compile-in-loop sampling. See `[[structural_advantage_thesis]]`.

## The ask

For Shape A: nothing from us beyond the spec + harness + a 30-min onboarding call. Run on your terms.

For Shape B: a 60-min scoping call to align on the comparison protocol + a published joint result.

For Shape C: a 60-min scoping call + a co-authored success-criteria doc before any work begins. We'd commit to a named contributor for the duration.

In all cases: a witness signature on the result. That's how the thesis becomes undeniable rather than just demonstrated.

## Candidate partner profiles (not specific orgs — user's call)

- **Coding-model labs** with their own RLVR pipeline who are starting to question opaque-verifier ceilings (Shape B is highest-leverage here).
- **DSL or low-code teams** at companies whose product is a domain-specific authoring surface (Shape C — Rail-as-substrate is the natural fit; partner gets a verifier they didn't have to build).
- **AI evaluation orgs** (e.g., academic benchmark groups, model-card publishers) who could run Shape A and publish independently.
- **Provenance/attestation projects** (e.g., supply-chain security, AI model registries) who could integrate Rail's witness pipeline as a verifier component.
- **Single high-context developers** building agentic systems (Shape A or C) who want a substrate where every compile is honest signal.

## Outreach template (draft)

> Subject: Independent reproduction of a 30/30 substrate result
>
> We've published a result that a frontier model + a 1KB language spec compiles 30/30 on a held-out hard-bench, beating our own fine-tuned ensemble at the same task. The verifier is open and the result is signed (link).
>
> If the substrate-vs-model framing matters to your work, we'd value an independent reproduction or a head-to-head against your own pipeline. We've outlined three shapes [link to this doc] from "1 day, no commitment" to "joint pilot."
>
> Worth a 30-min call?

## Open questions (decide before sending)

- Do we publish this pitch publicly (`/pilot` on ledatic.org) or use it only in 1:1 outreach?
- Do we name candidate partners on the public version, or keep targeting private?
- Witness signature on partner results — do we offer to co-witness or do we want partners to run their own witness?
- Pricing — is Shape C work pro-bono (in exchange for the pilot) or a paid engagement? If paid, what's the rate?

These are user calls. Do not pre-decide.

## Status

**Draft v0.** Do not publish until phase-2 Session C ships and `https://ledatic.org/playground` is live. The "you can reproduce it from the browser" headline cashes a check the playground writes.

**Audit closure:** F-53 ("30/30 needs reproducibility statement") closed 2026-05-13 by `tools/bench/{substrate_hard_bench.rail, repro_anthropic.py, repro_30of30.sh, README.md}`. External partners can now reproduce without Studio access.

Related: `[[substrate_30_of_30_2026-05-09]]`, `[[structural_advantage_thesis]]`, `[[provenance_tier_shipped_2026-05-09]]`, `[[strategic_arc_2026-05-13]]`, `notes/playground_v0_spec_2026-05-13.md`.
