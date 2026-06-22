# Independent verification: closing the trusting-trust gap

[THREAT_MODEL.md](THREAT_MODEL.md) names the one gap Rail's self-hosting does not
close: **a Rail compiler verifying a Rail compiler is not independent.** A
byte-identical self-compile proves a fixed point exists; it does not prove the seed
binary faithfully implements its source. A malicious seed could reproduce itself
byte-for-byte while miscompiling a target (Thompson's "trusting trust"). This is the
design for an *independent* check. It is a plan, not yet a guarantee.

## The threat, precisely

A trojaned `rail_native` that (a) miscompiles some program P and (b) re-inserts (a)
when it compiles `compile.rail`. Reproducible builds do not catch this — the trojan
reproduces itself. The source is auditable, so a *source* trojan is out of scope;
the danger is a **binary** behaviour absent from the source.

## Options, by how much independence they actually buy

### Option A — Non-Rail reference interpreter + differential testing  ★ recommended first
Implement a small interpreter for a **frozen Rail-core subset** in a *different
language* (e.g. Python), covering the constructs the test + conformance corpora use
(ints, lists, tuples, ADTs, pattern match, closures, the core builtins). Run every
corpus program through **both** `rail_native` (compile → run) and the independent
interpreter, and diff the outputs.

- **Independence: genuine** (different language, different author-path). A trojaned
  seed that miscompiles a covered program P diverges from the interpreter → detected.
- **Coverage: partial** — whatever the interpreter + corpus exercise. Grows over time.
- **Cost: low**, and it reuses the existing 178-test + `tools/test/conformance/` corpus.
- **Note:** this is the one component that *must not* be Rail — independence requires
  a non-Rail implementation. It is a deliberate, justified exception to the
  Rail-on-Rail convention, not a violation.

### Option B — Diverse Double-Compilation via the x86_64 backend
Cross-compile `compile.rail` with the x86_64 backend → `M_x86`; run `M_x86` to
compile `compile.rail` back to ARM64 → `O`; compare `O` to the normal ARM64
self-compile.

- **Independence: weak for this threat.** `M_x86` is produced *by the same ARM64
  seed*, so a seed-resident trojan is inherited. This checks **ARM64-vs-x86 codegen
  agreement** (genuinely useful for *correctness* / differential miscompilation), but
  does **not** defeat a trojan living in the seed.
- **Cost: low** — reuses the existing x86_64 backend. Good as a complementary
  cross-backend consistency check, not as the trusting-trust answer.

### Option C — Independently-bootstrapped second seed
A minimal bootstrap chain from a tiny, hand-auditable core (à la bootstrappable.org /
GNU Mes / Wheeler's DDC with a genuinely different compiler).

- **Independence: strongest.** Also the most work; long-term goal.

## Recommended phased plan

1. **Phase 3a (Option A)** — the non-Rail reference interpreter + differential run over
   the corpus. Genuine independence, tractable, reuses the conformance suite.
2. **Phase 3b (Option B)** — wire the x86 cross-compile diff as a complementary
   cross-backend consistency check in CI.
3. **Phase 3c (Option C)** — a minimal independently-bootstrapped core, when warranted.

## What to claim (and not) once 3a exists

> Every corpus program produces identical output under `rail_native` and an
> independent non-Rail interpreter — so a seed trojan affecting any covered program
> would have to also corrupt the independent checker, which it cannot reach.

Not "the compiler is proven correct." Coverage is the corpus; the claim is bounded by
it, and [STATUS.md](STATUS.md) / [VERIFY.md](../VERIFY.md) should state that bound.

## Decision needed before the prototype (Phase 3b/3c-independent #11)

The reference interpreter introduces **non-Rail code** into the repo for the first
time on purpose. That is the right call for an independence checker, but it deviates
from the Rail-on-Rail convention and should be an explicit, owned decision — hence
the prototype is gated.
