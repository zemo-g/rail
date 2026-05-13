#!/usr/bin/env python3
"""
time_jit_grade.py — measure grading-throughput delta of JIT-fast vs shell-only.

The real bench (repro_anthropic.py) is API-call-dominated (~15-20 min for 600
calls); the grading step is ~60s of that. To get an honest grading-only
measurement decoupled from API jitter, this harness:

  1. Synthesizes a deterministic set of "as if the LLM returned this"
     completions for every prompt in BENCH (30 prompts x N reranks).
  2. Times grading via grade_completion (shell-only path).
  3. Times grading via grade_completion_batch_jit (JIT-first path).
  4. Prints wall-clock for each + the JIT lower-hit rate.

The completions are deliberately a mix of:
  - Known-good completions (should compile under both paths).
  - Mildly bad completions (parse fails — should fail under both).
  - Subset-friendly completions (JIT lowers cleanly).

This is NOT a substitute for running the real bench. It IS a substitute for
measuring the grading-loop's wall-clock improvement, which is the part this
patch actually affects.

Usage:
  python3 tools/bench/time_jit_grade.py [--n 20] [--prompts fund/add,...]
"""
from __future__ import annotations
import argparse
import os
import sys
import time
from pathlib import Path

# Import bench + grading helpers from the canonical probe.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from repro_anthropic import (  # type: ignore
    BENCH,
    filter_prompts,
    grade_completion,
    grade_completion_batch_jit,
    ensure_jit_batch_bin,
)


# Hand-picked completions per prompt-name. None means "use the prompt itself
# as the LLM's verbatim echo" (frequently sub-clean output that will only
# pass when concatenated with the prompt).
COMPLETIONS: dict[str, list[str]] = {
    "fact_120": [
        # already-complete program in the prompt; LLM might just echo or
        # answer with shorter forms. Mix of completions:
        "fact n = if n <= 1 then 1 else n * fact (n - 1)\nmain = let _ = print (show (fact 5))\n  0\n",
        "main = let _ = print (show 120)\n  0\n",
    ],
    "add": [
        "let _ = print (show (add 3 4))\n  0",
        "add a b = a + b\nmain = let _ = print (show (add 3 4))\n  0\n",
    ],
    "square_sum": [
        "let _ = print (show (sum_sq 3 4))\n  0",
        "main = let _ = print (show (sum_sq 3 4))\n  0\n",
    ],
    "fib": [
        "let _ = print (show (fib 10))\n  0",
        "main = let _ = print (show (fib 10))\n  0\n",
    ],
    "triangular": [
        "let _ = print (show (triangular 5))\n  0",
        "main = let _ = print (show (triangular 5))\n  0\n",
    ],
    "split_get": [
        'let _ = print (show (split_get "a b c"))\n  0',
        'main = let _ = print (show (split_get "a b c"))\n  0\n',
    ],
    "join_csv": [
        'let _ = print (join_csv ["a","b","c"])\n  0',
        'main = let _ = print (join_csv ["a","b","c"])\n  0\n',
    ],
    "second": [
        "let _ = print (show (second [1,2,3]))\n  0",
        "main = let _ = print (show (second [1,2,3]))\n  0\n",
    ],
    "read_cfg": [
        'let _ = print (read_cfg 0)\n  0',
        'main = let _ = print "stub"\n  0\n',
    ],
    "first_line": [
        'let _ = print (first_line "a\\nb")\n  0',
        'main = let _ = print (first_line "a\\nb")\n  0\n',
    ],
    "opt": [
        "let _ = print (show (get_or (Some 7)))\n  0",
        "main = let _ = print (show (get_or (Some 7)))\n  0\n",
    ],
    "res": [
        "let _ = print (show (run (Ok 42)))\n  0",
        "main = let _ = print (show (run (Ok 42)))\n  0\n",
    ],
    "state": [
        "let _ = print (show (next Init))\n  0",
        "main = let _ = print (show 0)\n  0\n",
    ],
    "pair": [
        "let _ = print (show (fst (Pair 7 8)))\n  0",
        "main = let _ = print (show (fst (Pair 7 8)))\n  0\n",
    ],
    "maybe": [
        "let _ = print (show (value (Just 9)))\n  0",
        "main = let _ = print (show (value (Just 9)))\n  0\n",
    ],
    "expr": [
        "let _ = print (show (eval (Add (Num 3) (Num 4))))\n  0",
        "main = let _ = print (show (eval (Add (Num 3) (Num 4))))\n  0\n",
    ],
    "op": [
        "let _ = print (show 0)\n  0",
        "main = let _ = print (show 0)\n  0\n",
    ],
    "tok": [
        "let _ = print (show 0)\n  0",
        "main = let _ = print (show 0)\n  0\n",
    ],
    "asm": [
        'let _ = print (asm MOV)\n  0',
        'main = let _ = print (asm MOV)\n  0\n',
    ],
    "emit": [
        "let _ = print (emit (ILoad 1))\n  0",
        "main = let _ = print (emit (ILoad 1))\n  0\n",
    ],
    "count_lines": [
        'let _ = print (show (count_lines "a\\nb\\nc"))\n  0',
        'main = let _ = print (show (count_lines "a\\nb\\nc"))\n  0\n',
    ],
    "sum_list": [
        "let _ = print (show (sum_list [1,2,3,4,5]))\n  0",
        "main = let _ = print (show (sum_list [1,2,3,4,5]))\n  0\n",
    ],
    "reverse_str": [
        'let _ = print (reverse_str "abc")\n  0',
        'main = let _ = print (reverse_str "abc")\n  0\n',
    ],
    "doubled": [
        "let _ = print (show (doubled [1,2,3]))\n  0",
        "main = let _ = print (show (doubled [1,2,3]))\n  0\n",
    ],
    "filter_even": [
        "let _ = print (show (filter_even [1,2,3,4,5,6]))\n  0",
        "main = let _ = print (show (filter_even [1,2,3,4,5,6]))\n  0\n",
    ],
    "fact_complete": [
        "if n <= 1 then 1 else n * fact (n - 1)\nmain = let _ = print (show (fact 5))\n  0\n",
    ],
    "flatten": [
        'fold append [] xss\nmain = let _ = print (show (length (flatten [[1,2],[3,4]])))\n  0\n',
    ],
    "sum15": [
        "fold add 0 xs\nadd a b = a + b\nmain = let _ = print (show (sum_list [1,2,3,4,5]))\n  0\n",
    ],
    "doubled246": [
        "map dbl xs\ndbl x = x * 2\nmain = let _ = print (show (doubled [1,2,3]))\n  0\n",
    ],
    "find_key": [
        # plausible stub completion
        'match ls\n  | [] -> ""\n  | cons p t -> if (head p) == k then head (tail p) else find_key t k\nmain = let _ = print (find_key [["a", "rail"]] "a")\n  0\n',
    ],
}


def synthesize_completions(prompt: str, name: str, n: int) -> list[str]:
    """Return n synthesized completions for a prompt. Cycles the per-name
    canon completions; if none defined, returns the prompt itself n times."""
    canon = COMPLETIONS.get(name)
    if not canon:
        # Falls back to mild echo — likely won't compile but exercises both
        # shell and JIT fast-fail paths.
        return ["-- echo\n"] * n
    out: list[str] = []
    for i in range(n):
        out.append(canon[i % len(canon)])
    return out


def run_one_path(bench: dict, n: int, use_jit: bool, label: str) -> tuple[float, dict]:
    """Time grading across the whole bench. Returns (wall_clock_seconds, stats)."""
    print(f"[{label}] starting...", flush=True)
    t0 = time.time()
    total = 0
    passed = 0
    jit_stats = {"jit_pass": 0, "shell_pass": 0, "fail": 0, "total_candidates": 0}
    for band, tasks in bench.items():
        for tname, prompt in tasks:
            completions = synthesize_completions(prompt, tname, n)
            if use_jit:
                task_dir = Path(f"/tmp/time_jit_grade_{os.getpid()}/{band}_{tname}")
                per_pass, stats = grade_completion_batch_jit(prompt, completions, task_dir)
                np = sum(1 for ok in per_pass if ok)
                for k in jit_stats:
                    jit_stats[k] += stats[k]
            else:
                np = sum(1 for c in completions if grade_completion(prompt, c))
            total += 1
            if np > 0:
                passed += 1
    elapsed = time.time() - t0
    print(f"[{label}] done in {elapsed:.2f}s; {passed}/{total} prompts with >=1 pass", flush=True)
    return elapsed, jit_stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20, help="reranks per prompt (default: 20)")
    ap.add_argument("--prompts", default=None, help="comma-separated band/name selectors")
    ap.add_argument("--skip-shell", action="store_true", help="only run the JIT-fast path")
    ap.add_argument("--skip-jit", action="store_true", help="only run the shell-only path")
    args = ap.parse_args()

    bench = filter_prompts(BENCH, args.prompts)
    n_prompts = sum(len(v) for v in bench.values())
    print(f"timing grading: {n_prompts} prompts x N={args.n} = {n_prompts * args.n} candidates per path")
    print()

    shell_t = None
    jit_t = None
    jit_stats: dict = {}

    if not args.skip_shell:
        shell_t, _ = run_one_path(bench, args.n, use_jit=False, label="shell-only")
        print()

    if not args.skip_jit:
        # Pre-build to avoid mixing compile cost into timing.
        ensure_jit_batch_bin()
        jit_t, jit_stats = run_one_path(bench, args.n, use_jit=True, label="jit-fast")
        print()

    print("=" * 60)
    print(f"prompts:       {n_prompts}")
    print(f"reranks (n):   {args.n}")
    if shell_t is not None:
        print(f"shell-only:    {shell_t:.2f}s")
    if jit_t is not None:
        tc = jit_stats.get("total_candidates", 0)
        jp = jit_stats.get("jit_pass", 0)
        sp = jit_stats.get("shell_pass", 0)
        fl = jit_stats.get("fail", 0)
        print(f"jit-fast:      {jit_t:.2f}s")
        print(f"jit lower-hit: {jp}/{tc} = {(100.0 * jp / max(tc,1)):.1f}%  "
              f"(shell fallback: {sp}, fail: {fl})")
    if shell_t is not None and jit_t is not None and jit_t > 0:
        print(f"speedup:       {shell_t / jit_t:.2f}x")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
