# RUNG 31 - Freivalds-Succinct GEMM Through the Truncating Nonlinearity

**Status: VALIDATE-READY.** Code complete; foreign-verifier logic confirmed
green on a faithful model (the heavy artifact is the one serial GPU compile+run
the orchestrator runs via `validate.sh`).

## 1. What this rung proves

The dominant per-step arithmetic of the attested transformer is the exact GPU
readout GEMM `tgl_exact_matmul` (the `gpu_matvec` calls in
`lm10_attested_train.rail:82-91`). Today it is *verified* by `gpu_d2_all`
(`lm10:104`), which **recomputes every training pair's readout on the CPU** and
checks bit-equality - cost **O(pairs . m . k)**.

Rung 31 replaces that whole-checkpoint recompute with **one Fiat-Shamir random
linear check** - Freivalds' algorithm - costing **one matvec-pass O(m . k)**,
independent of the number of pairs. One projection certifies the entire epoch's
readout GEMMs.

## 2. The wall, and why the naive thing is unsound

Freivalds checks `A x == y` by picking random `r` and testing
`rᵀ(Ax) == rᵀy`. The readout output the trainer actually uses is **truncated**:
`out_i = trunc(S_i / 2²⁴)` where `S_i = <A_i, x>` is the exact integer
accumulator. Truncation is **nonlinear**:

```
trunc(rᵀ A x) != rᵀ trunc(A x)
```

so a Freivalds check on the *post*-truncation vector `out` is **unsound** - it
neither proves nor disproves the GEMM.

**The fix (from the ladder, implemented here):** run Freivalds on the **exact
2-limb PRE-truncation accumulator** `S_i = hi_i·2³¹ + lo_i` (this is `gpu_recon`'s
reconstruction *before* the `/2²⁴` in `gpu_one`, `lm10:80`). `S` is **linear**
in `A` and `x`, so Freivalds is sound on it. The truncation is then verified
**separately** as a per-output remainder range-check.

This is exactly the `gx5a_dot_bridge` GPU==CPU invariant (`reconstruct exact
S = hi·2³¹+lo, THEN apply the trainer's own truncate-divide`) **lifted from one
dot to one projection per checkpoint.**

## 3. How it extends the proven pipeline (reuse, don't reinvent)

| Reused verbatim | From | Role here |
|---|---|---|
| `tgl_exact_matmul` (GPU exact GEMM, 2-limb `[hi,lo]` output) | `stdlib/tensor.rail:255` | the prover: produces the readout accumulators |
| 2-limb reconstruction `hi·2³¹+lo` | `gpu_one`, `lm10:80` / `gx5b:147` | the exact pre-trunc accumulator `S_i` |
| signed two-limb superaccumulator `add/acc_a/acc_b/norm` | `gx1_superaccum.rail:17-39` | computes `rᵀS` and `(rᵀA)·v` (both overflow int63) |
| `sha256_hex` + `hex_to_bytes`/`arr_get` | `stdlib/sha256.rail`, `stdlib/bytes.rail` | Fiat-Shamir challenge derivation |
| Q.24 fixed-point (`s = 2²⁴`), truncate-toward-zero `/` | the trainer's scale | identical truncation semantics |
| foreign cross-language re-verification pattern | `lm10_foreign_check.py` / `utterance_foreign_check.py` | `r31_foreign_check.py` |

The GEMM here uses the **real readout shapes** (`m=64` rows x `k=128`, signed
Q.24-scale values) so each single GPU dot stays exact (`|S_i| < 2⁵¹ < 2⁶²`) while
the **projection sums genuinely overflow int63** (`rᵀS ~ 2⁶⁷`), forcing the
two-limb path - the named wall is *exercised*, not assumed (witnessed by `gWrap`:
the single-limb sum wraps to a different value than the two-limb reconstruction).

To slot into the live trainer: call `r31_verify rows v Hi Lo` once per checkpoint
on the readout `(w2, h1)` GEMM (the `Hi/Lo` the GPU already produced in
`gpu_matvec`), replacing the per-pair `gpu_d2_readout` loop. The FS challenge
folds into the existing `link = SHA256(prev|epoch|w_hex|loss)` chain as an extra
committed field (`freivalds_ok` per checkpoint), so the succinct check is itself
attested and re-derivable by both witnesses.

## 4. THE COMPOSED SOUNDNESS BOUND (the explicit proof obligation)

The gate demands `Pr[accept | tampered]` over the Freivalds projection **and**
the range-check **jointly** - "an adversary can satisfy one by violating the
other; passing both independently does not bound the composition." Here is the
argument, with the composition closed in **both** directions.

### Notation
- Honest: GPU returns limbs `(hi_i, lo_i)` with `lo_i ∈ [0, 2³¹)` and
  `S_i = hi_i·2³¹ + lo_i = <A_i, v>` exactly.
- The verifier accepts iff **all three** hold:
  - **F (Freivalds):** `rᵀS == (rᵀA)·v`, where `r = FS(H(A,v,S))`, `r_i ∈ [1,2¹⁶]`.
  - **R (remainder range):** for every `i`, `S_i - trunc(S_i)·2²⁴ ∈ (-2²⁴, 2²⁴)`
    and `trunc(S_i)·2²⁴ + rem(S_i) == S_i` (exact reconstruction of the
    quotient/remainder split).
  - **L (limb range):** for every `i`, `lo_i ∈ [0, 2³¹)`.

### Adversary model
A tamper changes the committed limbs `(hi_i, lo_i)` and/or claims a weight matrix
`A'` whose accumulators are not the true `<A'_i, v>`. Partition every tamper:

**Case (i): the reconstructed `S'_i = hi'_i·2³¹ + lo'_i` differs from the true
`<A_i, v>` for at least one `i`.** Then the error vector `e = S' - A·v != 0`.
F tests `rᵀS' == (rᵀA)·v`, i.e. `rᵀe == 0`. With `r` drawn **after** the
commitment is fixed (Fiat-Shamir over `H(A,v,S)`, so the adversary cannot choose
`A,v,S` to fit `r`), fix any coordinate `j` with `e_j != 0`; fixing the other
`r_{≠j}` leaves a linear equation `r_j·e_j = -Σ_{i≠j} r_i e_i` with **at most one
root** `r_j` in the `q = 2¹⁶`-element window. Hence

```
Pr_r[ F accepts | case (i) ]  <=  1/q  =  2⁻¹⁶   (per projection round).
```

**Case (ii): the reconstructed `S'_i == <A_i, v>` for all `i` (Freivalds is
BLIND - the value is unchanged) but a limb/remainder invariant is forged.** The
only way to keep `S_i` fixed while changing the committed limbs is to move mass
between `hi` and `lo`, e.g. `(hi_i-1, lo_i+2³¹)` - which leaves `lo'_i = lo_i+2³¹
∉ [0,2³¹)`, caught by **L with probability 1**. Any forged remainder split that
does not satisfy `q·2²⁴+rem == S` with `|rem|<2²⁴` is caught by **R with
probability 1**. So

```
Pr[ accept | case (ii) ]  =  0   (R and L are deterministic).
```

**Composition.** Every tamper is in (i) ∪ (ii) (either the reconstructed value
changed, or it did not). Therefore, for the single-round verifier shipped here:

```
Pr[ accept | tampered ]  <=  max( 2⁻¹⁶ , 0 )  =  2⁻¹⁶   per checkpoint.
```

The range/limb half contributes **0** to the bound (it is exact), so it cannot be
"satisfied by violating Freivalds" to help the adversary: a value-preserving
forge is forced into case (ii) where R/L catch it deterministically; a
value-changing forge is in case (i) where F catches it w.p. ≥ 1−2⁻¹⁶. **Neither
check can be traded against the other.** This is the joint bound the rung
requires.

### Amplification (path, not vacuous)
The `|fs|<blk>` re-hash already in `r31_fs_coeffs_from` extends to `t`
independent projection rounds (re-hash the digest with a round counter), giving

```
Pr[ accept | tampered ]  <=  2⁻¹⁶ᵗ   (t=4 -> 2⁻⁶⁴, cryptographic).
```

The shipped gate uses `t=1` (2⁻¹⁶ per checkpoint) for the demo; over an `E`-epoch
run with one check per checkpoint the chain-level catch probability for a
persistent tamperer compounds. The honest scope: **the single-round bound is
2⁻¹⁶, not negligible** - production should set `t≥3`. The mechanism is in place;
only the round count is a parameter.

### Honest residual (not swept under the rug)
- The bound assumes `r` is an *unpredictable* function of the commitment. We use
  `H(A,v,S)` (Fiat-Shamir). If a future variant lets the prover see `r` before
  committing `S`, soundness collapses - the FS binding is load-bearing and is why
  the PRNG (Rail int63-overflowing) is **not** used.
- The bound is over the *readout* GEMM only. Other per-step GEMMs (attention QKV,
  MLP) are out of scope for this rung (they remain on the rung-30 spot-check
  path); extending Freivalds to them is mechanical (same exact-2-limb trick) but
  not claimed here.

## 5. The gate (what `validate.sh` enforces)

GREEN iff **both**:
1. The Rail run (`r31_freivalds_gemm.rail`) prints `RUNG 31 PASS` (exit 0). It
   asserts, on a real signed Q.24 GEMM run through the **GPU** `tgl_exact_matmul`:
   - **BRIDGE**: GPU pre-trunc limbs reconstruct to the in-program CPU dots
     (gx5a invariant re-asserted);
   - **GATE 1**: the honest GEMM passes F ∧ R ∧ L;
   - **gWrap**: single-limb int63 `rᵀS` *wraps* vs the two-limb value (the
     two-limb path is load-bearing, not decorative);
   - **gNeg**: negative accumulators are exercised (signed case is real).
2. The foreign verifier (`r31_foreign_check.py`) prints `PASS` (exit 0): from the
   emitted transcript it independently re-derives `r`, recomputes `rᵀS` and
   `(rᵀA)·v` in Python bignum, range-checks, and reproduces every rejection -
   and cross-checks `committed S == foreign A·v` exactly.

## 6. The falsification tests (each MUST reject)

| # | Tamper | Caught by | Why |
|---|---|---|---|
| (a) | `Hi[3] += 1` (S₃ += 2³¹) | **F** | reconstructed S changed -> `rᵀe != 0` w.h.p. (case i) |
| (b) | `Lo[7] += 2²⁴` (one ULP of the quotient) | **F** | S changed; **range alone MISSES it** (same remainder) -> composition non-vacuous |
| (c) | wrong weight row `A[5]` (limbs honest) | **F** | `rᵀA'·v != rᵀS` - models "claims weights W' but accumulators are from W" (case i) |
| (d) | `Lo[2] += 12345` (sub-2²⁴) | **F** | reconstructed S changed -> caught (case i) |
| (e) | `Hi[9]-=1, Lo[9]+=2³¹` (reconstructed S UNCHANGED) | **L** | **Freivalds-BLIND** (`freivalds_blind=1`), but `lo ∉ [0,2³¹)` -> the OTHER composition direction (case ii) |

(a)-(d) exercise case (i) [F]; (e) exercises case (ii) [L] and is the sharp
"satisfies Freivalds, violates the limb invariant" adversary the rung names. (b)
additionally proves the range-check **alone** is insufficient (it accepts the
+2²⁴ tamper), so the AND is doing real work.

A single falsifier passing -> the rung FAILS (the gate is the conjunction).

## 7. EXACT validate command

```bash
bash rungs/r31/validate.sh
```

(Serial: one compile, one GPU run, one Python re-verify. No `self`, no training,
no 8GB arena. Uses `RAIL_ARENA_MB=4096`.)

## 8. Files

- `r31_freivalds_gemm.rail` - the Rail succinct verifier + GPU GEMM + 5 falsifiers.
- `r31_foreign_check.py`     - independent cross-language re-verifier.
- `r31_transcript.txt`       - emitted by the Rail run (A, v, exact pre-trunc S);
                               consumed by the foreign verifier. (A pre-generated
                               copy is checked in so the foreign logic is testable
                               standalone; the Rail run overwrites it.)
- `r31_proof.txt`            - emitted human-readable verdict from the Rail run.
- `validate.sh`              - the serial green-gate driver.

## 9. Soundness obligation - one-line summary

> One Fiat-Shamir projection on the **exact pre-truncation accumulators** (linear
> -> Freivalds-sound) plus a **deterministic** remainder+limb range-check bounds
> `Pr[accept | tampered] <= 2⁻¹⁶` per checkpoint (per round), with the two cases
> (value-changing / value-preserving) covered by F and R∧L respectively so
> neither check can be traded for the other; amplifiable to `2⁻¹⁶ᵗ`.
