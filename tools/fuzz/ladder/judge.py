"""The night ladder's judge: one rung's check program, then the whole suite. Exit 0 iff both hold.

A rung is a pointed task for the night worker (DeepSeek V4.1 through the clerk's letters door), and
this is the code that says whether it was done: never the model's own claim. `python3
tools/fuzz/ladder/judge.py C` first REBUILDS the compiler from the worktree's source when the rung
edits the compiler (B and C: `RAIL_ARENA_MB=6000 ./rail_native self`, the seed compiling the edited
tools/compile.rail into a gen-1 binary; the first two ladder nights judged compiler rungs with the
seed binary, which no edit can change, so those rungs could never pass), then compiles and runs the
rung's check program with the right binary and its own --out-prefix (never racing /tmp/rail_out),
compares what it printed with `<rung>.expected` line for line, bounds its wall clock and, for rung A,
its resident memory (the O(N^2) bytes_to_str it replaces took 5.8 GB for 100 KB on 2026-09-20; a
trivial program takes 120 MB), then runs `<binary> test` and requires every test to pass and the
count not to shrink.

Rungs, 2026-09-20:
  A  stdlib/http_client.rail bytes_to_str made linear        check tools/fuzz/ladder/A.rail        seed binary
  B  the live miscompile mixed_int_from_fn (float inference) check tools/fuzz/known/mixed_int_from_fn.rail  rebuilt
  C  "\\r" as an escape in string literals (lexer)             check tools/fuzz/ladder/C.rail        rebuilt
"""

import os
import re
import resource
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))  # tools/fuzz/ladder -> the tree
BANNER = ("as: OK", "ld: OK")
SUITE_FLOOR = 205  # master after PR #77: 203 plus t211 (cr_escape) and t212 (bytes_to_str_100k)
SELF_ARENA_MB = "6000"  # a bare self-compile refuses (1 GB thrashes for hours); 6000 = the in-process link
RUNGS = {
    # rung: (source, wall-clock limit s, max resident bytes or None, rebuild the compiler first)
    "A": ("tools/fuzz/ladder/A.rail", 30, 1 << 30, False),
    "B": ("tools/fuzz/known/mixed_int_from_fn.rail", 30, None, True),
    "C": ("tools/fuzz/ladder/C.rail", 30, None, True),
}


def printed(out):
    """Only what the program printed: everything after the compiler's final `ld: OK` line. A check that
    imports stdlib (A imports http_client) makes the compiler print a symbol table before the link, which
    the banner filter alone let through on the first night (rung A's judge failed a correct program)."""
    lines = out.splitlines()
    marks = [i for i, ln in enumerate(lines) if ln.strip() == "ld: OK"]
    if marks:
        return lines[marks[-1] + 1 :]
    return [ln for ln in lines if not ln.startswith("Compiling ") and ln.strip() not in BANNER]


def prefix(rung):
    """The compile's own output path, so a check never races /tmp/rail_out; overridable for a rehearsal
    beside a live run (RAIL_LADDER_PREFIX)."""
    return os.environ.get("RAIL_LADDER_PREFIX") or "/tmp/rail_ladder_" + rung


def run(argv, limit, env=None):
    """Own process group, SIGKILL on timeout (the compiled program is a grandchild), max RSS of what was reaped."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    t = time.time()
    p = subprocess.Popen(
        argv, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True
    )
    try:
        out, _ = p.communicate(timeout=limit)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        out, _ = p.communicate()
        rc = 124
    rss = max(before, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    return rc, out or "", time.time() - t, rss


def rebuild(rung):
    """The seed compiles the worktree's tools/compile.rail into a gen-1 binary, kept at a per-rung path
    (`self` always writes /tmp/rail_self, so the copy happens at once). Returns (binary path or None, note)."""
    env = dict(os.environ, RAIL_ARENA_MB=SELF_ARENA_MB)
    rc, out, secs, _ = run(["./rail_native", "self"], 600, env=env)
    if rc != 0 or not os.path.exists("/tmp/rail_self"):
        return None, f"self-compile exit {rc} in {secs:.0f} s:\n{out[-800:]}"
    dst = prefix(rung) + "_bin"
    shutil.copy2("/tmp/rail_self", dst)
    os.chmod(dst, 0o755)
    return dst, f"rebuilt in {secs:.0f} s"


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if len(argv) != 1 or argv[0] not in RUNGS:
        print(f"usage: judge.py <{'|'.join(sorted(RUNGS))}>")
        return 2
    rung = argv[0]
    src, limit, rss_cap, needs_rebuild = RUNGS[rung]
    with open(os.path.join(HERE, rung + ".expected"), encoding="utf-8") as f:
        want = f.read().splitlines()
    binary = "./rail_native"
    if needs_rebuild:
        binary, note = rebuild(rung)
        print(f"rung {rung} compiler: {note}")
        if not binary:
            print(f"FAILED (rung {rung}: the edited compiler does not build)")
            return 1
    rc, out, secs, rss = run([binary, "--out-prefix", prefix(rung), "run", src], limit)
    got = printed(out)
    print(f"rung {rung} check: {src} with {binary}, exit {rc}, {secs:.1f} s, max resident {rss >> 20} MB")
    for ln in want:
        print(f"  want |{ln}|")
    for ln in got[:12]:
        print(f"  got  |{ln}|")
    if rc == 124:
        print(f"FAILED (rung {rung}: the check did not finish in {limit} s)")
        return 1
    if rc != 0 or got != want:
        print(f"FAILED (rung {rung}: the check printed something else, exit {rc})")
        return 1
    if rss_cap and rss > rss_cap:
        print(f"FAILED (rung {rung}: the check took {rss >> 20} MB resident, cap {rss_cap >> 20} MB)")
        return 1
    rc, out, secs, _ = run([binary, "test"], 900)
    m = re.findall(r"(\d+)/(\d+) tests passed", out)
    if not m:
        print(f"FAILED (rung {rung}: the suite printed no result line, exit {rc})\n{out[-600:]}")
        return 1
    passed, total = int(m[-1][0]), int(m[-1][1])
    if passed != total or total < SUITE_FLOOR:
        print(f"FAILED (rung {rung}: check passed but the suite is {passed}/{total}, floor {SUITE_FLOOR})")
        return 1
    print(f"OK (rung {rung}: check passed in {secs:.1f} s; suite {passed}/{total})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
