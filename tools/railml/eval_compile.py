#!/usr/bin/env python3
"""Evaluate a rustane checkpoint by compile_pct.
Generates N Rail programs, runs each through ./rail_native, reports pass rate."""
import os, sys, subprocess, tempfile, argparse

GENERATE = "/Users/ledaticempire/rustane/target/release/generate"
TOKENIZER = "/Users/ledaticempire/projects/rail/training/tokenizer.json"
RAIL_NATIVE = "/Users/ledaticempire/projects/rail/rail_native"

# Common Rail seed prompts — short, complete-able
SEEDS = [
    "main = ",
    "main =\n  ",
    "add a b = ",
    "double x = ",
    "type Option = ",
    "fact n = if n",
    "main = let x = ",
    "main = print ",
    "fib n = if n",
    "main =\n  let x = 1\n  ",
    "len xs = match xs",
    "main = let _ = print ",
    "sum xs = fold ",
    "main =\n  let xs = [1,2,3]\n  ",
    "f x = x + ",
]

def load_tokenizer(path):
    """Load HF tokenizer.json — return encode/decode using token strings.
    BPE without GPT-2 byte-level encoding (rail_tokenizer is plain BPE)."""
    from tokenizers import Tokenizer
    return Tokenizer.from_file(path)

def generate(ckpt, prompt_tokens, n, temp, seed, real_vocab):
    inp = " ".join(str(t) for t in prompt_tokens)
    proc = subprocess.run(
        [GENERATE, "--ckpt", ckpt, "--n", str(n), "--temp", str(temp),
         "--seed", str(seed), "--real-vocab", str(real_vocab)],
        input=inp, capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        print(f"  generate failed: {proc.stderr}", file=sys.stderr)
        return []
    return [int(t) for t in proc.stdout.strip().split()]

def try_compile(rail_src):
    """Run rail_native on the source. Return (ok, error_or_empty)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".rail", delete=False) as f:
        f.write(rail_src)
        path = f.name
    try:
        proc = subprocess.run(
            [RAIL_NATIVE, path],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode == 0:
            return True, ""
        return False, (proc.stderr or proc.stdout).strip()[:200]
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    finally:
        os.unlink(path)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--n-tokens", type=int, default=120)
    ap.add_argument("--n-samples", type=int, default=30, help="how many programs to generate (cycles through seeds)")
    ap.add_argument("--temp", type=float, default=0.8)
    ap.add_argument("--real-vocab", type=int, default=4096)
    ap.add_argument("--save-dir", default="")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    print(f"=== Eval {os.path.basename(args.ckpt)} ===")
    print(f"  n_samples={args.n_samples}, n_tokens={args.n_tokens}, temp={args.temp}")
    tok = load_tokenizer(TOKENIZER)
    print(f"  vocab: {tok.get_vocab_size()}")

    if args.save_dir:
        os.makedirs(args.save_dir, exist_ok=True)

    passes = 0
    fails = 0
    failure_samples = []
    pass_samples = []

    for i in range(args.n_samples):
        seed_prompt = SEEDS[i % len(SEEDS)]
        prompt_ids = tok.encode(seed_prompt).ids
        gen_ids = generate(args.ckpt, prompt_ids, args.n_tokens,
                           args.temp, seed=42 + i, real_vocab=args.real_vocab)
        if not gen_ids:
            fails += 1
            continue
        full_ids = prompt_ids + gen_ids
        try:
            text = tok.decode(full_ids)
        except Exception as e:
            text = f"<<decode error: {e}>>"
        ok, err = try_compile(text)
        marker = "PASS" if ok else "FAIL"
        if args.verbose:
            print(f"\n[{i+1:02d}] {marker}  seed={seed_prompt!r}")
            print("    " + text.replace("\n", "\n    ")[:300])
            if not ok:
                print(f"    err: {err[:120]}")
        if ok:
            passes += 1
            if len(pass_samples) < 5:
                pass_samples.append((seed_prompt, text))
        else:
            fails += 1
            if len(failure_samples) < 3:
                failure_samples.append((seed_prompt, text, err))
        if args.save_dir:
            tag = "pass" if ok else "fail"
            with open(os.path.join(args.save_dir, f"{tag}_{i:03d}.rail"), "w") as f:
                f.write(text)

    total = passes + fails
    print(f"\n=== RESULT ===")
    print(f"  passes: {passes}/{total} = {100*passes/total:.1f}%")
    if pass_samples:
        print(f"\n--- PASS samples ---")
        for s, t in pass_samples[:3]:
            print(f"  seed: {s!r}")
            print("    " + t.replace("\n", "\n    ")[:200])
            print()
    if failure_samples:
        print(f"--- FAIL samples ---")
        for s, t, e in failure_samples[:3]:
            print(f"  seed: {s!r}")
            print("    " + t.replace("\n", "\n    ")[:200])
            print(f"    err: {e[:120]}")
            print()

if __name__ == "__main__":
    main()
