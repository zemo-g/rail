# Rail substrate hard-bench

The canonical bench behind the published claim:

> A frontier model + a 1KB Rail spec compiles **30/30** on a held-out
> hard-bench, beating a fine-tuned ensemble.

This directory is the public, reproducible artifact of that claim.

## What this bench is

30 prompts across 6 bands (5 prompts each), harvested from real Rail
codebase patterns:

| Band | What it probes | Source patterns |
|---|---|---|
| `fund` | basic recursion / arithmetic | numerics in `stdlib/oracle.rail` |
| `io` | string + list ops | `stdlib/bpe.rail`, `stdlib/tokenizer.rail` |
| `tools` | ADTs + pattern match | `stdlib/optim.rail`, `stdlib/checkpoint.rail` |
| `comp` | mini-compilers | shapes from `tools/compile.rail` |
| `adv` | higher-order functions | `stdlib/tensor.rail`, `stdlib/autograd.rail` |
| `comprehend` | "complete this so it prints X" | `stdlib/transformer.rail` shapes |

The full prompt list is in `tools/bench/substrate_hard_bench.rail`
(grep-able from outside the repo). Run it for a sanity smoke:

```bash
./rail_native run tools/bench/substrate_hard_bench.rail
# prints all 30 prompt names and a count
```

The prompt **bodies** (the user-message fragments handed to the LLM)
are embedded in the two probes:

- `tools/train/spec_in_context_probe_full.py` (Studio-internal, MLX)
- `tools/bench/repro_anthropic.py` (external partners, Anthropic API)

Both probes carry the **same** spec v3 (~1.4KB Rail cheat-sheet) and the
same N=20 rerank loop.

## The claim

**30/30 (100%) is achievable with a 100B+ open-weight model using Rail's
substrate (compiler + 1KB Rail spec) at N=20 reranks.**

Documented: memory entry `substrate_30_of_30_2026-05-09`. Conditions:
- N=20 sampling per prompt
- Spec v3 (HOF-in-main worked examples included)
- Naked Qwen-122B (no fine-tuning) as the original teacher
- Compile-grade via `./rail_native FILE` exit code

The substrate-thesis claim: **the verifier is the variable**, not the model.
Because Rail's compiler is open and correct, every compile attempt is honest
signal. The model gets a clean per-attempt verdict instead of a closed-
verifier heuristic.

## How to reproduce — two paths

### Path A — Anthropic API (recommended for external partners)

No local model required. ~$15-20 USD, ~15-25 min wall-clock.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
bash tools/bench/repro_30of30.sh
```

The script auto-detects: if no local MLX teacher is reachable and
`ANTHROPIC_API_KEY` is set, it uses `tools/bench/repro_anthropic.py`
against `claude-opus-4-7`. Override the model with `--model`:

```bash
ANTHROPIC_API_KEY=... python3 tools/bench/repro_anthropic.py \
    --model claude-sonnet-4-5
```

**Cost breakdown** (verify current pricing at
https://www.anthropic.com/pricing — figures below are claude-opus-4-7 at
late-2025 pricing of ~$15/M input + ~$75/M output):

- 30 prompts x N=20 reranks = **600 API calls**
- Per-call envelope: ~600 input tokens (system spec + small user prompt),
  ~256 output tokens
- Input cost:  600 * 600  / 1e6 * $15  ≈ **$5.40**
- Output cost: 600 * 256 / 1e6 * $75  ≈ **$11.52**
- Total: **~$15-20 USD** (range covers prompt-caching, output variance)

Smaller models will hit lower scores and may need more tokens. The bench is
a property of the substrate, not of any one model.

### Path B — local 100B+ open-weight (Studio-internal default)

For users running their own MLX or vLLM endpoint with a 100B+ model:

```bash
# Default endpoint: http://localhost:8082 (e.g. an SSH tunnel to the MLX host; override MLX_ENDPOINT)
bash tools/bench/repro_30of30.sh

# Override:
MLX_ENDPOINT=http://your-host:8082 bash tools/bench/repro_30of30.sh
```

The script probes `${MLX_ENDPOINT}/v1/models` first; if reachable, it
runs `tools/train/spec_in_context_probe_full.py` directly.

To run a 100B+ model locally:
- **MLX** (Apple Silicon): `mlx_lm.server --model <hf-id>` with any 100B+
  open-weight (Qwen-2.5-72B, Llama-3.1-405B-quantized, Qwen3.5-122B, etc.)
- **vLLM** (CUDA): `vllm serve <hf-id>` with the same.
- Endpoint must be OpenAI-compatible at `/v1/chat/completions`.

## How to interpret the output

Per-prompt line:

```
  fund/add: PASS (17/20 compile, first@0, 8.4s)
```

Means: 17 of 20 reranks compiled cleanly, the first one passed at index 0,
8.4 seconds for the prompt's full N=20 fan-out.

- **PASS** = at least one of the N=20 completions compiled (`./rail_native FILE`
  exit 0 on either the raw completion or `prompt + completion`).
- **FAIL** = all 20 reranks failed to compile.

Final line is the score:

```
RESULT: 30/30 in 18.3 min
```

The script exits **0 on 30/30** and **1 otherwise**.

## What this bench does NOT prove

Honest scope:

- The bench is **canonical, not exhaustive**. Production code is longer,
  involves file IO, multi-file, runtime errors, tests.
- It measures **Rail-comprehension at function-signature scale** —
  basically "can the model produce a syntactically valid Rail program that
  compiles, given this header?". It does not measure runtime correctness
  beyond compile.
- A model that scores 30/30 here is not "100% at code generation". It is
  a model that has cleanly internalized Rail's grammar via the 1KB spec.
- The substrate thesis predicts: **whatever model you use, the spec + open
  verifier brings it closer to its ceiling than the same model against an
  opaque verifier.** Reproduce against your model and publish — that's the
  whole point of an external pilot.

## Provenance

The 2026-05-09 result is documented in memory entry
`substrate_30_of_30_2026-05-09.md`. Witness-signed manifest URLs are at
`https://ledatic.org/provenance/manifest/<id>` (browser-verify at
`https://ledatic.org/verify/<id>`). The signing pipeline lives at
`tools/attest/report_attestation_publisher.sh` — partners can re-attest
their own results with the same toolchain.

## Gotchas

- **`rail_native` is ARM64 by default** (macOS / Linux ARM64). On Linux
  x86_64 (Razer / WSL), build the x86 binary first via
  `./rail_native x86 tools/compile.rail` per `CLAUDE.md > Rail Compiler`.
- **Network**: the Anthropic probe makes 600 sequential requests. If you
  hit rate limits, lower `--n` for a smaller smoke; the result then is
  not the canonical 30/30 claim — it is a partial probe.
- **5-minute hard timeout per prompt** (Anthropic probe) prevents a
  rate-limit storm from running indefinitely. If a prompt times out, it
  counts as FAIL.
- **`split` is single-character in Rail.** The `count_lines` and
  `first_line` prompts deliberately exercise this; the spec does not
  paper over it.
- **MLX endpoint is hardcoded to the MLX host (default `localhost:8082`)** in
  `tools/train/spec_in_context_probe_full.py`. Override the env var
  `MLX_ENDPOINT` for the auto-detect probe in `repro_30of30.sh`; for the
  Python file directly, edit the `ENDPOINT` constant.

## File map

| File | Purpose |
|---|---|
| `substrate_hard_bench.rail` | Pure-Rail snapshot of the 30 prompt names; sanity smoke |
| `repro_anthropic.py` | Anthropic-API probe (Path A) |
| `repro_30of30.sh` | Auto-detect orchestration (preferred entry point) |
| `README.md` | This file |
| `../train/spec_in_context_probe_full.py` | MLX-internal probe (Path B canonical) |
