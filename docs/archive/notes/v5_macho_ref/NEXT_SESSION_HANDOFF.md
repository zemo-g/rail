# v5.0 marathon — next-session handoff

Written 2026-05-14 02:38 UTC at the end of a long session that took Rail
from v4.0.0 release through v5 Phases 0–4b. This doc is the cold-start
brief for the next session to continue cleanly.

## Where to start reading

If you have 60 seconds: read this file top-to-bottom.
If you have 5 minutes: also read `COMPILE_RAIL_INTEGRATION.md` in this
directory — it has the engineering analysis behind tonight's stop point.

## Repo state

- Public repo: `zemo-g/rail` on GitHub
- Last tagged release: **v4.1.0** (no v5 tag yet — appropriate; v5 is RC quality, not GA)
- Master HEAD: `165bce7` (v5 Phase 4b)
- Working clone: `~/projects/rail` is on branch `half-s2-kernels` with
  uncommitted edits in `stdlib/https_client.rail`, `stdlib/sha256.rail`,
  `tools/fleet/fleet_agent_v3.rail`. **Do not work in that tree.**
  Use a worktree against `origin/master`:

  ```bash
  cd ~/projects/rail
  git fetch origin
  git worktree add --detach /tmp/rail_v5 origin/master
  cd /tmp/rail_v5
  git checkout -B v5/<your-phase>
  ```

## What v5 is

v5.0 retires `as`, `ld`, and `codesign` from Rail's build pipeline. The
substrate-thesis claim is that Rail produces its own binaries with zero
external tools. Phases 0–4b shipped the building blocks; the remaining
work is integration with `compile.rail`'s real output.

## What's already shipped

| Module | Lines | Role | Verification |
|---|---|---|---|
| `jit/arm64.rail` | 350 | ARM64 instruction encoders (46 mnemonics) | `./rail_native run jit/test_encoders.rail` → 89/89 byte-match vs `as` |
| `stdlib/macho.rail` | 320 | Mach-O 64-bit writer (header + load commands + segments) | header bytes 0–31 match canonical |
| `stdlib/codesign.rail` | 170 | Ad-hoc SuperBlob + CodeDirectory emitter | `codesign -v` passes |
| `tools/v5/asm.rail` | 400 | Rail-native ARM64 assembler (40 mnemonics, 4+ addressing modes) | `./rail_native run tools/v5/test_asm_full.rail` → 56/56 byte-match vs `as` |
| `tools/v5/compile_macho.rail` | 60 | File-level driver: `.s` → assembled bytes → Mach-O → signed | `./rail_native run tools/v5/compile_macho.rail tools/v5/example_program.s && /tmp/v5_compiled; echo $?` → 42 |

Run all four verification commands above before doing anything else — if
any of them fail, something regressed and that needs to be fixed before
new work.

## The single remaining problem (the "dyld-stub gap")

`compile.rail`'s actual `.s` output for **any** Rail program — even
`main = 42` — emits ~12,000 instructions because the full runtime is
always bundled. The runtime uses external symbols (`bl _malloc`,
`bl _fopen`, `bl _strlen`, `bl _fwrite`, ...) resolved by dyld at load
time against `/usr/lib/libSystem.B.dylib`.

Tonight's pipeline can **encode** those `bl` instructions but can't tell
dyld where to find the symbols. The kernel loads the binary and
immediately kills it with `Killed: 9` (no error message).

To close the gap, three picks ranked by scope / risk:

### Option 1 — Linux ELF first (recommended)

Linux compile.rail emits raw syscalls (no libc). No dyld-equivalent.
Just need an ELF writer.

- New module: `stdlib/elf.rail` (~1,000 lines, parallels `stdlib/macho.rail`)
- ELF64 header + program headers + section headers
- No code signing required on Linux
- Wire `tools/v5/compile_linux.rail` driver

**Acceptance:** a Rail program with `main = ...` compiles via
compile.rail → `.s` → asm.rail → ELF → runs on Pi or x86_64 Linux.

This is the **lowest-risk path to a real Rail program compiling
end-to-end via the Rail-only toolchain.**

### Option 2 — macOS dyld stubs (full macOS GA)

Estimated +1,500 lines on top of Phase 4b. Requires:

1. **`LC_LOAD_DYLIB`** load command pointing at `/usr/lib/libSystem.B.dylib`
2. **Indirect symbol table** in `__LINKEDIT` (list of imported externals)
3. **`__stubs` section** in `__TEXT` — 12-byte trampolines per import
4. **`__got` / `__la_symbol_ptr` section** in `__DATA` — 8-byte slots dyld fills
5. **Assembler rewriting**: `bl _foo` → branch to local `_foo$stub` address
6. **`__DATA` segment** for static globals (`.quad`, `.zerofill`)
7. New `LC_SEGMENT_64` for `__DATA`
8. Possibly **`LC_DYLD_INFO_ONLY` or `LC_DYLD_CHAINED_FIXUPS`** for binding
   info — modern macOS expects one of these; the older `LC_DYLD_INFO` is
   what `codesign --remove-signature` leaves on minimal binaries

Trickiest part: dyld's bind opcode stream (in `__LINKEDIT`) is a tiny
bytecode that tells dyld which `__la_symbol_ptr` slot maps to which
external symbol. Apple documents it in `mach-o/loader.h` and
`mach-o/fixup-chains.h` but it's poorly explained outside their source.

**Debug cost is high.** Failures are silent (`Killed: 9`). Tools like
`dyld_info` exist but require a working sample to compare against.

Recommend doing this AFTER option 1 lands, so we have a working integration
to compare bytes against when something doesn't work.

### Option 3 — Easy bite: assembler symbol-ref parsing

Tonight's `tools/v5/asm.rail` doesn't handle:
- `adrp x0, _foo@PAGE` + `add x0, x0, _foo@PAGEOFF` (PC-relative address load)
- `bl _foo` where `_foo` is an external symbol

Add the parsing — `~100 lines`. Doesn't make any program runnable on its
own (the symbol references still won't resolve), but pre-builds the
syntactic ground for option 2.

Useful as a warm-up bite or filler. Not on the critical path.

## Things that surprised us; the next session shouldn't relearn

1. **`write_file` truncates at NUL bytes** because the runtime stub uses
   `strlen` to determine length. Mach-O headers contain many NULs.
   Workaround: `stdlib/macho.rail`'s `macho_write_file` hex-encodes in
   Rail, then shells `xxd -r -p` to materialise the binary. Use it.

2. **Rail's parser breaks on `--` comments inside list literals.**
   `build_fixtures = [["a", 1], -- comment ["b", 2]]` fails with
   "expected decl, got kw 'let'" — Rail thinks the list ended at the
   comment. Strip in-list comments.

3. **Rail's `import` does NOT deduplicate.** Each `import "X.rail"`
   literally inlines all of X's declarations. If A imports B and the
   top-level driver also imports B, you get duplicate symbols at link
   time. Pattern that works: `stdlib/codesign.rail` does NOT
   `import "stdlib/macho.rail"` even though it uses macho's primitives;
   callers must import macho first.

4. **`head args` returns the program path, not user argv[1].** User
   arguments start at `head (tail args)`. compile.rail itself uses this
   pattern.

5. **`codesign --sign -` INSERTS a new LC_CODE_SIGNATURE entry after
   the existing load commands**, overwriting whatever bytes sat there.
   Solution: place code at file offset ≥ 1024 so there's 480 bytes of
   headroom past the LC array.

6. **macOS 11+ refuses unsigned ARM64 binaries.** Even an ad-hoc
   signature is required. `stdlib/codesign.rail` produces a valid
   ad-hoc sig; rely on it from day 1.

7. **`/tmp/rail_out` is shared between concurrent compiles.** The
   user's `mhd_beacon` daemon constantly recompiles and stomps it. For
   anything that needs the binary to stick around, use the pattern:
   ```bash
   rm -f /tmp/rail_out && ./rail_native foo.rail && mv /tmp/rail_out /tmp/my_binary
   ```
   Or work in a worktree — orphan processes from other shells still
   target `/tmp/rail_out` but the .o/.s intermediates go to mktemp.

8. **The `mhd_beacon` daemon (PID 44044) eats CPU and competes for /tmp.**
   It's the user's plasma simulator, intentionally running. Don't kill it.
   Use `mv /tmp/rail_out /tmp/X` between compile and run.

9. **Rail's `bit_or`, `bit_and`, `shr`, `shl` work on tagged ints** —
   the encoder math in `jit/arm64.rail` and the byte primitives in
   `stdlib/macho.rail` already account for this. Don't second-guess.

10. **Self-bootstrap is sacred.** `compile.rail` must continue to
    produce a byte-identical `rail_native` (`./rail_native self`). Any
    change to `tools/compile.rail` that doesn't survive the 2-pass
    byte-identical fixed point breaks the project. None of v5 phases 0–4b
    touched `tools/compile.rail` — that's deliberate. Keep it that way.

## Reference files

In `notes/v5_macho_ref/`:

- `STRUCTURE.md` — byte-level annotation of a canonical Mach-O (the
  `as`+`ld`+`codesign` output we're replacing)
- `CODESIGN.md` — byte-level annotation of the ad-hoc signature blob
- `COMPILE_RAIL_INTEGRATION.md` — the engineering plan with three
  strategies (A: parallel byte emission / B: Rail-native assembler /
  C: backend rewrite). Tonight picked B (the assembler) which proved
  faster and lower-risk than A.
- `exit42.canonical` — the canonical `as`+`ld` output for the smallest
  test case (16,840 bytes)
- `codesig.bin` — the 18,304-byte signature blob `codesign --sign -`
  produces, raw

In `notes/`:
- `v5_feasibility_2026-05-13.md` — the original scoping doc from before
  any code was written. Reread if confused about why we're doing this.

## How to verify "before any new work" everything still passes

```bash
cd /tmp/rail_v5     # or wherever your worktree is
./rail_native run jit/test_encoders.rail | tail -2
# Expect: "ALL 89 ENCODERS MATCH"

./rail_native run tools/v5/test_asm_full.rail | tail -2
# Expect: "PASS: 56/56 instructions match"

./rail_native run tools/v5/compile_macho.rail tools/v5/example_program.s
/tmp/v5_compiled ; echo $?
# Expect: 42

codesign -v /tmp/v5_compiled ; echo $?
# Expect: 0
```

If any of those fails, debug that first before adding new code.

## Recommended order for next session

1. **First 5 min**: run the four verification commands above.
2. **Next 5 min**: skim `COMPILE_RAIL_INTEGRATION.md` and the
   "dyld-stub gap" section of this doc.
3. **Pick the path**: I'd default to **Option 1 (Linux ELF)** because
   it bypasses the dyld problem entirely and gets us to "a real Rail
   program produces a runnable binary via pure-Rail tooling" much
   faster.
4. **Cut a worktree** off `origin/master` and start. Same pattern as
   tonight: small commits, byte-verify against canonical at each step,
   push when verified.

## What success looks like for v5.0 GA

A single command, no external tools invoked, produces a runnable binary:

```bash
./rail_native --macho-direct foo.rail     # on macOS
./rail_native --elf-direct foo.rail       # on Linux
./foo ; echo $?                           # runs
```

Behind the flag is the Phase 4b pipeline (compile.rail → .s → asm.rail
→ bytes → format writer → signed if macOS → file). The hard part is
making asm.rail handle the external-symbol referencing patterns
compile.rail emits, plus the format-writer side knowing how to emit the
dyld stubs (macOS) or just lay out the file (Linux).

When that ships, tag v5.0.0 and write the release notes the same way
v4.0.0 was done. The substrate-thesis claim — "Rail produces its own
binaries with zero external tools" — becomes publicly defensible at GA
quality, not just on the syscall-only subset we have today.

## Tag-readiness checklist (don't tag v5.0.0 until all yes)

- [ ] `compile.rail` output of a real Rail program (e.g. `main = print "hi"`)
      goes through the new pipeline and runs
- [ ] On both macOS (with dyld stubs) and Linux (with ELF)
- [ ] No regression on `./rail_native test` (currently 140/140 on master)
- [ ] No regression on `./rail_native self` byte-identical fixed point
- [ ] CHANGELOG.md v5.0.0 entry written
- [ ] README.md badge bumped to v5.0.0
- [ ] Leak guard CI still passes (`.github/workflows/leak-guard.yml`)
- [ ] Tagged annotated, pushed, GitHub Release created with notes

Good luck. The hard part is done — encoder, Mach-O, codesign, assembler
all work and are byte-verified. The remaining work is plumbing, not
discovery.

— prior session, signing off
