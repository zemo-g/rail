# 2026-05-07 evening — v2 JIT work shipped, two bugs open

## Where the working tree stands

Branch `jit` at HEAD `ef6bf63`. **Uncommitted** v2 work in:

- `jit/arm64.rail` — new instruction encodings for 112-byte frame (d10..d15 stp/ldp pairs).
- `jit/emit.rail` — prologue 24→36 bytes, op_ret/op_ret_float 24→36, fn_total_bytes constant.
- `jit/ir.rail` — `call_pack_typed` handles n=0 (v2-A).
- `jit/lower.rail` — bulk of v2 changes:
  - v2-A: `reg_lookup_arity`, var-as-0-arg-call in `lower_var`, `infer_type_var`, registry-aware `contains_call_r` / `used_after_call_r`.
  - v2-B: bitmap allocator for caller-save f0..f7 (ctr[10] free-mask, ctr[11] lock-mask), `st_free_float_caller`, `st_lock_float_caller`, float-let preservation, st_alloc_float_callee cap 2→8.
  - v2-C: `hoist_lambdas` pre-pass + helpers (`free_vars`, `lambda_true_captures`, `walk_hoist*`). Skips let-bound lambdas (P3-full v1 inline subst handles those).
- `jit/test_capture.rail` — 13 new fixtures (z1..z6 v2-A, m1..m3 v2-B, l1..l4 v2-C).
- `jit/test_enc.rail` — 6 new encoder fixtures for d10..d15 stp/ldp + 112-byte fp/lr.
- `jit/CONTINUATION.md` — full state doc updated.

All baselines green: 137/137 main; ALL LOWER PASS; ALL CAPTURE PASS (45 + 1 neg); ENC OK; PARITY OK; codegen ALL PASS; opt 29/29; parse 5/5.

**Recommend committing** before further work — three discrete commits would be clean: v2-A 0-arg fns, v2-B float frame expansion, v2-C lambda hoisting.

## Open bug A — chained op_apply over let-bound fn ref

Pre-existing on tip-of-tree (verified via `git stash` test). Affects:

```rail
let f = double in (f 7) + (f 3)        -- returns 0, expected 20
let f = double in let a = f 7 in
  let b = f 3 in print(show a)         -- prints "0", expected "14"
```

But these all WORK:

```rail
let f = double in print(show (f 7))                          -- "14"
let f = double in let a = f 7 in print(show a)               -- "14"
apply f x = f x; main = (apply double 7)+(apply double 3)    -- 20
```

So the bug is two op_apply emissions in the SAME fn body where `f` is bound via `let` to a fn ref.

### IR trace (looks correct, but runtime returns 0)

For `main = let f = double in (f 7) + (f 3)`:

```
1. op_const v1 double_idx 0          ; v1 = 1 (=double_idx)
2. op_mov v10 v1                     ; v10 = preserved fn_idx
3. op_const v2 7 0                   ; v2 = 7
4. op_apply v3 v10 v2                ; v3 = double(7) = 14
5. op_mov v11 v3                     ; v11 = preserved first result
6. op_const v2 3 0                   ; v2 = 3 (REUSED)
7. op_apply v4 v10 v2                ; v4 = double(3) = 6
8. op_add v_dst v11 v4               ; v_dst = 14+6 = 20
```

The IR sequence is consistent with what should produce 20. So the bug is in the EMIT — likely something about how op_apply's branch table interacts with the surrounding code's vreg use.

### Hypotheses to investigate (next session)

- **H1: b end displacement off-by-one when n_fns ≥ 2.** Recompute `b_rel = end_off - b_off = 20*(n_fns-k) - 12`. For k=0,n=2: 28 bytes = 7 inst. For k=1,n=2: 8 bytes = 2 inst. End_off should be `mov x_dst, x0` at off+44. Branch from off+16 (k=0) to off+44 = 28. ✓. From off+36 (k=1) to off+44 = 8. ✓. Checked — looks right.

- **H2: `cmp x_fn_idx, #k` with imm > 12 bits.** For our case k=0 or 1, imm fits trivially. Not the bug here, but worth looking at if imm > 4095.

- **H3: x0 is being reused/clobbered between the two op_applies.** The first apply's `mov x_dst, x0` captures result before x0 can be clobbered. But after the `b end → mov x_dst, x0`, control returns to caller. Caller does `op_mov v11 v3` which is `mov x20, x12` — doesn't touch x0. Then op_const v2 3 0 writes x11 = 3, doesn't touch x0. Then second op_apply's `mov x0, x_arg=x11=3` — x0 = 3. bl double. Returns 14 in x0... but if for some reason the cmp x19 fails (x19 not still =1), would fall through to `mov x0, #0`.

- **H4: x19 (v_fn preg) is NOT preserved across the bl inside the first op_apply.** The bl jumps to double's prologue which does `stp x19, x20, [sp, #16]` — saves caller's x19, restores in epilogue. So x19 should survive. **Worth verifying with a minimal asm test.** If `double`'s prologue is somehow not saving x19 correctly (e.g., a regression from v2-B's frame change), this could explain the failure.

### High-leverage next move

Disassemble the JIT page for `let f = double in (f 7) + (f 3)`. Compare to working `(apply double 7) + (apply double 3)`. The diff isolates the issue.

A diff-friendly approach: extend `try_jit_grade_str` to also dump the buffer bytes when it returns. Or write a one-shot test that calls `lower_source` + `emit_program` and prints byte offsets via `otool -d` against a temp file.

### Plan B (if H4 is the cause)

Make the prologue's `stp x19, x20` come BEFORE any potential clobber. It already does (offset 8 in prologue). But maybe v2-B's added stps (d10/d11 etc at offsets 20, 24, 28) somehow corrupt x19 — unlikely since stp d10/d11 doesn't touch GPRs. Still worth eliminating.

## Open bug B — inference_seed_segfault (compile.rail)

Per `inference_seed_segfault_root_cause` memory entry: bug requires `arena_reset` + multiply-add expr in `float_arr_set`. Multipliers 128, 130 crash; 127, 129 don't.

lldb hangs on the heisenbug (the failed task `bkdga0ad3` confirms). **Next move: dtrace store-watchpoint on `_rail_small_fl[0]`.** Workaround already in place (drop arena_reset from gen_loop in lm_infer_cpu.rail).

This blocks the grammar-walk Step 3a per `grammar_walk_climb_2026-05-05` memory.

## Other state preserved across reboot

- `next_session_pointer` memory still references `docs/plans/SESSION_HANDOFF_2026-04-27.md` — stale, supersede with this doc.
- The 4-arm Spur ablation experiments and ensemble ceiling (24/30) remain untouched.
- /holo, /render.wasm, /witness.html deployments live on Cloudflare.

## Resume checklist

1. `cd ~/projects/rail && git status` — confirm uncommitted v2 changes still there.
2. `./rail_native test` — verify 137/137 still green post-reboot.
3. Run the JIT test battery (test_lower, test_capture, test_codegen, test_print, test_enc, test_opt, test_parse, parity_check) — confirm all pass.
4. **Decide: commit v2-A/B/C as 3 commits, then start on bug A.** The fix loop for bug A wants the v2 changes locked in so investigation diffs only the bug-fix.
5. For bug A, start with H4 verification: a minimal program `double x = x*2; main = print (show (double 7)) ; main2 = print (show (double 3))` — if `double` returns correctly when called from two different fns, x19 isn't the issue. If it fails, frame regression.
