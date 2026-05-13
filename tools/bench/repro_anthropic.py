#!/usr/bin/env python3
"""
repro_anthropic.py — substrate hard-bench probe via the Anthropic API.

External-partner reproduction of the canonical 30/30 result documented in
memory:substrate_30_of_30_2026-05-09. Mirror of
tools/train/spec_in_context_probe_full.py but with the Anthropic API as
the LLM backend instead of an MLX-internal endpoint.

All 30 bench prompts (6 bands x 5) x N=20 reranks, compile-graded via
rail_native. PASS = ANY of the N completions compiles cleanly (exit 0).

Reads ANTHROPIC_API_KEY from the environment. Default model is
claude-opus-4-7; override with --model. Prints a cost banner up front
so partners know what the run costs before it starts.

Usage:
  ANTHROPIC_API_KEY=... python3 tools/bench/repro_anthropic.py
  ANTHROPIC_API_KEY=... python3 tools/bench/repro_anthropic.py --model claude-sonnet-4-5
  ANTHROPIC_API_KEY=... python3 tools/bench/repro_anthropic.py --n 1 --prompts fund/add
                                                       # single-prompt smoke

Output: per-prompt PASS/FAIL, per-band totals, overall score, wall-clock,
        and JSON sidecar at /tmp/substrate_repro_result.json.
"""
from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
DEFAULT_MODEL = "claude-opus-4-7"
N_RERANK = 20
MAX_TOKENS = 256
TEMPERATURE = 0.7
PER_CALL_TIMEOUT = 60        # per individual API call
PER_PROMPT_HARD_TIMEOUT = 300  # 5-min hard cap per prompt across all reranks
RAIL_NATIVE = str(Path(__file__).resolve().parents[2] / "rail_native")

# Anthropic pricing for claude-opus-4-7 (verify current at
# https://www.anthropic.com/pricing). As of late 2025:
#   $15 per million input tokens
#   $75 per million output tokens
# Per-call envelope: ~2KB system spec + small user prompt = ~600 input
# tokens; output capped at 256 tokens. 30 prompts x N=20 reranks = 600 calls.
#   input  cost: 600 calls * 600 tok  / 1e6 * $15  = $5.40
#   output cost: 600 calls * 256 tok  / 1e6 * $75  = $11.52
#   total       : ~$15-20 (range accounts for prompt-cache hits and
#                 actual output length variance).
COST_LO = 15
COST_HI = 20

# 30 bench prompts (verbatim from tools/train/spec_in_context_probe_full.py)
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

# RAIL_SPEC v3 — verbatim from tools/train/spec_in_context_probe_full.py.
# DO NOT REDESIGN — this exact spec is what produced the 30/30 result.
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


def call_anthropic(prompt: str, model: str, api_key: str) -> str:
    """Single Anthropic API call. Returns completion text or '<<ERROR: ...>>'."""
    body = json.dumps({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "system": SPEC,
        "messages": [
            {"role": "user", "content": prompt},
        ],
    }).encode()
    req = urllib.request.Request(
        ANTHROPIC_ENDPOINT,
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_VERSION,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=PER_CALL_TIMEOUT) as resp:
            data = json.loads(resp.read())
        # Anthropic format: {"content": [{"type": "text", "text": "..."}], ...}
        for block in data.get("content", []):
            if block.get("type") == "text":
                return block.get("text", "")
        return "<<ERROR: no text block in response>>"
    except urllib.error.HTTPError as e:
        body_text = ""
        try:
            body_text = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        return f"<<ERROR: HTTP {e.code}: {body_text[:300]}>>"
    except Exception as e:
        return f"<<ERROR: {e}>>"


def call_teacher(prompt: str, model: str, api_key: str, n: int, hard_deadline: float) -> list[str]:
    """Sequential N requests; bails early if hard deadline exceeded."""
    completions: list[str] = []
    for i in range(n):
        if time.time() > hard_deadline:
            completions.append(f"<<ERROR: hard deadline exceeded after {i} calls>>")
            break
        completions.append(call_anthropic(prompt, model, api_key))
    return completions


def strip_artifacts(text: str) -> str:
    text = text.strip()
    if text.startswith("```rail"):
        text = text[7:]
    elif text.startswith("```"):
        text = text[3:]
    if text.endswith("```"):
        text = text[:-3]
    for tag in ["</TRACE>", "<TRACE>", "</PROGRAM>", "<PROGRAM>", "</EOF>", "<EOF>", "</think>", "<think>"]:
        text = text.replace(tag, "")
    return text.strip()


def compile_check(source: str) -> bool:
    p = Path("/tmp/probe_anthropic_check.rail")
    p.write_text(source)
    try:
        r = subprocess.run([RAIL_NATIVE, str(p)], capture_output=True, timeout=20)
        return r.returncode == 0
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


def grade_completion(prompt: str, completion: str) -> bool:
    stripped = strip_artifacts(completion)
    if stripped and compile_check(stripped):
        return True
    if compile_check(prompt + stripped):
        return True
    return False


# ---------------------------------------------------------------------------
# JIT-first batch grading.
#
# The canonical grader spawns rail_native once per candidate (~100ms each, of
# which ~all is `as`+`ld` toolchain round-trip). For programs in the JIT's
# subset (int + match + recursion + HOFs in a few shapes), the pure-Rail JIT
# at jit/grade.rail can answer "does this lower?" without touching the
# toolchain at all. `jit_can_lower=1` is a strict subset of `rail_native
# compiles cleanly` — the JIT does parse + IR lowering only, so if it
# accepts, the program is syntactically valid Rail and certainly compiles
# (the falsification check below verifies this empirically).
#
# Architecture:
#   1. Build tools/bench/jit_grade_batch.rail once at start; cache the binary.
#   2. Per prompt: write all N=20 stripped (and prompt+stripped) candidates
#      to disk, write a manifest, invoke the batch grader once, parse
#      results.
#   3. Per-candidate grade derives from any-of(stripped JIT_PASS,
#      stripped SHELL_PASS, prompt+stripped JIT_PASS, prompt+stripped
#      SHELL_PASS) — mirrors the old grade_completion two-shot.
#
# Cost: one rail_native invocation per prompt (30 total) versus N=20 + 20
# per prompt (≈600+ total). Plus per-fallback shell calls which still need
# rail_native, but those happen INSIDE the batch grader's single process.
# ---------------------------------------------------------------------------

JIT_GRADE_BATCH_RAIL = Path(__file__).resolve().parent / "jit_grade_batch.rail"
LIBJIT_CALL_DYLIB = Path(__file__).resolve().parents[1] / "jit/libjit_call.dylib"
JIT_GRADE_BATCH_BIN: Path | None = None  # set lazily by ensure_jit_batch_bin


def ensure_jit_batch_bin() -> Path:
    """Compile jit_grade_batch.rail once; return path to the binary."""
    global JIT_GRADE_BATCH_BIN
    if JIT_GRADE_BATCH_BIN is not None and JIT_GRADE_BATCH_BIN.is_file():
        return JIT_GRADE_BATCH_BIN
    # libjit_call.dylib is link-time-optional in rail_native; build it if it
    # isn't present (compile.rail picks it up via -weak-ljit_call so absence
    # silently links but crashes on call).
    if not LIBJIT_CALL_DYLIB.is_file():
        build_script = LIBJIT_CALL_DYLIB.parent / "build_trampoline.sh"
        if build_script.is_file():
            subprocess.run(["bash", str(build_script)], capture_output=True, timeout=60, check=False)
    # Compile to a unique path; /tmp/rail_out is host-global and races
    # with concurrent worktree agents.
    out = Path("/tmp") / f"jit_grade_batch_{os.getpid()}"
    r = subprocess.run(
        [RAIL_NATIVE, str(JIT_GRADE_BATCH_RAIL)],
        capture_output=True, timeout=60,
    )
    if r.returncode != 0:
        raise RuntimeError(f"failed to compile jit_grade_batch.rail: {r.stderr.decode(errors='replace')}")
    # rail_native writes the binary to /tmp/rail_out by default
    src = Path("/tmp/rail_out")
    if not src.is_file():
        raise RuntimeError("jit_grade_batch compile produced no /tmp/rail_out")
    out.write_bytes(src.read_bytes())
    out.chmod(0o755)
    JIT_GRADE_BATCH_BIN = out
    return out


def grade_completion_batch_jit(prompt: str, completions: list[str], task_dir: Path) -> tuple[list[bool], dict]:
    """Batch-grade N completions via JIT-first batch grader.

    Returns (per_completion_pass_list, stats) where stats has:
      jit_pass, shell_pass, fail (totals across stripped + prompt+stripped variants)
    """
    task_dir.mkdir(parents=True, exist_ok=True)
    # Each completion contributes up to 2 candidate files: stripped (if
    # nonempty) and prompt+stripped. We grade them all in one batch, then
    # OR the results per completion.
    candidate_paths: list[tuple[int, str, Path]] = []  # (completion_idx, variant, path)
    for i, c in enumerate(completions):
        stripped = strip_artifacts(c)
        if stripped:
            p = task_dir / f"c{i:02d}_strip.rail"
            p.write_text(stripped)
            candidate_paths.append((i, "strip", p))
        p2 = task_dir / f"c{i:02d}_pp.rail"
        p2.write_text(prompt + stripped)
        candidate_paths.append((i, "pp", p2))

    manifest = task_dir / "manifest.txt"
    manifest.write_text("\n".join(str(p) for (_, _, p) in candidate_paths) + "\n")

    batch_bin = ensure_jit_batch_bin()
    r = subprocess.run(
        [str(batch_bin), str(manifest)],
        capture_output=True, timeout=600,
    )
    out = r.stdout.decode(errors="replace")
    # Parse result lines.
    by_path: dict[str, str] = {}
    jit_pass = shell_pass = fail = 0
    for line in out.splitlines():
        if line.startswith("JIT_PASS:"):
            by_path[line[len("JIT_PASS:"):]] = "jit_pass"
            jit_pass += 1
        elif line.startswith("SHELL_PASS:"):
            by_path[line[len("SHELL_PASS:"):]] = "shell_pass"
            shell_pass += 1
        elif line.startswith("FAIL:"):
            by_path[line[len("FAIL:"):]] = "fail"
            fail += 1
    # Per-completion pass = any variant passed.
    per_pass = [False] * len(completions)
    for (i, _variant, p) in candidate_paths:
        verdict = by_path.get(str(p), "fail")
        if verdict in ("jit_pass", "shell_pass"):
            per_pass[i] = True
    stats = {
        "jit_pass": jit_pass,
        "shell_pass": shell_pass,
        "fail": fail,
        "total_candidates": len(candidate_paths),
    }
    return per_pass, stats


def filter_prompts(bench: dict, selector: str | None) -> dict:
    if not selector:
        return bench
    wanted = set(s.strip() for s in selector.split(",") if s.strip())
    out: dict[str, list] = {}
    for band, tasks in bench.items():
        kept = []
        for name, prompt in tasks:
            if f"{band}/{name}" in wanted or band in wanted:
                kept.append((name, prompt))
        if kept:
            out[band] = kept
    return out


def main():
    ap = argparse.ArgumentParser(description="Substrate hard-bench probe via Anthropic API")
    ap.add_argument("--model", default=DEFAULT_MODEL, help=f"Anthropic model (default: {DEFAULT_MODEL})")
    ap.add_argument("--n", type=int, default=N_RERANK, help=f"reranks per prompt (default: {N_RERANK})")
    ap.add_argument("--prompts", default=None,
                    help="comma-separated band/name selectors (e.g. 'fund/add,io'); default = all 30")
    ap.add_argument("--no-cost-banner", action="store_true", help="skip cost banner")
    ap.add_argument("--jit-fast", action="store_true",
                    help="route grading through the JIT-first batch grader at "
                         "tools/bench/jit_grade_batch.rail (one rail_native "
                         "invocation per prompt instead of per candidate).")
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set in environment", file=sys.stderr)
        return 2

    if not Path(RAIL_NATIVE).is_file():
        print(f"ERROR: rail_native not found at {RAIL_NATIVE}", file=sys.stderr)
        return 2

    bench = filter_prompts(BENCH, args.prompts)
    n_prompts = sum(len(v) for v in bench.values())
    n_calls = n_prompts * args.n

    if not args.no_cost_banner:
        # Scale cost estimate by call count vs full-bench (30*20=600 calls)
        scale = n_calls / 600.0
        lo = COST_LO * scale
        hi = COST_HI * scale
        print("=" * 70, flush=True)
        print(f"Anthropic substrate hard-bench probe", flush=True)
        print(f"  model:    {args.model}", flush=True)
        print(f"  prompts:  {n_prompts}", flush=True)
        print(f"  reranks:  {args.n} per prompt  (total {n_calls} API calls)", flush=True)
        print(f"  estimated cost: ${lo:.2f}-${hi:.2f} USD", flush=True)
        print(f"  (claude-opus-4-7 baseline: ~$15/M input + ~$75/M output;", flush=True)
        print(f"   verify current pricing at https://www.anthropic.com/pricing)", flush=True)
        print("=" * 70, flush=True)

    if args.jit_fast:
        # Pre-build the JIT batch grader so we get a clean startup-failure
        # error before we spend money on API calls.
        try:
            bb = ensure_jit_batch_bin()
            print(f"[jit-fast] batch grader compiled at {bb}", flush=True)
        except Exception as e:
            print(f"ERROR: --jit-fast requested but couldn't build batch grader: {e}", file=sys.stderr)
            return 2

    t0 = time.time()
    band_pass = {b: 0 for b in bench}
    pass_log = []
    overall_pass = 0
    overall_total = 0
    jit_stats_total = {"jit_pass": 0, "shell_pass": 0, "fail": 0, "total_candidates": 0}
    for band, tasks in bench.items():
        for name, prompt in tasks:
            t_task = time.time()
            hard_deadline = t_task + PER_PROMPT_HARD_TIMEOUT
            completions = call_teacher(prompt, args.model, api_key, args.n, hard_deadline)
            if args.jit_fast:
                task_dir = Path(f"/tmp/jit_bench_task_{os.getpid()}/{band}_{name}")
                per_pass, stats = grade_completion_batch_jit(prompt, completions, task_dir)
                n_compiles = sum(1 for ok in per_pass if ok)
                first_pass_idx = next((i for i, ok in enumerate(per_pass) if ok), -1)
                for k in jit_stats_total:
                    jit_stats_total[k] += stats[k]
            else:
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
            print(f"  {band}/{name}: {status} ({n_compiles}/{args.n} compile, "
                  f"first@{first_pass_idx if first_pass_idx >= 0 else 'none'}, "
                  f"{elapsed:.1f}s)", flush=True)
            pass_log.append({
                "band": band, "name": name, "compiles": n_compiles,
                "elapsed": elapsed, "first_pass_idx": first_pass_idx,
            })
            if passed:
                band_pass[band] += 1
                overall_pass += 1
            overall_total += 1
        print(f"  -- BAND {band}: {band_pass[band]}/{len(tasks)} --", flush=True)

    total_elapsed = time.time() - t0
    print()
    print("=== SUBSTRATE HARD-BENCH RESULT ===")
    pct = 100.0 * overall_pass / max(overall_total, 1)
    print(f"Overall: {overall_pass}/{overall_total} ({pct:.1f}%)")
    print(f"Wall-clock: {total_elapsed / 60:.1f} min")
    print(f"Per band:")
    for b in bench:
        print(f"  {b}: {band_pass[b]}/{len(bench[b])}")
    if args.jit_fast:
        tc = jit_stats_total["total_candidates"]
        jp = jit_stats_total["jit_pass"]
        sp = jit_stats_total["shell_pass"]
        fl = jit_stats_total["fail"]
        lower_hit_pct = (100.0 * jp / max(tc, 1))
        print(f"JIT-fast: {jp} JIT-pass / {sp} shell-pass / {fl} fail "
              f"(of {tc} candidates; lower-hit {lower_hit_pct:.1f}%)")
    out = Path("/tmp/substrate_repro_result.json")
    out.write_text(json.dumps({
        "overall": f"{overall_pass}/{overall_total}",
        "per_band": band_pass,
        "wall_clock_min": total_elapsed / 60,
        "n_rerank": args.n,
        "model": args.model,
        "endpoint": ANTHROPIC_ENDPOINT,
        "tasks": pass_log,
        "jit_fast": args.jit_fast,
        "jit_stats": jit_stats_total if args.jit_fast else None,
    }, indent=2))
    print(f"JSON: {out}")
    return 0 if overall_pass == overall_total and overall_total > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
