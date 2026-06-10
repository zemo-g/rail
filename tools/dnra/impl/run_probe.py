#!/opt/homebrew/bin/python3.11
"""DNRA D-vs-base mode-separation probe runner.

NOTE: mlx_lm lives in /opt/homebrew/bin/python3.11 (not the default python3).
Always invoke explicitly with python3.11.

Usage:
    # dry-run: validate prompt set + JSONL output schema without loading a model
    /opt/homebrew/bin/python3.11 tools/dnra/impl/run_probe.py --dry-run --tag base

    # real run against an MLX-quantized base model (downloads if needed)
    /opt/homebrew/bin/python3.11 tools/dnra/impl/run_probe.py \\
        --model mlx-community/Llama-3.2-1B-Instruct-4bit \\
        --tag base

    # real run against trained-D LoRA adapter (post-training)
    /opt/homebrew/bin/python3.11 tools/dnra/impl/run_probe.py \\
        --model mlx-community/Llama-3.2-1B-Instruct-4bit \\
        --adapter adapters/<run>/ \\
        --tag d_v0_trained

Output:
    tools/dnra/sets/probe_responses_<tag>.jsonl
    one record per prompt: {id, domain, text, model_tag, response, gen_time_ms}

The edit-distance step (separate script) consumes two
probe_responses_*.jsonl files and emits the surface-diff metric.
"""

import argparse
import json
import sys
import time
from pathlib import Path

PROBE_SET = Path("tools/dnra/sets/probe_v0.jsonl")
OUT_DIR = Path("tools/dnra/sets")


def load_prompts(path: Path):
    prompts = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            prompts.append(json.loads(line))
    return prompts


def dry_run(prompts, tag: str):
    """Validate the prompt set + the output schema; do not load any model.
    Dry-run output goes to /tmp/ so it doesn't pollute the committed set dir."""
    out_path = Path(f"/tmp/dnra_probe_responses_{tag}.dry.jsonl")
    with open(out_path, "w") as f:
        for p in prompts:
            rec = {
                "id": p["id"],
                "domain": p["domain"],
                "text": p["text"],
                "model_tag": tag,
                "response": "[DRY-RUN no model loaded]",
                "gen_time_ms": 0,
            }
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    print(f"DRY: wrote {len(prompts)} stub responses to {out_path}")
    print(f"DRY: schema validated; pipeline ready.")
    return 0


def real_run(prompts, model: str, adapter: str | None, tag: str,
             max_tokens: int, temp: float = 0.0, min_tokens: int = 0):
    """Load model via mlx_lm + generate one response per prompt.

    `temp` > 0 turns on stochastic sampling.  `min_tokens` > 0 masks the
    EOS / EOT family until at least that many tokens have been generated,
    forcing the model past empty-emit collapse.
    """
    try:
        from mlx_lm import load, generate  # type: ignore[import-not-found]
        from mlx_lm.sample_utils import make_sampler  # type: ignore[import-not-found]
    except ImportError as e:
        print(f"ERROR: mlx_lm not importable: {e}. Use /opt/homebrew/bin/python3.11.", file=sys.stderr)
        return 2

    print(f"Loading model: {model}" + (f" + adapter: {adapter}" if adapter else ""))
    load_kwargs = {}
    if adapter:
        load_kwargs["adapter_path"] = adapter
    mdl, tok = load(model, **load_kwargs)

    sampler = make_sampler(temp=temp) if temp > 0 else None

    # Collect EOS / EOT-family token ids the min-tokens processor will mask.
    eos_ids: list[int] = []
    if getattr(tok, "eos_token_id", None) is not None:
        eos_ids.append(int(tok.eos_token_id))
    for special in ("<|eot_id|>", "<|end_of_text|>", "<|eom_id|>"):
        try:
            tid = tok.encode(special, add_special_tokens=False)
            if isinstance(tid, list) and len(tid) == 1 and tid[0] not in eos_ids:
                eos_ids.append(int(tid[0]))
        except Exception:
            pass
    print(f"sampler: temp={temp}  min_tokens={min_tokens}  eos_to_mask={eos_ids}")

    def make_min_tokens_processor():
        counter = {"n": 0}
        def proc(_input_ids, logits):
            counter["n"] += 1
            if counter["n"] <= min_tokens:
                for tid in eos_ids:
                    logits[..., tid] = float("-inf")
            return logits
        return proc

    out_path = OUT_DIR / f"probe_responses_{tag}.jsonl"
    with open(out_path, "w") as f:
        for i, p in enumerate(prompts):
            t0 = time.time()
            gen_kwargs: dict = {"max_tokens": max_tokens, "verbose": False}
            if sampler is not None:
                gen_kwargs["sampler"] = sampler
            if min_tokens > 0:
                gen_kwargs["logits_processors"] = [make_min_tokens_processor()]
            response = generate(mdl, tok, prompt=p["text"], **gen_kwargs)
            elapsed_ms = int((time.time() - t0) * 1000)
            rec = {
                "id": p["id"],
                "domain": p["domain"],
                "text": p["text"],
                "model_tag": tag,
                "response": response,
                "gen_time_ms": elapsed_ms,
            }
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            f.flush()
            print(f"  [{i+1:2}/{len(prompts)}] {p['id']} ({elapsed_ms}ms)")
    print(f"wrote {len(prompts)} responses to {out_path}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="HF model id or local path (MLX-quantized)")
    ap.add_argument("--adapter", help="LoRA adapter path (optional)")
    ap.add_argument("--tag", required=True, help="Output tag (e.g. base, d_v0_trained)")
    ap.add_argument("--dry-run", action="store_true", help="Validate pipeline without loading a model")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--temp", type=float, default=0.0,
                    help="Sampling temperature (0.0 = greedy default).")
    ap.add_argument("--min-tokens", type=int, default=0,
                    help="Force model to emit at least N tokens before EOS allowed.")
    args = ap.parse_args()

    if not PROBE_SET.exists():
        print(f"ERROR: probe set missing at {PROBE_SET}. Run tools/dnra/impl/gen_probe_set.py first.", file=sys.stderr)
        return 1

    prompts = load_prompts(PROBE_SET)
    if len(prompts) == 0:
        print("ERROR: probe set is empty.", file=sys.stderr)
        return 1
    print(f"loaded {len(prompts)} prompts from {PROBE_SET}")

    if args.dry_run:
        return dry_run(prompts, args.tag)
    if not args.model:
        print("ERROR: --model is required unless --dry-run is set.", file=sys.stderr)
        return 1
    return real_run(prompts, args.model, args.adapter, args.tag,
                    args.max_tokens, args.temp, args.min_tokens)


if __name__ == "__main__":
    sys.exit(main())
