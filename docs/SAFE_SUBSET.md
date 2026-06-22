# Rail attested subset

A *verifiable* / *replayable* computation must be hermetic and deterministic: the
same inputs must produce the same bytes, with nothing reaching outside the
sandbox. Rail's full language is deliberately larger than that — it has FFI, a
shell, raw pointers, and compile-time codegen. This page draws the line.

## Inside the attested subset (hermetic, deterministic)

- Pure Rail: functions, ADTs, pattern matching, closures, lists, tuples, strings.
- Integer / fixed-point arithmetic (exact; see [NUMERICS.md](NUMERICS.md)).
- IEEE 754 doubles **within one platform** (deterministic, fixed reduction order).
- GC-managed memory (`cons`, `arr_new`/`arr_get`/`arr_set`, the bump arena +
  conservative GC).
- File reads of pinned inputs, deterministic string ops.

Code in this subset is reproducible: re-running it on the same platform yields
byte-identical results, which is what attestation signs over.

## Outside the attested subset

These compile and are useful, but they break hermeticity or determinism. A program
that uses them **cannot** be treated as a reproducible/attested computation without
additional pinning, and a result derived through them is not covered by the
reproducibility claim.

| Construct | Why it's outside |
|---|---|
| `foreign` (FFI) | Calls host code; results depend on the host library/version. Can return raw pointers that bypass Rail's object model. |
| `shell` | Runs arbitrary host commands — fully non-hermetic and non-deterministic. |
| raw pointer returns (`-> ptr` / `-> str`) | Escape Rail's GC'd value model; lifetime/aliasing are unchecked. |
| `arena_reset` | Manually invalidates allocations after a mark; misuse creates dangling references. |
| `rc_alloc` / `rc_retain` / `rc_release` | Manual reference counting outside the GC; correctness is the caller's burden. |
| `#generate` / compile-time LLM codegen | Non-deterministic and non-hermetic; splices model-generated code at build time. |
| host **libm** (`sin`/`cos`/`sqrt`/…) | Not correctly-rounded; not bit-identical across platforms ([NUMERICS.md](NUMERICS.md)). |
| Metal / GPU JIT | Kernel determinism (FMA, reduction order, denormals) is not guaranteed by default. |

## Rule of thumb

If a computation is meant to be **attested or independently reproduced**, keep it
inside the subset and pin its inputs. If it must step outside (e.g. GPU training, an
HTTPS fetch), the hermetic boundary moves to the *artifact* it produces — pin and
sign that artifact, and treat the non-hermetic step as trusted input, not as part of
the verified computation.

A future `tools/lint/check_quirks.rail` pass can flag out-of-subset constructs in
code annotated as attested; today the boundary is enforced by convention and review.
