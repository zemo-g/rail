# Check Rail yourself

Rail's claim is **"check me, don't trust me."** This page is the kit: every core
claim below is something *you* can verify on your own machine, with one command.
A pass is reproducible provenance — not a proof of correctness (see the last
section for exactly what each check does and does not establish).

**One command for all of it:**

```bash
tools/verify/check.sh          # full self-audit (~25 min: rebuild + tests)
tools/verify/check.sh --quick  # fast pass (~2 min: skips the rebuild, quick tests)
```

…or run any single check below on its own.

---

## 1. The shipped binary is what the shipped source produces

```bash
./verify_reproducible.sh       # exit 0 = reproducible, 1 = mismatch, 2 = env error
```

Rebuilds the committed seed (`rail_native`) from *this checkout's* source using
Rail's own pure-Rail toolchain — its AArch64 assembler, Mach-O linker, and ad-hoc
signer, with **no external `as`/`ld`/`codesign`** — then confirms the rebuilt
binary is byte-for-byte identical to the committed one. A match proves the binary
you run is exactly what the source you read produces. (Apple Silicon macOS;
`RAIL_ARENA_MB>=6000`.)

## 2. The tests pass, and the runner reports its own count

```bash
./rail_native test; echo "exit $?"      # full suite, self-reports N/N and exits 0 iff N == N
./rail_native quick                    # ~30s core subset
```

The runner prints its own pass count and its exit status carries the verdict.
The expected total is an explicit gate inside `tools/compile.rail` (grep
`tests passed`); growing the suite moves the gate in the same diff, so a
silently-skipped test still fails the run. One test, `gpu_map`, needs a Metal
device: on a machine without one it reports "No Metal device" and counts as a
failure, which is honest but means GPU behaviour is only verified on Apple
Silicon with a GPU attached.

## 3. The self-compile reaches a byte-identical fixed point

```bash
./rail_native self && cmp rail_native /tmp/rail_self   # silent = identical
```

The compiler's own source is its regression suite.

## 4. Read the grammar

The language surface is a single EBNF file you can read end to end:

```bash
less grammar/rail.ebnf
```

## 5. The status numbers are recomputed live

```bash
./rail_native run tools/deploy/gen_status.rail && git diff --exit-code docs/STATUS.md
```

[`docs/STATUS.md`](docs/STATUS.md) is a pure function of the source tree
(compiler LOC, stdlib count, seed hash/size, dependency boundary): no timestamp,
so a clean `git diff` after regeneration means the committed copy is current,
and `check.sh` section 4 fails when it is not. Each row carries the command to
re-verify it. Regenerate and commit it whenever the compiler or the seed changes.

## 6. A release is attested against a public beacon

```bash
tools/attest/verify_selftest.sh        # positive control + a replacement artifact both verifiers must reject
tools/verify/check_selftest.sh         # the umbrella itself must fail on a crashed test run or an ok-then-crash verifier
git show 28ad78be16259b7c9af48bbf3e2a06810aa6491e:tools/compile.rail > /tmp/v530_compile.rail
./rail_native run tools/attest/verify.rail /tmp/v530_compile.rail releases/v5.3.0/compile.rail.attestation.json
```

Tagged releases are Ed25519-signed and anchored to a public entropy beacon; the
verifier is itself Rail (`tools/attest/verify.rail`), and `check.sh` runs it
against the newest `releases/v*/index.json`. The witness public key is fetched
from `https://ledatic.org/attest/fleet0.pub.pem` on first use; that fetch trusts
the site's TLS, nothing more. A verifier passes only when it exits 0 AND
prints `ok`, and the file's digest equals the digest inside the signed witness; the unsigned `artifact.sha256`
field in the sidecar must agree with both (until 2026-09-06 the shell verifier
compared only the unsigned field, see `verify_selftest.sh`).

---

## What these checks prove — and what they don't

- **They prove provenance:** the binary matches the source, the tests the runner
  ran, the numbers the tree actually contains, the signatures the witnesses made.
- **They do *not* prove correctness.** A program (or the compiler) can compile,
  reproduce, and be signed, and still be wrong. Compilation means *accepted by
  the binary you run*, not *correct*.
- **Platform boundary:** "no C" means no C in the source-owned compiler and
  runtime, and no external assembler, linker, or signer on the reproducible
  path. The macOS seed still links `libSystem` (the kernel interface), and the
  everyday `./rail_native file.rail` builds use the system `as` and `ld`. GPU
  paths are only exercised where a Metal device exists.
- **One honest gap:** a Rail compiler verifying a Rail compiler is not an
  *independent* check — it does not defeat a trusting-trust attack. Closing that
  (diverse double-compilation or a non-Rail reference checker) is open work, not
  yet claimed. The defensible claim is **check me**, never *proof of truth*.
