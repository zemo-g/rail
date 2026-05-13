#!/usr/bin/env python3
"""
spec_in_context_probe.py — Test whether putting Rail's language spec in
the teacher's context lifts compile-pass rate vs naked prompts.

Two arms:
  naked: just the bench prompt, no Rail-specific priming
  spec:  Rail self-spec prefix + the bench prompt

Calls Studio's local Qwen-122B-A10B at 10.42.0.2:8088 (OpenAI-compatible
mlx_lm.server). N=3 reranks per (prompt, arm). Grades each completion
with `./rail_native parse-check` AND `./rail_native FILE` (full compile).

Usage:
    python3 tools/train/spec_in_context_probe.py
"""
from __future__ import annotations
import json
import subprocess
import sys
import urllib.request
import urllib.error
from pathlib import Path

ENDPOINT = "http://10.42.0.2:8088/v1/chat/completions"
MODEL = "mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq"
N_RERANK = 3
MAX_TOKENS = 256
TEMPERATURE = 0.7
TIMEOUT = 120

# 5 representative bench prompts — one per band that's tractable single-shot.
BENCH_PROMPTS = {
    "fund_fact": "fact n = if n <= 1 then 1 else n * fact (n - 1)\nmain = let _ = print (show (fact 5))\n  0",
    "fund_add":  "add a b = a + b\nmain = ",
    "tools_opt": "type Opt = | Some x | None\nget_or o = match o | Some x -> x | None -> 0\nmain = ",
    "tools_pair":"type Pair = | Pair a b\nfst p = match p | Pair a _ -> a\nmain = ",
    "comp_eval": "type Expr = | Num x | Add a b\neval e = match e | Num x -> x | Add a b -> eval a + eval b\nmain = ",
}

# Tier-1 self-spec — minimal, ~1KB. If this lifts, search for smaller floor.
SELF_SPEC = """You are completing a Rail program. Rail is a small functional language.

Syntax cheatsheet:
  -- comments start with two dashes
  add a b = a + b                              -- function decl
  double x = x * 2
  fact n = if n <= 1 then 1 else n * fact (n - 1)
  main = let _ = print (show 42)               -- main returns int (exit code)
    0
  type Opt = | Some x | None                   -- ADT
  get_or o = match o
    | Some x -> x
    | None -> 0
  fold add 0 [1,2,3,4,5]                       -- 15
  map f xs, filter f xs, head xs, tail xs, length xs, range N
  show n         -- int -> string
  cat [a, b, c]  -- string concat
  join "," xs    -- list-of-strings -> string

Rules:
  - Every program ends with `main = <expr>` where <expr> evaluates to an int.
  - Use `let _ = side_effect` then a value; bindings are layout-sensitive.
  - Indent let bodies by exactly 2 spaces.
  - Pattern match has no `with`/`of` keyword: `match expr | Ctor a -> ... | _ -> ...`.

Complete the program below. Output ONLY the complete Rail source code (no
markdown fences, no commentary). Make sure it compiles and that `main`
produces a sensible int.
"""

# Just the bench prompt, no priming. Mirrors what teacher_distill.sh does today.
NAKED_PROMPT_PREFIX = "Complete this Rail program. Output ONLY the complete Rail source code, no commentary or markdown fences:\n\n"


def call_teacher(messages, seed):
    body = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "seed": seed,
    }
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read())
            return data["choices"][0]["message"]["content"]
    except (urllib.error.URLError, KeyError, json.JSONDecodeError) as e:
        return f"<<TEACHER_ERROR: {e}>>"


def extract_rail(raw):
    """Strip markdown fences if the model used them despite instructions."""
    s = raw.strip()
    if s.startswith("```"):
        # Drop first line + maybe last fence line
        lines = s.splitlines()
        lines = lines[1:]
        if lines and lines[-1].startswith("```"):
            lines = lines[:-1]
        s = "\n".join(lines)
    return s


def grade(rail_src, label):
    path = Path(f"/tmp/probe_{label}.rail")
    path.write_text(rail_src)
    parse_ok = subprocess.run(
        ["./rail_native", "parse-check", str(path)],
        capture_output=True,
    ).returncode == 0
    compile_ok = subprocess.run(
        ["./rail_native", str(path)],
        capture_output=True,
    ).returncode == 0
    return parse_ok, compile_ok


def run_arm(arm_name, system_msg, prompt_id, bench_prompt):
    print(f"  [{arm_name}] {prompt_id}")
    results = []
    for i in range(N_RERANK):
        seed = 1000 + i  # deterministic seeds across arms
        if system_msg:
            messages = [
                {"role": "system", "content": system_msg},
                {"role": "user", "content": bench_prompt},
            ]
        else:
            messages = [
                {"role": "user", "content": NAKED_PROMPT_PREFIX + bench_prompt},
            ]
        raw = call_teacher(messages, seed)
        rail = extract_rail(raw)
        label = f"{arm_name}_{prompt_id}_s{seed}"
        parse_ok, compile_ok = grade(rail, label)
        # Save raw + extracted for later inspection
        Path(f"/tmp/probe_{label}.raw").write_text(raw)
        results.append({
            "seed": seed,
            "parse": parse_ok,
            "compile": compile_ok,
            "rail_len": len(rail),
            "rail_preview": rail.replace("\n", " | ")[:160],
        })
        print(f"     seed={seed}  parse={'P' if parse_ok else '.'}  "
              f"compile={'C' if compile_ok else '.'}  len={len(rail)}")
    return results


def main():
    rows = []
    for prompt_id, bench in BENCH_PROMPTS.items():
        for arm_name, system_msg in [("naked", None), ("spec", SELF_SPEC)]:
            rs = run_arm(arm_name, system_msg, prompt_id, bench)
            for r in rs:
                rows.append({"prompt": prompt_id, "arm": arm_name, **r})

    print("\n" + "="*80)
    print("=== SUMMARY ===")
    print("="*80)
    naked_p = sum(1 for r in rows if r["arm"] == "naked" and r["parse"])
    naked_c = sum(1 for r in rows if r["arm"] == "naked" and r["compile"])
    spec_p  = sum(1 for r in rows if r["arm"] == "spec"  and r["parse"])
    spec_c  = sum(1 for r in rows if r["arm"] == "spec"  and r["compile"])
    n_total = len(BENCH_PROMPTS) * N_RERANK
    print(f"naked: parse={naked_p}/{n_total}  compile={naked_c}/{n_total}")
    print(f"spec:  parse={spec_p}/{n_total}   compile={spec_c}/{n_total}")
    print(f"compile delta: {spec_c - naked_c} (positive = spec helped)")

    # Per-prompt breakdown
    print("\n=== Per-prompt compile pass (out of N=3) ===")
    print(f"{'prompt':<14} {'naked':<8} {'spec':<8}")
    for prompt_id in BENCH_PROMPTS:
        nc = sum(1 for r in rows if r["prompt"] == prompt_id
                 and r["arm"] == "naked" and r["compile"])
        sc = sum(1 for r in rows if r["prompt"] == prompt_id
                 and r["arm"] == "spec" and r["compile"])
        print(f"{prompt_id:<14} {nc}/3      {sc}/3")

    # Save full data
    Path("/tmp/spec_probe_results.json").write_text(json.dumps(rows, indent=2))
    print("\nFull data: /tmp/spec_probe_results.json")
    print("Per-trial outputs: /tmp/probe_<arm>_<prompt>_s<seed>.{rail,raw}")


if __name__ == "__main__":
    main()
