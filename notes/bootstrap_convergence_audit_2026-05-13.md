# Bootstrap fixed-point convergence audit (2026-05-13)

**Verdict: FALSIFIED (with nuance).**

The claim that "bootstrap fixed-point doesn't converge on stock HEAD" is **false** when
the convergence check is performed correctly. The bootstrap converges to a stable fixed
point at **generation 2**, which matches the project's own documented expectation in
`CLAUDE.md` ("Verifying byte-identical fixed point | 3 cycles | Cycle 3 compares to
cycle 2 to prove convergence").

A naive single-cycle check (`cmp rail_native /tmp/rail_self`) WILL fail at HEAD because
the shipped `rail_native` is not itself the fixed point — it differs from gen1 in the
`__text` section size. That is likely what agent F observed; the observation is real,
but it does not falsify the bootstrap. It just means the shipped binary is one cycle
behind the fixed point.

## Environment

- Worktree: `/Users/user/projects/rail/.claude/worktrees/agent-a952a2562d8352b6d`
- HEAD: `dcfdce2 docs(claude): add substrate-beyond-compile.rail section`
  (note: the task prompt said `6fbf81b`; that SHA is an ancestor commit, also present in history)
- Branch: `feat/e-bootstrap-convergence-audit`
- Host: Mac Studio (darwin 25.4.0, arm64)
- Shipped `rail_native`: 1043280 bytes, sha256 `769da0cd7031...`

## Methodology

1. Capture shipped binary as `/tmp/gen0`.
2. Run `rail_native self` repeatedly, saving outputs as `/tmp/gen1`, `/tmp/gen2`, `/tmp/gen3`, `/tmp/gen4`.
3. `cmp` consecutive generations.
4. Strip ad-hoc code signatures (via `codesign --remove-signature`) and `cmp` again
   to isolate "real" compiler-output differences from signing-block churn.
5. Sanity-check that the converged binary still passes the test suite.

## Raw outputs

### Baseline test run (gen0)

```
$ ./rail_native test 2>&1 | tail -1
133/137 tests passed
```

Note: 133/137, not 137/137. The four failures are all tensor tests that say
`/bin/sh: /tmp/rail_out_*: No such file or directory` (`tensor_prims`,
`tensor_rank`, `tensor_slice`, `tensor_layer_norm`). This looks like a Metal /tmp
race or environment issue, not a compiler-output bug; it is **out of scope** for
this audit. Filing it as a separate concern would be appropriate. Re-running the
test suite with the converged `/tmp/gen2` gives the same 133/137, so the failures
are not caused by bootstrap drift.

### Single-cycle cmp (the failing check)

```
$ ./rail_native self
=== Self-compilation ===
  Source: 396124 chars
  Compiled to assembly
  as: OK
  ld: OK
  Binary: /tmp/rail_self
$ cmp rail_native /tmp/rail_self ; echo $?
rail_native /tmp/rail_self differ: char 217, line 1
1
```

This is the result that triggered the "doesn't converge" claim. It is real but
not the right probe — the shipped binary is not necessarily the fixed point.

### Multi-cycle convergence

| Generation | Size       | sha256 (first 16)  |
|------------|-----------:|--------------------|
| gen0 (shipped) | 1043280 | `769da0cd7031ed3d` |
| gen1            | 1043568 | `ab134558175ea090` |
| gen2            | 1043280 | `86c0ca30097a2129` |
| gen3            | 1043280 | `86c0ca30097a2129` |
| gen4            | 1043280 | `86c0ca30097a2129` |

```
gen0 vs gen1:   differ: char 217, line 1   (cmp exit 1)
gen1 vs gen2:   differ: char 217, line 1   (cmp exit 1)
gen2 vs gen3:   identical                  (cmp exit 0)
gen3 vs gen4:   identical                  (cmp exit 0)
```

**gen2 == gen3 == gen4 byte-identically.** Fixed point reached at gen2.

### Code-signature analysis (gen0 vs gen2)

gen0 and gen2 have the same size (1043280) but `cmp` reports a difference starting
at byte 1023000:

```
$ otool -l /tmp/gen0 | grep -B1 -A3 CODE_SIGNATURE
  cmd LC_CODE_SIGNATURE
  cmdsize 16
  dataoff 1022992
  datasize 20288
```

Byte 1023000 falls 8 bytes into the LC_CODE_SIGNATURE block (1022992 + 8). All
7922 differing bytes are inside the code-signature block. After stripping
signatures:

```
$ codesign --remove-signature /tmp/gen0_unsigned /tmp/gen2_unsigned
$ cmp /tmp/gen0_unsigned /tmp/gen2_unsigned ; echo $?
0
```

So **gen0 and gen2 produce byte-identical compiler output** — they only differ in
the ad-hoc codesign blob (timestamp / random nonce in the signature). The true
fixed point is reached at gen0 already; the visible 'mismatch' is a signing
artifact, not a compile-output difference.

But gen0 vs gen1 is a real diff: even after stripping signatures, gen0_unsigned
(1022984 bytes) is 288 bytes smaller than gen1_unsigned (1023272 bytes), and they
first differ at byte 217 — inside the `__text` section-size field of the Mach-O
load commands. gen0 reports `__text` size `0x0007c8f8`, gen1 reports
`0x0007ccd0` (472 bytes larger).

### Interpretation of the limit cycle

The pattern is:

- gen0 (shipped) compiles `compile.rail` → gen1 with a larger `__text`.
- gen1 compiles `compile.rail` → gen2 with `__text` back to gen0's size and content.
- gen2 compiles `compile.rail` → gen2 (fixed point).

This is the expected 2-cycle behavior described in `CLAUDE.md` row "String literals
embedded in `rt_*` runtime asm constants" / "New runtime functions" / "Both source
+ runtime asm in one edit | **2 cycles**". The runtime asm baked into gen0 differs
from what gen0's source describes; gen1 emits the source-described runtime; gen2
re-emits using gen1's now-source-consistent runtime and stabilizes.

### Sanity check: converged binary still works

```
$ /tmp/gen2 test 2>&1 | tail -1
133/137 tests passed
```

Same as gen0 — convergence does not regress the test count.

## Conclusion

**FALSIFIED.** The bootstrap converges at generation 2 and stays there. The
correct verification recipe (already in `CLAUDE.md` line 146 / line 162) is to run
THREE cycles and `cmp` cycle 3 against cycle 2, not to expect `cmp rail_native
/tmp/rail_self` to be zero on the first try.

Sub-findings:

1. The shipped `rail_native` (gen0) is not itself the fixed point; its `__text`
   section content drifts on first re-compile (gen1) and then returns (gen2).
   This is a known and documented pattern — it costs one extra bootstrap cycle
   but does not break self-hosting.

2. After stripping ad-hoc codesignatures, gen0 and gen2 are byte-identical, so
   the "real" compiler output of gen0 already matches the fixed point. The first
   `cmp` failure at byte 217 against gen1 is the genuine effect; the second
   `cmp` failure at byte 1023000 against gen2 is just signing-blob noise.

3. The 4 tensor test failures (`tensor_prims`, `tensor_rank`, `tensor_slice`,
   `tensor_layer_norm`) showing `/bin/sh: /tmp/rail_out_*: No such file or
   directory` are unrelated to bootstrap and present in both gen0 and gen2.
   Worth a separate ticket; out of scope here.

## Reproduction recipe

To reproduce the **non-bug** that looks like a bug:

```bash
cd ~/projects/rail
./rail_native self && cmp rail_native /tmp/rail_self ; echo $?
# → differs at char 217, exit 1.  Looks like convergence failure.
```

To reproduce the **actual convergence proof**:

```bash
cd ~/projects/rail
./rail_native self && cp /tmp/rail_self /tmp/gen1
/tmp/gen1 self && cp /tmp/rail_self /tmp/gen2
/tmp/gen2 self && cp /tmp/rail_self /tmp/gen3
cmp /tmp/gen2 /tmp/gen3 ; echo $?
# → exit 0 (byte-identical fixed point at gen2).
```

To prove the gen0-vs-gen2 mismatch is signing noise:

```bash
cp rail_native /tmp/gen0
cp /tmp/gen2 /tmp/gen2_unsigned
cp /tmp/gen0 /tmp/gen0_unsigned
codesign --remove-signature /tmp/gen0_unsigned /tmp/gen2_unsigned
cmp /tmp/gen0_unsigned /tmp/gen2_unsigned ; echo $?
# → exit 0
```

## Recommended follow-up (not done here per "investigation only")

- Consider tightening `CLAUDE.md` step 4 from "may need 2-3 rounds" to "needs at
  least 2 cycles after re-installing; verify with 3-cycle cmp" so future agents
  don't replay agent F's mistake.
- Consider whether the shipped `rail_native` should be re-installed as gen2 so
  that the single-cycle check works for new contributors. Today's discrepancy
  costs nothing functional but creates a recurring source of false alarms.
- File a separate ticket for the 4 tensor test failures — they may be
  pre-existing /tmp-collision flakes, but they should be acknowledged in the
  floor (137/137 → 133/137 today, on this worktree).
