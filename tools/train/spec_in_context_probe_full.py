#!/usr/bin/env python3
"""
spec_in_context_probe_full.py — substrate hard-bench probe.

All 30 bench prompts (6 bands × 5) × N=10 reranks against Studio's 122B
teacher at 10.42.0.2:8082. Compile-grade each generation via rail_native.
Pass = ANY of the N completions compiles cleanly (exit 0).

Output: per-prompt PASS/FAIL, per-band totals, overall score and wall-clock.
"""
from __future__ import annotations
import json
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

ENDPOINT = "http://10.42.0.2:8082/v1/chat/completions"
MODEL = "mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq"
N_RERANK = 20
MAX_TOKENS = 256
TEMPERATURE = 0.7
TIMEOUT = 180
RAIL_NATIVE = "~/projects/rail/rail_native"

# 30 bench prompts (extracted from flywheel-local/bench_railnative.rail)
BENCH = {
    "fund": [
        ("fact_120", "fact n = if n <= 1 then 1 else n * fact (n - 1)\nmain = let _ = print (show (fact 5))\n  0\n"),
        ("add", "add a b = a + b\nmain = "),
        ("square_sum", "square x = x * x\nsum_sq a b = square a + square b\nmain = "),
        ("fib", "fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)\nmain = "),
        ("triangular", "triangular n = if n <= 0 then 0 else n + triangular (n - 1)\nmain = "),
    ],
    "io": [
        ("split_get", 'split_get s = split " " s\nmain = '),
        ("join_csv", 'join_csv xs = join "," xs\nmain = '),
        ("second", "second xs = head (tail xs)\nmain = "),
        ("read_cfg", 'read_cfg _ = read_file "/tmp/bench_railnative_cfg.txt"\nmain = '),
        ("first_line", 'first_line s = head (split "\\n" s)\nmain = '),
    ],
    "tools": [
        ("opt", "type Opt = | Some x | None\nget_or o = match o | Some x -> x | None -> 0\nmain = "),
        ("res", "type Res = | Ok x | Err x\nrun r = match r | Ok v -> v | Err _ -> 0\nmain = "),
        ("state", "type State = | Init | Run | Done\nnext s = match s | Init -> Run | Run -> Done | Done -> Done\nmain = "),
        ("pair", "type Pair = | Pair a b\nfst p = match p | Pair a _ -> a\nmain = "),
        ("maybe", "type Maybe = | Just x | Nothing\nvalue m = match m | Just x -> x | Nothing -> 0\nmain = "),
    ],
    "comp": [
        ("expr", "type Expr = | Num x | Add a b\neval e = match e | Num x -> x | Add a b -> eval a + eval b\nmain = "),
        ("op", "type Op = | Push x | Mul | Halt\nstep ops = ops\nmain = "),
        ("tok", "type Tok = | TNum x | TPlus | TEof\nmain = "),
        ("asm", 'type Instr = | MOV | ADD | RET\nasm i = match i | MOV -> "mov x0, 0" | ADD -> "add x0, x0, 1" | RET -> "ret"\nmain = '),
        ("emit", 'type Inst = | ILoad x | IStore x\nemit i = match i | ILoad n -> cat ["ldr x0, [sp,#", show n, "]"] | IStore n -> cat ["str x0, [sp,#", show n, "]"]\nmain = '),
    ],
    "adv": [
        ("count_lines", 'count_lines text = length (split "\\n" text)\nmain = '),
        ("sum_list", "sum_list xs = fold add 0 xs\nmain = "),
        ("reverse_str", 'reverse_str s = join "" (reverse (chars s))\nmain = '),
        ("doubled", "doubled xs = map (\\x -> x * 2) xs\nmain = "),
        ("filter_even", "filter_even xs = filter is_even xs\nis_even n = n % 2 == 0\nmain = "),
    ],
    "comprehend": [
        ("fact_complete", "-- complete this factorial so it prints 120\nfact n = "),
        ("flatten", "-- complete this flatten so [[1,2],[3,4]] prints 4\nflatten xss = "),
        ("sum15", "-- complete this fold so it prints 15\nsum_list xs = "),
        ("doubled246", "-- complete this map so it prints [2,4,6]\ndoubled xs = "),
        ("find_key", "-- complete this find_key so it prints rail\nfind_key ls k = "),
    ],
}

SPEC = r"""You are completing a Rail program. Rail is a small functional language.

Syntax cheatsheet:
  -- comments start with two dashes
  add a b = a + b                              -- function decl (top-level)
  double x = x * 2
  fact n = if n <= 1 then 1 else n * fact (n - 1)
  main = let _ = print (show 42)               -- main returns int (exit code)
    0
  let x = 1 in x + 1                           -- let-in form, OR
  let x = 1                                    -- newline-let (no `in`)
  x + 1
  match opt                                    -- pattern match (NO `with` keyword)
    | Some x -> x
    | None -> 0
  type Opt = | Some x | None                   -- ADT definition
  cons head tail                               -- list cons
  head [1,2,3]; tail [1,2,3]; length [1,2,3]
  map f xs; filter f xs; fold f init xs
  reverse xs; chars s; split "c" s; join "c" xs
  show n        -- int/list/string -> string
  print s       -- IO side effect, returns 0
  read_file path; write_file path content

Higher-order functions in `main` — common patterns (use these EXACTLY):
  -- using fold:
  sum_list xs = fold add 0 xs
  add a b = a + b
  main = let _ = print (show (sum_list [1,2,3,4,5]))
    0

  -- using filter:
  is_even n = n % 2 == 0
  filter_even xs = filter is_even xs
  main = let _ = print (show (filter_even [1,2,3,4,5,6]))
    0

  -- using map with a lambda:
  doubled xs = map (\x -> x * 2) xs
  main = let _ = print (show (doubled [1,2,3]))
    0

  -- using map with a named helper (preferred for compile clarity):
  double_one x = x * 2
  doubled xs = map double_one xs
  main = let _ = print (show (doubled [1,2,3]))
    0

Hard rules:
- NO `with` keyword. NO Haskell-style `(x:xs)` cons patterns. NO `[h,...t]` literals. NO tuples.
- Lists are built via `cons` or `[1,2,3]` literal. Top-level decls only: `name args = body`.
- `match` arms without `with`. Each arm `| Constructor args -> expr`.
- `main` must return an int (exit code). Use `let _ = print (show <expr>)` then `  0` on next line.
- For `fold`, `map`, `filter`: pass a 2-arg named function (for fold) or a 1-arg named function or single lambda. Single lambdas like `\x -> x + 1` work; nested `\a -> \b -> ...` also works. NEVER use multi-clause functions or guards.
- `is_even` etc. must be a top-level decl, not inline in a lambda body.

Output ONLY valid Rail source. No prose, no markdown fences, no explanation. Your entire
response is the Rail program that completes the user's prompt fragment.
"""


def call_teacher(prompt: str, n: int = N_RERANK) -> list[str]:
    """Sequential N requests to the teacher; return list of completion texts."""
    completions = []
    for i in range(n):
        body = json.dumps({
            "model": MODEL,
            "messages": [
                {"role": "system", "content": SPEC},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "chat_template_kwargs": {"enable_thinking": False},
        }).encode()
        req = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data = json.loads(resp.read())
            completions.append(data["choices"][0]["message"]["content"])
        except Exception as e:
            completions.append(f"<<ERROR: {e}>>")
    return completions


def strip_artifacts(text: str) -> str:
    text = text.strip()
    # strip code fences
    if text.startswith("```rail"):
        text = text[7:]
    elif text.startswith("```"):
        text = text[3:]
    if text.endswith("```"):
        text = text[:-3]
    # strip common tag artifacts
    for tag in ["</TRACE>", "<TRACE>", "</PROGRAM>", "<PROGRAM>", "</EOF>", "<EOF>", "</think>", "<think>"]:
        text = text.replace(tag, "")
    return text.strip()


def compile_check(source: str) -> bool:
    p = Path("/tmp/probe_full_check.rail")
    p.write_text(source)
    try:
        r = subprocess.run([RAIL_NATIVE, str(p)], capture_output=True, timeout=20)
        return r.returncode == 0
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


def grade_completion(prompt: str, completion: str) -> bool:
    """Try several interpretations; pass if any compiles."""
    stripped = strip_artifacts(completion)
    # Variant 1: completion alone (most common — model emits a full program)
    if stripped and compile_check(stripped):
        return True
    # Variant 2: prompt + completion concatenated
    if compile_check(prompt + stripped):
        return True
    return False


def main():
    t0 = time.time()
    band_pass = {b: 0 for b in BENCH}
    pass_log = []
    overall_pass = 0
    overall_total = 0
    for band, tasks in BENCH.items():
        for name, prompt in tasks:
            t_task = time.time()
            completions = call_teacher(prompt, n=N_RERANK)
            n_compiles = 0
            first_pass_idx = -1
            for i, c in enumerate(completions):
                if grade_completion(prompt, c):
                    n_compiles += 1
                    if first_pass_idx < 0:
                        first_pass_idx = i
            elapsed = time.time() - t_task
            passed = n_compiles > 0
            status = "PASS" if passed else "FAIL"
            print(f"  {band}/{name}: {status} ({n_compiles}/{N_RERANK} compile, first@{first_pass_idx if first_pass_idx >= 0 else 'none'}, {elapsed:.1f}s)", flush=True)
            pass_log.append({"band": band, "name": name, "compiles": n_compiles, "elapsed": elapsed, "first_pass_idx": first_pass_idx})
            if passed:
                band_pass[band] += 1
                overall_pass += 1
            overall_total += 1
        print(f"  -- BAND {band}: {band_pass[band]}/5 --", flush=True)

    total_elapsed = time.time() - t0
    print()
    print(f"=== SUBSTRATE HARD-BENCH RESULT ===")
    print(f"Overall: {overall_pass}/{overall_total} ({100 * overall_pass / overall_total:.1f}%)")
    print(f"Wall-clock: {total_elapsed / 60:.1f} min")
    print(f"Per band:")
    for b, p in band_pass.items():
        print(f"  {b}: {p}/5")
    out = Path("/tmp/substrate_probe_result.json")
    out.write_text(json.dumps({
        "overall": f"{overall_pass}/{overall_total}",
        "per_band": band_pass,
        "wall_clock_min": total_elapsed / 60,
        "n_rerank": N_RERANK,
        "model": MODEL,
        "endpoint": ENDPOINT,
        "tasks": pass_log,
    }, indent=2))
    print(f"JSON: {out}")


if __name__ == "__main__":
    main()
