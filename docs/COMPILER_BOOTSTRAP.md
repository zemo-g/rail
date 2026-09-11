# Modifying the compiler

Moved out of CLAUDE.md on 2026-09-11 so it is read only when tools/compile.rail is being edited.


After editing `tools/compile.rail` (prefix every `self` with `RAIL_ARENA_MB=6000`: the
inlined linker makes the compiler bigger; default rail-link path needs the arena):
1. `RAIL_ARENA_MB=6000 ./rail_native self`: self-compile (in-process rail-link)
2. `cp /tmp/rail_self rail_native`: install new binary
3. `./rail_native test`: verify 203/203
4. `RAIL_ARENA_MB=6000 ./rail_native self && cmp rail_native /tmp/rail_self`: verify fixed point. **Needs ≥2 cycles**: gen0's shipped runtime asm doesn't necessarily match what gen0's source emits, so cycle 1 typically differs. Cycle 2 always lands the byte-identical fixed point (gen2 == gen3 == gen4). See `notes/bootstrap_convergence_audit_2026-05-13.md` for the empirical proof. Verify by running self twice after installing and `cmp`-ing the two outputs.

**NOTE**: Self-compile works cleanly since the 256MB stack fix. No gen2_head bootstrap needed.

**IMPORTANT**: If you change the runtime (`rt_core`, `rt_list`, `rt_string`, etc.), the old binary generates the old runtime. You must bootstrap: compile → install → compile again with new binary.

**DATA SECTION BUG**: Changes to the `data` string literal in `compile_program` may not propagate. If you need new data section labels, construct strings at runtime via `malloc` + byte stores in the ARM64 assembly instead. See polymorphic show implementation in `rshow` for the pattern.

**BOOTSTRAP CYCLE PATTERN**: The self-hosting bootstrap has subtleties that have wasted hours. Use this mental model:

| Edit type | Cycles needed | Why |
|---|---|---|
| Source-only logic (e.g., `all_params_int` predicate, parser branches) | **1 cycle** | Compile-time decisions take effect when next binary parses code |
| String literals embedded in `rt_*` runtime asm constants (e.g., `_rail_alloc` body) | **2 cycles** | Cycle 1 puts new strings in data section; cycle 2's emit USES them as runtime |
| New runtime functions or data section symbols | **2 cycles** | Same: needs cycle 2 to bake the new emit pattern |
| Both source + runtime asm in one edit | **2 cycles** | Source effect is immediate; runtime effect needs one more |
| Verifying byte-identical fixed point | **3 cycles** | Cycle 3 compares to cycle 2 to prove convergence |

**Diagnostic pattern**: After bootstrapping, if your edit doesn't seem to take, check:

1. `grep <new-symbol-or-string> tools/compile.rail`: confirm source has it
2. `grep <new-symbol-or-string> /tmp/rail_self.s`: confirm asm output has it
3. `nm rail_native | grep <symbol>`: confirm binary has it
4. Test the actual behavior

If steps 1–3 pass but 4 fails, you probably need another cycle. If step 2 fails despite step 1 passing, the running compiler doesn't know how to emit your new construct: that's almost always "cycle 1 has the new strings in data, but its compile_program function still uses the old data_section_asm or runtime_asm constant". Run cycle 2 to land it.

**ASCII-only inside string literals emitted to asm**: avoid em-dashes (,), curly quotes, etc. inside any string that flows into `.asciz` output. The lexer handles UTF-8 in literals but the assembler can be unhappy with multi-byte content in some contexts. Use `-` (hyphen-minus) and `'` (apostrophe). Comments (outside string literals) can use anything Unicode you want.

