# Closures — design + scaffold

Status: NOT shipped. This doc + the IR-opcode reservations below are the
scaffold; full implementation is the next big push (~4–6 hr).

The variant in `closures-without-captures` (~1 hr) ships first if the
training session profiling shows captures are uncommon; otherwise go
direct to the full design.

---

## Surface syntax

```rail
\x -> body                        -- single-arg
\a b -> body                      -- multi-arg (parser flattens nested \)
let inc = \x -> x + 1 in inc 5
let n = 10 in
let f = \x -> x + n in            -- captures n
f 7                                -- = 17
map (\x -> x * 2) [1, 2, 3]
```

## Variant A: closures-without-captures

If we ship this first, lambdas without free variables work as
top-level fn references. Lambdas WITH captures are rejected at
lower time.

### Surface restriction

```rail
add5 x = x + 5                    -- top-level fn
let f = add5 in f 7                -- f holds add5's fn_idx; f 7 -> 12
map add5 [1, 2, 3]                 -- works: map's f arg is a known fn
let bad = let n = 10 in \x -> x + n in ...   -- REJECTED (captures n)
```

### IR

```
op_make_fn_ref  (27)  a=dst, b=fn_idx          -- dst := fn_idx (just an int)
op_apply        (29)  a=dst, b=ref_reg, c=packed_args    -- indirect call
```

### Emit for op_apply

For up to N known fns at emit time, dispatch via cmp+b:

```
ldr_or_use ref_reg
mov x0, arg0
mov x1, arg1            -- if 2-arg
cmp ref_reg, #0
b.eq fn0_target
cmp ref_reg, #1
b.eq fn1_target
... (up to n_fns)
b unreachable_trap
fn0_target:
  bl <fn0_offset>
  b done
fn1_target:
  bl <fn1_offset>
  b done
...
done:
mov dst, x0
```

Cost: 2 instr per known fn + 4 for arg/dst handling. For 5 fns:
14 instr = 56 bytes per apply. Acceptable.

### Lower changes

```
lower_var: if name resolves to a top-level fn (in registry) AND
           the var is used in non-call position (i.e., as a value),
           emit op_make_fn_ref with the fn_idx.
lower_call: if the head is a var of type "fn_ref" (env-tracked),
            emit op_apply instead of op_call.
```

Type tracking: extend env type to include "fn_ref<arity>" so `f 7` knows
arity 1 and packs accordingly.

---

## Variant B: full closures with captures

### IR

```
op_make_closure  (27)  a=dst, b=fn_idx, c=n_captures
                       -- bump-allocates 16+8n bytes; stores code_ptr
                       -- and (initially uninitialized) capture slots
op_set_capture   (28)  a=closure_ptr, b=index, c=src_reg
                       -- store src_reg at closure[16 + 8*index]
op_apply         (29)  a=dst, b=closure_ptr, c=packed_args
                       -- ldr code, [closure, 0]; mov x0, closure;
                       -- args in x1..xN; blr code; mov dst, x0
```

### Heap layout per closure

```
Offset  Size  Field
  0     8     code_ptr (absolute address; resolved at make_closure time)
  8     8     n_captures
 16     8     captured_var_0
 24     8     captured_var_1
 32     8     captured_var_2
 ...
```

Allocate from the same bump pointer as cons cells (different size
per closure, but the bump allocator handles it: alloc N bytes,
return ptr, advance by N).

### Lambda hoisting (lower-time pre-pass)

Walk every `fn_def`'s body. For each `lambda` AST node:

1. Generate a synthetic name `__lam_<idx>`.
2. Compute free vars: `body's referenced names` − `lambda's args` − `enclosing-fn's args + lets`.
3. Hoist a new top-level fn:
    `__lam_idx (closure_ptr arg0 arg1 ...) = let cap0 = closure[16] in let cap1 = closure[24] in ... body`
4. Rewrite the original `lambda` site to `make_closure + set_capture × n + closure_ptr_value`.

### Apply-site lowering

When `lower_call` sees an app whose innermost head is a `let`-bound or
arg-bound name typed as "closure", emit `op_apply` instead of `op_call`.

When seeing an app whose head is a var matching a top-level fn (no
captures), emit a fresh closure with 0 captures and immediate apply.
This handles `map add5 [...]` uniformly.

### ARM64 emit for op_apply

```
ldr  x16, [closure_ptr_preg, #0]    -- load code_ptr (absolute address)
mov  x0,  closure_ptr_preg          -- closure-as-env in x0
mov  x1,  arg0_preg                 -- user args in x1..xN
mov  x2,  arg1_preg                 -- if 2-arg
...
blr  x16                            -- indirect call
mov  dst_preg, x0                   -- result
```

`blr xN` is 4 bytes per call. Closures are PROPER first-class values
in this design.

### Helper-fn prologue

Each hoisted `__lam_idx` reads its captures from `closure_ptr` (in x0):

```
stp x29, x30, [sp, #-32]!
mov x29, sp
stp x19, x20, [sp, #16]
mov x27, x_heap_addr_passed_via_???   -- need a way to get heap to closures
                                       -- (separate arg or recover from x0?)
ldr v_cap0_preg, [x0, #16]
ldr v_cap1_preg, [x0, #24]
...
mov v0_preg, x1                       -- shift user args (closure took x0)
mov v1_preg, x2
...
```

**Heap-pointer access from within a closure body:** The current ABI
(v2) puts heap_addr in x0 at fn entry. If x0 is the closure_ptr in
the helper, we lose direct access to heap_addr.

Options:
- Pass heap_addr as a separate arg (x_LAST), shifting user args.
- Bake heap_addr address into the JIT page as PC-relative data and
  ldr it (similar to the original Stage-5 attempt that failed; would
  need shl-1 trick again).
- Stash heap_addr in a callee-save reg at the OUTER entry point and
  rely on it being preserved across the inner blr call. This is the
  cleanest: x27 is callee-save in standard ABI, so the inner closure
  inherits it from the caller. (Just don't clobber x27 in apply emit.)

The x27-callee-save approach works if every helper preserves x27.
Our existing prologue already saves x19/x20 but not x27. We need to
save x27 too — adds 4 bytes prologue + 4 bytes epilogue. Or use the
inherited x27 without saving (since we don't write to it in helper bodies).

Actually since helpers DON'T modify x27 (they only USE the heap via
op_cons/op_head/etc., reading x27), and x27 starts with the caller's
heap_addr (preserved via the standard ARM64 callee-save discipline...
wait, in standard ABI x27 IS callee-save, meaning the callee MUST
preserve it if used. Our prologue currently *writes* x27 without
saving the old value, breaking this.).

**Cleanest fix:** the OUTER entry point captures heap_addr to x27.
Inner-call helpers ALSO have `mov x27, x0` in their prologue —
but x0 is the closure_ptr, not heap! So we'd need both heap and
closure passed.

Option: for closures, pass the closure_ptr in x0 AND heap_addr in x1.
Helper's prologue: `mov x27, x1; mov x_closure, x0; ...`. Adjust user
args to start at x2.

This is ugly but consistent. Document well.

---

## Files to touch (full design)

| File | Change |
| --- | --- |
| `jit/lex.rail` | `\` → mk_op "\\". |
| `jit/syntax.rail` | `parse_lambda` after seeing `\`; flatten nested. |
| `jit/lower.rail` | `hoist_lambdas` pre-pass; free-var analysis; lower_apply for closure-typed calls; type tracking extended to "closure". |
| `jit/ir.rail` | op_make_closure (27), op_set_capture (28), op_apply (29). |
| `jit/emit.rail` | Three new emit handlers; closure prologue tweaks. |
| `jit/test_lower.rail` | 4–6 closure tests: simple, with captures, in `map`, recursive. |

## Non-goals (v1 closures)

- Mutually recursive closures via `let rec` — not in our subset.
- Higher-rank types — we don't have a type system anyway.
- Closure GC — the heap is bump-only; closures leak. Acceptable for
  short rollouts.
