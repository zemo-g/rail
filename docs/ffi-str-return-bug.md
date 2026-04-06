# The `foreign ... -> str` bug (91/92 → 92/92) ✅ FIXED 2026-04-06

**The failing test:** `ffi_getenv` — was failing on master since before the current session's work. **Now passes.** First 92/92 in the repo's history.

**The fix:** Option A (below) — wrap `str`-returning foreign call return values in `_strdup` so they land in an 8-byte aligned malloc'd buffer. Self-compile: byte-identical fixed point. All stress tests pass. Applied in commit where the README badge flipped to 92/92.

**TL;DR:** Rail's pointer-tagging convention is `LSB=0 → heap pointer, LSB=1 → tagged integer`. This assumes all "heap" values (including strings) are 8-byte or at least 2-byte aligned. But `getenv(3)` returns a pointer into the process's environment strings (`char **environ`), and those pointers can land at **odd byte offsets** inside the environment page. When that pointer has `LSB=1`, Rail's `_rail_print` / `_rail_show` mistakenly dispatch to the integer path, shift the pointer right by 1, and print the mangled "number" instead of the string.

It's non-deterministic — the same Rail binary prints the string correctly when invoked one way and garbage when invoked another way, because the environment layout differs.

---

## Reproduction

```rail
-- /tmp/repro_src.rail
foreign getenv s -> str
main =
  let _ = print (getenv "HOME")
  0
```

```bash
cd ~/projects/rail
./rail_native /tmp/repro_src.rail     # compiles to /tmp/rail_out
mv /tmp/rail_out /tmp/getenv_bin

# Direct run:
/tmp/getenv_bin
# → /Users/ledaticempire      (works)

# Via any shell wrapper:
bash -c /tmp/getenv_bin
# → 3047530103                (BROKEN — different number each run)

sh -c /tmp/getenv_bin
# → 3080068731                (BROKEN — different number again)
```

Even more telling: flip the env var name and the behavior inverts.

```bash
# getenv "USER" instead of "HOME":
/tmp/getenv_bin
# → 3045833732                (BROKEN when run directly)

bash -c /tmp/getenv_bin
# → ledaticempire              (works via bash)
```

Non-deterministic pattern = memory-layout-dependent bug. The difference is **where the environment strings land in the child process's memory** under different invocation paths.

---

## Root cause in the compiler

### The FFI call codegen

`tools/compile.rail:1067-1077`

```rail
let ar_raw = afind fname ar
if ar_raw >= 1000 then
  -- Foreign function call: untag int args, call C function
  let is_ptr_ret = ar_raw >= 2000 && ar_raw < 3000
  let is_float_ret = ar_raw >= 3000
  let (pa, lc1, sl1) = cg_push_args args env ar lc sl fs
  let pop = cg_pop_regs (length args) 0
  let untag = if is_float_ret then untag_float_args (length args) 0 else untag_args (length args) 0
  let retag = if is_ptr_ret then "" else if is_float_ret then "    fmov x0, d0\n" else "    lsl x0, x0, #1\n    orr x0, x0, #1\n"
  let call = cat ["    stp x29, x30, [sp, #-16]!\n    bl _", fname, "\n    ldp x29, x30, [sp], #16\n", retag]
  (cat [pa, pop, untag, call], lc1, sl1)
```

Note line: `let retag = if is_ptr_ret then ""` — when a foreign function returns `str` or `ptr`, **no tagging is applied to `x0`**. The raw C return value is used directly.

### The Rail runtime's tagging convention

Rail encodes values in a single 64-bit word using the low bit:

- `LSB = 1` → tagged integer. `actual_value = x >> 1`
- `LSB = 0` → heap pointer. First 8 bytes at `[x]` are a type header.

`_rail_print` (generated at `tools/compile.rail:2100`):

```asm
_rail_print:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    tst x0, #1             ; test LSB
    b.eq .Lprnt_heap       ; LSB=0 → heap path
    asr x0, x0, #1         ; LSB=1 → integer, untag
    str x0, [sp, #-16]!
    adrp x0, _fmt_int@PAGE
    add x0, x0, _fmt_int@PAGEOFF
    bl _printf
    add sp, sp, #16
    b .Lprnt_done
.Lprnt_heap:
    ldr x1, [x0]           ; read type header
    cmp x1, #6             ; is it a float box?
    b.eq .Lprnt_float
    str x0, [sp, #-16]!
    adrp x0, _fmt_str@PAGE ; fall through: print as %s
    add x0, x0, _fmt_str@PAGEOFF
    bl _printf
    ...
```

`_rail_show` has the same `tst x0, #1` dispatch at the top.

### Why strings work *most* of the time

Rail string literals are emitted as `.asciz` followed by `.p2align 2`. That puts them at 4-byte aligned addresses, which have `LSB=0` and `bit 1 = 0`. Good — the heap path fires, the first 8 bytes of "/Users/l..." are 0x6C2F73726573552F which ≠ 6, and `printf("%s")` runs.

`read_file`, `shell`, `cat`, `join` and friends all go through `_rail_alloc` / `_malloc` which return 8-byte-aligned pointers. LSB always 0. Always takes the heap path. Always works.

### Why `getenv` is special

`getenv(3)` doesn't return a pointer to a malloc'd buffer. It returns a pointer **into the process's environment vector** — specifically, the byte just past the `"KEY="` prefix of one of the strings pointed to by `environ[]`.

On macOS (and Linux), those environment strings are laid out contiguously in a single page written by the dynamic linker at program startup. The page is page-aligned (4KB), but the individual strings are **not** guaranteed to be at any particular byte alignment. A given string starts wherever the previous one ended (plus a null terminator). An env like:

```
_=/Users/ledaticempire/bin/bash
HOME=/Users/ledaticempire
USER=ledaticempire
```

has strings packed end-to-end. The address of `"/Users/ledaticempire"` (what `getenv("HOME")` returns) can land on any byte address — including one with `LSB=1`.

When the returned pointer's LSB is 1, Rail's `_rail_print` dispatches to the integer path, does `asr x0, x0, #1` (losing the low bit of the pointer), and prints the shifted value as `%ld`. The observed garbage numbers (3047530103, 3085590135, ...) are exactly `(original_pointer >> 1)` for a range of `0x100000000`-ish macOS ARM64 heap pointers.

**Direct vs. shell-invocation flips the behavior** because the environment layout differs: `bash -c '/tmp/bin'` prepends its own env vars, shifting all subsequent strings by the length of what came before. HOME's byte address changes parity. Same binary, different alignment, opposite behavior.

### Why other foreign functions are fine

Look at the other FFI tests:

```rail
foreign abs n                            -- returns int; retag applies
foreign strlen s                         -- returns int; retag applies
foreign sqrt x -> float                  -- returns float; fmov from d0
foreign free p                           -- return ignored
```

None of these have the problem, because:

- **Int returns** get re-tagged: `lsl x0, x0, #1; orr x0, x0, #1` — LSB forced to 1
- **Float returns** come back in `d0` and are `fmov`'d
- **Pointer returns for non-string consumers** (like `free`) don't get printed

`getenv` is the only FFI test that returns a `str` AND prints it. The rest of the codebase avoids it without realizing.

---

## The fix

Three options, ordered by invasiveness:

### Option A — `strdup` after the call (smallest change)

Copy the returned string to a malloc'd buffer immediately after the foreign call. `_malloc` returns 8-byte aligned pointers on macOS, so the LSB is guaranteed to be 0.

In `tools/compile.rail` around line 1076:

```rail
let call = if is_ptr_ret then
  cat ["    stp x29, x30, [sp, #-16]!\n    bl _", fname,
       "\n    cbz x0, .Lffi_null_", show lc,
       "\n    bl _strdup\n.Lffi_null_", show lc, ":\n    ldp x29, x30, [sp], #16\n"]
else
  cat ["    stp x29, x30, [sp, #-16]!\n    bl _", fname, "\n    ldp x29, x30, [sp], #16\n", retag]
```

- `cbz x0, .Lffi_null_N` skips the `strdup` if the pointer is null (getenv returns NULL for unset vars)
- `bl _strdup` copies the string to a malloc'd (aligned) buffer
- The malloc'd buffer is leaked — matches Rail's current string-lifetime model (no string freeing)

**Cost:** ~10 lines. Localized to one compiler path. Fixes the bug for every `foreign ... -> str` function. Doesn't touch the runtime or affect other code.

**Downside:** Leaks one malloc'd buffer per FFI string call. For tests and normal use, irrelevant. For hot loops calling `getenv` in a tight loop, slow. Not a use case Rail cares about today.

### Option B — Wrap in a Rail heap box (proper)

Instead of returning the raw C pointer, allocate a heap box via `_rail_alloc`, copy the string into it, and return a pointer to the box. The box has a type header byte so the runtime can distinguish it from an integer without relying on pointer alignment.

Requires:
- New type tag for "string box" (e.g., `7` — float is `6`)
- `_rail_print` / `_rail_show` recognize the new tag and dereference appropriately
- Every `str`-returning FFI call wraps in the box

**Cost:** ~40 lines in compile.rail + runtime. Touches the runtime, so bootstrap care required.

**Benefit:** Aligns with how floats already work (`.Lprnt_float` reads `[x0, #8]` after checking tag 6). Consistent pattern. Fixes potential future bugs with other FFI calls that return non-aligned pointers.

### Option C — Change Rail's tagging scheme to 2-bit or 3-bit

Use the low 2 or 3 bits of every value as a type tag. Aligns with OCaml, V8, Lua, JuliaVM, etc. Rail would have room for `int`, `pointer`, `string`, `float`, `symbol` etc. without the alignment assumption.

**Cost:** Every arithmetic operation in the compiler needs updating. Runtime needs updating. Multi-day rewrite. Out of scope for fixing one test.

---

## Recommended fix: Option A

Small, localized, no runtime changes, fixes `ffi_getenv` and any future `foreign ... -> str` users. Add the 10 lines to `tools/compile.rail`, self-compile, verify fixed point, run the test suite — should see 92/92.

### Verification steps after the fix

```bash
cd ~/projects/rail
./rail_native self                    # self-compile (expect success)
cp /tmp/rail_self rail_native         # install
./rail_native self                    # compile again → byte-identical
diff rail_native /tmp/rail_self       # must be empty
./rail_native test                    # expect 92/92 for the first time
./rail_native run tools/plasma/d8_test.rail        # still 5/5
./rail_native run tools/plasma/float_bug_test.rail # still 7/7
```

Also verify the failing reproduction case:

```bash
./rail_native /tmp/repro_src.rail > /dev/null
mv /tmp/rail_out /tmp/getenv_bin
/tmp/getenv_bin                       # /Users/ledaticempire
bash -c /tmp/getenv_bin               # /Users/ledaticempire (was garbage)
```

Run the test a few times and with different env var names (`HOME`, `USER`, `PATH`, `SHELL`) to confirm the non-determinism is gone.

### Edge cases to check

- `getenv` of a missing env var returns `NULL`. The `cbz x0, .Lffi_null_N` guard handles that — we skip `strdup` and `x0` remains `NULL`. Then `_rail_print` would try to `ldr x1, [0]` and segfault. So the NULL case still needs handling at the print level, or the fix should return a static empty string pointer.
  - Fix: in the null branch, load `adrp x0, _rail_empty_str@PAGE` instead of passing through.
- String literals passed TO foreign functions go through `untag_args`, which uses `tst` + `csel` to skip the shift when LSB is 0. Already correct, no changes needed.
- Other `foreign ... -> str` users in the codebase? None currently. This bug only affects the `ffi_getenv` test. Fixing it is purely a correctness improvement; no existing code relies on the broken behavior.

---

## Why this was off the radar

- The test has been failing since before the current session's work. The CI was checking for `70/70 tests passed` (even staler) until tonight. After updating CI to `91/92`, the failing test became the documented baseline.
- Nobody uses `foreign ... -> str` in practice. The Rail stdlib uses `read_file`, `shell`, and friends — all of which allocate their strings via `_rail_alloc` (aligned), not via OS APIs returning pointers into system memory.
- The fact that the test sometimes passes by coincidence (when environment layout happens to produce an LSB=0 pointer for HOME) means the breakage isn't consistent across machines. On some developer's machine it might pass. On CI it fails.

It's a **latent correctness bug that's been waiting** for someone to look carefully enough. Fixing it gets the first 92/92 test run in the repo's history.

---

## File-level changes summary

| File | Change | Est. lines |
|---|---|---|
| `tools/compile.rail` | Option A: wrap `is_ptr_ret` foreign call with `cbz` + `strdup` | ~10 |
| `.github/workflows/ci.yml` | Update expected count `91/92` → `92/92` | 1 |
| `README.md` | Update test badge | 1 |
| `tools/compile.rail` (test count messages) | Any `"91/92"` strings in test output → `"92/92"` | ~3 |

After the fix, also update `docs/neural-plasma-engine.md` and the session report to note that the `ffi_getenv` baseline has been cleared.

---

## Author's note

This bug was found during the end-of-session audit for 2026-04-06. The reproduction was a dead-end for about 15 minutes because running `/tmp/rail_out` directly after compiling from the shell worked perfectly — the bug only appears when the binary is invoked from a child shell process. The "aha" came from noticing that swapping `HOME` for `USER` flipped the direct vs. shell behavior: that's the signature of a memory-layout-dependent pointer alignment issue.

The fix itself is small. The diagnosis is the whole thing. Writing this file is the gift — a fresh session can read it and ship the fix in under half an hour instead of re-deriving from scratch.
