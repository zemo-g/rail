#!/usr/bin/env python3
"""cloud_gen.py — Use a large cloud model (Together.ai) to generate Rail training data.
Compiler-as-oracle: generate → compile → verify → harvest successes.

Usage:
  python3 cloud_gen.py                        # default: 3 passes over levels 1-10
  python3 cloud_gen.py --levels 2-5 --passes 5
  python3 cloud_gen.py --model meta-llama/Llama-3.3-70B-Instruct-Turbo
"""

import argparse, json, os, subprocess, sys, time, random

TOGETHER_KEY = os.environ.get("TOGETHER_API_KEY", "")
if not TOGETHER_KEY:
    print("ERROR: Set TOGETHER_API_KEY environment variable"); sys.exit(1)
TOGETHER_URL = "https://api.together.xyz/v1/chat/completions"
DEFAULT_MODEL = "Qwen/Qwen3-235B-A22B-Instruct-2507-tput"
RAIL_DIR = os.path.expanduser("~/projects/rail")
RAIL_BIN = os.path.join(RAIL_DIR, "rail_native")
HARVEST_FILE = os.path.join(RAIL_DIR, "training/self_train/cloud_harvest.jsonl")
REPAIR_FILE = os.path.join(RAIL_DIR, "training/self_train/cloud_repairs.jsonl")

# Read grammar if available
GRAMMAR_PATH = os.path.join(RAIL_DIR, "grammar/rail.ebnf")
GRAMMAR = ""
if os.path.exists(GRAMMAR_PATH):
    with open(GRAMMAR_PATH) as f:
        GRAMMAR = f.read()

_grammar_section = ("GRAMMAR:\n" + GRAMMAR + "\n\n") if GRAMMAR else ""
SYSTEM_PROMPT = f"""{_grammar_section}You are a Rail language expert. Rail compiles to native ARM64.

CRITICAL RULES:
- Functions: name params = body (top-level only, no 'let rec')
- Let uses NEWLINES not 'in': let x = 5 then next line uses x
- If: if cond then a else b (always both branches)
- Match: match expr | Pat args -> expr (NO 'with', NO '::')
- Lambda: backslash x -> expr (single arg only)
- Lists: [1,2,3], head, tail, cons, map, filter, fold, length, reverse, range
- Tuples: (a,b), let (x,y) = expr
- ADTs: type T = | A x | B  then match val | A x -> ... | B -> ...
- Strings: "hello", NO char literals, NO string indexing
- print outputs value, show converts int to string
- join sep list, split sep str, append str1 str2
- main must exist and return an int
- Use let _ = print expr for side effects
- shell "command" runs a shell command and returns stdout
- read_file "path" reads file, write_file "path" "content" writes file
- arena_mark / arena_reset for memory management in loops
- cat [s1, s2, s3] concatenates strings (same as join "" [s1, s2, s3])
- NO: let rec, match...with, x::xs, arr[i], where, in (at end of let), fn keyword

Write ONLY the Rail code. No markdown fences, no explanation. Just the program."""

REPAIR_SYSTEM = """You are a Rail language expert that fixes compiler errors in Rail code.
Given broken code and the compiler error, output ONLY the corrected Rail code.
No markdown fences, no explanation. Just the fixed program."""

# Seeds per level (task descriptions only)
SEEDS = {
    1: [
        "Write a Rail program that computes 2^10 (1024) using repeated multiplication",
        "Write a Rail program that prints the sum of 1 to 100",
        "Write a Rail program that converts Celsius 37 to Fahrenheit and prints it",
        "Write a Rail program that computes absolute value of -42",
        "Write a Rail program that prints the larger of 17 and 25",
        "Write a Rail program that computes remainder of 100 divided by 7",
        "Write a Rail program that prints hello world 3 times using recursion",
        "Write a Rail program that checks if 17 is odd and prints yes or no",
        "Write a Rail program that computes the average of 10, 20, 30 as an integer",
        "Write a Rail program that computes GCD of 48 and 18 using recursion",
    ],
    2: [
        "Write a Rail program that filters even numbers from [1,2,3,4,5,6,7,8,9,10] and prints count",
        "Write a Rail program that computes dot product of [1,2,3] and [4,5,6]",
        "Write a Rail program that finds the second-largest element in [3,1,4,1,5,9]",
        "Write a Rail program that removes all zeros from [1,0,2,0,3,0]",
        "Write a Rail program that generates the first 10 fibonacci numbers",
        "Write a Rail program that checks if [1,2,3,4,5] is sorted ascending",
        "Write a Rail program that rotates a list [1,2,3,4,5] left by 2 positions",
        "Write a Rail program that computes sum of squares of [1,2,3,4,5]",
        "Write a Rail program that reverses a list using fold",
        "Write a Rail program that finds the maximum element in [3,7,2,9,4] using recursion",
    ],
    3: [
        "Write a Rail program with a Maybe ADT that safely divides 10 by 0 and prints None",
        "Write a Rail program with a List ADT (Cons/Nil) that computes length of a 3-element list",
        "Write a Rail program with a Tree ADT that counts the number of leaves",
        "Write a Rail program with an Expr ADT (Num/Add/Mul) that evaluates Add (Num 3) (Mul (Num 2) (Num 4))",
        "Write a Rail program that implements a stack ADT with push pop and peek",
        "Write a Rail program that uses tuples to return both quotient and remainder of 17/5",
        "Write a Rail program with a Color ADT (Red/Green/Blue) that converts to RGB integer values",
        "Write a Rail program with a Result ADT (Ok/Err) that chains two operations",
        "Write a Rail program with a Shape ADT (Circle/Rect) that computes area",
        "Write a Rail program that uses closures to create increment and decrement functions",
    ],
    4: [
        "Write a Rail program that implements insertion sort on [5,3,8,1,9,2]",
        "Write a Rail program that flattens a list of lists using fold and append",
        "Write a Rail program that implements binary search for 7 in [1,3,5,7,9,11]",
        "Write a Rail program that converts a number to its binary string representation",
        "Write a Rail program that implements run-length encoding: AAABBC -> 3A2B1C",
        "Write a Rail program that finds the longest common prefix of hello, help, heap",
        "Write a Rail program that groups consecutive equal elements and prints group lengths",
        "Write a Rail program that transposes a 2x3 matrix represented as lists",
        "Write a Rail program that implements a simple calculator evaluating Add/Sub/Mul expressions",
        "Write a Rail program that merges two sorted lists into one sorted list",
    ],
    5: [
        "Write a Rail program that uses shell to run hostname and prints the result",
        "Write a Rail program that writes key=value config to a file then reads it back",
        "Write a Rail program that uses shell to list files in /tmp and counts how many",
        "Write a Rail program that builds a JSON object with 3 fields using cat and prints it",
        "Write a Rail program that reads a file, splits into lines, filters lines containing ERROR",
        "Write a Rail program that writes numbers 1 to 10 to a file one per line then sums them",
        "Write a Rail program that splits a URL into protocol host and path and prints each",
        "Write a Rail program that builds an HTML table from 3 name-value pairs using cat",
        "Write a Rail program that reads /etc/hostname via shell and prints it trimmed",
        "Write a Rail program that writes a CSV file with 3 rows then reads it back and prints each row",
    ],
    6: [
        "Write a Rail program that parses an HTTP request line GET /status HTTP/1.1 into method path version",
        "Write a Rail program that builds an HTTP response with status 200 and JSON body",
        "Write a Rail program that parses query string name=foo&age=25 into pairs",
        "Write a Rail program that URL-encodes a string replacing spaces with %20",
        "Write a Rail program that builds a JSON array of 3 objects using cat and string helpers",
        "Write a Rail program with a Route ADT (Get/Post) that dispatches to handler functions",
        "Write a Rail program that parses HTTP headers from a multi-line string into pairs",
        "Write a Rail program that escapes HTML entities in a string: < > & quotes",
        "Write a Rail program that builds a JSON nested object with string and int fields",
        "Write a Rail program that validates a simple auth token and returns 200 or 403 status",
    ],
    7: [
        "Write a Rail program that generates an HTML page with a title and 3 list items",
        "Write a Rail program that reads key=value config lines and looks up a specific key",
        "Write a Rail program that generates a status page showing hostname and date via shell",
        "Write a Rail program that writes output to a file incrementally in chunks to avoid large strings",
        "Write a Rail program that reads a CSV file and prints a formatted table",
        "Write a Rail program that checks if a process is running via shell pgrep",
        "Write a Rail program that generates an HTML table with alternating row colors",
        "Write a Rail program that reads a progress file, increments a counter, writes it back",
        "Write a Rail program that generates a multi-section HTML report",
        "Write a Rail program that builds a deploy script checking prerequisites then copying files",
    ],
    8: [
        "Write a Rail program that uses arena_mark and arena_reset to process 50 items in a loop",
        "Write a Rail program with a Result ADT that chains operations and propagates errors",
        "Write a Rail program that manages child processes: start via shell, check alive, kill if needed",
        "Write a Rail program that implements retry logic: try up to 3 times with increasing delay",
        "Write a Rail program with a Config ADT that loads defaults then overrides from file",
        "Write a Rail program that writes to temp file then atomically renames via shell mv",
        "Write a Rail program that implements a simple task queue reading from a file",
        "Write a Rail program that checks disk usage via shell df and warns if above 90%",
        "Write a Rail program that implements a state machine for a deployment pipeline",
        "Write a Rail program with a Logger that writes timestamped entries to a file",
    ],
    9: [
        "Write a Rail program with a Bytecode ADT (Push/Add/Mul/Print) and a stack VM that executes it",
        "Write a Rail program that compiles arithmetic Expr ADTs into stack bytecodes then runs them",
        "Write a Rail program that implements constant folding on an Expr ADT",
        "Write a Rail program with a bytecode VM supporting Push Add Mul JmpIf and Halt",
        "Write a Rail program that implements a peephole optimizer for Push-Push-Add sequences",
        "Write a Rail program that implements simple type inference for Int and Bool expressions",
        "Write a Rail program that compiles If expressions into bytecode with conditional jumps",
        "Write a Rail program that implements scope analysis collecting free variables",
        "Write a Rail program that emits ARM64 assembly strings for simple arithmetic",
        "Write a Rail program that lexes a simple expression string into tokens",
    ],
    10: [
        "Write a Rail program that implements a complete HTTP health-check server response",
        "Write a Rail program that generates a full HTML dashboard with system stats via shell",
        "Write a Rail program that implements a CLI tool: parse args, read config, execute, output",
        "Write a Rail program that implements a site generator: read data, build HTML, write output",
        "Write a Rail program that implements a deploy pipeline: check, build, copy, verify, report",
        "Write a Rail program that implements a log analyzer: read log, parse, compute stats, report",
        "Write a Rail program that implements a key-value store: get set delete via file storage",
        "Write a Rail program that implements a service monitor checking 3 endpoints via shell curl",
        "Write a Rail program that implements a training data harvester reading source files",
        "Write a Rail program that implements a progress tracker with state file and batch processing",
    ],
}


def call_together(messages, model=DEFAULT_MODEL, max_tokens=2048, temperature=0.7):
    """Call Together.ai API via curl (no deps needed)."""
    payload = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    })
    result = subprocess.run([
        "curl", "-s", "-X", "POST", TOGETHER_URL,
        "-H", f"Authorization: Bearer {TOGETHER_KEY}",
        "-H", "Content-Type: application/json",
        "-d", payload,
    ], capture_output=True, text=True, timeout=120)

    if result.returncode != 0:
        return None, f"curl failed: {result.stderr}"

    try:
        resp = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, f"bad JSON: {result.stdout[:200]}"

    if "error" in resp:
        return None, f"API error: {resp['error']}"

    if "choices" not in resp or not resp["choices"]:
        return None, f"no choices: {result.stdout[:200]}"

    content = resp["choices"][0]["message"]["content"]
    usage = resp.get("usage", {})
    return content, usage


def clean_code(raw):
    """Strip markdown fences and leading/trailing whitespace."""
    code = raw.strip()
    if code.startswith("```"):
        lines = code.split("\n")
        # Remove first line (```rail or ```) and last line (```)
        lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        code = "\n".join(lines)
    return code.strip()


def verify_rail(code):
    """Compile and run Rail code. Returns (status, error_msg)."""
    test_file = "/tmp/rail_cloud_test.rail"
    bin_file = "/tmp/rail_cloud_bin"

    with open(test_file, "w") as f:
        f.write(code)

    # Compile
    subprocess.run(["rm", "-f", bin_file], capture_output=True)
    compile_result = subprocess.run(
        [RAIL_BIN, test_file],
        capture_output=True, text=True, timeout=30, cwd=RAIL_DIR
    )
    # rail_native compiles to /tmp/rail_out
    cp_result = subprocess.run(
        ["cp", "/tmp/rail_out", bin_file],
        capture_output=True, text=True
    )

    if not os.path.exists(bin_file):
        error = compile_result.stdout + compile_result.stderr
        return "compile_fail", error.strip()

    # Run with timeout
    try:
        run_result = subprocess.run(
            [bin_file], capture_output=True, text=True, timeout=5
        )
        if run_result.returncode == 0:
            return "success", ""
        else:
            return "runtime_fail", f"exit {run_result.returncode}: {run_result.stderr}"
    except subprocess.TimeoutExpired:
        return "timeout", "exceeded 5s"


def harvest_entry(task, code):
    """Create JSONL training entry."""
    sys_prompt = "You are a Rail language expert. Rail is a pure functional language that compiles to native ARM64 and Metal GPU shaders. Write correct Rail code."
    return json.dumps({
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": task},
            {"role": "assistant", "content": code},
        ]
    }, ensure_ascii=False)


def repair_entry(task, broken_code, error_msg, fixed_code):
    """Create JSONL repair training entry."""
    sys_prompt = "You are a Rail language expert that fixes compiler errors in Rail code."
    user_msg = f"Fix this Rail code:\n\n{broken_code}\n\nCompiler error:\n{error_msg}"
    return json.dumps({
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_msg},
            {"role": "assistant", "content": fixed_code},
        ]
    }, ensure_ascii=False)


def attempt_task(task, model, retries=3):
    """Generate code for a task, verify, retry on failure. Returns harvested entries."""
    entries = []
    prev_code = None
    prev_error = None

    for attempt in range(retries):
        if attempt == 0:
            user_msg = task
        else:
            user_msg = f"{task}\n\nYour previous attempt had this error:\n{prev_error}\n\nFix the code."

        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ]

        raw, usage_or_err = call_together(messages, model=model)
        if raw is None:
            print(f"    API error: {usage_or_err}")
            break

        code = clean_code(raw)
        if not code or "main" not in code:
            print(f"    No valid code generated (attempt {attempt+1})")
            prev_code = code
            prev_error = "Generated code has no main function"
            continue

        status, error = verify_rail(code)

        if status == "success":
            # Harvest success
            entries.append(("harvest", harvest_entry(task, code)))

            # If this was a retry, also harvest the repair
            if prev_code and prev_error:
                entries.append(("repair", repair_entry(task, prev_code, prev_error, code)))

            tokens = usage_or_err.get("total_tokens", "?") if isinstance(usage_or_err, dict) else "?"
            print(f"    ✓ attempt {attempt+1} ({tokens} tok)")
            return entries
        else:
            print(f"    ✗ attempt {attempt+1}: {status} — {error[:80]}")
            prev_code = code
            prev_error = error

    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--levels", default="1-10", help="Level range (e.g., 2-5)")
    parser.add_argument("--passes", type=int, default=3, help="Passes over each level")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Together.ai model ID")
    parser.add_argument("--shuffle", action="store_true", default=True)
    args = parser.parse_args()

    # Parse level range
    parts = args.levels.split("-")
    start_level = int(parts[0])
    end_level = int(parts[1]) if len(parts) > 1 else start_level

    total_success = 0
    total_repair = 0
    total_fail = 0
    total_tasks = 0

    print(f"=== RAIL CLOUD DATA GENERATOR ===")
    print(f"  Model: {args.model}")
    print(f"  Levels: {start_level}-{end_level}")
    print(f"  Passes: {args.passes}")
    print(f"  Harvest: {HARVEST_FILE}")
    print(f"  Repairs: {REPAIR_FILE}")
    print()

    for pass_num in range(1, args.passes + 1):
        print(f"--- Pass {pass_num}/{args.passes} ---")

        for level in range(start_level, end_level + 1):
            tasks = SEEDS.get(level, [])
            if args.shuffle:
                random.shuffle(tasks)

            print(f"  Level {level} ({len(tasks)} tasks)")

            for task in tasks:
                total_tasks += 1
                print(f"  [{total_tasks}] L{level}: {task[:60]}...")

                entries = attempt_task(task, args.model)

                for kind, entry_json in entries:
                    if kind == "harvest":
                        with open(HARVEST_FILE, "a") as f:
                            f.write(entry_json + "\n")
                        total_success += 1
                    elif kind == "repair":
                        with open(REPAIR_FILE, "a") as f:
                            f.write(entry_json + "\n")
                        total_repair += 1

                if not entries:
                    total_fail += 1

                # Small delay to not hammer API
                time.sleep(0.5)

        print()

    print(f"=== DONE ===")
    print(f"  Tasks attempted: {total_tasks}")
    print(f"  Successes: {total_success}")
    print(f"  Repairs: {total_repair}")
    print(f"  Failures: {total_fail}")
    print(f"  Pass rate: {total_success*100/max(total_tasks,1):.0f}%")

    # Count total harvest
    if os.path.exists(HARVEST_FILE):
        with open(HARVEST_FILE) as f:
            count = sum(1 for _ in f)
        print(f"  Total cloud harvest: {count} examples")


if __name__ == "__main__":
    main()
