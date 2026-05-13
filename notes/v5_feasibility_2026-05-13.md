# Rail v5.0.0 — Self-hosted Toolchain Feasibility

**Date:** 2026-05-13
**Target:** Rail produces its own Mach-O and ELF binaries. `as` and `ld` are no longer build-time dependencies.
**Status:** Scoping — no code committed.

## 1. The head start exists (against earlier reports)

Rail's v4.0.0 JIT is a real ARM64 machine-code emitter in pure Rail. ~3,600 lines across `jit/`. Verified on `origin/master`:

| File | Lines | Role |
|---|---|---|
| `jit/arm64.rail` | 210 | Bit-level instruction encoders (`enc_mov_reg`, `enc_add`, `enc_bl_byte_off`, `enc_fadd`, ...) |
| `jit/emit.rail` | 930 | IR → ARM64 byte sequences (prologue, epilogue, op_call, op_str_*, op_apply, op_cons, op_read_file, op_print_*) |
| `jit/codebuf.rail` | 36 | In-memory byte buffer |
| `jit/loader.rail` | 121 | `mmap` RW page → write bytes → `mprotect` RX → `sys_icache_invalidate` → `pthread_create` (used as indirect call) |
| `jit/lower.rail` | 2,020 | Rail AST → IR |
| `jit/ir.rail` | 294 | IR definition |

**The JIT already produces executable ARM64 bytes that run on Apple Silicon.** What it does NOT do is write those bytes to a disk file in a format the kernel knows how to load (Mach-O / ELF). It loads them in-process and jumps to them.

## 2. ISA coverage — JIT vs. compile.rail AOT

`compile.rail` (6,889 lines on master) emits assembly text for roughly **48 distinct ARM64 mnemonics** scattered through its codegen (lines 597–2,537 + runtime stubs 2,640–2,913).

The JIT encoder in `jit/arm64.rail` covers roughly **30 of those 48**, including all the architecturally interesting ones:

| Category | JIT covers | Gap (needed for AOT) |
|---|---|---|
| Move | `mov`, `movk` | `movz`, `movn` |
| Arith | `add`, `sub`, `mul`, `udiv`, `msub` | `sdiv`, `asr`, `lsr`, `lsl`, `and`, `orr`, `eor` |
| Compare / cset | `cmp`, `cmp_imm`, `fcmp`, `cset` (lt/eq/gt/le/ge/mi/ls) | (full set covered) |
| Branch | `cbz`, `b`, `bl`, `bne`, `ret`, `blr`, `adr` | `cbnz`, `b.lt/gt/le/hi/hs/lo` (the rest of cond suffix range) |
| Memory | (only specific `stp fp,lr` / `ldp fp,lr` for frame) | general `ldr`, `str`, full `stp` / `ldp` (multi-register, indexed) |
| Float | `fadd`, `fsub`, `fmul`, `fdiv`, `fmov_d_x`, `fmov_d_d`, `scvtf`, `fcvtzs` | (full set covered) |

**Realistic coverage: ~60–65% by mnemonic, and the gaps are mostly *variants* of patterns the JIT already encodes** (another bit-or with a different opcode base). Filling them is ~300–500 lines of mechanical extension to `jit/arm64.rail`, not net-new design.

The Explore agent's "0% overlap, no JIT" reading was wrong. Treat its cost numbers as upper bounds, not real ones.

## 3. What is genuinely new

| Chunk | Existing? | New Rail (est.) |
|---|---|---|
| ARM64 encoder completion (fill the mnemonic gaps above) | 60% done (JIT) | 300–500 |
| x86_64 encoder | 0% | 800–1,200 |
| Mach-O writer (macOS ARM64) | 0% — no `MH_MAGIC`, no `LC_SEGMENT_64`, no `LC_SYMTAB` references anywhere in tree | 1,200–1,800 |
| ELF writer (Linux ARM64 + x86_64) | 0% — no `Elf64_Ehdr`, `PT_LOAD`, `ELFMAG` references | 1,000–1,500 |
| Code-signing stub for Apple Silicon (see §5) | 0%, but SHA-256 + Ed25519 already in Rail (TLS stack) | 400–700 |
| Integration: route compile.rail output through new emitters instead of `as`/`ld` | — | 200–400 |

**Total v5.0 (macOS ARM64 only, with ad-hoc sign):** ~2,500–3,800 lines of new Rail.
**Total v5.full (macOS + Linux ARM64 + Linux x86_64):** ~4,500–6,500 lines of new Rail.

For reference: the v3.0.0 TLS stack was ~3,800 lines and shipped in roughly that timeline. v5.0 is a comparable scope.

## 4. Runtime stubs — already inline

`compile.rail` lines 2,640–2,913 define ~20 `rt_*` variables (`rt_core`, `rt_list`, `rt_closure`, `rt_io`, `rt_arith`, `rt_fiber`, `rt_gc_1`, `rt_str_gc`, etc.) that get concatenated into the emitted `.s`. Together they define **101 distinct `_rail_*` symbols**.

**Implication for v5:** All runtime stubs are already ARM64 assembly *text* embedded in the compiler. For v5 we need to either (a) assemble those text strings through our new encoder before writing to the binary, or (b) pre-assemble them once at build time and store the byte array as a Rail constant. Option (b) is simpler — same approach the JIT uses for the prologue/epilogue templates.

External symbols the binary currently links to:
- **macOS:** `_malloc`, `_free`, `_strcmp`, `_strlen`, `_strcat`, `_strcpy`, `_snprintf`, `_write`, plus libSystem syscall stubs. Linked via `-lSystem`.
- **Linux:** Zero libc. Inline syscall stubs in `rt_syscall` (line 2,867). v5 ELF for Linux is therefore SIMPLER than v5 Mach-O — no dynamic linker, no DYLIB loading.

## 5. The real risk: macOS code-signing

**macOS 11+ refuses to execute unsigned ARM64 binaries.** Even ad-hoc signing is required. This is the only hard wall v5 hits.

Three paths:

1. **Embed an ad-hoc signature emitter in Rail.** Apple's `LC_CODE_SIGNATURE` + `__LINKEDIT` `CodeDirectory` blob is documented (Apple's `cs_blobs.h` + `codedirectory.h`). It uses SHA-256 hashes of every page, which Rail already has. Ad-hoc signatures don't need a key. Cost: ~400–700 lines. **This is the right answer for v5's purity story.**
2. **Shell to `codesign --sign -`.** Trivial but defeats the whole v5 thesis. Reject.
3. **Targeting only Linux first.** Sidesteps the problem but doesn't close the Apple-Silicon story Rail leads with.

Recommend (1). The ad-hoc signer is independent crypto work using primitives Rail already has.

## 6. Proposed staging

| Release | Scope | Cost (est. Rail LOC) | Anchor test |
|---|---|---|---|
| **v5.0** | macOS ARM64 Mach-O + ad-hoc signing. ARM64 encoder completion. compile.rail emits `.macho` directly. `as`/`ld` retired on macOS only. | ~2,500–3,800 | `./rail_native self` produces a Mach-O that runs and reaches byte-identical fixed point. 137/137 tests pass. |
| **v5.1** | Linux ARM64 ELF. Pi self-host with no external linker. | ~600–900 incremental | Pi `./rail_native test` → 137/137 with binary produced by Rail-only toolchain. |
| **v5.2** | Linux x86_64 ELF + x86_64 encoder. | ~1,400–2,100 incremental | x86 conformance harness with Rail-only toolchain. |
| **v5.3** | WASM-binary emission (currently `wat2wasm`-dependent). Cortex-M direct ELF (currently uses external linker script). Final retirement of all external toolchain. | ~800–1,200 incremental | "Rail produces every binary it can run on, with zero external tools." |

**Total program:** ~5,300–8,000 lines of new Rail over four releases. Comparable to the v3.0.0 → v3.11.0 substrate-thesis arc in raw scope.

## 7. Self-bootstrap concern

v5.0's MVP path requires booting once: an existing `rail_native` (built by `as`+`ld`) compiles the v5 compiler, which then produces a Mach-O of itself, which then compiles itself again, and the two outputs must be byte-identical. The same fixed-point discipline that has worked through v1.0 → v4.1.0.

The risk is silent encoding errors. The mitigation is the existing 140-test suite — any miscoded instruction produces a wrong answer on at least one test. Bootstrap-by-test is how Rail has always validated codegen changes; v5 is the same loop at a higher level.

## 8. Verdict

**Feasible.** Closer than the v3.0.0 TLS work was at its scoping moment, because:

- ARM64 encoding is a fixed bit-pattern table — no key exchange, no certificate parsing, no protocol negotiation.
- Mach-O / ELF are documented, frozen formats.
- The JIT already proves Rail can emit and run ARM64 bytes — `jit/loader.rail` is the existence proof.
- The crypto for ad-hoc signing (SHA-256) is already in `stdlib/sha256.rail`.

The real blockers are tedium (binary format details) and the code-signing question, not novel design work. Both are tractable.

**Recommended next move:** v5 Phase 0 — extend `jit/arm64.rail` to AOT-complete (fill the ~18 missing mnemonics). 1–2 days of work. The output is a self-contained "ARM64 encoder in Rail" PR that doesn't yet touch Mach-O. It's a separable bite that proves out the encoder before the format-writer scope opens.
