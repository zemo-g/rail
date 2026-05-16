# Data-section literal-string propagation (A5 diagnostic)

## What CLAUDE.md says

> Changes to the `data` string literal in `compile_program` may not propagate. If you need new data section labels, construct strings at runtime via `malloc` + byte stores in the ARM64 assembly instead.

## What this actually is

Not a bug. A property of self-hosting bootstrap.

When you edit the `data` field of `compile_program` in `tools/compile.rail`, the *running* `rail_native` binary still has the *old* data baked into its own `.data` section. It will emit the old bytes when it compiles itself. The new bytes only appear after one bootstrap cycle:

1. `./rail_native self` → produces `/tmp/rail_self` (still using old data because the running binary's data section is the old one)
2. `cp /tmp/rail_self ./rail_native && codesign -s - --force ./rail_native`
3. `./rail_native self` → now produces `/tmp/rail_self` with the new data

This is exactly the same "two-phase install" problem that affects any self-compiling change to the runtime asm or to literals embedded in the compiler. It's documented in `tools/compile.rail` (line 132 of CLAUDE.md) under "If you change the runtime" with the same prescription.

## Repro to confirm it's a bootstrap quirk and nothing more

```bash
# Edit a literal string in compile.rail's data section
# Run self-compile once
./rail_native self
strings /tmp/rail_self | grep <new-literal>   # likely empty (old binary, old data)
# Install
cp /tmp/rail_self ./rail_native
codesign -s - --force ./rail_native
# Self-compile again
./rail_native self
strings /tmp/rail_self | grep <new-literal>   # now present
```

If the literal appears after step 2, the system is working as designed.

## When the workaround (runtime malloc + byte stores) is needed

You only need `malloc + byte stores` when you cannot afford a bootstrap cycle (e.g., you're in the middle of a multi-step debug and can't risk an intermediate-broken binary). For ordinary changes, just bootstrap.

## Recommendation

No code change. Update CLAUDE.md to reframe the note as "bootstrap quirk, not bug" so future readers don't think there's broken behavior to fix. The workaround section can stay; it's a real recipe.

## Verdict on the backlog item

**A5 closed as "won't fix — documented expected behavior."** No regression risk, no perf impact, has a recipe for the rare case it matters. Backlog ranking marked low EV; this confirms the EV is functionally zero.
