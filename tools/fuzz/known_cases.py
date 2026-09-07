#!/usr/bin/env python3
"""Run the known-miscompile corpus in tools/fuzz/known/ against a compiler.

Each case is a .rail program plus an entry in cases.json with a status:
  fixed      a miscompile that was fixed; it must pass (regression).
  live       a defect still present; it is expected to FAIL today, and the
             runner reports loudly when one starts passing so its status is
             promoted instead of the pass going unnoticed.
  semantics  defined behaviour that surprises people; must pass, and an
             independent oracle must MODEL it rather than flag it.

Exit 0 iff every fixed/semantics case passes and every live case still fails.
Usage: python3 tools/fuzz/known_cases.py [--compiler PATH] [--only NAME]
"""
import argparse, json, os, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
KNOWN = HERE / "known"


def run(argv, cwd, timeout):
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", "", ""


def observe(compiler, repo, src, timeout):
    with tempfile.TemporaryDirectory(prefix="rail-known-") as d:
        binary = Path(d) / "program"
        rc, out, err = run([compiler, "--out-prefix", str(binary), str(src)], repo, timeout)
        if rc == "timeout":
            return "compile timeout"
        errs = [l.strip() for l in (out + err).splitlines() if "error" in l.lower()]
        if rc != 0 or errs or not binary.is_file():
            return "compile error: " + (errs[0][:100] if errs else f"exit {rc}")
        rc, out, err = run([str(binary)], repo, timeout)
        if rc == "timeout":
            return "runtime timeout"
        if rc != 0:
            return f"exit {rc}: {out.strip()}"
        return out.rstrip("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compiler", default=str(HERE.parent.parent / "rail_native"))
    ap.add_argument("--only")
    ap.add_argument("--timeout", type=float, default=30)
    a = ap.parse_args()
    repo = str(HERE.parent.parent)
    cases = json.load(open(KNOWN / "cases.json"))
    bad = 0
    for name, (status, expected, note) in cases.items():
        if a.only and name != a.only:
            continue
        got = observe(a.compiler, repo, KNOWN / f"{name}.rail", a.timeout)
        passed = got == expected
        if status == "live":
            if passed:
                bad += 1
                print(f"  PROMOTE  {name}: live case now PASSES; set its status to fixed and say what fixed it")
            else:
                print(f"  live     {name}: still fails ({got.splitlines()[0][:60] if got else 'no output'})")
        elif passed:
            print(f"  ok       {name}")
        else:
            bad += 1
            print(f"  NO       {name} [{status}]: expected {expected!r}, got {got!r}\n           {note}")
    print(f"{'ok' if bad == 0 else 'NO'}: {len(cases)} cases, {bad} unexpected")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
