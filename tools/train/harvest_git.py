#!/usr/bin/env python3
"""harvest_git.py — Extract training data from Rail's git history.

For each commit that added/modified .rail files, creates training pairs:
  - Commit message (intent) → file content at that commit (implementation)
  - Variants: "Write a Rail program that...", "Implement in Rail: ...", etc.

Also harvests complete tool source code as "real-world Rail" examples.

Usage: cd ~/projects/rail && /opt/homebrew/bin/python3.11 tools/train/harvest_git.py
Output: training/git_harvest.jsonl
"""

import json
import subprocess
import sys
import os

os.chdir(os.path.expanduser("~/projects/rail"))

SYS_PROMPT = "You are a Rail language expert. Rail is a pure functional language that compiles to native ARM64 and Metal GPU shaders. Write correct Rail code."
SYS_COMPILER = "You are a Rail compiler engineer. Rail is a pure functional language that self-hosts its compiler (compile.rail). Write correct Rail compiler code."

OUTPUT = "training/git_harvest.jsonl"

def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

def entry(sys_msg, user_msg, asst_msg):
    return json.dumps({
        "messages": [
            {"role": "system", "content": sys_msg},
            {"role": "user", "content": user_msg},
            {"role": "assistant", "content": asst_msg},
        ]
    })

def get_file_at_commit(commit, path):
    """Get file content at a specific commit."""
    return run(f"git show {commit}:{path} 2>/dev/null")

def get_commits_touching_rail():
    """Get all commits that touch .rail files, with metadata."""
    log = run('git log --format="%H|%s|%an|%ad" --date=short --diff-filter=AM -- "*.rail"')
    commits = []
    for line in log.split("\n"):
        if not line.strip():
            continue
        parts = line.split("|", 3)
        if len(parts) >= 2:
            commits.append({"hash": parts[0], "subject": parts[1], "author": parts[2] if len(parts) > 2 else "", "date": parts[3] if len(parts) > 3 else ""})
    return commits

def get_changed_rail_files(commit):
    """Get list of .rail files added/modified in a commit."""
    out = run(f'git diff-tree --no-commit-id -r --diff-filter=AM --name-only {commit} -- "*.rail"')
    return [f for f in out.split("\n") if f.strip().endswith(".rail")]

def make_variants(sys_msg, task_desc, code):
    """Single entry per program — with prompt masking, variants are pure waste."""
    return [entry(sys_msg, task_desc, code)]

# Skip these — they're training infrastructure, not Rail programs to teach
SKIP_FILES = {
    "tools/train/build_training_data.rail",
    "tools/train/overfitting_test.rail",  # meta, not real programs
}

# These are high-value real-world Rail programs
TOOL_FILES = {
    "tools/train/self_train.rail": "a self-training loop where Rail trains itself using the compiler as an oracle",
    "tools/apps/brain.rail": "a brain/reasoning module",
    "tools/gpu.rail": "GPU dispatch for Metal compute shaders",
    "tools/apps/llm_call.rail": "an LLM API caller",
    "tools/apps/speak.rail": "a text-to-speech interface",
    "tools/deploy/gen_site.rail": "a static site generator",
    "tools/deploy/cf_deploy.rail": "a Cloudflare Workers deployment tool",
    "tools/apps/dash_serve.rail": "an HTTP dashboard server",
    "tools/apps/http_serve.rail": "an HTTP server",
    "tools/deploy/flash_pi.rail": "a Raspberry Pi flash and deploy tool",
    "tools/apps/config_check.rail": "a service configuration checker",
    "tools/apps/services.rail": "a service status checker",
    "tools/deploy/update_site.rail": "a site data updater",
    "tools/train/train_dashboard.rail": "a training dashboard with live metrics",
}

def harvest_git_commits():
    """Extract training pairs from git commit history."""
    commits = get_commits_touching_rail()
    entries = []
    seen_files = set()  # Deduplicate: only take latest version of each file

    print(f"Found {len(commits)} commits touching .rail files")

    for commit in commits:
        files = get_changed_rail_files(commit["hash"])
        subject = commit["subject"]

        for filepath in files:
            if filepath in SKIP_FILES:
                continue

            # For tool files, use the special description
            if filepath in TOOL_FILES and filepath not in seen_files:
                seen_files.add(filepath)
                code = get_file_at_commit(commit["hash"], filepath)
                if not code or len(code) < 50:
                    continue

                desc = TOOL_FILES[filepath]
                sys_msg = SYS_COMPILER if "compile" in filepath else SYS_PROMPT

                # Full file as "write this tool" training
                entries.extend(make_variants(sys_msg, f"Write a Rail program that implements {desc}", code))
                print(f"  + {filepath} ({len(code)} chars) — tool")
                continue

            # For compiler changes, extract the diff context
            if filepath == "tools/compile.rail":
                code = get_file_at_commit(commit["hash"], filepath)
                if not code or len(code) < 50:
                    continue

                # Don't include full 1700-line compiler for every commit — too big
                # Instead, get just the diff
                diff = run(f"git show {commit['hash']} -- {filepath} | head -200")
                if len(diff) > 200:
                    task = f"Modify the Rail compiler: {subject}"
                    entries.extend(make_variants(SYS_COMPILER, task, diff))
                    print(f"  + compile.rail diff — {subject}")
                continue

            # For regular .rail files — full file at that commit
            if filepath not in seen_files:
                seen_files.add(filepath)
                code = get_file_at_commit(commit["hash"], filepath)
                if not code or len(code) < 30:
                    continue

                # Clean up the subject into a task description
                task = subject.replace("T2: ", "").replace("T1: ", "")
                sys_msg = SYS_PROMPT
                entries.extend(make_variants(sys_msg, f"Write a Rail program: {task}", code))
                print(f"  + {filepath} ({len(code)} chars) — {task}")

    return entries

def harvest_stdlib():
    """Extract stdlib modules as training data."""
    entries = []
    stdlib_dir = "stdlib"
    if not os.path.isdir(stdlib_dir):
        return entries

    for fname in sorted(os.listdir(stdlib_dir)):
        if not fname.endswith(".rail"):
            continue
        path = os.path.join(stdlib_dir, fname)
        code = open(path).read()
        if len(code) < 20:
            continue
        module = fname.replace(".rail", "")
        entries.extend(make_variants(
            SYS_PROMPT,
            f"Write a Rail stdlib module for {module} operations",
            code
        ))
        print(f"  + stdlib/{fname} ({len(code)} chars)")

    return entries

def harvest_test_files():
    """Extract test files as training data — tests are concise, correct Rail."""
    entries = []
    tests_dir = "tests"
    if not os.path.isdir(tests_dir):
        return entries

    for fname in sorted(os.listdir(tests_dir)):
        if not fname.endswith(".rail"):
            continue
        path = os.path.join(tests_dir, fname)
        code = open(path).read()
        if len(code) < 10:
            continue

        # Parse test name into a description
        name = fname.replace(".rail", "").replace("_", " ")
        entries.extend(make_variants(
            SYS_PROMPT,
            f"Write a Rail test program for: {name}",
            code
        ))

    print(f"  + {len(entries)//3} test files")
    return entries

def main():
    print("=== Rail Git History Harvester ===\n")

    all_entries = []

    print("--- Git commits ---")
    all_entries.extend(harvest_git_commits())

    print("\n--- Stdlib modules ---")
    all_entries.extend(harvest_stdlib())

    print("\n--- Test files ---")
    all_entries.extend(harvest_test_files())

    # Write output
    with open(OUTPUT, "w") as f:
        for e in all_entries:
            f.write(e + "\n")

    print(f"\n=== Done: {len(all_entries)} entries written to {OUTPUT} ===")

    # Show stats
    existing_train = sum(1 for _ in open("training/train.jsonl"))
    existing_harvest = sum(1 for _ in open("training/self_train/harvest.jsonl"))
    print(f"\nTraining data inventory:")
    print(f"  Original (build_training_data.rail): {existing_train}")
    print(f"  Self-training harvest:               {existing_harvest}")
    print(f"  Git history harvest (NEW):           {len(all_entries)}")
    print(f"  TOTAL:                               {existing_train + existing_harvest + len(all_entries)}")

if __name__ == "__main__":
    main()
