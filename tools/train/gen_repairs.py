#!/usr/bin/env python3
"""gen_repairs.py — Generate synthetic repair training data.

Takes known-good Rail programs, systematically introduces common model errors,
compiles to get real compiler error messages, pairs (broken + error → fixed).

This is "synthetic corruption" — we know the fix because we started with working code.

Usage:
  python3 gen_repairs.py                          # default: all mutations
  python3 gen_repairs.py --source cloud           # only cloud-harvested examples
  python3 gen_repairs.py --mutations 3            # max mutations per example
"""

import argparse, json, os, random, subprocess, sys

RAIL_DIR = os.path.expanduser("~/projects/rail")
RAIL_BIN = os.path.join(RAIL_DIR, "rail_native")
OUTPUT = os.path.join(RAIL_DIR, "training/self_train/synthetic_repairs.jsonl")

REPAIR_SYSTEM = "You are a Rail language expert that fixes compiler errors in Rail code."

# Common model mistakes — based on what LLMs actually generate wrong for Rail
MUTATIONS = {
    "add_let_in": {
        "desc": "Add 'in' after let binding (OCaml/Haskell habit)",
        "fn": lambda code: code.replace("\n  let ", "\n  let ", 1).replace(
            "\n  let ", "\n  let ", 1) if "\n  let " in code else None,
        "apply": lambda code: apply_let_in_mutation(code),
    },
    "add_fn_keyword": {
        "desc": "Add 'fn' before function def (Rust habit)",
        "apply": lambda code: apply_fn_keyword(code),
    },
    "match_with": {
        "desc": "Use 'match...with' instead of 'match...| pat ->'",
        "apply": lambda code: apply_match_with(code),
    },
    "cons_operator": {
        "desc": "Use :: instead of cons (OCaml habit)",
        "apply": lambda code: apply_cons_operator(code),
    },
    "string_index": {
        "desc": "Try to index a string with s[0] (Python/JS habit)",
        "apply": lambda code: apply_string_index(code),
    },
    "missing_else": {
        "desc": "Remove else branch from if-then-else",
        "apply": lambda code: apply_missing_else(code),
    },
    "let_rec": {
        "desc": "Add 'rec' after let for recursive function (OCaml habit)",
        "apply": lambda code: apply_let_rec(code),
    },
    "wrong_lambda": {
        "desc": "Use 'fun x ->' instead of '\\x ->' (OCaml lambda syntax)",
        "apply": lambda code: apply_wrong_lambda(code),
    },
    "semicolons": {
        "desc": "Add semicolons at end of statements (C/Rust/JS habit)",
        "apply": lambda code: apply_semicolons(code),
    },
    "type_annotation_colon": {
        "desc": "Use 'x: int' instead of 'x' in function params",
        "apply": lambda code: apply_type_colon(code),
    },
    "return_keyword": {
        "desc": "Add 'return' before last expression (imperative habit)",
        "apply": lambda code: apply_return_keyword(code),
    },
    "multi_char_split": {
        "desc": "Use multi-char split separator (Rail split is single-char only)",
        "apply": lambda code: apply_multi_char_split(code),
    },
    "where_clause": {
        "desc": "Add 'where' clause (Haskell habit)",
        "apply": lambda code: apply_where_clause(code),
    },
    "list_brackets": {
        "desc": "Use [x] pattern match instead of cons/head/tail",
        "apply": lambda code: apply_list_brackets(code),
    },
    "do_notation": {
        "desc": "Use 'do' block (Haskell habit)",
        "apply": lambda code: apply_do_notation(code),
    },
}


# --- Mutation functions ---

def apply_let_in_mutation(code):
    """Add 'in' after a let binding."""
    lines = code.split("\n")
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("let ") and "=" in stripped and i + 1 < len(lines):
            indent = line[:len(line) - len(stripped)]
            lines[i] = line + " in"
            return "\n".join(lines)
    return None


def apply_fn_keyword(code):
    """Add 'fn' before a top-level function definition."""
    lines = code.split("\n")
    for i, line in enumerate(lines):
        stripped = line.strip()
        if (not stripped.startswith("--") and not stripped.startswith("let ")
            and not stripped.startswith("type ") and not stripped.startswith("import ")
            and not stripped.startswith("main") and "=" in stripped
            and not stripped.startswith("|") and not stripped.startswith("fn ")
            and stripped and stripped[0].isalpha()):
            lines[i] = "fn " + line
            return "\n".join(lines)
    return None


def apply_match_with(code):
    """Replace 'match expr' with 'match expr with'."""
    if "match " not in code:
        return None
    lines = code.split("\n")
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("match ") and "with" not in stripped:
            lines[i] = line + " with"
            return "\n".join(lines)
    return None


def apply_cons_operator(code):
    """Replace 'cons x xs' with 'x :: xs'."""
    if "cons " not in code:
        return None
    import re
    new = re.sub(r'cons (\w+) (\w+)', r'\1 :: \2', code, count=1)
    return new if new != code else None


def apply_string_index(code):
    """Add a string indexing operation."""
    if '"' not in code:
        return None
    lines = code.split("\n")
    for i, line in enumerate(lines):
        if 'let ' in line and '= "' in line:
            var = line.split("let ")[1].split("=")[0].strip()
            lines.insert(i + 1, f"  let first_char = {var}[0]")
            return "\n".join(lines)
    return None


def apply_missing_else(code):
    """Remove an else branch."""
    if " else " not in code:
        return None
    lines = code.split("\n")
    for i, line in enumerate(lines):
        if " else " in line and "if " in line:
            idx = line.index(" else ")
            lines[i] = line[:idx]
            return "\n".join(lines)
    return None


def apply_let_rec(code):
    """Add 'rec' keyword to a recursive function."""
    lines = code.split("\n")
    for i, line in enumerate(lines):
        stripped = line.strip()
        if (stripped and stripped[0].isalpha() and "=" in stripped
            and not stripped.startswith("let ") and not stripped.startswith("main")
            and not stripped.startswith("type ") and not stripped.startswith("--")
            and not stripped.startswith("import ")):
            fname = stripped.split()[0]
            # Check if function is actually recursive
            if fname in code.split("=", 1)[1] if "=" in code else "":
                lines[i] = "let rec " + line.lstrip()
                return "\n".join(lines)
    return None


def apply_wrong_lambda(code):
    """Replace \\x -> with fun x ->."""
    if "\\" not in code or "->" not in code:
        return None
    import re
    new = re.sub(r'\\(\w+)\s*->', r'fun \1 ->', code, count=1)
    return new if new != code else None


def apply_semicolons(code):
    """Add semicolons at end of statements."""
    lines = code.split("\n")
    modified = False
    for i, line in enumerate(lines):
        stripped = line.rstrip()
        if (stripped and not stripped.startswith("--") and not stripped.endswith(",")
            and not stripped.endswith("[") and not stripped.endswith("=")
            and not stripped.endswith("then") and not stripped.endswith("else")
            and not stripped.endswith(";")):
            if any(kw in stripped for kw in ["let ", "print ", "= ", "in "]):
                lines[i] = stripped + ";"
                modified = True
                break
    return "\n".join(lines) if modified else None


def apply_type_colon(code):
    """Add type annotations to function params."""
    lines = code.split("\n")
    for i, line in enumerate(lines):
        stripped = line.strip()
        if (stripped and stripped[0].isalpha() and " = " in stripped
            and not stripped.startswith("let ") and not stripped.startswith("type ")
            and not stripped.startswith("main") and not stripped.startswith("--")):
            parts = stripped.split(" = ", 1)
            tokens = parts[0].split()
            if len(tokens) >= 2:
                name = tokens[0]
                params = tokens[1:]
                typed_params = [f"({p}: int)" for p in params]
                lines[i] = f"{name} {' '.join(typed_params)} = {parts[1]}"
                return "\n".join(lines)
    return None


def apply_return_keyword(code):
    """Add 'return' before the last expression in main."""
    lines = code.split("\n")
    for i in range(len(lines) - 1, -1, -1):
        stripped = lines[i].strip()
        if stripped and not stripped.startswith("--") and not stripped.startswith("let "):
            if stripped.isdigit() or stripped.startswith("print") or stripped[0].isalpha():
                indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
                lines[i] = indent + "return " + stripped
                return "\n".join(lines)
    return None


def apply_multi_char_split(code):
    """Replace single-char split with multi-char."""
    if 'split "' not in code:
        return None
    import re
    new = re.sub(r'split "(.)"', r'split "\1\1"', code, count=1)
    return new if new != code else None


def apply_where_clause(code):
    """Add a where clause to a function."""
    lines = code.split("\n")
    for i, line in enumerate(lines):
        stripped = line.strip()
        if (stripped and stripped[0].isalpha() and "=" in stripped
            and not stripped.startswith("let ") and not stripped.startswith("type ")
            and not stripped.startswith("--") and not stripped.startswith("import ")):
            parts = stripped.split("=", 1)
            if len(parts) == 2 and parts[1].strip():
                body = parts[1].strip()
                lines[i] = f"{parts[0]}= result\n  where result = {body}"
                return "\n".join(lines)
    return None


def apply_do_notation(code):
    """Wrap main body in do block."""
    if "main =" not in code and "main=" not in code:
        return None
    lines = code.split("\n")
    for i, line in enumerate(lines):
        if line.strip().startswith("main"):
            lines[i] = line.replace("main =", "main = do").replace("main=", "main = do")
            return "\n".join(lines)
    return None


def apply_list_brackets(code):
    """Replace head/tail with pattern match [x]."""
    if "head " not in code:
        return None
    import re
    # Replace 'head xs' with 'xs[0]'
    new = re.sub(r'head (\w+)', r'\1[0]', code, count=1)
    return new if new != code else None


def verify_rail(code):
    """Compile Rail code. Returns (success, error_msg)."""
    test_file = "/tmp/rail_repair_test.rail"
    bin_file = "/tmp/rail_repair_bin"

    with open(test_file, "w") as f:
        f.write(code)

    subprocess.run(["rm", "-f", bin_file], capture_output=True)
    try:
        result = subprocess.run(
            [RAIL_BIN, test_file],
            capture_output=True, text=True, timeout=10, cwd=RAIL_DIR
        )
    except subprocess.TimeoutExpired:
        return False, "compile timeout"
    subprocess.run(["cp", "/tmp/rail_out", bin_file], capture_output=True)

    if not os.path.exists(bin_file):
        return False, (result.stdout + result.stderr).strip()

    try:
        run = subprocess.run([bin_file], capture_output=True, text=True, timeout=5)
        return run.returncode == 0, ""
    except subprocess.TimeoutExpired:
        return False, "timeout"


def make_repair_entry(broken_code, error_msg, fixed_code):
    """Create JSONL repair training entry."""
    user_msg = f"Fix this Rail code:\n\n{broken_code}\n\nCompiler error:\n{error_msg}"
    return json.dumps({
        "messages": [
            {"role": "system", "content": REPAIR_SYSTEM},
            {"role": "user", "content": user_msg},
            {"role": "assistant", "content": fixed_code},
        ]
    }, ensure_ascii=False)


def load_good_examples():
    """Load all known-good Rail code from harvest files."""
    examples = []
    files = [
        os.path.join(RAIL_DIR, "training/self_train/cloud_harvest.jsonl"),
        os.path.join(RAIL_DIR, "training/self_train/harvest.jsonl"),
        os.path.join(RAIL_DIR, "training/handcrafted_l2_l5.jsonl"),
    ]
    for path in files:
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    code = d["messages"][-1]["content"]
                    task = d["messages"][1]["content"]
                    if len(code) > 30 and "main" in code:
                        examples.append((task, code))
                except (json.JSONDecodeError, KeyError, IndexError):
                    continue
    return examples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mutations", type=int, default=2, help="Max mutations per example")
    parser.add_argument("--limit", type=int, default=0, help="Max examples to process (0=all)")
    args = parser.parse_args()

    examples = load_good_examples()
    random.shuffle(examples)
    if args.limit:
        examples = examples[:args.limit]

    print(f"=== SYNTHETIC REPAIR GENERATOR ===")
    print(f"  Good examples: {len(examples)}")
    print(f"  Mutation types: {len(MUTATIONS)}")
    print(f"  Output: {OUTPUT}")

    total = 0
    success = 0
    failed_verify = 0
    no_mutation = 0

    mutation_names = list(MUTATIONS.keys())

    with open(OUTPUT, "a") as out_f:
        for idx, (task, good_code) in enumerate(examples):
            # First verify the "good" code actually compiles
            ok, _ = verify_rail(good_code)
            if not ok:
                failed_verify += 1
                continue

            # Try each mutation
            random.shuffle(mutation_names)
            applied = 0

            for mut_name in mutation_names:
                if applied >= args.mutations:
                    break

                mut = MUTATIONS[mut_name]
                broken = mut["apply"](good_code)
                if broken is None or broken == good_code:
                    continue

                # Verify broken code actually fails
                broke_ok, error = verify_rail(broken)
                if broke_ok:
                    # Mutation didn't break it — skip
                    continue
                if not error or error == "timeout":
                    continue

                # We have: broken code + real compiler error + known fix
                entry = make_repair_entry(broken, error[:500], good_code)
                out_f.write(entry + "\n")
                applied += 1
                success += 1

                if (success % 25) == 0:
                    print(f"  [{success}] {mut_name}: {task[:50]}...")

            total += 1
            if applied == 0:
                no_mutation += 1

    print(f"\n=== DONE ===")
    print(f"  Processed: {total}")
    print(f"  Repairs generated: {success}")
    print(f"  Failed initial verify: {failed_verify}")
    print(f"  No applicable mutations: {no_mutation}")
    # Count total file
    if os.path.exists(OUTPUT):
        with open(OUTPUT) as f:
            count = sum(1 for _ in f)
        print(f"  Total in file: {count}")


if __name__ == "__main__":
    main()
