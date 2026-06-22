# Independent verification (the one non-Rail corner)

This directory is, by deliberate design, the **only non-Rail code in the repo**.

[`docs/INDEPENDENCE.md`](../../docs/INDEPENDENCE.md) explains why: Rail's
byte-identical self-hosting proves a fixed point exists, but it does **not**
defeat a trusting-trust attack — a malicious seed could reproduce itself
byte-for-byte while miscompiling a target. A Rail compiler verifying a Rail
compiler is not *independent*. The independent check therefore has to be written
in a different language, by a different code path. That is what lives here.

This is a deliberate, owned exception to the repo's Rail-on-Rail convention — and
the exception is the whole point.

## `ddc_int.py` — independent differential checker (Option A, prototype)

A small **Python** evaluator for a frozen Rail-core integer subset, run
differentially against `rail_native`:

1. build a random AST (Python),
2. pretty-print it to Rail source, compile + run it with `rail_native`,
3. evaluate the *same* AST with the Python evaluator,
4. diff the two results.

```bash
python3 tools/independence/ddc_int.py --seed 1 --n 200
# exit 0 = all agree, 2 = at least one divergence
```

A divergence between `rail_native` and an evaluator it cannot influence is
evidence of a codegen bug that a trojaned seed could not hide. Agreement is
**independent corroboration** — not a proof of correctness, and bounded to the
covered subset.

### Frozen subset

```
E ::= int[-7..7] | var | (E + E) | (E - E) | (E * E)
    | (let x = E in E) | (if E < E then E else E)
```

Literals are bounded so neither Python's bignums nor Rail's 63-bit tagged ints
overflow — keeping the two semantics provably identical on this subset. (`/`,
`%`, and floats are intentionally excluded until their signed-division /
signed-zero semantics are pinned, so the oracle never reports a false divergence.
See `docs/INDEPENDENCE.md`.)

### Status & extension path

Prototype (Phase 3a). Genuine independence over the int core. Natural extensions,
each of which widens the corroborated subset:

- pin signed `/` and `%` semantics, then add them;
- lists + `head`/`tail`/`length`/`fold`/`map`;
- named functions and multi-arg calls;
- run the existing `tools/test/conformance/` programs through it directly.

It complements — does not replace — the in-repo differential fuzzer
(`tools/fuzz/diff_fuzz.rail`), whose reference evaluator is Rail (fast, broad, but
*not* independent). This one is narrow but independent.
