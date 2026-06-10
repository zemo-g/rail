---
name: Rail GC — Implementation Plan
description: Garbage collector design for Rail — conservative mark-sweep, replaces 256MB bump allocator, fixes test flakiness and program size limits
type: project
---

## Rail GC Implementation Plan (2026-03-20)

**Why:** The 256MB bump allocator is Rail's biggest constraint. Tests are non-deterministic (20-67/67 per run), large programs segfault, self_train needs one-process-per-round, gen_site.rail needs incremental file writes. A GC removes ALL of these limits.
**How to apply:** Follow this plan in a dedicated session. Read `tools/compile.rail` first — the allocator is at line 1224, heap init at line 1402.

---

### Current Architecture

```
_rail_heap:      256MB BSS block (.zerofill)
_rail_heap_ptr:  bump pointer (monotonically increases)
_rail_alloc:     bump ptr += size (8-byte aligned), return old ptr
arena_mark:      save heap_ptr
arena_reset:     restore heap_ptr (reclaims everything allocated since mark)
```

No free. No reuse. No bounds check. When ptr hits end of 256MB → segfault.

### Object Tags (already in place — GC can trace these)

| Tag | Type | Layout |
|-----|------|--------|
| 1 | Cons (list node) | `[1, head, tail]` — 24 bytes |
| 2 | Nil (empty list) | `[2]` — 8 bytes (singleton) |
| 3 | Tuple | `[3, elem0, elem1, ...]` — 8 + N*8 bytes |
| 4 | Closure | `[4, fn_ptr, num_caps, cap0, cap1, ...]` — 24 + N*8 bytes |
| 5 | ADT | `[5, ctor_idx, field0, field1, ...]` — 16 + N*8 bytes |
| 6 | Float | `[6, f64_value]` — 16 bytes |

Integers: tagged inline (LSB=1, value in upper 63 bits) — NOT on heap.
Strings: C pointers to either .rodata (static) or arena-allocated buffers (no tag).

### Key Insight: Rail Is Pure Functional = No Cycles

Rail has no mutation. Closures capture by value. The reference graph is always a DAG. This means:
- **Reference counting would work** (no cycle detection needed)
- **Mark-sweep is simpler** (no weak refs, no finalizers)
- **Copying GC is ideal** (compaction is free, no fragmentation)

### Recommended: Conservative Mark-Sweep

**Why conservative**: We don't have precise stack maps. The compiler doesn't track which stack slots contain pointers. Conservative scanning treats anything that looks like a heap pointer as a root.

**Algorithm:**
1. **Mark phase**: Walk the stack (scan frame from sp to x29 chain), scan global `_rail_heap_ptr` region. For each value that falls within [heap_base, heap_base+256MB], treat as potential pointer. Load tag byte, follow children recursively.
2. **Sweep phase**: Walk heap linearly. Unmarked objects → add to free list (or compact). Clear all mark bits.
3. **Trigger**: When `_rail_alloc` can't satisfy a request, run GC. If GC doesn't free enough, grow heap.

### Implementation Steps

#### Step 1: Add mark bit to objects (~30 min)
- Use bit 63 of the tag word as mark bit (tags are small, never use high bits)
- `mark(obj)`: `obj[0] |= (1 << 63)`
- `is_marked(obj)`: `obj[0] & (1 << 63)`
- `clear_mark(obj)`: `obj[0] &= ~(1 << 63)`

#### Step 2: Write the mark phase (~2h)
```arm64
_rail_gc_mark:
    // Walk stack frames (x29 chain)
    mov x0, x29
.Lmark_frame:
    cbz x0, .Lmark_globals
    // Scan frame: for each 8-byte slot between x0 and [x0] (parent frame)
    ldr x1, [x0]        // parent frame pointer
    add x2, x0, #16     // start of locals (after saved x29, x30)
.Lmark_scan:
    cmp x2, x1
    b.ge .Lmark_next_frame
    ldr x3, [x2]        // potential pointer
    bl _rail_gc_try_mark // if it's a heap ptr, mark it + children
    add x2, x2, #8
    b .Lmark_scan
.Lmark_next_frame:
    ldr x0, [x0]
    b .Lmark_frame
.Lmark_globals:
    // Also scan known globals (nil, etc.)
    ret
```

`_rail_gc_try_mark(ptr)`:
- Check if ptr is in heap range [heap_base, heap_base + heap_size]
- Check if ptr is 8-byte aligned
- Check if already marked → return
- Load tag word. If tag is 1-6, it's a valid object. Mark it.
- Recursively mark children based on tag type.

#### Step 3: Write the sweep phase (~1h)
Two options:
- **Free list**: Walk heap, add unmarked objects to a size-bucketed free list. `_rail_alloc` checks free list before bumping.
- **Compact (simpler)**: Reset heap_ptr to heap_base. Copy marked objects forward (updating pointers). This is essentially a copying collector using the same space.

**Compact is simpler and eliminates fragmentation.** But requires updating ALL pointers — stack, globals, and intra-object references. This is the hardest part.

**Recommendation**: Start with free list. Simpler, no pointer updating needed. Accept some fragmentation. Switch to compacting later if fragmentation becomes an issue.

#### Step 4: Hook into _rail_alloc (~30 min)
```arm64
_rail_alloc:
    // Try bump allocation
    load heap_ptr, try advance
    if fits: return
    // Doesn't fit: run GC
    bl _rail_gc
    // Retry bump allocation
    load heap_ptr, try advance
    if fits: return
    // Still doesn't fit: grow heap (malloc new chunk)
    bl _rail_grow_heap
    // Retry
    ...
```

#### Step 5: Handle strings (~1h)
Strings are the hard case. They're C pointers without tags. Options:
- **Tag all strings**: Allocate a wrapper `[7, char*]` — adds 8 bytes per string, simplest
- **Separate string arena**: Keep strings in their own bump allocator, GC only the tagged heap
- **Conservative**: Treat any pointer into the heap that doesn't have a valid tag as a string — risky

**Recommendation**: Tag strings. Add tag 7 for heap-allocated strings. Static strings (.rodata) don't need GC.

#### Step 6: Update arena_mark/arena_reset (~30 min)
These should still work as a fast path. If you mark/reset within a GC cycle, the reset just moves the bump pointer. The GC only runs when the bump allocator can't satisfy a request.

### Estimated Effort

| Step | Time | Risk |
|------|------|------|
| Add mark bits | 30 min | Low |
| Mark phase (conservative stack scan) | 2-3h | Medium — getting frame scanning right |
| Sweep phase (free list) | 1-2h | Low |
| Hook into allocator | 30 min | Low |
| Tag strings | 1-2h | Medium — many codegen sites to update |
| Test + debug | 2-4h | High — subtle pointer bugs |
| **Total** | **7-12h** | **1-2 sessions** |

### What This Fixes

| Problem | Current | After GC |
|---------|---------|----------|
| Test suite flakiness | 20-67/67 per run | Deterministic 67/67 |
| gen_site.rail segfaults | Needs incremental writes | Just runs |
| self_train.rail | One round per process | Multiple rounds, no restart |
| 65K compiler char limit | Arena overflow on large programs | No limit |
| Long-running servers | Impossible | Possible |

### What Failed (2026-03-20)

Attempted growing arena (Option 1): `malloc` new chunks when bump exhausts. Failed because `arena_mark`/`arena_reset` stores/restores the bump pointer — if the pointer was in chunk A and you reset it, but new allocations went to chunk B, you get use-after-free. The arena_reset semantic fundamentally conflicts with multi-chunk allocation.

Also tried increasing BSS from 256MB to 1GB — macOS doesn't guarantee zeroing of large BSS sections, causing non-deterministic garbage data.

### Pre-requisites

- Read `tools/compile.rail` lines 1220-1240 (runtime assembly)
- Read line 1402 (data section, heap declaration)
- Understand tagged pointer scheme (LSB=1 for ints)
- Run `./rail_native test` a few times to see the flakiness baseline
