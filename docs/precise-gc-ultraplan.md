# Precise GC + Generational + Compacting — Ultraplan

**Status:** approved 2026-04-16. Execution in progress — Track A landed, Track B C5 scaffolding landed.

## Session 1 ship log (2026-04-16)

| Commit | Track | Status | SHA-at-fixed-point |
|---|---|---|---|
| C1 v2.22.0: slot type descriptor scaffolding | A | ✅ 116/116 | 0014ec1c |
| C2 v2.22.1: `_gc_lookup_fn_desc` binary search | A | ✅ 116/116 | a70a9b1a |
| C3 v2.22.2: `_rail_gc` consults descriptor (slots 0/1 precise) | A | ✅ 116/116 | 989edec9 |
| C4 v2.22.3: param/d8 precision from env markers | A | ✅ 116/116 | 7680ca98 |
| C5 v2.23.0: young gen semi-space layout (64MB × 2) | B | ✅ 116/116 | be7a370b |

Track A (precise roots) **COMPLETE**. `_rail_gc` now skips saved x29/x30,
int-typed params, float-typed params, and saved d8 slots. Unknown slots
still fall through to the original tag-filtered scan path — precision
is additive, never unsafe.

**Remaining work (est. 2-3 sessions):**
- C6-C8 (Track B generational runtime): young alloc + Cheney scavenge + write barrier
- C9-C11 (Track C compacting): sliding compaction + forward pointers + auto-trigger
- C12 (Track D polish): tuning + docs + retire `_rail_stack_top` kludge
**Motivation:** BPE segfault post-mortem (`docs/gc-phase0-findings.md`) proved conservative scan is fine for correctness but can't support compaction. Precise roots + compaction are needed for long training runs without `arena_mark`/`reset` workarounds. Generational is the perf win on top.

## Architectural decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Per-function slot type descriptors (NOT shadow stack, NOT per-safepoint stackmaps) | Reuses existing `is_int`/`is_float` env markers. Zero runtime instrumentation. |
| D2 | 2 bits/slot encoding: `00=int`, `01=float`, `10=heap`, `11=fallback-to-tag` | Unknown slots get conservative check, never unsafe. |
| D3 | Descriptor lookup by return-address binary search | Sorted table: ~335 fns → ~9-level search. |
| D4 | `RAIL_GC_MODE=precise\|conservative\|both` during rollout | `both` validates precise is a SUBSET of conservative — fast regression detection. |
| D5 | Young gen = Cheney copying, 64MB default | Proven in Track C (WASM). |
| D6 | Promotion at 2 survivals | Standard. |
| D7 | Old gen = mark-sweep + sliding compaction at fragmentation threshold (>30% gap density) | Keeps existing free-list path. |
| D8 | Jonkers sliding compaction, not copying | 50% copying waste unacceptable for 512MB arena. |
| D9 | Forward pointer in bit 62 of header (63=mark, 0-7=tag, 8-31=size) | Reuses existing header word. |
| D10 | Write barrier on `arr_set` / `float_arr_set` only | Rail is mostly immutable. These are the only old→young creation paths. |
| D11 | Card marking: 1 byte per 512 bytes of old gen | Simple, cache-friendly. 128KB card table. |
| D12 | REPL and rail_safe opt out via `RAIL_GC_MODE=conservative` | Compiler-as-service wants determinism during hardening. |

## Commit sequence (12 commits, 4 tracks)

### Track A — Precise roots (Phase 1)
- **C1** v2.22.0: emit slot type descriptors (scaffolding, no consumer)
- **C2** v2.22.1: `_gc_lookup_fn_desc` binary-search helper
- **C3** v2.22.2: GC consults descriptor; `RAIL_GC_MODE=both` validation
- **C4** v2.22.3: precision default; retire `_rail_stack_top` kludge

### Track B — Generational (Phase 2)
- **C5** v2.23.0: young gen semi-space + Cheney scavenge + promotion
- **C6** v2.23.1: write barrier at arr_set / float_arr_set
- **C7** v2.23.2: card marking remembered set
- **C8** v2.23.3: minor GC in `_rail_alloc` slow path

### Track C — Compacting (Phase 3)
- **C9** v2.24.0: sliding compaction (Jonkers) over old gen
- **C10** v2.24.1: bit-62 forward pointer encoding stable across all traversal paths
- **C11** v2.24.2: compaction auto-trigger at fragmentation threshold

### Track D — Polish (Phase 4)
- **C12** v2.24.3: docs + tuning + perf numbers

## Gate at every commit

1. `./rail_native test` → 113/113
2. `./rail_native self && cmp rail_native /tmp/rail_self` → byte-identical
3. Phase-specific smoke (see per-phase doc)
4. `./rail_native run tools/train/three_class_mlp.rail` → 100%

Regression = rollback that commit, diagnose, retry.

## Descriptor table format (C1)

```
.data
.p2align 3
_gc_desc_table_start:
  ; N × 32-byte entries (sorted by fn_start_pc)
  .quad .Lfn_<name>_start    ; 8 bytes
  .quad .Lfn_<name>_end      ; 8 bytes
  .long <nslots>              ; 4 bytes
  .long <bits_packed>         ; 4 bytes (16 slots × 2 bits)
  .quad 0                     ; 8 bytes padding
_gc_desc_table_end:
```

Count computed at runtime: `(end - start) / 32`.

In C1 all `bits_packed = 0xffffffff` (all slots marked "fallback-to-tag" = same behavior as current conservative scan). This ships the plumbing with zero behavior change.

## Lookup helper contract (C2)

```
_gc_lookup_fn_desc: x0 = PC → x0 = record pointer or 0
```

Binary search over `[_gc_desc_table_start+8 .. _gc_desc_table_end)` as 32-byte entries. Miss returns 0 → caller falls back to current conservative per-slot tag-check.

## Rollback per phase

- **C1-C4**: `RAIL_GC_MODE=conservative` bypasses precision. One env var = revert.
- **C5-C8**: `_rail_young_end = _rail_young_base` → young overflows immediately → everything goes to old gen. One-line patch.
- **C9-C11**: `_rail_compact_enable = 0` → compaction skipped. One-line patch.

Worst case: `git revert C1..C12` — all commits are additive.

## Success metrics (measured at C12)

1. BPE train 500 iterations without `arena_mark`/`reset`, RSS < 50MB
2. seq=1499 lm_transformer 10k steps, no OOM
3. Self-compile wall time ≤ current +5%
4. fib(40) wall time ≤ current +1%
5. three_class_mlp final accuracy = 100%
6. RSS at BPE peak < 50% of pre-GC peak (compaction dividend)
7. No new `arena_mark`/`reset` workarounds shipped in any stdlib

## Settled questions (from approval)

1. Version numbering: v2.22.0+ incremental.
2. Young gen size: 64MB fixed; adaptive in C8.
3. `RAIL_GC_MODE=both` validation: 1 merged C3 cycle, then C4 retires.
4. `rail_safe` opts in to precision (same code path).
5. Perf bench: fresh `tools/bench/gc_perf.rail`.
6. Test schedule: full gate every commit.
