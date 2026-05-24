#!/opt/homebrew/bin/python3.11
"""Workshop orchestrator: classifier -> retriever -> deriver.

CLI:
    python3 tools/dnra/workshop/orchestrator.py --probe        # 30-prompt probe
    python3 tools/dnra/workshop/orchestrator.py --prompt "..."  # one-off

Library:
    from tools.dnra.workshop.orchestrator import answer
    result = answer("Does RFC 8259 require unique JSON keys?")
    # result = {prompt, classification, retrieval, response, attestation}

Output records mirror the existing probe_responses_*.jsonl shape so
score_probe.py can grade workshop outputs identically.
"""

from __future__ import annotations
import argparse
import json
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
from tools.dnra.workshop.classifier import classify  # type: ignore[import-not-found]
from tools.dnra.workshop.convener import convene  # type: ignore[import-not-found]
from tools.dnra.workshop.retriever import retrieve  # type: ignore[import-not-found]
from tools.dnra.workshop.deriver import derive_cited, derive_uncited, derive_empirical  # type: ignore[import-not-found]


def _derive_one_mode(prompt: str, mode: str, retrieval: dict | None) -> tuple[str, str]:
    """Return (response, path) for a single panelist mode."""
    if retrieval is None:
        return derive_uncited(prompt), "uncited"
    if mode == "empirical":
        return derive_empirical(prompt, retrieval), "cited_empirical"
    return derive_cited(prompt, retrieval), "cited_deductive"


def answer(prompt: str, *, mode: str = "deductive", verbose: bool = False) -> dict:
    """Single-panelist answer (legacy single-mode pipeline).

    For multi-panel deliberation use deliberate()."""
    t0 = time.time()
    cls = classify(prompt)
    if verbose:
        print(f"  classify: needs_cite={cls['needs_cite']}  sources={cls['source_candidates']}  mode={mode}")
    retrieval = None
    if cls["needs_cite"] and cls["source_candidates"]:
        retrieval = retrieve(cls["source_candidates"], prompt)
        if verbose and retrieval:
            print(f"  retrieve: {retrieval['source']} sec {retrieval['section']} "
                  f"(score={retrieval['score']}, fallback={retrieval['fallback']})")
        elif verbose:
            print(f"  retrieve: NO SECTION FOUND")
    response, path = _derive_one_mode(prompt, mode, retrieval)
    return {
        "prompt": prompt,
        "mode": mode,
        "classification": cls,
        "retrieval": retrieval,
        "response": response,
        "path": path,
        "gen_time_ms": int((time.time() - t0) * 1000),
    }


def deliberate(prompt: str, *, verbose: bool = False) -> dict:
    """Convener-routed multi-panelist deliberation.

    The convener picks which modes (subset of {deductive, empirical,
    uncited}) to invoke.  Each mode runs its full classifier->retrieve->
    derive pipeline.  Returns {triage, retrieval, responses_by_mode, ...}.
    """
    t0 = time.time()
    triage = convene(prompt)
    if verbose:
        print(f"  convener: modes={triage['modes']}  path={triage['path']}  reason={triage['reason']}")

    cls = triage["classification"]
    retrieval = None
    if cls["needs_cite"] and cls["source_candidates"]:
        retrieval = retrieve(cls["source_candidates"], prompt)
        if verbose and retrieval:
            print(f"  retrieve: {retrieval['source']} sec {retrieval['section']}")
        elif verbose:
            print(f"  retrieve: NO SECTION FOUND")

    responses_by_mode: dict[str, dict] = {}
    for m in triage["modes"]:
        rt0 = time.time()
        resp, path = _derive_one_mode(prompt, m, retrieval)
        responses_by_mode[m] = {
            "response": resp,
            "path": path,
            "gen_time_ms": int((time.time() - rt0) * 1000),
        }

    return {
        "prompt": prompt,
        "triage": {"path": triage["path"], "modes": triage["modes"], "reason": triage["reason"]},
        "classification": cls,
        "retrieval": retrieval,
        "responses_by_mode": responses_by_mode,
        "total_time_ms": int((time.time() - t0) * 1000),
    }


def run_probe(out_tag: str, probe_path: Path | None = None, verbose: bool = False,
              mode: str = "deductive") -> None:
    """Run the standard 30-prompt probe through the workshop."""
    pp = probe_path or REPO_ROOT / "tools/dnra/sets/probe_v0.jsonl"
    prompts = [json.loads(l) for l in open(pp) if l.strip()]
    out_path = REPO_ROOT / "tools/dnra/sets" / f"probe_responses_{out_tag}.jsonl"
    print(f"workshop probe (mode={mode}): {len(prompts)} prompts -> {out_path.name}")
    with open(out_path, "w") as f:
        for i, p in enumerate(prompts, start=1):
            try:
                result = answer(p["text"], mode=mode, verbose=verbose)
            except Exception as e:
                print(f"  [{i:2}/{len(prompts)}] {p['id']} ERROR: {e}")
                continue
            rec = {
                "id": p["id"],
                "domain": p["domain"],
                "text": p["text"],
                "model_tag": out_tag,
                "response": result["response"],
                "gen_time_ms": result["gen_time_ms"],
                "path": result["path"],
                "retrieval_source": (result["retrieval"]["source"] if result["retrieval"] else None),
                "retrieval_section": (result["retrieval"]["section"] if result["retrieval"] else None),
                "classifier_needs_cite": result["classification"]["needs_cite"],
            }
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            f.flush()
            print(f"  [{i:2}/{len(prompts)}] {p['id']}  path={result['path']}  "
                  f"src={rec['retrieval_source']}  ({result['gen_time_ms']}ms)")
    print(f"wrote {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", help="Run a single prompt and print the full result.")
    ap.add_argument("--probe", action="store_true", help="Run the 30-prompt probe set.")
    ap.add_argument("--tag", default="workshop_v0", help="Output tag for --probe mode.")
    ap.add_argument("--mode", default="deductive",
                    choices=["deductive", "empirical", "deliberate"],
                    help="Panelist mode.  'deliberate' uses the Convener to "
                         "auto-route between D/E and run a multi-mode panel "
                         "when warranted.")
    ap.add_argument("--verbose", action="store_true", help="Print classify+retrieve traces.")
    args = ap.parse_args()
    if args.prompt:
        if args.mode == "deliberate":
            result = deliberate(args.prompt, verbose=True)
            print()
            print(f"=== triage: modes={result['triage']['modes']} reason={result['triage']['reason']} ===")
            for m, r in result["responses_by_mode"].items():
                print()
                print(f"--- {m} ({r['gen_time_ms']}ms, {r['path']}) ---")
                print(r["response"])
            print()
            print(f"total time: {result['total_time_ms']}ms")
        else:
            result = answer(args.prompt, mode=args.mode, verbose=True)
            print()
            print(f"=== response ({result['mode']}) ===")
            print(result["response"])
            print()
            print(f"path={result['path']} time={result['gen_time_ms']}ms")
    elif args.probe:
        run_probe(args.tag, verbose=args.verbose, mode=args.mode)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
