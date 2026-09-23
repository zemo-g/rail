#!/usr/bin/env python3
"""Run programs under RAIL_GC_STRESS and compare them with their normal runs.

The collector only runs when the arena fills, and at the default 1 GB almost
no test program fills it, so a collector bug hides behind a correct answer.
RAIL_GC_STRESS=N makes the runtime collect on every Nth allocation and poison
what it frees, so a live object the collector misses crashes or changes the
output instead of passing unnoticed.

Programs: every suite test in tools/compile.rail (run_test "name" "src"
"expected"), and every runnable program in the tree that stays inside its
process (the rundiff safety filter). Each is compiled once and run normally;
then under N = 1, 13, 127, 1021, taking the first N that finishes inside the
budget. Verdicts:
  ok      same exit status and output as the normal run
  DIFF    finished under stress with a different status or output
  slow    no N finished inside the budget (not a failure; say how many)
  skip    the normal run itself failed to compile, timed out or crashed

Exit 0 iff no DIFF.
Usage: python3 tools/fuzz/gc_stress.py [--compiler ./rail_native] [--jobs 8]
         [--budget 30] [--ladder 1,13,127,1021] [--only suite|tree] [--env K=V ...]
"""
import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

DANGER = re.compile(r'\b(shell|write_file|append_file|write_bytes|tcp_\w*|socket\w*|sock_\w*|http\w*|connect|bind|listen|accept|send|recv|spawn\w*|fork|exec\w*|dlopen|llm|anthropic\w*|slack\w*|mlx\w*|fleet\w*|deploy\w*|gpu_\w*|tgl_\w*|metal\w*|args|read_line|getenv|system|popen|unlink|mkdir|rename|remove|kill|sleep|usleep|nanosleep|fopen|fwrite|open|mmap|foreign|join_thread|rc_\w*|chan\w*|fiber_\w*|mutex_\w*|quartz\w*|cg_\w*|jit\w*)\b')
IMPORT = re.compile(r'^import\s+"([^"]+)"', re.MULTILINE)


def resolve(name, frm):
    for c in (REPO / name, frm.parent / name, REPO / 'stdlib' / name, REPO / 'stdlib' / (name + '.rail')):
        if c.is_file():
            return c
    return None


def safe(path, seen):
    if path in seen:
        return True
    seen.add(path)
    try:
        src = path.read_text(errors='replace')
    except OSError:
        return False
    code = '\n'.join(l.split('--')[0] for l in src.splitlines())
    if DANGER.search(code):
        return False
    for m in IMPORT.finditer(src):
        p = resolve(m.group(1), path)
        if p is None or not safe(p, seen):
            return False
    return True


def rail_string(s, i):
    """Parse the Rail string literal starting at s[i] == '"'; return (text, next index)."""
    out, i = [], i + 1
    while s[i] != '"':
        if s[i] == '\\':
            c = s[i + 1]
            out.append({'n': '\n', 't': '\t', 'r': '\r'}.get(c, c))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out), i + 1


def suite_programs():
    src = (REPO / 'tools' / 'compile.rail').read_text()
    progs = []
    for m in re.finditer(r'let (t\d+) = run_test "', src):
        i = m.end() - 1
        name, i = rail_string(src, i)
        if src[i] != ' ' or src[i + 1] != '"':
            continue
        text, i = rail_string(src, i + 1)
        progs.append((f'suite {m.group(1)} {name}', text))
    return progs


def tree_programs():
    files = subprocess.run(['git', 'ls-files', '*.rail'], cwd=REPO, capture_output=True, text=True, check=False).stdout.split()
    progs = []
    for f in files:
        path = REPO / f
        src = path.read_text(errors='replace')
        if re.search(r'^main\b', src, re.MULTILINE) and safe(path, set()):
            progs.append((f, None))
    return progs


def run(argv, timeout, env=None):
    try:
        p = subprocess.run(argv, cwd=REPO, capture_output=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL, check=False)
        return p.returncode, p.stdout.decode(errors='replace')
    except subprocess.TimeoutExpired:
        return 'timeout', ''


def one(prog, args):
    label, text = prog
    with tempfile.TemporaryDirectory(prefix='gcs-') as d:
        if text is None:
            src = label
        else:
            src = Path(d) / 'prog.rail'
            src.write_text(text)
        binary = Path(d) / 'prog'
        rc, _ = run([args.compiler, '--out-prefix', str(binary), str(src)], 300)
        if rc != 0 or not binary.is_file():
            return label, 'skip', 'compile failed'
        base = run([str(binary)], 20)
        if base[0] == 'timeout' or not 0 <= base[0] < 128:
            return label, 'skip', f'normal run rc={base[0]}'
        for n in args.ladder:
            env = dict(os.environ, RAIL_GC_STRESS=str(n), **args.env)
            got = run([str(binary)], args.budget, env)
            if got[0] == 'timeout':
                continue
            if got == base:
                return label, 'ok', f'N={n}'
            return label, 'DIFF', f'N={n}\n    normal rc={base[0]} out={base[1][-300:]!r}\n    stress rc={got[0]} out={got[1][-300:]!r}'
        return label, 'slow', f'no N finished in {args.budget}s'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--compiler', default=str(REPO / 'rail_native'))
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--budget', type=int, default=30)
    ap.add_argument('--ladder', default='1,13,127,1021')
    ap.add_argument('--only', choices=['suite', 'tree'])
    ap.add_argument('--env', nargs='*', default=[])
    args = ap.parse_args()
    args.compiler = str(Path(args.compiler).resolve())
    args.ladder = [int(x) for x in args.ladder.split(',')]
    args.env = dict(kv.split('=', 1) for kv in args.env)
    progs = []
    if args.only != 'tree':
        progs += suite_programs()
    if args.only != 'suite':
        progs += tree_programs()
    counts = {}
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        for label, verdict, detail in ex.map(lambda p: one(p, args), progs):
            counts[verdict] = counts.get(verdict, 0) + 1
            if verdict in ('DIFF', 'slow'):
                print(f'{verdict:5} {label}  {detail}', flush=True)
    print('  '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    return 1 if counts.get('DIFF') else 0


if __name__ == '__main__':
    sys.exit(main())
