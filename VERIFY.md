# Check Rail yourself

Rail's claim is **"check me, don't trust me."** This page is the kit: every core
claim below is something *you* can verify on your own machine, with one command.
A pass is reproducible provenance — not a proof of correctness (see the last
section for exactly what each check does and does not establish).

**One command for all of it:**

```bash
tools/verify/check.sh          # full self-audit (~25 min: rebuild + tests)
tools/verify/check.sh --quick  # fast pass (~1 min: skips the rebuild, quick tests)
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

## 2. The tests pass — and the runner reports its own count

```bash
./rail_native test             # full suite, self-reports N/N
./rail_native quick            # ~30s core subset
```

The runner prints its own pass count. (The expected total — 178 — is an explicit gate inside `tools/compile.rail`; growing the suite moves the gate in the same diff, so a silently-skipped test still fails the run.)

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
./rail_native run tools/deploy/gen_status.rail && cat docs/STATUS.md
```

[`docs/STATUS.md`](docs/STATUS.md) is regenerated from the source tree on every
run (compiler LOC, stdlib count, seed hash/size, dependency boundary), so it
cannot drift. Each row carries the command to re-verify it.

## 6. A release is attested against a public beacon

```bash
ls tools/attest/               # attest.rail (Rail verifier), release_index.rail, ...
```

Tagged releases are Ed25519-signed and anchored to a public entropy beacon; the
verifier is itself Rail. See `tools/attest/`.

---

## What these checks prove — and what they don't

- **They prove provenance:** the binary matches the source, the tests the runner
  ran, the numbers the tree actually contains, the signatures the witnesses made.
- **They do *not* prove correctness.** A program (or the compiler) can compile,
  reproduce, and be signed, and still be wrong. Compilation means *accepted by
  the binary you run*, not *correct*.
- **One honest gap:** a Rail compiler verifying a Rail compiler is not an
  *independent* check — it does not defeat a trusting-trust attack. Closing that
  (diverse double-compilation or a non-Rail reference checker) is open work, not
  yet claimed. The defensible claim is **check me**, never *proof of truth*.
