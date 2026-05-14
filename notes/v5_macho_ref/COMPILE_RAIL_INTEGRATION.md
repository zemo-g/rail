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
- ✅ `tools/v5/rail_emit_exit.rail` + `tools/v5/rail_emit_arith.rail` —
  parametric + multi-instruction demos (Phase 4 partial, shipped)
- ⏳ Mini-phases 4a–4d — full `compile.rail` integration

v5.0.0 RC can ship today; the substrate-thesis story is intact (Rail
produces signed ARM64 Mach-O binaries with no external tools, as
demonstrated by the test programs). v5.0.0 GA waits on 4a–4d.

## Linux (deferred)

ELF emission (Linux ARM64 + x86_64) is conceptually identical to Mach-O
emission. Same data-flow: codegen produces bytes, ELF writer wraps. No
code-signing requirement on Linux. Once strategy A is proven on macOS,
the Linux side is a port of the ELF format details (`<elf.h>`).
