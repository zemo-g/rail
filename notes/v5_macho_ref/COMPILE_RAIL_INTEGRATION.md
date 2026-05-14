# v5.0 — Routing compile.rail through the pure-Rail toolchain

Phases 0–2 + 4 prove the toolchain *works*: `jit/arm64.rail` encodes every
ARM64 mnemonic `compile.rail` emits, `stdlib/macho.rail` produces a valid
Mach-O around any byte buffer, `stdlib/codesign.rail` ad-hoc-signs it,
and `tools/v5/rail_emit_*` demonstrate that parameterised + multi-
instruction programs all run.

What remains for v5.0 release: **plumb compile.rail's existing AOT
backend through these modules** so that every `./rail_native foo.rail`
invocation skips `as` + `ld` + `codesign`.

## The shape of the problem

`tools/compile.rail`'s ARM64 backend (lines 597–2537 of codegen + 2640–2913
of runtime stubs) does its work entirely in **assembly text** — every
`emit_x1`, `cg_let_binds`, `compile_func` ultimately calls `cat [...]`
building strings like `"    mov x0, #5\n"`. The final `.s` file gets
shelled to `as` to produce `.o`, then `ld` to produce the executable.

The new toolchain expects **machine bytes** — a 16,384-byte buffer ready
for the Mach-O writer to wrap.

The bridge problem: how do we get from the text representation to the
byte representation?

## Three strategies, ranked by realism

### A. Parallel byte emission (recommended for v5.0)

Augment each codegen call site in compile.rail with a *parallel* byte
emission. Where today there's:

```rail
(cat ["    mov x0, ", show v, "\n"], lc, sl)
```

add:

```rail
let _ = cb_emit byte_buf byte_off (enc_mov_imm16 0 v)
```

A side-buffer accumulates bytes in lockstep with the text. The text path
keeps working (no regression risk for the 137-test bootstrap); the byte
path is what the Mach-O writer consumes.

**Scope estimate**: ~50 call sites to mirror. ~150 lines of new code in
compile.rail. The expensive part is being sure the byte ordering and
offset tracking mirror the text exactly. Every byte-emitting call has to
return the next offset so chains compose like `mw_u32` does in
`stdlib/macho.rail`.

**Risks**:
- Byte-identical self-compile must be preserved. The text path is the
  byte-identical contract; the byte path is additive output. If the byte
  buffer is only emitted when a `--macho` flag is set, the default text
  path stays untouched.
- Forward-branch patching. `cg_if`, `cg_match`, `self_loop_emit` all
  emit branches whose offsets aren't known at emit time — they get
  filled in later by string substitution. The byte path needs the same
  patch-it-later facility (`cb_patch` exists in `jit/codebuf.rail`).

**Sequencing**:
1. Add `byte_buf` + `byte_off` to the codegen accumulator type.
2. Mirror `emit_load_int`, `emit_x1`, `cg_*` int-arith ops first
   (covers ~80% of typical programs).
3. Mirror branches + forward-patch handling.
4. Mirror runtime-stub embedding (`rt_core`, `rt_arith`, etc. — these
   are large static blocks, so factor each to also produce its
   pre-computed byte form).
5. Gate behind a new `compile_macho` entry point that takes the same
   inputs as `compile_macos`, runs codegen once with both buffers
   active, then writes a Mach-O instead of a `.s`.

### B. Rail-native assembly-text parser

Write `stdlib/assembler.rail`: parse the `.s` text compile.rail emits,
translate each instruction line to bytes via `jit/arm64.rail`. Run
compile.rail's existing text path, capture the output, run our assembler
on it, get bytes, wrap in Mach-O.

**Scope estimate**: ~600 lines. A subset of ARM64 syntax (the subset
compile.rail emits) is well-bounded.

**Pros**: completely decoupled from compile.rail — no risk to the
137/137 byte-identical contract. Could be developed and tested in
isolation against `.s` files captured from existing compiles.

**Cons**: redundant work at every compile (text→bytes when bytes are
what we wanted). And the assembler itself is a maintenance burden — a
new ARM64 directive in compile.rail's output requires an update in
both places. Plus relocations: a real assembler resolves symbol
references; ours would need to either compile relocations forward into
the Mach-O or resolve them at emit time.

### C. Wholesale rewrite of compile.rail's ARM64 backend

Throw out the assembly-text codegen entirely; emit bytes from day one.

**Scope estimate**: weeks. The current codegen is ~2,000 lines of
text-emission and many of the contracts are implicit (offsets implied by
string lengths, branches resolved by sed-like substitution).

**Reject for v5.0**. Save for v6 if the parallel-emission cost becomes
maintenance-painful.

## Recommended plan for v5.0

**Strategy A**, staged across four mini-phases:

| Mini-phase | Scope | Acceptance |
|---|---|---|
| 4a | Add parallel byte buffer threading to `cg_let_binds` + `emit_x1` + 6 int-arith ops | A hand-fixed Rail program (`main = 1 + 2 + 3 + 4`) produces a byte buffer matching `as` output for the same source |
| 4b | Forward-branch byte patching (`cg_if`, `cg_match`) | A program with `if` produces matching bytes |
| 4c | Runtime stubs as pre-encoded byte blocks | A program calling `print "hello"` produces correct bytes (text path keeps emitting the asm; byte path uses cached pre-assembled stubs) |
| 4d | `compile_macho` driver: runs codegen with both buffers active, writes Mach-O via `stdlib/macho.rail` + signs via `stdlib/codesign.rail` | `./rail_native foo.rail --macho` produces a self-signed runnable Mach-O for any program currently buildable with `./rail_native run foo.rail` |

After 4d, default `./rail_native foo.rail` can switch from `.s`/`as`/`ld`
to the macho path on macOS. The text path stays available behind a
`--text-output` flag for byte-identical bootstrap verification.

## What the immediate v5.0.0 release contains

- ✅ `jit/arm64.rail` — AOT-complete encoder (Phase 0, shipped)
- ✅ `stdlib/macho.rail` — Mach-O writer (Phase 1, shipped)
- ✅ `stdlib/codesign.rail` — ad-hoc signer (Phase 2, shipped)
- ✅ Hand-built demos that emit signed exit-code Mach-Os (Phase 4 partial, shipped)
- ✅ `tools/v5/asm.rail` — Rail-native ARM64 assembler covering ~40
  mnemonics + addressing modes (Phase 4a/4b, shipped)
- ✅ `tools/v5/compile_macho.rail` — file-level driver: takes any
  self-contained `.s` file → signed runnable Mach-O (Phase 4b, shipped)
- ⏳ Full `compile.rail` integration — see "The dyld-stub gap" below

## The dyld-stub gap (the real remaining work)

When `compile.rail` is invoked on **any** Rail program — even
`main = 42` — it emits roughly 12,000 instructions of `.s` that
includes the full runtime (allocator, GC, print, file I/O, syscalls).
That runtime uses **external symbols**: `bl _malloc`, `bl _fopen`,
`bl _strlen`, `bl _fwrite`, etc., resolved at load time by `dyld`
against `/usr/lib/libSystem.B.dylib`.

Tonight's `tools/v5/asm.rail` cannot resolve external references; it
only encodes the mnemonic. To take compile.rail's actual output and
produce a runnable Mach-O, the toolchain needs:

1. **`LC_LOAD_DYLIB` load command** — tells dyld to map libSystem.
2. **Indirect symbol table** in `__LINKEDIT` — list of imported
   external symbols (`_malloc`, `_free`, etc.).
3. **`__stubs` section** in `__TEXT` — one 12-byte trampoline per
   external symbol. The trampoline reads a pointer from `__got` /
   `__la_symbol_ptr` and branches to it.
4. **`__got` / `__la_symbol_ptr` section** in `__DATA` —
   one 8-byte slot per imported symbol; dyld fills these at load time.
5. **Rewriting `bl _foo` calls** to target the stub address instead of
   the (unknown) library address.

That's roughly **~1,000 additional lines** of pure-Rail Mach-O
plumbing, plus an extension to the assembler's symbol-resolution pass
to rewrite external `bl` operands to stub-relative offsets.

After that, `.data` and `.zerofill` sections need to be supported
(static globals like `_rail_argc`, `_rail_envp`), which means a
`__DATA` segment + `LC_SEGMENT_64 __DATA`.

**Total remaining estimate**: ~1,500 lines on top of Phase 4b. Half a
session if it goes well, more likely 2–3.

## What's defensible today

The v5 substrate-thesis claim is **publicly defensible** at RC quality
on programs that don't pull in libSystem:

```
./rail_native run tools/v5/compile_macho.rail tools/v5/example_program.s
   → assembled 24 bytes (6 instructions)
   → wrote /tmp/v5_compiled (16,616 B, self-signed)

/tmp/v5_compiled ; echo $?      → 42  (= 2 × 21 computed on real ARM64)

codesign -v /tmp/v5_compiled    → exit 0 (signature validates)
```

End-to-end: arbitrary self-contained ARM64 assembly → bytes → Mach-O →
ad-hoc signed → runs. No external macOS toolchain involved.

For v5.0.0 GA, the remaining work is the dyld-stub gap above. After
that, every `./rail_native foo.rail` produces a native Mach-O for any
Rail program.

## Linux (still deferred)

ELF emission is conceptually identical to Mach-O emission. Same data
flow: codegen → bytes → ELF writer. No code-signing requirement on
Linux. **But also no dyld-stub problem**: compile.rail's Linux output
uses raw syscalls (no libc), so once Phase 4b's pipeline is wired and
an ELF writer (~1,000 lines) exists, Linux works without the extra
LC_LOAD_DYLIB / stub / GOT machinery. Linux might therefore land
**before** macOS GA.

## Linux (deferred)

ELF emission (Linux ARM64 + x86_64) is conceptually identical to Mach-O
emission. Same data-flow: codegen produces bytes, ELF writer wraps. No
code-signing requirement on Linux. Once strategy A is proven on macOS,
the Linux side is a port of the ELF format details (`<elf.h>`).
