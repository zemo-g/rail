#!/usr/bin/env python3
"""tools/independence/ddc_int.py -- INDEPENDENT (non-Rail) reference checker.

This is, by design, the ONE non-Rail component in the repo. docs/INDEPENDENCE.md
explains why: a Rail compiler verifying a Rail compiler cannot defeat a
trusting-trust attack, so the independent check MUST be written in a different
language. This is the Option-A prototype: an independent Python evaluator for a
frozen Rail-core integer subset, run differentially against rail_native.

For each generated program we:
  1. build a random AST (Python),
  2. pretty-print it to Rail source and compile+run it with rail_native,
  3. evaluate the SAME AST with this Python evaluator,
  4. diff the two results.

If rail_native were trojaned to miscompile any program here, it would diverge
from this evaluator -- which the trojan cannot reach. Agreement is independent
corroboration; it is not a proof of correctness, and coverage is exactly this
subset.

Frozen subset (chosen so Python int and Rail 63-bit int provably coincide --
literals are bounded so neither side overflows):
    E ::= int[-7..7] | var | (E + E) | (E - E) | (E * E)
        | (let x = E in E) | (if E < E then E else E)

No /, %, or floats yet: those need their semantics (signed division, signed
zero) pinned before an independent oracle can match them. See INDEPENDENCE.md.

Usage:  python3 tools/independence/ddc_int.py [--seed N] [--n N]
Exit 0 = all agree, 2 = at least one divergence.
"""
import os, random, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAIL = os.path.join(REPO, "rail_native")
OUTPREFIX = f"/tmp/ddc_{os.getpid()}"   # isolated compile output: never the shared /tmp/rail_out
LITLO, LITHI, DEPTH = -7, 7, 4          # bounded so 7**16 << 2**62 -> no overflow either side
NAMES = ["a", "b", "c", "d", "e"]

def gen(rng, depth, vars):
    if depth <= 0 or rng.random() < 0.35:
        if vars and rng.random() < 0.5:
            return ("var", rng.choice(vars))
        return ("lit", rng.randint(LITLO, LITHI))
    k = rng.randint(0, 5)
    if k == 0: return ("add", gen(rng, depth-1, vars), gen(rng, depth-1, vars))
    if k == 1: return ("sub", gen(rng, depth-1, vars), gen(rng, depth-1, vars))
    if k == 2: return ("mul", gen(rng, depth-1, vars), gen(rng, depth-1, vars))
    if k == 3:
        nm = rng.choice(NAMES)
        return ("let", nm, gen(rng, depth-1, vars), gen(rng, depth-1, vars + [nm]))
    if k == 4:
        return ("if", gen(rng, depth-1, vars), gen(rng, depth-1, vars),
                gen(rng, depth-1, vars), gen(rng, depth-1, vars))
    return ("add", gen(rng, depth-1, vars), gen(rng, depth-1, vars))

def pp(a):
    t = a[0]
    if t == "lit": return f"({a[1]})" if a[1] < 0 else str(a[1])
    if t == "var": return a[1]
    if t == "add": return f"({pp(a[1])} + {pp(a[2])})"
    if t == "sub": return f"({pp(a[1])} - {pp(a[2])})"
    if t == "mul": return f"({pp(a[1])} * {pp(a[2])})"
    if t == "let": return f"(let {a[1]} = {pp(a[2])} in {pp(a[3])})"
    return f"(if {pp(a[1])} < {pp(a[2])} then {pp(a[3])} else {pp(a[4])})"

def ev(a, env):
    t = a[0]
    if t == "lit": return a[1]
    if t == "var": return env.get(a[1], 0)
    if t == "add": return ev(a[1], env) + ev(a[2], env)
    if t == "sub": return ev(a[1], env) - ev(a[2], env)
    if t == "mul": return ev(a[1], env) * ev(a[2], env)
    if t == "let":
        e2 = dict(env); e2[a[1]] = ev(a[2], env); return ev(a[3], e2)
    return ev(a[3], env) if ev(a[1], env) < ev(a[2], env) else ev(a[4], env)

NOISE = ("Compiling", "as:", "ld:", "[tgl", "[rail-link", "wrote ", "Binary")
def rail_run(src):
    txt = f"main =\n  let _ = print (show {src})\n  0\n"
    env = dict(os.environ); env["RAIL_ARENA_MB"] = "4096"
    # Compile through an isolated --out-prefix (NOT the shared /tmp/rail_out), so a
    # concurrent rail_native process cannot make us execute *its* binary. Belt and
    # suspenders: our programs only ever print one integer, so a captured line that
    # is not an int is a collision artifact (or env noise), not a codegen result --
    # reject and retry.
    rc, last = -1, ""
    for _ in range(4):
        with tempfile.NamedTemporaryFile("w", suffix=".rail", delete=False, dir="/tmp") as f:
            f.write(txt); path = f.name
        try:
            r = subprocess.run([RAIL, "--out-prefix", OUTPREFIX, "run", path],
                               capture_output=True, text=True, env=env, timeout=30)
        finally:
            os.unlink(path)
        rc = r.returncode
        keep = [l.strip() for l in r.stdout.splitlines()
                if l.strip() and not l.strip().startswith(NOISE)]
        if keep:
            last = keep[-1]
            if last.lstrip("-").isdigit():
                return last
    return last if last else f"<no-output ec={rc}>"

def opt(flag, default):
    return int(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else default

def main():
    seed, n = opt("--seed", 1), opt("--n", 100)
    rng = random.Random(seed)
    print(f"ddc_int  independent Python oracle  seed={seed}  n={n}")
    agree = diverge = 0
    for i in range(n):
        a = gen(rng, DEPTH, [])
        expect, got = str(ev(a, {})), rail_run(pp(a))
        if got == expect:
            agree += 1
        else:
            diverge += 1
            print(f"[{i}] DIVERGE  rail={got}  python={expect}\n     src: {pp(a)}")
    print(f"results: {agree} agree / {diverge} DIVERGENCE / {n} total  "
          f"(rail_native vs independent non-Rail evaluator)")
    sys.exit(2 if diverge else 0)

if __name__ == "__main__":
    main()
