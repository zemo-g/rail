#!/usr/bin/env python3
"""Generate complete Rail programs by calling `claude -p`.

Each call asks Claude for K programs, separated by a delimiter.
Each program is compile-verified by ./rail_native.
Passes are saved to JSONL with full source.

Usage: gen_rail_claude.py --target 200 --per-call 10 --out training/claude_rail.jsonl
"""
import argparse, subprocess, tempfile, os, json, sys, hashlib, time, random
from pathlib import Path

REPO = Path("/Users/ledaticempire/projects/rail")
RAIL_NATIVE = REPO / "rail_native"
DELIM = "--- END PROGRAM ---"

# Topics to bias diversity — we cycle through these
TOPICS = [
    "ADTs and pattern matching",
    "list operations (map, filter, fold, length)",
    "recursive functions (fact, fib, gcd, ackermann-like)",
    "string manipulation (split, join, length, contains)",
    "let-binding chains and arithmetic",
    "if/else logic and conditionals",
    "tree/binary structures",
    "linked-list-like structures",
    "math functions (power, sqrt approximation, sum of series)",
    "sorting and searching",
    "polynomial evaluation",
    "expression evaluators (parse and compute)",
    "state machines",
    "counting and statistics on lists",
    "tuple-like records via ADTs",
    "Maybe/Option/Result patterns",
    "fibonacci, lucas, catalan number sequences",
    "binary, hex, decimal conversions",
    "small interpreters",
    "validation routines (palindrome, sorted, unique)",
]

PROMPT_TEMPLATE = """Generate {k} different complete Rail programs about {topic}. Each program MUST:
- Be 15-60 lines long
- End with `main = ...\\n  0` (main returns int 0)
- Use real Rail features (let, if, match, ADTs, lists, recursion, etc.)
- COMPILE successfully (no syntax errors, proper indentation)
- Be different from one another (different functions, different topics)

Output format — STRICT:
- ONLY Rail code, NO markdown fences, NO explanations, NO comments outside code
- Separate each program with this exact line on its own:
{delim}
- After the last program, also emit the delimiter
- No trailing backticks, no headers

Rail syntax quick reference (study before generating):
```
add a b = a + b                          -- function def
main = let _ = print (show (add 3 4))   -- main returns int
  0
type Option = | Some x | None            -- ADT
get_or d opt = match opt                 -- pattern match
  | Some x -> x
  | None -> d
fact n = if n < 2 then 1 else n * fact (n - 1)  -- recursion
fold add 0 [1,2,3,4,5]                  -- list ops (named functions, no nested lambdas)
```

Output the {k} programs now:"""

def call_claude(prompt: str, model: str = "haiku") -> str:
    """Call claude -p, return stdout."""
    proc = subprocess.run(
        ["claude", "-p", "--model", model],
        input=prompt, capture_output=True, text=True, timeout=300,
    )
    if proc.returncode != 0:
        print(f"  claude failed: {proc.stderr[:200]}", file=sys.stderr)
        return ""
    return proc.stdout

def parse_programs(text: str) -> list[str]:
    """Split by delimiter, clean, return non-empty."""
    parts = text.split(DELIM)
    progs = []
    for p in parts:
        p = p.strip()
        # Strip markdown fences if Claude added them
        if p.startswith("```"):
            lines = p.split("\n")
            # Drop first line (``` or ```rail) and last line (```)
            if lines and lines[0].startswith("```"):
                lines = lines[1:]
            if lines and lines[-1].strip() == "```":
                lines = lines[:-1]
            p = "\n".join(lines).strip()
        if len(p) > 20 and "main" in p:
            progs.append(p)
    return progs

def compile_check(src: str) -> tuple[bool, str]:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".rail", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        proc = subprocess.run(
            [str(RAIL_NATIVE), path],
            capture_output=True, text=True, timeout=10,
        )
        ok = proc.returncode == 0
        err = "" if ok else (proc.stderr or proc.stdout).strip()[:300]
        return ok, err
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    finally:
        os.unlink(path)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=int, default=200, help="target passing programs")
    ap.add_argument("--per-call", type=int, default=10, help="programs per Claude call")
    ap.add_argument("--out", default="training/claude_rail.jsonl")
    ap.add_argument("--model", default="haiku", choices=["haiku", "sonnet", "opus"])
    ap.add_argument("--max-calls", type=int, default=100)
    args = ap.parse_args()

    out_path = REPO / args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Resume if file exists
    seen_hashes = set()
    n_passing = 0
    if out_path.exists():
        with open(out_path) as f:
            for line in f:
                try:
                    obj = json.loads(line)
                    seen_hashes.add(obj.get("sha", ""))
                    n_passing += 1
                except json.JSONDecodeError:
                    pass
        print(f"  resuming: {n_passing} programs already in {out_path}")

    n_calls = 0
    n_attempts = 0
    n_compile_fails = 0
    t0 = time.time()

    with open(out_path, "a") as f:
        while n_passing < args.target and n_calls < args.max_calls:
            topic = random.choice(TOPICS)
            prompt = PROMPT_TEMPLATE.format(k=args.per_call, topic=topic, delim=DELIM)
            print(f"\n[call {n_calls+1}] topic={topic}")
            text = call_claude(prompt, model=args.model)
            n_calls += 1
            if not text:
                continue
            progs = parse_programs(text)
            print(f"  parsed {len(progs)} program candidates")
            for src in progs:
                n_attempts += 1
                h = hashlib.sha256(src.encode()).hexdigest()
                if h in seen_hashes:
                    continue
                seen_hashes.add(h)
                ok, err = compile_check(src)
                if ok:
                    n_passing += 1
                    obj = {"sha": h, "topic": topic, "source": src}
                    f.write(json.dumps(obj) + "\n")
                    f.flush()
                    print(f"  ✓ pass [{n_passing}/{args.target}] ({len(src)} chars)")
                else:
                    n_compile_fails += 1
                    print(f"  ✗ fail: {err[:80]}")
            elapsed = time.time() - t0
            rate = n_passing / max(elapsed, 1)
            print(f"  --- progress: {n_passing}/{args.target} pass | {n_compile_fails} fail | {n_calls} calls | {elapsed:.0f}s | {rate:.2f} pass/s")

    elapsed = time.time() - t0
    print(f"\n=== DONE ===")
    print(f"  passing programs: {n_passing}")
    print(f"  total attempts: {n_attempts}")
    print(f"  compile pass rate: {100*n_passing/max(n_attempts,1):.1f}%")
    print(f"  total calls: {n_calls}")
    print(f"  elapsed: {elapsed:.0f}s")
    print(f"  output: {out_path}")

if __name__ == "__main__":
    main()
