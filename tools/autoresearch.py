#!/opt/homebrew/bin/python3.11
"""
autoresearch.py -- Autonomous prompt optimization for Rail code generation.

Explores a parameter space of prompt styles, example counts, temperatures,
and instruction variants to find the system prompt that maximises correct
Rail code generation from a local LLM.

Usage:
    python3 tools/autoresearch.py
    python3 tools/autoresearch.py --iterations 20 --model /path/to/model
"""

import argparse
import copy
import json
import os
import random
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

RAIL_CARGO = os.path.expanduser("~/.cargo/bin/cargo")
RAIL_PROJECT = os.path.expanduser("~/projects/rail")
LLM_ENDPOINT = "http://localhost:8080/v1/chat/completions"
DEFAULT_MODEL = os.path.expanduser("~/models/Qwen3.5-9B-6bit")
RESULTS_DIR = Path(__file__).resolve().parent / "autoresearch_results"
RESULTS_FILE = RESULTS_DIR / "results.jsonl"
TIMEOUT_SECS = 30  # per rail run invocation


# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------

@dataclass
class Task:
    name: str
    description: str
    expected_output: str
    difficulty: str  # easy, medium, hard


TASKS: List[Task] = [
    # --- Easy ---
    Task(
        name="factorial_5",
        description="Write a Rail program whose main computes factorial of 5 and prints the result.",
        expected_output="120",
        difficulty="easy",
    ),
    Task(
        name="max_two",
        description="Write a Rail program whose main prints the maximum of 7 and 12.",
        expected_output="12",
        difficulty="easy",
    ),
    Task(
        name="absolute_value",
        description="Write a Rail program whose main prints the absolute value of -42.",
        expected_output="42",
        difficulty="easy",
    ),
    Task(
        name="fibonacci_10",
        description="Write a Rail program whose main computes the 10th Fibonacci number (fib 0 = 0, fib 1 = 1) and prints it.",
        expected_output="55",
        difficulty="easy",
    ),
    Task(
        name="is_even",
        description="Write a Rail program whose main prints true if 14 is even, false otherwise. Rail bools are lowercase: true, false.",
        expected_output="true",
        difficulty="easy",
    ),
    Task(
        name="subtract",
        description="Write a Rail program whose main prints 100 - 37.",
        expected_output="63",
        difficulty="easy",
    ),
    # --- Medium ---
    Task(
        name="sum_list",
        description="Write a Rail program that sums the list [1, 2, 3, 4, 5] using fold and prints the result.",
        expected_output="15",
        difficulty="medium",
    ),
    Task(
        name="filter_even",
        description="Write a Rail program that filters even numbers from [1,2,3,4,5,6,7,8,9,10] and prints the resulting list.",
        expected_output="[2, 4, 6, 8, 10]",
        difficulty="medium",
    ),
    Task(
        name="compose_functions",
        description="Write a Rail program that defines double (x*2) and inc (x+1), composes them as inc(double(x)) on 5, and prints the result.",
        expected_output="11",
        difficulty="medium",
    ),
    Task(
        name="fizzbuzz_15",
        description='Write a Rail program whose main prints FizzBuzz for 15 (i.e. just the single number 15: print "FizzBuzz" because 15 is divisible by both 3 and 5).',
        expected_output="FizzBuzz",
        difficulty="medium",
    ),
    Task(
        name="length_list",
        description="Write a Rail program that prints the length of the list [10, 20, 30, 40].",
        expected_output="4",
        difficulty="medium",
    ),
    Task(
        name="reverse_list",
        description="Write a Rail program that reverses the list [1, 2, 3] and prints the result.",
        expected_output="[3, 2, 1]",
        difficulty="medium",
    ),
    Task(
        name="map_double",
        description="Write a Rail program that doubles every element of [1, 2, 3] using map and prints the result.",
        expected_output="[2, 4, 6]",
        difficulty="medium",
    ),
    Task(
        name="string_greeting",
        description='Write a Rail program that builds the string "Hello, World!" using append and prints it.',
        expected_output="Hello, World!",
        difficulty="medium",
    ),
    # --- Hard ---
    Task(
        name="partition",
        description="Write a Rail program that partitions [3,1,4,1,5,9,2,6] into elements less than 4 and elements >= 4, printing the two lists on separate lines (less-than first).",
        expected_output="[3, 1, 1, 2]\n[4, 5, 9, 6]",
        difficulty="hard",
    ),
    Task(
        name="join_strings",
        description='Write a Rail program that joins ["alpha", "beta", "gamma"] with ", " and prints the result.',
        expected_output="alpha, beta, gamma",
        difficulty="hard",
    ),
    Task(
        name="range_sum",
        description="Write a Rail program that creates a range from 1 to 11 (range is exclusive like Python), sums it with fold, and prints the result. range 1 11 gives [1,2,...,10].",
        expected_output="55",
        difficulty="hard",
    ),
    Task(
        name="nested_append",
        description='Write a Rail program that builds "abc" by chaining append on "a", "b", "c" and prints it.',
        expected_output="abc",
        difficulty="hard",
    ),
    Task(
        name="pipe_chain",
        description="Write a Rail program that uses the pipe operator to take 5, double it, add 3, and print the result.",
        expected_output="13",
        difficulty="hard",
    ),
]


# ---------------------------------------------------------------------------
# Parameter space
# ---------------------------------------------------------------------------

PARAM_SPACE = {
    "grammar_style": ["formal", "example_heavy", "minimal"],
    "num_examples": [1, 3, 5, 8],
    "instruction_prefix": [
        "Output ONLY valid Rail code. No markdown, no explanation.",
        "You are a Rail language expert. Respond with ONLY the Rail program.",
        "Generate a Rail program. Output raw code only, no commentary.",
        "Write the requested Rail program. Return ONLY the code.",
    ],
    "temperature": [0.1, 0.3, 0.5, 0.7],
    "include_builtins": [True, False],
    "include_gotchas": [True, False],
}


@dataclass
class PromptVariant:
    grammar_style: str
    num_examples: int
    instruction_prefix: str
    temperature: float
    include_builtins: bool
    include_gotchas: bool

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def random_variant() -> PromptVariant:
    return PromptVariant(
        grammar_style=random.choice(PARAM_SPACE["grammar_style"]),
        num_examples=random.choice(PARAM_SPACE["num_examples"]),
        instruction_prefix=random.choice(PARAM_SPACE["instruction_prefix"]),
        temperature=random.choice(PARAM_SPACE["temperature"]),
        include_builtins=random.choice(PARAM_SPACE["include_builtins"]),
        include_gotchas=random.choice(PARAM_SPACE["include_gotchas"]),
    )


def mutate_variant(v: PromptVariant) -> PromptVariant:
    """Mutate exactly one dimension of the variant."""
    new = copy.deepcopy(v)
    dim = random.choice(list(PARAM_SPACE.keys()))
    setattr(new, dim, random.choice(PARAM_SPACE[dim]))
    return new


# ---------------------------------------------------------------------------
# Grammar templates
# ---------------------------------------------------------------------------

RAIL_EXAMPLES_POOL = [
    # 1 - hello world
    '''\
-- Hello world
main = print "Hello, World!"
''',
    # 2 - factorial
    '''\
-- Factorial via recursion
factorial : i32 -> i32
factorial n =
  if n <= 1 then 1
  else n * factorial (n - 1)

main =
  let _ = print (factorial 5)
  0
''',
    # 3 - sum with fold
    '''\
-- Sum a list with fold
main =
  let nums = [1, 2, 3, 4, 5]
  let total = fold 0 (\\a -> \\b -> a + b) nums
  let _ = print total
  0
''',
    # 4 - filter + map
    '''\
-- Filter evens, then double them
main =
  let nums = [1, 2, 3, 4, 5, 6]
  let evens = filter (\\x -> x % 2 == 0) nums
  let doubled = map (\\x -> x * 2) evens
  let _ = print doubled
  0
''',
    # 5 - string building
    '''\
-- Build a greeting string
greet : String -> String
greet name = append (append "Hello, " name) "!"

main =
  let _ = print (greet "Rail")
  0
''',
    # 6 - pipe operator
    '''\
-- Pipe operator demo
double : i32 -> i32
double x = x * 2

inc : i32 -> i32
inc x = x + 1

main =
  let result = 5 |> double |> inc
  let _ = print result
  0
''',
    # 7 - match expression
    '''\
-- Match on a value
describe : i32 -> String
describe n =
  match n
    0 -> "zero"
    1 -> "one"
    _ -> "other"

main =
  let _ = print (describe 0)
  let _ = print (describe 1)
  let _ = print (describe 42)
  0
''',
    # 8 - head/tail recursion
    '''\
-- Sum a list with head/tail recursion
sumList : [i32] -> i32
sumList xs =
  if length xs == 0 then 0
  else head xs + sumList (tail xs)

main =
  let _ = print (sumList [10, 20, 30])
  0
''',
    # 9 - range
    '''\
-- Print a range
main =
  let nums = range 1 6
  let _ = print nums
  0
''',
    # 10 - show and append
    '''\
-- Convert number to string
main =
  let msg = append "The answer is " (show 42)
  let _ = print msg
  0
''',
]

BUILTINS_BLOCK = """\
Builtin functions:
  List:    head, tail, length, map, filter, fold, reverse, sort, range, cons
  String:  split, join, trim, contains, replace, append, show
  I/O:     print, read_file, write_file
  System:  shell, shell_lines, env, timestamp
  Network: http_get, http_post, json_parse, json_get
  AI:      prompt, prompt_with
"""

GOTCHAS_BLOCK = """\
CRITICAL - Rail does NOT have:
  - NO `with` keyword in match expressions
  - NO `|` before match arms (just indent the arms under `match expr`)
  - NO multi-line lambdas (use named helper functions instead)
  - NO string interpolation (use `append` chains)
  - `append` takes exactly 2 args; chain them: append (append a b) c
  - `fold` takes 3 args: initial_value, function, list (in that order)
  - NO list pattern matching like (x :: xs) -- use head/tail with length check
  - Lambdas are single-expression only: \\x -> x + 1
"""


def _grammar_formal() -> str:
    return """\
Rail Language Grammar (BNF-like):

  program     ::= decl*
  decl        ::= typeSig | funcDef
  typeSig     ::= name ':' type ('->' type)*
  funcDef     ::= name param* '=' body
  body        ::= expr | INDENT stmt+ DEDENT
  stmt        ::= 'let' name '=' expr | expr
  expr        ::= ifExpr | matchExpr | letExpr | lambda | pipe | binop | app | atom
  ifExpr      ::= 'if' expr 'then' expr 'else' expr
  matchExpr   ::= 'match' expr INDENT (pattern '->' expr)+ DEDENT
  pattern     ::= literal | constructor | '_'
  lambda      ::= '\\\\' name '->' expr           (single expression only)
  pipe        ::= expr '|>' expr
  binop       ::= expr op expr
  op          ::= '+' | '-' | '*' | '/' | '%' | '==' | '/=' | '<' | '>' | '<=' | '>=' | '&&' | '||'
  app         ::= expr expr+
  atom        ::= number | string | bool | list | '(' expr ')'
  list        ::= '[' (expr (',' expr)*)? ']'
  type        ::= 'i32' | 'f64' | 'Bool' | 'String' | '[' type ']' | '(' type ',' type ')'

  Entry point: main = expr  (returns i32 or unit)
  Comments: -- to end of line
  print returns unit -- use: let _ = print x
"""


def _grammar_example_heavy() -> str:
    return """\
Rail Language -- Learn by Example

Type signatures and function definitions:
  factorial : i32 -> i32
  factorial n = if n <= 1 then 1 else n * factorial (n - 1)

Multi-line function body (indented under =):
  sumList : [i32] -> i32
  sumList xs =
    if length xs == 0 then 0
    else head xs + sumList (tail xs)

If/else (always both branches):
  if x > 0 then "positive" else "non-positive"

Match (literal/constructor patterns, arms indented, NO `with`, NO `|`):
  match n
    0 -> "zero"
    1 -> "one"
    _ -> "other"

Let bindings in blocks:
  main =
    let x = 10
    let y = x + 5
    let _ = print y
    0

Lists:                [1, 2, 3]
String concat:        append "hello" " world"
Chained concat:       append (append "a" "b") "c"
Show (to string):     show 42
Pipe:                 5 |> double |> inc
Lambda:               \\x -> x + 1       (single expr only!)
Fold (init, fn, list): fold 0 (\\a -> \\b -> a + b) [1,2,3]

Operators: + - * / % == /= < > <= >= && ||
Types: i32, f64, Bool, String, [a], (a, b)
Entry point: main = expr
print returns unit, so: let _ = print x
Use head/tail/length for list traversal (NO cons patterns in match).
"""


def _grammar_minimal() -> str:
    return """\
Rail: typed functional language. Syntax:
  name : type -> type      -- type signature
  name params = body       -- definition (indent body under =)
  if c then a else b       -- conditional
  match expr               -- pattern match (indent arms, NO `with`, NO `|`)
    pattern -> result
  let x = expr             -- binding
  \\x -> expr               -- lambda (single expr only)
  x |> f                   -- pipe (means f x)
  [1, 2, 3]               -- list
  append s1 s2             -- string concat (2 args only, chain with parens)
  fold init fn list        -- fold
  print expr               -- print (returns unit, use let _ = print ...)
  main = expr              -- entry point
Operators: + - * / % == /= < > <= >= && ||
Types: i32 f64 Bool String [a] (a,b)
List ops: head tail length map filter fold reverse sort range cons
String ops: split join trim contains replace append show
"""


def build_system_prompt(v: PromptVariant) -> str:
    """Construct the system prompt from a PromptVariant."""
    parts = [v.instruction_prefix, ""]

    # Grammar
    if v.grammar_style == "formal":
        parts.append(_grammar_formal())
    elif v.grammar_style == "example_heavy":
        parts.append(_grammar_example_heavy())
    else:
        parts.append(_grammar_minimal())

    # Builtins
    if v.include_builtins:
        parts.append(BUILTINS_BLOCK)

    # Gotchas
    if v.include_gotchas:
        parts.append(GOTCHAS_BLOCK)

    # Examples
    examples = RAIL_EXAMPLES_POOL[: v.num_examples]
    if examples:
        parts.append("Example Rail programs:\n")
        for i, ex in enumerate(examples, 1):
            parts.append(f"--- Example {i} ---")
            parts.append(ex)

    parts.append(
        "\nRespond with ONLY the Rail code. No markdown fences, no explanation."
    )
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# LLM client
# ---------------------------------------------------------------------------

def llm_generate(system_prompt: str, user_prompt: str, temperature: float,
                 model: str) -> Optional[str]:
    """Call the local LLM via OpenAI-compatible API. Returns generated text or None."""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": temperature,
        "max_tokens": 1024,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        LLM_ENDPOINT,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode())
        content = body["choices"][0]["message"]["content"]
        return _strip_markdown_fences(content)
    except Exception as e:
        print(f"  [LLM ERROR] {e}", file=sys.stderr)
        return None


def _strip_markdown_fences(text: str) -> str:
    """Remove ```rail ... ``` or ``` ... ``` wrappers if present."""
    text = text.strip()
    if text.startswith("```"):
        lines = text.split("\n")
        # drop first line (```rail or ```)
        lines = lines[1:]
        # drop last ``` if present
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines)
    return text.strip()


# ---------------------------------------------------------------------------
# Rail runner
# ---------------------------------------------------------------------------

def run_rail(code: str) -> Tuple[Optional[str], Optional[str]]:
    """Write code to a temp file, run it with Rail, return (stdout, stderr)."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".rail", dir="/tmp", delete=False
    ) as f:
        f.write(code)
        f.write("\n")
        tmppath = f.name

    try:
        result = subprocess.run(
            [RAIL_CARGO, "run", "-q", "--", "run", tmppath, "--open"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECS,
            cwd=RAIL_PROJECT,
        )
        stdout = result.stdout.strip() if result.stdout else ""
        stderr = result.stderr.strip() if result.stderr else ""
        return stdout, stderr
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"
    except Exception as e:
        return None, str(e)
    finally:
        try:
            os.unlink(tmppath)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

@dataclass
class TaskResult:
    task_name: str
    difficulty: str
    passed: bool
    expected: str
    actual: Optional[str]
    stderr: Optional[str]
    code: str


@dataclass
class EvalResult:
    variant: Dict[str, Any]
    score: float
    correct: int
    total: int
    by_difficulty: Dict[str, Dict[str, int]]  # {difficulty: {correct, total}}
    task_results: List[Dict[str, Any]]
    system_prompt_len: int
    timestamp: float


def evaluate_variant(
    variant: PromptVariant, tasks: List[Task], model: str, verbose: bool = False
) -> EvalResult:
    """Run all tasks with the given prompt variant and return results."""
    system_prompt = build_system_prompt(variant)
    results: List[TaskResult] = []
    by_diff: Dict[str, Dict[str, int]] = {}

    for i, task in enumerate(tasks):
        if verbose:
            print(f"  [{i+1}/{len(tasks)}] {task.name} ({task.difficulty})...", end=" ", flush=True)

        code = llm_generate(system_prompt, task.description, variant.temperature, model)
        if code is None:
            tr = TaskResult(task.name, task.difficulty, False, task.expected_output, None, "LLM_ERROR", "")
            results.append(tr)
            if verbose:
                print("LLM_ERROR")
            continue

        stdout, stderr = run_rail(code)
        passed = stdout is not None and stdout == task.expected_output

        tr = TaskResult(task.name, task.difficulty, passed, task.expected_output, stdout, stderr, code)
        results.append(tr)

        if verbose:
            if passed:
                print("PASS")
            else:
                got = stdout if stdout is not None else f"ERR({stderr[:60]})" if stderr else "NONE"
                print(f"FAIL (expected={task.expected_output!r}, got={got!r})")

    # Aggregate
    correct = sum(1 for r in results if r.passed)
    total = len(results)

    for r in results:
        d = r.difficulty
        if d not in by_diff:
            by_diff[d] = {"correct": 0, "total": 0}
        by_diff[d]["total"] += 1
        if r.passed:
            by_diff[d]["correct"] += 1

    return EvalResult(
        variant=variant.to_dict(),
        score=correct / total if total > 0 else 0.0,
        correct=correct,
        total=total,
        by_difficulty=by_diff,
        task_results=[
            {
                "task": r.task_name,
                "difficulty": r.difficulty,
                "passed": r.passed,
                "expected": r.expected,
                "actual": r.actual,
                "stderr": r.stderr[:200] if r.stderr else None,
                "code": r.code[:500],
            }
            for r in results
        ],
        system_prompt_len=len(system_prompt),
        timestamp=time.time(),
    )


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log_result(result: EvalResult) -> None:
    """Append result to results.jsonl."""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(RESULTS_FILE, "a") as f:
        f.write(json.dumps(asdict(result), default=str) + "\n")


# ---------------------------------------------------------------------------
# Optimization loop
# ---------------------------------------------------------------------------

def run_optimization(iterations: int, model: str, verbose: bool) -> None:
    """Main optimization loop: random exploration then hill-climbing."""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    tasks = TASKS

    # Phase 1: Random exploration (first 10 or iterations, whichever is less)
    exploration_count = min(10, iterations)
    hill_climb_count = max(0, iterations - exploration_count)

    leaderboard: List[Tuple[float, PromptVariant, EvalResult]] = []

    print(f"=== Rail Autoresearch ===")
    print(f"Tasks: {len(tasks)} | Iterations: {iterations} (explore={exploration_count}, climb={hill_climb_count})")
    print(f"Model: {model}")
    print(f"Results: {RESULTS_FILE}")
    print()

    # --- Exploration phase ---
    print("--- Phase 1: Random Exploration ---")
    for i in range(exploration_count):
        variant = random_variant()
        print(f"\n[Explore {i+1}/{exploration_count}] {variant.grammar_style} | examples={variant.num_examples} | "
              f"temp={variant.temperature} | builtins={variant.include_builtins} | gotchas={variant.include_gotchas}")

        result = evaluate_variant(variant, tasks, model, verbose)
        log_result(result)
        leaderboard.append((result.score, variant, result))

        print(f"  Score: {result.correct}/{result.total} = {result.score:.1%}")
        for d, counts in sorted(result.by_difficulty.items()):
            print(f"    {d}: {counts['correct']}/{counts['total']}")

    # Sort leaderboard
    leaderboard.sort(key=lambda x: x[0], reverse=True)

    # --- Hill-climbing phase ---
    if hill_climb_count > 0:
        print("\n--- Phase 2: Hill Climbing ---")
        best_score, best_variant, _ = leaderboard[0]
        stale = 0
        max_stale = 5  # restart from a different top-N candidate after 5 stale rounds

        for i in range(hill_climb_count):
            candidate = mutate_variant(best_variant)
            print(f"\n[Climb {i+1}/{hill_climb_count}] mutated from best ({best_score:.1%}) | "
                  f"{candidate.grammar_style} | examples={candidate.num_examples} | "
                  f"temp={candidate.temperature} | builtins={candidate.include_builtins} | "
                  f"gotchas={candidate.include_gotchas}")

            result = evaluate_variant(candidate, tasks, model, verbose)
            log_result(result)
            leaderboard.append((result.score, candidate, result))

            print(f"  Score: {result.correct}/{result.total} = {result.score:.1%}", end="")

            if result.score > best_score:
                print(f"  ** NEW BEST (was {best_score:.1%}) **")
                best_score = result.score
                best_variant = candidate
                stale = 0
            else:
                stale += 1
                print(f"  (stale={stale})")

            # If stuck, jump to a different top candidate
            if stale >= max_stale and len(leaderboard) >= 3:
                leaderboard.sort(key=lambda x: x[0], reverse=True)
                # Pick randomly from top 3 (excluding current best to diversify)
                candidates = leaderboard[:3]
                pick = random.choice(candidates)
                best_score, best_variant, _ = pick
                stale = 0
                print(f"  [RESTART] Jumping to variant with score {best_score:.1%}")

    # --- Final leaderboard ---
    leaderboard.sort(key=lambda x: x[0], reverse=True)
    print("\n" + "=" * 70)
    print("LEADERBOARD (top 10)")
    print("=" * 70)
    for rank, (score, variant, result) in enumerate(leaderboard[:10], 1):
        print(f"\n  #{rank}  Score: {result.correct}/{result.total} = {score:.1%}")
        print(f"       style={variant.grammar_style} examples={variant.num_examples} "
              f"temp={variant.temperature}")
        print(f"       builtins={variant.include_builtins} gotchas={variant.include_gotchas}")
        print(f"       prefix={variant.instruction_prefix[:50]}...")
        for d, counts in sorted(result.by_difficulty.items()):
            print(f"         {d}: {counts['correct']}/{counts['total']}")

    # Best variant details
    if leaderboard:
        best_score, best_variant, best_result = leaderboard[0]
        print(f"\n{'=' * 70}")
        print(f"BEST VARIANT: {best_score:.1%} ({best_result.correct}/{best_result.total})")
        print(f"{'=' * 70}")
        print(json.dumps(best_variant.to_dict(), indent=2))

        # Show which tasks still fail
        failing = [t for t in best_result.task_results if not t["passed"]]
        if failing:
            print(f"\nFailing tasks ({len(failing)}):")
            for t in failing:
                print(f"  - {t['task']} ({t['difficulty']}): expected={t['expected']!r}, got={t['actual']!r}")

        # Save best prompt
        best_prompt_path = RESULTS_DIR / "best_prompt.txt"
        with open(best_prompt_path, "w") as f:
            f.write(build_system_prompt(best_variant))
        print(f"\nBest prompt saved to: {best_prompt_path}")

    print(f"\nAll results logged to: {RESULTS_FILE}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Autonomous prompt optimization for Rail code generation"
    )
    parser.add_argument(
        "--iterations", type=int, default=50,
        help="Total optimization iterations (default: 50)"
    )
    parser.add_argument(
        "--model", type=str, default=DEFAULT_MODEL,
        help=f"Model path (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Show per-task pass/fail output"
    )
    args = parser.parse_args()

    run_optimization(args.iterations, args.model, args.verbose)


if __name__ == "__main__":
    main()
