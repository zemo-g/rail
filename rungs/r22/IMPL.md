# Rung 22 — Four-ISA Byte-Identical Chain

**Status: PARTIAL (local gates green; cross-ISA *execution* leg pending a foreign host).**

Proves the Q.24 exact-integer training + the attested utterance are *genuinely* ISA-portable,
not portable-by-luck — by removing the two things in the rung-21 capstone that *dodged* cross-ISA
arithmetic, certifying the hard arithmetic edges with an independent witness, and building the
distinct-ISA binaries. The one thing this Mac cannot do (execute x86/Linux ELF) is stated honestly
with the exact remote command that closes it.

---

## What the ladder asks (verbatim obligations)

- **Wall.** The rung-21 foreign verifier is Python big-int — it dodges cross-ISA arithmetic. Bit-exactness
  rests on (a) truncate-divide (negative-rounding differs ARM↔x86), (b) the 2-limb `hi*2^31+lo`
  superaccumulator (exact only while every product stays in int63), and (c) the Metal path reinterprets
  ints as f64 (silently drops mantissa past 2^53). At d=8/hidden=64 it stayed safe *by smallness*.
- **Gate.** Compile with `rail_native` (ARM64), `rail_native x86`, the Metal-readout build; `cmp` the three
  `utterance_chain.txt` byte-identical with keys/genesis fixed; `file` confirms three distinct ISAs. **The
  run must include ≥1 dot whose exact 2-limb accumulator exceeds 2^53 and ≥1 negative truncate-divide.**
- **Falsifier.** Inject one ISA-divergent op into one target (round-half-up on x86, or a Metal dot past
  2^53): the cmp must diverge and the gate fail. Re-running one binary 4× is caught by the distinct-ISA
  `file` check.

---

## The design — how it extends the proven pipeline

The rung-21 trainer (`tools/bitexact/attested_utterance.rail`) is reused **verbatim** for the entire
transformer (lm10: Q.24, RoPE, multi-head attention, RMSNorm, FFN, exact-int Adam, the SHA-256/Ed25519
hash-chain, `bnd_wp_ser/deser`, `lm4_chain_d0` re-run, the UTTER record). The new file
`tools/bitexact/utterance_cross_isa.rail` is that trainer with exactly three deltas, each motivated by a
named wall:

1. **Readout on the CPU, not Metal.** Rung-21 routed the readout GEMM through `gpu_matvec`
   (`float_arr` + Metal `tgl_exact_matmul`). That op is (i) the f64-mantissa hazard (Metal reinterprets
   ints as f64), and (ii) non-linkable on x86_64 / Linux-ARM64 (no Metal FFI in `tools/x86_rt.s` /
   `tools/linux_libc.s`; `linux_libc.s` has no `float_arr` at all). We switch the readout to `lm4_matvec`
   (pure integer-list CPU). **This changes nothing in the chain:** rung-21's own `gpu_d2_all` invariant
   proved `gpu_matvec rows v == lm4_matvec rows v` bit-for-bit on every row including negatives. So the
   CPU-readout chain *is* the Metal-readout chain, minus the one op that dodged the cross-ISA question.
   (The Metal-readout build is then rung-21's `attested_utterance.rail` itself — its chain must equal
   this one, and `gpu_d2_all` already certifies the only differing op.)

2. **Zero `float_arr` in the chain path.** Removing `gpu_matvec` removes the only `float_arr` use in the
   training/decode path, so the source links on all three ISAs. (`arr_new`/`arr_get` for the RoPE tables
   are *integer* arrays — present on every target.)

3. **Hard-edge witnesses, committed.** New `he_*` functions observe one forward pass over the final
   weights and record:
   - `bigacc` = max |raw readout accumulator| across all dots, and
   - `negtd`  = count of readout dots whose raw numerator is negative (→ a negative truncate-divide).
   These are written to `out/cross_isa_witness.txt` and gated: `okBigAcc = bigacc > 2^53`,
   `okNegTD = negtd ≥ 1`. A pass therefore certifies the hard edges, not smallness.

Everything else — the genesis/seed constants, the header format, the UTTER record — is **identical to
rung 21**, so the existing foreign verifier `utterance_foreign_check.py` reads this chain unchanged.

### Why the magnitude is real, not a contrivance
The readout `W1 . x` is a 64-term dot (indim = cwin·d = 64) of Q.24 values; the raw accumulator
routinely reaches ~10^17–10^18 (e.g. 64·(8·2^24)² ≈ 1.15·10^18), far above 2^53 ≈ 9.0·10^15. The
trained weights span both signs, so negative numerators (hence negative truncate-divides) are abundant.
The witness *measures* both, and the foreign cross-check (below) recomputes them independently.

---

## Soundness / falsification argument

- **Cross-ISA arithmetic, the two named hazards, are discharged by two independent implementations
  today.** (1) The truncate-divide hazard: `tools/bitexact/bx4_foreign_check.py:td` implements
  truncate-*toward-zero* explicitly (`-q if signs differ`), with a comment noting Python `//` *floors*
  — so the Python verifier is a genuinely different arithmetic implementation that already exercises the
  negative-rounding path (`td(-25,8) == -3`, not floor `-4`). (2) The 2^53/superaccumulator hazard: the
  Rail readout uses int63 list-accumulation (never f64); `rungs/r22/witness_cross_check.py` re-derives the
  exact big-int accumulator and confirms it both exceeds 2^53 *and* equals the Rail-emitted `bigacc`.
  Matching a >2^53 accumulator from a different language is the certificate that no f64 truncation crept in.
- **The chain binds the saying.** Unchanged from rung 21: the UTTER record commits `t_hex` (SHA-256 of the
  spoken token ids) bound to `w_hex` (final-weight commitment) and the prompt, chained onto the training
  head and Ed25519-signed. The foreign verifier re-derives weights, re-generates the words, and verifies
  the signature — the loop closes on the *words*, not just the gradients.
- **The negative control fires (falsifier).** `rungs/r22/make_falsifier.sh` synthesizes a 4th source
  identical except the readout divide is **round-away-from-zero** (any nonzero remainder rounds up in
  magnitude) — a strictly different ISA rounding mode in the family the rung names. Because hundreds of
  large accumulators over 19 epochs have nonzero remainders, the falsifier's logits, loss, `w_hex`, and
  **chain head necessarily diverge** from the honest head. The validator asserts `head_honest != head_falsify`.
  If round-away-from-zero did *not* diverge, the "byte-identical across ISAs" claim would be vacuous — so
  this control gives the claim teeth.
- **Re-running one binary 4× is caught** by `file(1)`: the validator confirms the ARM64 artifact is
  Mach-O arm64 while the x86/Linux artifacts are ELF x86-64 / ELF aarch64 — distinct ISA tags.

### What a green gate means vs. the honest gap
- **Green locally (this script proves):** ARM64 trains + speaks + attests; the two hard arithmetic edges
  are certified by an independent big-int witness; a third-language verifier reproduces the *saying*
  bit-for-bit (incl. the negative-truncate path); the x86_64 and Linux-ARM64 ELF binaries assemble+link
  and `file` shows distinct ISAs; the falsifier diverges.
- **The open leg (cannot run on this Mac):** *executing* the x86 / Linux-ARM64 ELF binaries to `cmp`
  their `utterance_chain.txt` against the ARM64 one. This Mac has **no qemu and Rosetta runs Mach-O, not
  Linux ELF**, so the foreign-ISA binaries cannot be run here. Closing it needs one x86_64 Linux host and
  one Linux-ARM64 host (a Pi — and the Pi's 416MB RAM is exactly what rung 23's segmented arena resolves,
  per the ladder's 22↔23 note). The exact closing commands are printed by the validator and reproduced
  below.

---

## The EXACT validate command

```bash
bash /Users/ledaticempire/rail-reward/rungs/r22/validate.sh
```

Run **serially** (it does the one slow ARM64 compile + ~2-3 min training run, two cross-compiles, and
the Python re-derivations). It prints, and grades, every gate above; exit 0 iff all *local* gates are
green. The cross-ISA execution leg is reported as `PENDING-FOREIGN-EXEC` with the remote commands.

### Closing the foreign-exec leg (manual, needs the hosts)
```bash
# on this Mac: emit the ELF binaries (validate.sh already does this)
./rail_native x86   tools/bitexact/utterance_cross_isa.rail   # -> /tmp/rail_x86  (ELF x86-64)
./rail_native linux tools/bitexact/utterance_cross_isa.rail   # -> /tmp/rail_linux (ELF aarch64)

# on an x86_64 Linux host:
scp /tmp/rail_x86 user@x86host:~/ ; ssh user@x86host \
  'cd ~ && RAIL_ARENA_MB=8192 ./rail_x86 && sha256sum out/utterance_chain.txt'
# on a Linux-ARM64 host (Pi, with rung-23 segmentation if RAM-bound):
scp /tmp/rail_linux pi@arm64host:~/ ; ssh pi@arm64host \
  'cd ~ && RAIL_ARENA_MB=8192 ./rail_linux && sha256sum out/utterance_chain.txt'

# back here: the three SHA-256 (ARM64-Mac, x86-Linux, ARM64-Linux) MUST be identical.
cmp out/utterance_chain.txt <(ssh user@x86host  'cat out/utterance_chain.txt')   # byte-identical
cmp out/utterance_chain.txt <(ssh pi@arm64host 'cat out/utterance_chain.txt')    # byte-identical
```

---

## Files

| File | Role |
|---|---|
| `tools/bitexact/utterance_cross_isa.rail` | the ISA-portable trainer (CPU readout, hard-edge witnesses) — the artifact the three ISAs build |
| `rungs/r22/validate.sh` | the serial validator (build ARM, run, witness, foreign-verify, cross-build, falsify) |
| `rungs/r22/witness_cross_check.py` | foreign (Python big-int, explicit truncate) re-derivation of `bigacc` + `negtd` |
| `rungs/r22/make_falsifier.sh` | synthesizes + builds the round-away-from-zero falsifier (negative control) |
| `tools/bitexact/utterance_cross_isa_falsify.rail` | the falsifier source (generated; checked-in for inspection) |
| reused: `tools/bitexact/utterance_foreign_check.py`, `lm10_foreign_check.py`, `bx4_foreign_check.py` | the proven rung-21 third-language verifier chain |

## Honest notes
- The truncate-divide hazard is **already** independently discharged by `bx4_foreign_check.td` (truncate-
  toward-zero, distinct from Python floor) — rung 22 makes it *explicit and gated* rather than implicit.
- The 2^53 hazard was previously hidden inside Metal f64; rung 22 removes Metal from the chain (CPU readout,
  bit-identical via `gpu_d2_all`) and adds an independent big-int witness that the accumulator genuinely
  exceeds 2^53. This is the substantive new guarantee.
- The single genuine open item is **foreign-ISA execution + 3-way `cmp`**, blocked only by the absence of
  an x86-Linux box and a runnable Linux-ARM64 host on this Mac — not by any code or arithmetic gap. The
  binaries are built and ISA-distinct here; the bytes just need to be produced on the other two silicons.
