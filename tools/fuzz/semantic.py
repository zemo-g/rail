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
VERSION = 1
POSITIONS = ("tail", "argument", "let", "comparison")


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
    if op == "iflt":
        left, right = integer(ev(args[0])), integer(ev(args[1]))
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
    if op in ("add", "sub", "mul", "div", "mod"):
        a, b = integer(ev(args[0])), integer(ev(args[1]))
        if op in ("div", "mod"):
            if b == 0:
                raise DomainError("zero divisor excluded")
            q = (abs(a) // abs(b)) * (-1 if (a < 0) != (b < 0) else 1)
            return integer(q if op == "div" else a - q * b)
        return integer({"add": lambda: a + b, "sub": lambda: a - b,
                        "mul": lambda: a * b}[op]())
    raise DomainError(f"unknown node {op}")


def render(e):
    op, *a = e
    if op == "int":
        return str(a[0]) if a[0] >= 0 else f"(0 - {abs(a[0])})"
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
    symbols = {"add": "+", "sub": "-", "mul": "*", "div": "/", "mod": "%"}
    return f"({render(a[0])} {symbols[op]} {render(a[1])})"


def source(e, position="argument"):
    expr = render(e)
    prefix = "-- independent semantic probe v1\n"
    if position == "tail":
        prefix += f"probe ignored = {expr}\n"
        expr = "(probe 0)"
    elif position == "let":
        expr = f"(let result = {expr} in result)"
    elif position == "comparison":
        expected = render(["int", integer(evaluate(e))])
        expr = f"(if {expr} == {expected} then 1 else 0)"
    elif position != "argument":
        raise DomainError("unknown expression position")
    return prefix + "main =\n  let _ = print (show " + expr + ")\n  0\n"


def generate(rng, depth, names=()):
    if depth <= 0:
        if names and rng.randrange(2):
            return ["var", rng.choice(names)]
        # Mostly small, sometimes a literal astride the 16-bit tagged-immediate
        # boundary (2N+1 <= 0xFFFF iff N <= 32767), where ARM64 codegen has
        # miscompiled before (t192).
        if rng.randrange(8) == 0:
            return ["int", rng.choice([32767, 32768, -32768, 65535, 65536, 16777216])]
        return ["int", rng.randint(-10, 10)]
    def child(scope=names):
        return generate(rng, depth - 1, scope)
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


def controls():
    # Captured x must survive rebinding x at the call site.
    return [
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
        value = integer(evaluate(tree))
        expected = str(1 if self.position == "comparison" else value) + "\n"
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
    magnitude = abs(tree[1]) if tree[0] == "int" else 0
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
                integer(evaluate(candidate))
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
    trees = controls()
    rejected = 0
    while len(trees) < len(controls()) + args.cases:
        tree = generate(rng, args.depth)
        try:
            integer(evaluate(tree))
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
          f"({args.cases} generated, {len(controls())} controls, {len(POSITIONS)} positions; "
          f"seed={args.seed}, out-of-domain={rejected})")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
