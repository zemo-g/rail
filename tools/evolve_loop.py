#!/usr/bin/env python3
"""Rail evolution loop v2 — actually learns.

Each cycle:
1. Generate Rail programs for tasks
2. Validate by running them
3. For failures: extract the generated code + error
4. Feed the EXACT failing code + error back as a correction example
5. Promote passing code into the few-shot examples
6. Explore prompt mutations (temperature, example selection)

Reports to ledatic.org status board every cycle.
"""

import subprocess
import os
import sys
import time
import json
import random
from pathlib import Path

sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)
sys.stderr = os.fdopen(sys.stderr.fileno(), 'w', buffering=1)

RAIL = os.path.expanduser("~/projects/rail/target/release/rail")
SITE_UPDATE = os.path.expanduser("~/ledatic-site/update_site_data.py")
PYTHON = "/opt/homebrew/bin/python3.11"
MODEL = "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"
TMP = "/tmp/_rail_evolve_loop.rail"
STATE_FILE = "/tmp/rail_evolve_state.json"

# Seed examples — known working Rail programs
SEED_EXAMPLES = [
    ("Print factorial of 7",
     "factorial n = if n <= 1 then 1 else n * (factorial (n - 1))\nmain =\n  let _ = print (factorial 7)\n  0"),
    ("Filter even numbers",
     "main =\n  let evens = filter (\\x -> x % 2 == 0) (range 1 21)\n  let _ = print evens\n  0"),
    ("Fibonacci sequence",
     "fib n = if n <= 1 then n else (fib (n - 1)) + (fib (n - 2))\nmain =\n  let fibs = map fib (range 0 10)\n  let _ = print fibs\n  0"),
    ("Reverse a list",
     "my_reverse lst = fold [] (\\acc -> \\x -> cons x acc) lst\nmain =\n  let _ = print (my_reverse [1, 2, 3, 4, 5])\n  0"),
    ("Sum of squares",
     "square x = x * x\nmain =\n  let result = fold 0 (\\acc -> \\x -> acc + (square x)) [1, 2, 3, 4, 5]\n  let _ = print result\n  0"),
    ("Print each element",
     "main =\n  let _ = map (\\x -> print x) (range 1 6)\n  0"),
    ("Max of two numbers",
     "my_max a b = if a > b then a else b\nmain =\n  let _ = print (my_max 3 7)\n  0"),
    ("String length",
     "main =\n  let _ = print (length \"hello world\")\n  0"),
]

BASE_RULES = """You write Rail programs. Output ONLY valid Rail code. No markdown, no backticks, no comments.
RULES:
- Every program needs main = ... that returns 0
- Print: let _ = print value
- Functions: fname arg1 arg2 = body (NO type signatures, NO colons after names)
- 2-space indent for multi-line bodies
- if cond then a else b (always on one line for simple cases)
- Lambda: (\\x -> x * 2)
- Lists: [1, 2, 3]. map f list. filter f list. fold init f list
- range start end gives [start..end). cons x list. head list. tail list
- reverse list. append a b. length list. sort list. zip list1 list2
- % is modulo: x % 2
- No semicolons, no where, no do, no @, no import, no guards
- ADTs: type Option T =
    | Some T
    | None
- Pattern match: match val
    Some x -> expr
    None -> expr
- Records: type Point =
    x: f64
    y: f64
  Create: let p = { x: 1.0, y: 2.0 }
  Access: p.x"""

TASKS = [
    # Tier 1 — basic
    "Print numbers 1 through 5 each on its own line",
    "Print the factorial of 7",
    "Print all even numbers from 1 to 20",
    "Compute the sum of squares of [1,2,3,4,5] and print it",
    # Tier 2 — functions
    "Print the first 10 fibonacci numbers as a list",
    "Reverse the list [1,2,3,4,5] and print it",
    "Define a max function and find the max of 3 and 7",
    "Print the length of the string hello world",
    "Generate a list of the first 8 powers of 2 and print it",
    "Check if 17 is prime and print true or false",
    # Tier 3 — algorithms
    "Compute the GCD of 48 and 18 using Euclid's algorithm and print it",
    "Flatten a list of lists [[1,2],[3,4],[5]] into [1,2,3,4,5] and print it",
    "Compute the dot product of [1,2,3] and [4,5,6] and print it",
    "Find all numbers from 1 to 50 that are divisible by both 3 and 5",
    # Tier 4 — complex
    "Implement insertion sort and sort [5,3,8,1,9,2]",
    "Create an Option type with Some and None, wrap 42 in Some, then unwrap and print it",
    "Implement a simple stack: push 1 2 3, then pop and print the result",
    "Count how many words are in the string 'the quick brown fox jumps over the lazy dog'",
]


def call_llm(system, user, temperature=0.7):
    """Direct LLM call via curl."""
    body = json.dumps({
        "model": MODEL,
        "temperature": temperature,
        "max_tokens": 1024,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    })
    r = subprocess.run(
        ["curl", "-s", "--max-time", "90", "-X", "POST",
         "http://localhost:8080/v1/chat/completions",
         "-H", "content-type: application/json", "-d", body],
        capture_output=True, text=True, timeout=120
    )
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        resp = json.loads(r.stdout)
        content = resp["choices"][0]["message"]["content"]
        # Strip markdown fences
        if content.strip().startswith("```"):
            lines = content.strip().split("\n")
            lines = [l for l in lines if not l.strip().startswith("```")]
            content = "\n".join(lines)
        return content.strip()
    except Exception:
        return None


def validate(code):
    """Run Rail code, return (output, success)."""
    Path(TMP).write_text(code)
    r = subprocess.run(
        [RAIL, "run", TMP, "--open"],
        capture_output=True, text=True, timeout=10
    )
    output = (r.stdout.strip() + " " + r.stderr.strip()).strip()
    success = r.returncode == 0 and "error" not in output.lower()
    return output, success


def build_prompt(examples, corrections, extra_rules=""):
    """Build system prompt from rules + dynamic examples + corrections."""
    prompt = BASE_RULES

    # Add working examples (seed + discovered)
    prompt += "\n\nWORKING EXAMPLES:\n"
    # Pick up to 6 examples (mix of seed and discovered)
    selected = random.sample(examples, min(6, len(examples)))
    for desc, code in selected:
        prompt += f"\nTask: {desc}\n{code}\n---"

    # Add corrections from recent failures
    if corrections:
        prompt += "\n\nCOMMON MISTAKES TO AVOID:\n"
        for bad, error, fix in corrections[-5:]:  # last 5 corrections
            prompt += f"\nWRONG:\n{bad}\nERROR: {error}\n"
            if fix:
                prompt += f"CORRECT:\n{fix}\n"
            prompt += "---"

    if extra_rules:
        prompt += f"\n\n{extra_rules}"

    return prompt


def update_status(msg):
    try:
        subprocess.run(
            [PYTHON, SITE_UPDATE, "focus",
             "--big-picture", "Rail v0.6.0 — autonomous evolution loop",
             "--next-up", msg],
            capture_output=True, timeout=30
        )
    except Exception:
        pass


def load_state():
    if Path(STATE_FILE).exists():
        return json.loads(Path(STATE_FILE).read_text())
    return {
        "cycle": 0,
        "best_score": 0,
        "best_pct": 0,
        "examples": [],  # [(desc, code)] discovered working programs
        "corrections": [],  # [(bad_code, error, good_code)]
        "lifetime_pass": 0,
        "lifetime_total": 0,
        "task_best": {},  # task -> best code that worked
    }


def save_state(state):
    Path(STATE_FILE).write_text(json.dumps(state, indent=2))


def main():
    state = load_state()
    all_examples = list(SEED_EXAMPLES) + [(d, c) for d, c in state.get("examples", [])]
    corrections = state.get("corrections", [])

    print("=" * 60)
    print("Rail Evolution Loop v2")
    print(f"Model: {MODEL}")
    print(f"Tasks: {len(TASKS)}")
    print(f"Seed examples: {len(SEED_EXAMPLES)}")
    print(f"Discovered examples: {len(state.get('examples', []))}")
    print(f"Corrections: {len(corrections)}")
    print(f"Resuming from cycle {state['cycle']}")
    print("=" * 60)

    # Temperature schedule — explore then exploit
    temps = [0.7, 0.5, 0.3, 0.8, 0.6, 0.4, 0.2, 0.9]

    while True:
        state["cycle"] += 1
        cycle = state["cycle"]
        temp = temps[(cycle - 1) % len(temps)]

        print(f"\n{'='*60}")
        print(f"CYCLE {cycle} (temp={temp})")
        print(f"{'='*60}")

        prompt = build_prompt(all_examples, corrections)
        passed = 0
        total = len(TASKS)

        for task in TASKS:
            code = call_llm(prompt, task, temperature=temp)
            if code is None:
                print(f"  FAIL: {task} (LLM timeout)")
                continue

            output, success = validate(code)

            if success:
                passed += 1
                print(f"  PASS: {task}")

                # Promote to examples if not already known
                if task not in state.get("task_best", {}):
                    state.setdefault("examples", []).append((task, code))
                    all_examples.append((task, code))
                state.setdefault("task_best", {})[task] = code

            else:
                short_err = output[:80]
                print(f"  FAIL: {task}")
                print(f"    -> {short_err}")

                # If we have a known-good version, create a correction
                if task in state.get("task_best", {}):
                    corrections.append((code[:300], short_err, state["task_best"][task][:300]))
                else:
                    corrections.append((code[:300], short_err, None))

                # Keep corrections bounded
                if len(corrections) > 20:
                    corrections = corrections[-20:]

        pct = passed * 100 // total
        state["lifetime_pass"] = state.get("lifetime_pass", 0) + passed
        state["lifetime_total"] = state.get("lifetime_total", 0) + total
        state["corrections"] = corrections

        if passed > state.get("best_score", 0):
            state["best_score"] = passed
            state["best_pct"] = pct

        save_state(state)

        summary = (
            f"Cycle {cycle}: {passed}/{total} ({pct}%) temp={temp} | "
            f"Best: {state['best_score']}/{total} ({state['best_pct']}%) | "
            f"Examples: {len(all_examples)} | "
            f"Lifetime: {state['lifetime_pass']}/{state['lifetime_total']}"
        )
        print(f"\n{summary}")
        update_status(summary)

        print(f"\n  Sleeping 15s...\n")
        time.sleep(15)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
