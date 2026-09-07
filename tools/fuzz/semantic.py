#!/usr/bin/env python3
"""Independent, bounded AST semantics and differential testing for Rail.

No compiler code is imported. See SEMANTICS.md for the deliberately small domain.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import subprocess
import sys
import tempfile

LIMIT = 2**40
FLOAT_MAX = 1e30          # |float results| above this, or subnormal, or non-finite: out of domain
FLOAT_MIN = 1e-30
VERSION = 2
POSITIONS = ("tail", "argument", "let", "comparison")
# Milestone 2 (2026-09-07): floats compared BIT-EXACTLY. Rail prints them with
# show_float_exact (%.17g) and CPython formats the same double with the same
# spec; both are correctly rounded, so the strings agree iff the bits agree.
ALLOW_MIXED = [False]   # int op float; see KNOWN_CASES.md, live until the inference handles it
FLOATS = (0.5, 0.25, 0.125, 0.75, 1.5, 2.0, 3.0, 0.421875, 1024.0, 65536.0,
          0.001953125, 1.0000000000000002, 4503599627370496.0, 0.1, 0.3)


class DomainError(ValueError):
    """Outside the specified subset; never a compiler failure."""


@dataclass
class Closure:
    name: str
    body: list
    env: dict


def integer(value):
    if type(value) is not int or abs(value) > LIMIT:
        raise DomainError("expected bounded integer")
    return value


def number(value):
    """int in [-2^40, 2^40] or a finite, normal-or-zero float with |v| <= FLOAT_MAX."""
    if type(value) is int:
        return integer(value)
    if type(value) is float:
        if value != value or value in (float("inf"), float("-inf")):
            raise DomainError("non-finite float")
        if value != 0.0 and not (FLOAT_MIN <= abs(value) <= FLOAT_MAX):
            raise DomainError("float magnitude out of domain")
        return value
    raise DomainError("expected number")


def same_kind(a, b):
    if type(a) is not type(b):
        raise DomainError("mixed int/float comparison excluded")


def evaluate(tree, env=None, fuel=None):
    env = {} if env is None else env
    fuel = [10000] if fuel is None else fuel
    fuel[0] -= 1
    if fuel[0] < 0:
        raise DomainError("reference fuel exhausted")
    if not isinstance(tree, list) or not tree:
        raise DomainError("invalid AST")
    op, *args = tree
    def ev(child, scope=env):
        return evaluate(child, scope, fuel)
    if op == "int":
        return integer(args[0])
    if op == "float":
        v = args[0]
        if type(v) is not float:
            raise DomainError("float literal must be a float")
        return number(v)
    if op == "fn2":
        # ["fn2", name, [params], body, [args]]: a hoisted top-level function
        # applied to args. Semantics: call-by-value, lexical, no recursion.
        name, params, body, cargs = args
        vals = [ev(a) for a in cargs]
        if len(vals) != len(params):
            raise DomainError("fn2 arity")
        return ev(body, dict(env, **dict(zip(params, vals))))
    if op == "loop":
        # ["loop", name, n, acc, step_op, const]: name n acc = if n == 0 then acc
        # else name (n - 1) (acc STEP const). n must be a small non-negative int.
        name, n_tree, acc_tree, step, ctree = args
        n = integer(ev(n_tree))
        if not 0 <= n <= 12:
            raise DomainError("loop count out of domain")
        acc = number(ev(acc_tree))
        c = number(ev(ctree))
        for _ in range(n):
            acc = arith(step, acc, c)
        return acc
    if op == "var":
        if args[0] not in env:
            raise DomainError("unbound variable")
        return env[args[0]]
    if op == "let":
        name, bound, body = args
        return ev(body, dict(env, **{name: ev(bound)}))
    if op == "fn":
        return Closure(args[0], args[1], dict(env))
    if op == "call":
        fn = ev(args[0])
        arg = ev(args[1])
        if not isinstance(fn, Closure):
            raise DomainError("calling non-function")
        return ev(fn.body, dict(fn.env, **{fn.name: arg}))
    if op in ("iflt", "fiflt"):
        left, right = number(ev(args[0])), number(ev(args[1]))
        same_kind(left, right)
        if op == "fiflt" and type(left) is not float:
            raise DomainError("<. needs floats")
        return ev(args[2] if left < right else args[3])
    if op == "list":
        return [integer(ev(item)) for item in args]
    if op in ("length", "head", "tail"):
        value = ev(args[0])
        if type(value) is not list:
            raise DomainError("expected list")
        if op == "length":
            return len(value)
        if not value:
            raise DomainError("head/tail of empty list excluded")
        return value[0] if op == "head" else value[1:]
    if op in ("add", "sub", "mul", "div", "mod", "fadd", "fsub", "fmul", "fdiv"):
        return arith(op, number(ev(args[0])), number(ev(args[1])))
    raise DomainError(f"unknown node {op}")


def arith(op, a, b):
    """Rail arithmetic: int op int is exact and bounded (div truncates, mod has the
    dividend's sign); anything with a float is IEEE binary64, as in Python. The
    dotted forms require two floats."""
    if op.startswith("f"):
        if type(a) is not float or type(b) is not float:
            raise DomainError("dotted op needs floats")
        op = op[1:]
    if type(a) is int and type(b) is int:
        if op in ("div", "mod"):
            if b == 0:
                raise DomainError("zero divisor excluded")
            q = (abs(a) // abs(b)) * (-1 if (a < 0) != (b < 0) else 1)
            return integer(q if op == "div" else a - q * b)
        return integer({"add": a + b, "sub": a - b, "mul": a * b}[op])
    if op == "mod":
        raise DomainError("float modulo excluded")
    if type(a) is not type(b) and not ALLOW_MIXED[0]:
        raise DomainError("mixed int/float arithmetic excluded (--mixed)")
    a, b = float(a), float(b)
    if op == "div":
        if b == 0.0:
            raise DomainError("zero divisor excluded")
        return number(a / b)
    return number({"add": a + b, "sub": a - b, "mul": a * b}[op])


def float_literal(v):
    text = "%.17g" % abs(v)
    if "." not in text and "e" not in text and "n" not in text:
        text += ".0"
    return text if v >= 0 else f"(0.0 -. {text})"


def kind_of(tree, env=None):
    """Static kind of an expression: 'int', 'float', 'list', 'fn' or 'any' (a bare
    param whose kind depends on the caller). Raises DomainError for shapes Rail
    cannot type: mixed if-branches, dotted ops on non-floats, mixed comparisons.
    Checked on EVERY subtree, taken or not, so a dead branch cannot smuggle an
    ill-typed program past the evaluator (the reducer produced `(0 *. 0)` in a
    branch that was never evaluated)."""
    env = {} if env is None else env
    if not isinstance(tree, list) or not tree:
        raise DomainError("invalid AST")
    op, *a = tree
    if op == "int":
        return "int"
    if op == "float":
        return "float"
    if op == "var":
        return env.get(a[0], "any")
    if op == "let":
        return kind_of(a[2], dict(env, **{a[0]: kind_of(a[1], env)}))
    if op == "fn":
        kind_of(a[1], dict(env, **{a[0]: "any"}))
        return "fn"
    if op == "call":
        kf = kind_of(a[0], env); kind_of(a[1], env)
        if kf not in ("fn", "any"):
            raise DomainError("calling non-function")
        return "any"
    if op == "fn2":
        name, params, body, cargs = a
        ks = [kind_of(x, env) for x in cargs]
        return kind_of(body, dict(env, **dict(zip(params, ks))))
    if op == "loop":
        name, n, acc, step, c = a
        if kind_of(n, env) not in ("int", "any"):
            raise DomainError("loop count must be int")
        return join_kind(step, kind_of(acc, env), kind_of(c, env))
    if op in ("iflt", "fiflt"):
        kl, kr = kind_of(a[0], env), kind_of(a[1], env)
        if "any" not in (kl, kr) and kl != kr:
            raise DomainError("mixed comparison")
        if op == "fiflt" and "int" in (kl, kr):
            raise DomainError("<. on int")
        kt, ke = kind_of(a[2], env), kind_of(a[3], env)
        if kt == ke or "any" in (kt, ke):
            return kt if kt != "any" else ke
        raise DomainError("if branches of different kinds")
    if op == "list":
        for x in a:
            if kind_of(x, env) not in ("int", "any"):
                raise DomainError("list elements must be ints")
        return "list"
    if op in ("length", "head", "tail"):
        if kind_of(a[0], env) not in ("list", "any"):
            raise DomainError("expected list")
        return "int" if op != "tail" else "list"
    if op in ("add", "sub", "mul", "div", "mod", "fadd", "fsub", "fmul", "fdiv"):
        return join_kind(op, kind_of(a[0], env), kind_of(a[1], env))
    raise DomainError(f"unknown node {op}")


def join_kind(op, kl, kr):
    if kl in ("list", "fn") or kr in ("list", "fn"):
        raise DomainError("arithmetic on non-number")
    if op.startswith("f"):
        if "int" in (kl, kr):
            raise DomainError("dotted op on int")
        return "float"
    if op == "mod" and "float" in (kl, kr):
        raise DomainError("float modulo excluded")
    if kl == kr:
        return kl
    if "any" in (kl, kr):
        return kl if kl != "any" else kr
    if not ALLOW_MIXED[0]:
        raise DomainError("mixed int/float arithmetic excluded (--mixed)")
    return "float"


def render(e):
    op, *a = e
    if op == "int":
        return str(a[0]) if a[0] >= 0 else f"(0 - {abs(a[0])})"
    if op == "float":
        return float_literal(a[0])
    if op == "fn2":
        name, params, body, cargs = a
        return "(" + " ".join([name] + [render(x) for x in cargs]) + ")"
    if op == "loop":
        name, n, acc, step, c = a
        return f"({name} {render(n)} {render(acc)})"
    if op == "fiflt":
        return f"(if {render(a[0])} <. {render(a[1])} then {render(a[2])} else {render(a[3])})"
    if op == "var":
        return a[0]
    if op == "let":
        return f"(let {a[0]} = {render(a[1])} in {render(a[2])})"
    if op == "fn":
        return f"(\\{a[0]} -> {render(a[1])})"
    if op == "call":
        return f"({render(a[0])} {render(a[1])})"
    if op == "iflt":
        return f"(if {render(a[0])} < {render(a[1])} then {render(a[2])} else {render(a[3])})"
    if op == "list":
        return "[" + ", ".join(map(render, a)) + "]"
    if op in ("length", "head", "tail"):
        return f"({op} {render(a[0])})"
    symbols = {"add": "+", "sub": "-", "mul": "*", "div": "/", "mod": "%",
               "fadd": "+.", "fsub": "-.", "fmul": "*.", "fdiv": "/."}
    return f"({render(a[0])} {symbols[op]} {render(a[1])})"


def decls(e, acc=None):
    """Top-level function declarations an expression needs (fn2 and loop nodes),
    in first-seen order, deduplicated by name."""
    acc = {} if acc is None else acc
    if not isinstance(e, list) or not e:
        return acc
    op = e[0]
    if op == "fn2":
        name, params, body, cargs = e[1:]
        decls(body, acc)
        for x in cargs:
            decls(x, acc)
        acc.setdefault(name, f"{name} {' '.join(params)} = {render(body)}")
    elif op == "loop":
        name, n, a, step, c = e[1:]
        decls(n, acc); decls(a, acc); decls(c, acc)
        sym = {"add": "+", "sub": "-", "mul": "*", "div": "/", "mod": "%",
               "fadd": "+.", "fsub": "-.", "fmul": "*.", "fdiv": "/."}[step]
        acc.setdefault(name, f"{name} n acc = if n == 0 then acc else {name} (n - 1) (acc {sym} {render(c)})")
    else:
        for x in e[1:]:
            if isinstance(x, list):
                decls(x, acc)
    return acc


def literal_of(value):
    return ["float", value] if type(value) is float else ["int", value]


def source(e, position="argument"):
    expr = render(e)
    value = number(evaluate(e))
    printer = "show_float_exact" if type(value) is float else "show"
    prefix = "-- independent semantic probe v2\n" + "".join(d + "\n" for d in decls(e).values())
    if position == "tail":
        prefix += f"probe ignored = {expr}\n"
        expr = "(probe 0)"
    elif position == "let":
        expr = f"(let result = {expr} in result)"
    elif position == "comparison":
        expr = f"(if {expr} == {render(literal_of(value))} then 1 else 0)"
        printer = "show"
    elif position != "argument":
        raise DomainError("unknown expression position")
    return prefix + "main =\n  let _ = print (" + printer + " " + expr + ")\n  0\n"


def expected_text(value):
    return ("%.17g" % value) if type(value) is float else str(value)


def generate(rng, depth, names=(), floats=True, counter=None):
    """counter: a one-element list threaded through the whole campaign so hoisted
    function names are unique AND deterministic for a seed (a global counter made
    two generators with the same seed disagree)."""
    counter = [0] if counter is None else counter
    def fresh(prefix):
        counter[0] += 1
        return f"{prefix}{counter[0]}"
    if depth <= 0:
        if names and rng.randrange(2):
            return ["var", rng.choice(names)]
        if floats and rng.randrange(3) == 0:
            v = rng.choice(FLOATS)
            return ["float", -v if rng.randrange(4) == 0 else v]
        # Mostly small, sometimes a literal astride the 16-bit tagged-immediate
        # boundary (2N+1 <= 0xFFFF iff N <= 32767), where ARM64 codegen has
        # miscompiled before (t192).
        if rng.randrange(8) == 0:
            return ["int", rng.choice([32767, 32768, -32768, 65535, 65536, 16777216])]
        return ["int", rng.randint(-10, 10)]
    def child(scope=names):
        return generate(rng, depth - 1, scope, floats, counter)
    if floats and rng.randrange(6) == 0:
        kind = rng.randrange(4)
        if kind == 0:      # dotted float arithmetic
            return [rng.choice(["fadd", "fsub", "fmul", "fdiv"]), child(), child()]
        if kind == 1:      # dotted float comparison
            return ["fiflt", child(), child(), child(), child()]
        if kind == 2:      # multi-param user fn, body in bare operators: the thin-inference zone
            k = rng.randint(1, 4)
            params = tuple(f"p{i}" for i in range(k))
            body = generate(rng, depth - 1, params, floats, counter)
            return ["fn2", fresh("f"), list(params), body, [child() for _ in params]]
        step = rng.choice(["add", "sub", "mul", "add", "fadd", "fmul", "fsub"])
        cval = (["float", rng.choice(FLOATS)] if step.startswith("f")
                else ["int", rng.choice([1, 2, 3, 7, 4096, 65536, 100000, -3])])
        acc = ["float", rng.choice(FLOATS)] if step.startswith("f") else child()
        return ["loop", fresh("loop"), ["int", rng.randint(0, 12)], acc, step, cval]
    kind = rng.randrange(10)
    if kind < 3:
        return [["add", "sub", "mul"][kind], child(), child()]
    if kind < 5:
        return [["div", "mod"][kind - 3], child(), ["int", rng.choice([-7, -3, -1, 1, 3, 7])]]
    if kind == 5:
        return ["iflt", child(), child(), child(), child()]
    if kind == 6:
        name = f"x{len(names)}"
        return ["let", name, child(), child(names + (name,))]
    if kind == 7:
        name = f"x{len(names)}"
        return ["call", ["fn", name, child(names + (name,))], child()]
    if kind == 8:
        return ["head", ["list", child(), child()]]
    return ["length", ["tail", ["list", child(), child(), child()]]]


def allowed(tree):
    try:
        kind_of(tree); number(evaluate(tree))
        return True
    except DomainError:
        return False


def controls():
    # Captured x must survive rebinding x at the call site.
    return [
        ["fadd", ["float", 0.1], ["float", 0.2]],
        ["fdiv", ["float", 1.0000000000000002], ["float", 3.0]],
        ["fn2", "mul2c", ["a", "b"], ["mul", ["var", "a"], ["var", "b"]], [["float", 0.5], ["float", 0.25]]],
        ["fn2", "msec", ["y", "t"], ["mul", ["sub", ["var", "y"], ["var", "t"]], ["sub", ["var", "y"], ["var", "t"]]],
            [["fn2", "mul2c", ["a", "b"], ["mul", ["var", "a"], ["var", "b"]], [["float", 0.5], ["float", 0.25]]], ["float", 1.0]]],
        ["loop", "loopc1", ["int", 2], ["int", 1], "mul", ["int", 100000]],
        ["loop", "loopc2", ["int", 10], ["float", 0.1], "fadd", ["float", 0.1]],
        ["add", ["int", 5], ["float", 0.5]],
        ["iflt", ["float", 0.1], ["float", 0.3], ["int", 1], ["int", 0]],
        ["int", 42],
        ["div", ["int", -7], ["int", 3]],
        ["mod", ["int", -7], ["int", 3]],
        ["mod", ["int", 7], ["int", -3]],
        ["let", "x", ["int", 10], ["let", "f", ["fn", "y", ["add", ["var", "x"], ["var", "y"]]],
            ["let", "x", ["int", 90], ["call", ["var", "f"], ["int", 2]]]]],
        ["call", ["call", ["fn", "x", ["fn", "y", ["add", ["var", "x"], ["var", "y"]]]], ["int", 8]], ["int", 3]],
        ["iflt", ["int", 1], ["int", 2], ["int", 7], ["div", ["int", 1], ["int", 0]]],
        ["length", ["list"]],
    ]


@dataclass
class Process:
    code: int | None
    stdout: str
    stderr: str
    timeout: bool = False


def execute(argv, cwd, timeout):
    # Own a process group: a timed-out compiler can have assembler children.
    with subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True) as p:
        try:
            out, err = p.communicate(timeout=timeout)
            return Process(p.returncode, out.decode(errors="replace"), err.decode(errors="replace"))
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            out, err = p.communicate()
            return Process(p.returncode, out.decode(errors="replace"), err.decode(errors="replace"), True)


@dataclass
class Result:
    kind: str
    expected: str
    compile: Process
    run: Process | None = None


class Runner:
    def __init__(self, compiler, repo, timeout=10, position="argument"):
        self.compiler, self.repo, self.timeout = str(compiler), repo, timeout
        if position not in POSITIONS:
            raise DomainError("unknown expression position")
        self.position = position

    def check(self, tree):
        kind_of(tree)
        value = number(evaluate(tree))
        expected = ("1" if self.position == "comparison" else expected_text(value)) + "\n"
        with tempfile.TemporaryDirectory(prefix="rail-semantic-") as scratch:
            src, binary = Path(scratch) / "case.rail", Path(scratch) / "program"
            src.write_text(source(tree, self.position))
            build = execute([self.compiler, "--out-prefix", str(binary), str(src)], self.repo, self.timeout)
            if build.timeout:
                return Result("compile_timeout", expected, build)
            if build.code != 0 or not binary.is_file() or not os.access(binary, os.X_OK):
                return Result("compile_error", expected, build)
            run = execute([str(binary)], self.repo, self.timeout)
            kind = ("runtime_timeout" if run.timeout else "runtime_error" if run.code != 0 else
                    "mismatch" if run.stdout != expected or run.stderr else "pass")
            return Result(kind, expected, build, run)


def size(tree):
    return 1 + sum(size(x) for x in tree[1:] if isinstance(x, list))


def complexity(tree):
    magnitude = abs(tree[1]) if tree[0] in ("int", "float") else 0
    return size(tree), magnitude + sum(complexity(x)[1] for x in tree[1:] if isinstance(x, list))


def candidates(tree):
    """Greedy structural reductions; re-evaluation rejects unbound/ill-typed cases."""
    for n in (0, 1, -1):
        yield ["int", n]
    for i, child in enumerate(tree[1:], 1):
        if isinstance(child, list):
            yield child
            for smaller in candidates(child):
                yield tree[:i] + [smaller] + tree[i + 1:]
    if tree[0] == "list":
        for i in range(1, len(tree)):
            yield tree[:i] + tree[i + 1:]


def minimize(tree, runner, kind, budget):
    current, attempts = tree, 0
    seen = {json.dumps(tree)}
    while attempts < budget:
        changed = False
        for candidate in candidates(current):
            key = json.dumps(candidate)
            if key in seen or complexity(candidate) >= complexity(current):
                continue
            seen.add(key)
            try:
                kind_of(candidate)
                number(evaluate(candidate))
            except (DomainError, TypeError, ValueError, IndexError):
                continue
            attempts += 1
            if runner.check(candidate).kind == kind:
                current, changed = candidate, True
                break
            if attempts >= budget:
                break
        if not changed:
            break
    return current, attempts


def save_failure(output, tree, result, runner, seed, index, budget):
    reduced, attempts = minimize(tree, runner, result.kind, budget)
    final = runner.check(reduced)
    if final.kind != result.kind:
        reduced, final = tree, runner.check(tree)
    destination = output / f"seed-{seed}-case-{index}-{runner.position}"
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "original.rail").write_text(source(tree, runner.position))
    (destination / "minimal.rail").write_text(source(reduced, runner.position))
    (destination / "case.json").write_text(json.dumps({
        "version": VERSION, "seed": seed, "index": index, "original": tree, "tree": reduced,
        "python_version": sys.version,
        "position": runner.position,
        "compiler_sha256": hashlib.sha256(Path(runner.compiler).read_bytes()).hexdigest(),
        "original_result": asdict(result), "result": asdict(final), "reduction_attempts": attempts,
        "stable": final.kind == result.kind,
    }, indent=2) + "\n")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=Path("rail_native"))
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--cases", type=int, default=50)
    parser.add_argument("--depth", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--reduce-steps", type=int, default=50)
    parser.add_argument("--output", type=Path, default=Path("semantic-repros"))
    parser.add_argument("--replay", type=Path, help="re-evaluate and run a saved case.json")
    parser.add_argument("--keep-going", action="store_true", help="save every failure and finish the campaign")
    parser.add_argument("--no-floats", action="store_true", help="milestone-1 integer grammar only")
    parser.add_argument("--mixed", action="store_true", help="include int-op-float arithmetic (live compiler defects, see KNOWN_CASES.md)")
    args = parser.parse_args()
    if args.cases < 0 or not 0 <= args.depth <= 5 or args.timeout <= 0 or args.reduce_steps < 0:
        parser.error("cases/reduce-steps >= 0, depth 0..5, timeout > 0 required")
    runner = Runner(args.compiler.resolve(), args.repo.resolve(), args.timeout)
    if args.replay:
        record = json.loads(args.replay.read_text())
        if record["version"] != VERSION:
            parser.error("unsupported case version")
        runner = Runner(args.compiler.resolve(), args.repo.resolve(), args.timeout,
                        record.get("position", "argument"))
        result = runner.check(record["tree"])
        print(json.dumps(asdict(result), indent=2))
        return 0 if result.kind == "pass" else 1
    rng = random.Random(args.seed)
    counter = [0]
    ALLOW_MIXED[0] = args.mixed
    trees = [t for t in controls() if allowed(t)]
    n_controls = len(trees)
    rejected = 0
    while len(trees) < n_controls + args.cases:
        tree = generate(rng, args.depth, (), not args.no_floats, counter)
        try:
            kind_of(tree)
            number(evaluate(tree))
        except DomainError:
            rejected += 1
            if rejected > 1000:
                raise DomainError("generator exceeded rejection budget")
            continue
        trees.append(tree)
    failures = 0
    for index, tree in enumerate(trees):
        for position in POSITIONS:
            runner = Runner(args.compiler.resolve(), args.repo.resolve(), args.timeout, position)
            result = runner.check(tree)
            if result.kind != "pass":
                failures += 1
                path = save_failure(args.output, tree, result, runner, args.seed, index, args.reduce_steps)
                print(f"FAIL {result.kind}: {path} (seed={args.seed}, index={index}, position={position})", flush=True)
                if not args.keep_going:
                    return 1
    total = len(trees) * len(POSITIONS)
    print(f"{'FAIL' if failures else 'PASS'} {total - failures}/{total} comparisons, {failures} failures "
          f"({args.cases} generated, {n_controls} controls, {len(POSITIONS)} positions; "
          f"seed={args.seed}, out-of-domain={rejected})")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
