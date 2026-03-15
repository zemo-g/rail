#!/usr/bin/env python3
"""Rail stdlib evolution — the 27B writes Rail's standard library.

Each cycle:
1. Pick a capability the stdlib doesn't have yet
2. Ask the 27B to write it as a Rail module
3. Validate every function with test cases
4. If it passes, add it to the growing stdlib
5. Future cycles can import previous modules

The language gets more capable every cycle because
the last cycle added tools the next cycle can use.
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
STDLIB_DIR = os.path.expanduser("~/projects/rail/stdlib")
SITE_UPDATE = os.path.expanduser("~/ledatic-site/update_site_data.py")
PYTHON = "/opt/homebrew/bin/python3.11"
MODEL = "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"
TMP = "/tmp/_rail_stdlib_evolve.rail"
STATE_FILE = "/tmp/rail_stdlib_state.json"

RAIL_RULES = """You write Rail standard library modules. Output ONLY valid Rail code.
ABSOLUTE RULE: NO TYPE SIGNATURES. Never write "fname : Type -> Type". Just write "fname arg1 arg2 = body".
RULES:
- Module declaration: module ModuleName
- Export functions: export (func1, func2, func3)
- Functions: fname arg1 arg2 = body
- WRONG: take : Int -> [a] -> [a]    <-- NEVER DO THIS
- RIGHT: take n lst = ...             <-- JUST THE DEFINITION
- 2-space indent for multi-line bodies
- if cond then a else b
- Lambda: (\\x -> x * 2)
- Lists: [1,2,3]. map f list. filter f list. fold init f list
- range start end. cons x list. head list. tail list. length list
- reverse list. append list1 list2. sort list. zip list1 list2
- % is modulo. No semicolons, no where, no do, no @
- ADTs: type Option T = | Some T | None
- match val\\n  pattern -> expr
- Records: type Point = x: f64, y: f64
- Available from Prelude: id, const, flip, compose, negate
- Available from Math: square, cube, is_even, is_odd, gcd, lcm, factorial, fib, clamp, lerp
- Available from String: words, unwords, lines, unlines, is_empty, repeat_str
- Rail does NOT have: null, nil, and, or, not, isEmpty, head', tail', fst, snd, elem, notElem, otherwise
- Empty list check: length list == 0 (not "null list")
- Boolean and/or: use && and || operators (not "and"/"or" functions)
- First/rest of list: head list, tail list
- Check if list has 1 element: length list == 1"""

# What we want the stdlib to have — ordered by dependency
STDLIB_GOALS = [
    {
        "module": "ListExtra",
        "description": "Extended list operations",
        "functions": [
            ("take", "take n list — first n elements", "take 3 [1,2,3,4,5] should give [1,2,3]"),
            ("drop", "drop n list — remove first n elements", "drop 2 [1,2,3,4,5] should give [3,4,5]"),
            ("last", "last element of a list", "last [1,2,3] should give 3"),
            ("init_list", "all but the last element", "init_list [1,2,3,4] should give [1,2,3]"),
            ("sum", "sum of a list of integers", "sum [1,2,3,4,5] should give 15"),
            ("product", "product of a list of integers", "product [1,2,3,4,5] should give 120"),
            ("any_true", "any_true predicate list — true if any element matches", "any_true (\\x -> x > 3) [1,2,3,4,5] should give true"),
            ("all_true", "all_true predicate list — true if all elements match", "all_true (\\x -> x > 0) [1,2,3] should give true"),
            ("flatten", "flatten a list of lists into one list", "flatten [[1,2],[3],[4,5]] should give [1,2,3,4,5]"),
            ("unique", "remove duplicates from a sorted list", "unique [1,1,2,2,3] should give [1,2,3]"),
        ],
    },
    {
        "module": "StringExtra",
        "description": "Extended string operations",
        "functions": [
            ("char_at", "char_at index string — character at position", "char_at 0 \"hello\" should give \"h\""),
            ("string_reverse", "reverse a string", "string_reverse \"hello\" should give \"olleh\""),
            ("pad_left", "pad_left n char string — pad to length n", "pad_left 5 \"0\" \"42\" should give \"00042\""),
            ("count_char", "count occurrences of a substring", "count_char \"l\" \"hello\" should give 2"),
            ("is_digit", "check if string is all digits", "is_digit \"123\" should give true"),
            ("capitalize", "uppercase first character", "capitalize \"hello\" should give \"Hello\""),
        ],
    },
    {
        "module": "Sort",
        "description": "Sorting algorithms",
        "functions": [
            ("insertion_sort", "sort a list using insertion sort", "insertion_sort [5,3,8,1,9,2] should give [1,2,3,5,8,9]"),
            ("merge_sort", "sort a list using merge sort", "merge_sort [38,27,43,3,9,82,10] should give [3,9,10,27,38,43,82]"),
            ("sort_by", "sort_by comparator list — sort with custom comparison", "sort_by (\\a -> \\b -> a > b) [3,1,2] should give [3,2,1]"),
            ("min_of", "minimum element of a list", "min_of [3,1,4,1,5] should give 1"),
            ("max_of", "maximum element of a list", "max_of [3,1,4,1,5] should give 5"),
        ],
    },
    {
        "module": "Dict",
        "description": "Association list (key-value) operations",
        "functions": [
            ("dict_new", "create empty dict (empty list)", "dict_new () should give []"),
            ("dict_insert", "dict_insert key value dict — add or update", "dict_insert \"a\" 1 [] should give [(\"a\", 1)]"),
            ("dict_get", "dict_get key dict — find value or return None", "dict_get \"a\" [(\"a\", 1)] should give Some 1"),
            ("dict_has", "dict_has key dict — check if key exists", "dict_has \"a\" [(\"a\", 1)] should give true"),
            ("dict_keys", "list of all keys", "dict_keys [(\"a\", 1), (\"b\", 2)] should give [\"a\", \"b\"]"),
            ("dict_values", "list of all values", "dict_values [(\"a\", 1), (\"b\", 2)] should give [1, 2]"),
        ],
    },
    {
        "module": "Algo",
        "description": "Common algorithms",
        "functions": [
            ("binary_search", "binary_search target sorted_list — index or -1", "binary_search 7 [1,3,5,7,9,11] should give 3"),
            ("is_prime", "check if a number is prime", "is_prime 17 should give true, is_prime 4 should give false"),
            ("primes_up_to", "list of primes up to n", "primes_up_to 20 should give [2,3,5,7,11,13,17,19]"),
            ("dot_product", "dot product of two lists", "dot_product [1,2,3] [4,5,6] should give 32"),
            ("transpose", "transpose a matrix (list of lists)", "transpose [[1,2],[3,4]] should give [[1,3],[2,4]]"),
        ],
    },
    {
        "module": "Functional",
        "description": "Higher-order functional programming utilities",
        "functions": [
            ("twice", "apply function twice: twice f x = f (f x)", "twice (\\x -> x + 1) 5 should give 7"),
            ("iterate_n", "apply f n times: iterate_n f n x", "iterate_n (\\x -> x * 2) 3 1 should give 8"),
            ("scan", "like fold but keeps intermediates", "scan 0 (\\acc -> \\x -> acc + x) [1,2,3] should give [0,1,3,6]"),
            ("zip_with", "zip_with f list1 list2 — zip and apply", "zip_with (\\a -> \\b -> a + b) [1,2,3] [10,20,30] should give [11,22,33]"),
            ("compose_all", "compose a list of functions", "compose_all [(\\x -> x + 1), (\\x -> x * 2)] 3 should give 7"),
            ("pipe_all", "pipe value through list of functions", "pipe_all 3 [(\\x -> x * 2), (\\x -> x + 1)] should give 7"),
        ],
    },
]


def call_llm(system, user, temperature=0.3):
    body = json.dumps({
        "model": MODEL,
        "temperature": temperature,
        "max_tokens": 2048,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    })
    r = subprocess.run(
        ["curl", "-s", "--max-time", "120", "-X", "POST",
         "http://localhost:8080/v1/chat/completions",
         "-H", "content-type: application/json", "-d", body],
        capture_output=True, text=True, timeout=150
    )
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        resp = json.loads(r.stdout)
        content = resp["choices"][0]["message"]["content"]
        if content.strip().startswith("```"):
            lines = content.strip().split("\n")
            lines = [l for l in lines if not l.strip().startswith("```")]
            content = "\n".join(lines)
        return content.strip()
    except Exception:
        return None


def validate_rail(code, timeout=10):
    Path(TMP).write_text(code)
    r = subprocess.run(
        [RAIL, "run", TMP, "--open"],
        capture_output=True, text=True, timeout=timeout
    )
    output = (r.stdout.strip() + " " + r.stderr.strip()).strip()
    return output, r.returncode == 0


def build_test_program(module_code, func_name, test_desc):
    """Build a Rail program that imports the module and tests one function."""
    # Write module to a temp file, then write a test that uses it
    return f"""{module_code}

main =
  let result = {test_desc.split(' should give ')[0]}
  let _ = print result
  0"""


def generate_module(goal, existing_modules):
    """Ask LLM to write a complete module."""
    func_specs = "\n".join(
        f"  - {name}: {desc}" for name, desc, _ in goal["functions"]
    )

    existing_info = ""
    if existing_modules:
        existing_info = "\n\nAlready built (you can use these):\n"
        for mod_name, funcs in existing_modules.items():
            existing_info += f"  {mod_name}: {', '.join(funcs)}\n"

    prompt = f"""Write a Rail module called {goal['module']}.
{goal['description']}.

Functions needed:
{func_specs}

{existing_info}

Write the complete module with module declaration, exports, and all function implementations.
Each function should work standalone — don't import other custom modules.
Use recursion with if/else for algorithms. Use fold, map, filter for list operations."""

    return call_llm(RAIL_RULES, prompt, temperature=0.2)


def test_function(module_code, func_name, test_spec):
    """Test one function from the module."""
    parts = test_spec.split(" should give ")
    if len(parts) != 2:
        return False, f"bad test spec: {test_spec}"

    call_expr = parts[0].strip()
    expected = parts[1].strip()

    test_code = f"""{module_code}

main =
  let result = {call_expr}
  let _ = print result
  0"""

    output, success = validate_rail(test_code)

    if not success:
        return False, output[:100]

    # Check output matches expected
    actual = output.strip().split("\n")[-1] if output.strip() else ""

    # Normalize for comparison
    actual_clean = actual.strip().lower()
    expected_clean = expected.strip().lower()

    if actual_clean == expected_clean:
        return True, actual
    # Try numeric comparison
    try:
        if float(actual_clean) == float(expected_clean):
            return True, actual
    except (ValueError, TypeError):
        pass
    # Try list comparison (Rail prints [1, 2, 3])
    if actual_clean.replace(" ", "") == expected_clean.replace(" ", ""):
        return True, actual

    return False, f"expected '{expected}', got '{actual}'"


def update_status(msg):
    try:
        subprocess.run(
            [PYTHON, SITE_UPDATE, "focus",
             "--big-picture", "Rail v0.6.0 — stdlib evolution (27B writing Rail's standard library)",
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
        "completed_modules": {},  # module_name -> {code, functions, attempts}
        "failed_functions": {},   # func_name -> [error1, error2, ...]
        "total_functions": 0,
        "total_passed": 0,
    }


def save_state(state):
    Path(STATE_FILE).write_text(json.dumps(state, indent=2))


def main():
    state = load_state()

    print("=" * 60)
    print("Rail Stdlib Evolution")
    print(f"Model: {MODEL}")
    print(f"Modules to build: {len(STDLIB_GOALS)}")
    print(f"Total functions: {sum(len(g['functions']) for g in STDLIB_GOALS)}")
    print(f"Already completed: {len(state['completed_modules'])} modules")
    print("=" * 60)

    while True:
        # Find next module to work on
        target = None
        for goal in STDLIB_GOALS:
            if goal["module"] not in state["completed_modules"]:
                target = goal
                break

        if target is None:
            # All modules done — cycle back and try to improve
            print("\n*** ALL MODULES COMPLETED ***")
            print(f"Total: {len(state['completed_modules'])} modules, "
                  f"{state['total_passed']} functions")

            # List what we built
            for mod_name, mod_info in state["completed_modules"].items():
                funcs = mod_info["functions"]
                print(f"  {mod_name}: {', '.join(funcs)}")

            update_status(
                f"STDLIB COMPLETE: {len(state['completed_modules'])} modules, "
                f"{state['total_passed']} functions — all written by 27B locally"
            )

            # Start hardening — retry failed functions
            if state.get("failed_functions"):
                print(f"\nRetrying {len(state['failed_functions'])} failed functions...")
                time.sleep(60)
                continue
            else:
                print("\nNothing left to do. Exiting.")
                break

        state["cycle"] += 1
        cycle = state["cycle"]

        print(f"\n{'='*60}")
        print(f"CYCLE {cycle}: Building {target['module']}")
        print(f"  {target['description']}")
        print(f"  {len(target['functions'])} functions")
        print(f"{'='*60}")

        # Generate the module
        existing = {
            name: info.get("functions", [])
            for name, info in state["completed_modules"].items()
            if info.get("functions")
        }

        module_code = generate_module(target, existing)
        if module_code is None:
            print("  LLM generation failed, retrying in 30s...")
            time.sleep(30)
            continue

        # Post-process: strip type signatures the model adds despite instructions
        cleaned_lines = []
        for line in module_code.split("\n"):
            stripped = line.strip()
            # Skip lines that look like type sigs: "name : Type -> Type"
            if " : " in stripped and " -> " in stripped and "=" not in stripped and not stripped.startswith("--"):
                continue
            # Skip lines that are just a type signature (name : Type)
            if " : " in stripped and "=" not in stripped and not stripped.startswith("--") and not stripped.startswith("module") and not stripped.startswith("export"):
                continue
            cleaned_lines.append(line)
        module_code = "\n".join(cleaned_lines)

        print(f"\n  Generated {len(module_code.splitlines())} lines")

        # Test each function
        passed_funcs = []
        failed_funcs = []

        for func_name, func_desc, test_spec in target["functions"]:
            # Some test specs have multiple tests separated by comma
            tests = [t.strip() for t in test_spec.split(", ")]
            all_pass = True
            last_error = ""

            for test in tests:
                if " should give " not in test:
                    continue
                success, detail = test_function(module_code, func_name, test)
                state["total_functions"] = state.get("total_functions", 0) + 1

                if success:
                    pass
                else:
                    all_pass = False
                    last_error = detail
                    break

            if all_pass:
                passed_funcs.append(func_name)
                state["total_passed"] = state.get("total_passed", 0) + 1
                print(f"  PASS: {func_name}")
            else:
                failed_funcs.append((func_name, last_error))
                state.setdefault("failed_functions", {})[func_name] = last_error
                print(f"  FAIL: {func_name} -> {last_error[:60]}")

        pass_rate = len(passed_funcs) * 100 // len(target["functions"]) if target["functions"] else 0
        print(f"\n  Module {target['module']}: {len(passed_funcs)}/{len(target['functions'])} ({pass_rate}%)")

        # If >70% pass, accept the module and save it
        if pass_rate >= 70:
            # Save to stdlib directory
            module_file = Path(STDLIB_DIR) / f"{target['module'].lower()}.rail"
            module_file.write_text(module_code)
            print(f"  SAVED: {module_file}")

            state["completed_modules"][target["module"]] = {
                "code_file": str(module_file),
                "functions": passed_funcs,
                "pass_rate": pass_rate,
                "attempts": state.get("completed_modules", {}).get(target["module"], {}).get("attempts", 0) + 1,
            }

            # Remove passed functions from failed list
            for fn in passed_funcs:
                state.get("failed_functions", {}).pop(fn, None)
        else:
            print(f"  REJECTED: {pass_rate}% < 70% threshold, will retry")
            state["completed_modules"].setdefault(target["module"], {})["attempts"] = \
                state.get("completed_modules", {}).get(target["module"], {}).get("attempts", 0) + 1

            # If we've tried too many times, accept what we have and move on
            attempts = state.get("completed_modules", {}).get(target["module"], {}).get("attempts", 0)
            if attempts >= 5:
                print(f"  FORCING after {attempts} attempts")
                module_file = Path(STDLIB_DIR) / f"{target['module'].lower()}.rail"
                module_file.write_text(module_code)
                state["completed_modules"][target["module"]] = {
                    "code_file": str(module_file),
                    "functions": passed_funcs,
                    "pass_rate": pass_rate,
                    "forced": True,
                    "attempts": attempts,
                }

        save_state(state)

        summary = (
            f"Cycle {cycle}: {target['module']} {len(passed_funcs)}/{len(target['functions'])} | "
            f"Modules: {len([m for m in state['completed_modules'] if state['completed_modules'][m].get('functions')])}/{len(STDLIB_GOALS)} | "
            f"Functions: {state['total_passed']}"
        )
        print(f"\n{summary}")
        update_status(summary)

        time.sleep(15)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
