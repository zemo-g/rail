# JIT — float user-fn args session prompt

Paste below the rule line into a fresh session. Self-contained; ship the
last named v1 limit end-to-end in one session.

---

Branch `jit` on `next` (origin = Mini → GitHub `zemo-g/rail.git`). Pull,
build the trampoline dylib, then verify environment:

    git pull
    bash jit/build_trampoline.sh
    ./rail_native run jit/test_lower.rail      # ALL LOWER PASS  (100+3)
    ./rail_native run jit/test_capture.rail    # ALL CAPTURE PASS (26+1)
    ./rail_native run jit/test_enc.rail        # ENC OK (22 fixtures)
    ./rail_native run jit/parity_check.rail    # PARITY OK
    ./rail_native test                          # 137/137

If any fail: stop, do not start on a broken floor.

## Memory to fetch

- `jit_in_pure_rail.md` — full project state through P4-ext
- `rail_top_level_int_add_bug.md` — relevant for any helper int constants

## 5-minute read

- `jit/CONTINUATION.md` — sequencing + status (you're closing the last
  named v1-limit row)
- `jit/SESSION_PROMPT.md` — paste-ready training-session briefing; the
  "Hard rules" block at the top is load-bearing, not folklore
- `jit/SESSION_PROMPT_P4.md` — predecessor; you're picking up where it
  left off

## What's already done (do NOT re-derive)

- Float literals lex/parse, 12 float opcodes (op_fconst .. op_print_float).
- ARM64 float encoders: enc_fadd/fsub/fmul/fdiv/fcmp/scvtf/fcvtzs/
  fmov_d_x/fmov_d_d/cset_mi/cset_ls/ldr_x27/str_x27/blr.
- jit_print_float trampoline (libjit_call.dylib); address dlsym-equivalent
  at heap[24..31]; output buffer base at heap[32].
- 64-byte function frame with d8/d9 callee-save (P4-ext).
- preserve_callee_float for cross-call float survival (2 slots: f8, f9).
- Float-returning user fns: registry tracks ret_type per fn via single-pass
  forward inference; op_call_fret + op_ret_float close the d0 boundary.
- op_fle (float `<=` via cset ls).

## DONE CRITERION

`try_jit_grade_str "area r = 3.14 * r * r\nmain = print (show (area 5.0))" "78.5\n"`
returns `["jit_pass"]`. Plus 5+ regression fixtures covering:

- Float arg, float body, float ret (`area`, `square`).
- Float + int args mixed in declaration order — `scaled n r = int_to_float n * r`.
- Float arg used in cross-call float op.
- Recursive float-arg fn (`pow b e = if e < 1 then 1.0 else b * pow b (e-1)`).
- Bench-style: `dist x y = sqrt(...)` IF the surrounding compute infrastructure
  can route to a foreign sqrt — defer if it pulls in math.rail wiring.

Commit + push (Studio→Mini→GitHub flow at the bottom).

## Design decisions — locked in, do not re-derive

### AAPCS64 mixed-arg ABI

Apple ARM64 non-variadic call convention: int args fill x0..x7 in
declaration order, float args fill d0..d7 in declaration order, **each
class indexes independently**. So `f(int, float, int, float)`:

- int arg @ position 0 → x0 (int_slot 0)
- float arg @ position 1 → d0 (float_slot 0)
- int arg @ position 2 → x1 (int_slot 1)
- float arg @ position 3 → d1 (float_slot 1)

Both caller (op_call) and callee (prologue arg-bind) must compute slot
positions the same way: walk arg list left-to-right, increment int_slot
or float_slot based on per-arg type.

### Per-arg type inference: call-site fixed-point

Body inference is circular for binary ops (lhs type depends on rhs and
vice versa). Skip that approach; use call-site inference instead:

```
1. Build registry with all arg_types = ["int", ..., "int"] and
   ret_type = "int" (then refine ret_type via the existing single-pass
   forward inference — that part is already in lower.rail).
2. For each fn body, walk every call-site:
     for each arg in call:
       arg_ty = infer_type env arg          -- already works for floats
       if arg_ty == "float" and callee.arg_types[i] == "int":
         callee.arg_types[i] = "float"
         changed = true
3. If changed, repeat. Typically converges in 1-2 passes.
```

Forward refs (a fn called before it's seen) get caught on a later pass.
Mutual recursion works after enough passes (cap at 4 to avoid infinite
loops on pathological input).

This lives next to `build_registry` in `jit/lower.rail`. The output is
the same `[name, fn_idx, ret_ty]` registry but extended to
`[name, fn_idx, ret_ty, arg_types]` — append the arg_types list as a
fourth slot.

### IR encoding — extend op_call's c-slot, no new opcodes

Current c-slot (bits 0..23 used):

    bits 0..3   n_args (1..4)
    bits 4..8   arg0_vreg (5 bits)
    bits 9..13  arg1_vreg
    bits 14..18 arg2_vreg
    bits 19..23 arg3_vreg

Add type bits (8 free bits remain):

    bits 24..27 arg type bits (1 per arg position; 0=int, 1=float)
    bit 28      ret type (0=int, 1=float; folds op_call_fret semantics)

`op_call_fret` (43) becomes redundant — can either delete (and rewire
emit + lower to dispatch by bit 28) or leave as a back-compat alias.
Recommend folding into op_call for cleaner IR; the migration is
mechanical (search/replace in emit.rail dispatch + lower_call_emit).

Helpers in `jit/ir.rail`:

```rail
call_pack_4_typed a0 a1 a2 a3 t0 t1 t2 t3 ret_t = ...
call_arg_type_n c n = bit_and (shr c (24 + n)) 1
call_ret_type c     = bit_and (shr c 28) 1
```

### emit_op_call (post-extension)

For each arg slot i (0..n-1):
- decode arg_type via `call_arg_type_n c i`
- if int: track int_slot, emit `mov x_int_slot, x_preg(arg_i)`, increment int_slot
- if float: track float_slot, emit `fmov d_float_slot, d_arg_i`, increment float_slot

After bl, decode ret_type via `call_ret_type c`:
- if int: `mov x_dst, x0`
- if float: `fmov f_dst, d0`

Same total byte count as before (5 inst per call shouldn't grow on
typical 1-2 arg patterns).

### Prologue arg-bind (post-extension)

`build_arg_env` looks up the fn's `arg_types` in the registry. For each
arg name + type:
- if int, current behavior (mov v_i_preg, x_int_slot)
- if float, bind name to float_slot in env with type "float"; emit `fmov f_slot, d_float_slot` (1 inst) — actually a no-op move if f_slot == float_slot, but emit explicitly for code clarity

Increment int_slot or float_slot per arg based on type.

The prologue size is now `24 + 4*n_args` regardless of arg type (each
arg still gets one move instruction). No frame-size change needed.

### Lowering: per-arg lowering ALREADY WORKS

`lower_args_with_preserve` in lower.rail already lowers each arg to its
"natural" vreg (int or float, whichever the AST says). The vreg ends up
in the right space (caller-save x_N or d_N). `lower_call_emit` then
encodes the vreg numbers + type bits into op_call's c-slot.

If the callee expects int but the AST gives float (or vice versa), this
is a type error — fail with a clear "arg N: callee expects float, got int".

## Operations to ship (not many)

- `call_pack_4_typed` and decoders in `jit/ir.rail`
- Extended `emit_op_call` (mixed dispatch)
- `arg_types` slot in registry + fixed-point inference loop
- `build_arg_env` consults registry instead of `infer_arg_type` heuristic
  (for fn args; the heuristic stays for HOF param naming)
- `lower_call_emit` packs type bits

No new opcodes. No new encoders. The hard work is the registry + inference.

## Files to touch (in order)

1. `jit/ir.rail` — `call_pack_4_typed` + decoders (15 min).
2. `jit/lower.rail` — extend registry to `[name, idx, ret_ty, arg_types]`;
   add fixed-point arg-type inference; update `build_arg_env` to consult
   sig; update `lower_call_emit` to pack type bits (1 hr).
3. `jit/emit.rail` — `emit_op_call` mixed dispatch; emit_prologue handles
   float arg-binds (45 min).
4. `jit/test_lower.rail` + `jit/test_capture.rail` — 6+ fixtures (30 min).
5. `jit/CONTINUATION.md` + `jit/SESSION_PROMPT.md` + memory entry (15 min).

## Gotchas to know cold

1. **as+otool+python — ALWAYS.** New ARM64 constants (probably none this
   session, but if you need any) go through the pipeline in
   `SESSION_PROMPT.md`'s "Hard rules" block. Two failure modes already
   logged: bit 9 in stp writeback, decimal typos. test_enc fixtures lock
   them in.

2. **No hex literals.** `byte_set p 0 0x40` parses as 4 args (`0`, ident
   `x40`); ld errors `_RAIL_UNDEFINED_IDENT_x40`. Decimal everywhere.

3. **Foreign-call ABI.** `-> int` retags result; `-> ptr` does not;
   `-> float` returns d0 + post-call `fmov x0, d0`. Float ARGS go in
   d0..d7, not x0..x7. compile.rail handles this via untag_float_args
   (already wired for jit_print_float etc.).

4. **48-byte frame is dead; 64-byte frame is live.** Don't regress.

5. **AAPCS64 d-regs.** d0–d7 caller-save, d8–d15 callee-save (low 64 bits
   only). Today only d8/d9 are saved by the prologue. If you need more
   float callee-save slots for cross-call ABI, the frame must grow
   beyond 64 — that's a separate decision. Don't sneak it in.

6. **Mixed args interleave by class, not by position.** `f(int, float)`
   passes int via x0 and float via d0, not int in x0 and float in d1.
   Caller and callee MUST agree.

7. **0-arg user fns are a known limit.** `pi = 3.14` defines a fn with
   n_args=0; calling `pi` lowers as a fn_idx materialization (op_const)
   rather than a call. Out of scope this session — explicitly punt.

8. **Don't try to infer arg types from body usage.** The cycle is:
   `f x = x * y` — type of `x` depends on type of `y`, type of `y`
   depends on type of `x`. Forward-only call-site inference is the
   only thing that converges cleanly. (You will be tempted; don't.)

## Suggested pacing (one session, ~4 hr)

1. (30 min) Extend registry to carry `arg_types`. Update existing
   ret_type pass to also initialize `arg_types`. Build fixed-point loop
   skeleton.
2. (45 min) Implement call-site inference. Write a pass that walks each
   fn body, finds calls, propagates arg types. Iterate.
3. (15 min) Extend `call_pack` helpers + decoders.
4. (45 min) Update `emit_op_call` for mixed-arg dispatch (int vs float
   slot tracking).
5. (45 min) Update `emit_prologue` + `build_arg_env` for float arg
   binding.
6. (30 min) Fixtures. Aim for 6+: `area r`, `scaled n r`, recursive
   `pow b e`, mixed-arg, cross-call float-arg, print(show(...)) with
   float arg.
7. (15 min) Doc + memory updates. Commit + push.

## Stop conditions / fallback scopes

If fixed-point inference turns into a tar pit past ~90 min:

- Ship the all-float-args-only path. Mark a fn as "float-args" if the
  FIRST arg in its first call is float; assume all args are float.
  Mixed-args fns become an err. This handles `area r = 3.14 * r * r`
  cleanly. Document mixed as deferred-v2.

If the IR c-slot encoding feels cramped:

- Add `op_call_v2` (45) and put the new sig info in `b` slot, with `b`
  pointing into a separate sig-pool. Cleaner long-term but more code
  this session.

If the prologue arg-bind tangles:

- Drop the explicit `fmov f_slot, d_float_slot` and just bind the env
  entry — d-regs are already at the right slot per AAPCS64. The fmov
  is conceptual clarity, not correctness.

## Floors to protect (regression net)

- 137/137 main suite
- 100+3 test_lower fixtures
- 26+1 test_capture fixtures
- 11 parity_check rows
- 22 test_enc encoder fixtures
- 64-byte frame size + d8/d9 callee-save
- All float-ret + cross-call float fixtures (P4-ext)

If any of those break: stop, root-cause, don't paper over.

## Round-trip flow

    # On Studio:
    git add jit/... 
    git commit -m "jit: float user-fn args — last named v1 limit"
    git push origin jit                                               # → Mini
    ssh <user>@<host> 'cd ~/projects/rail && git push origin jit'  # → GitHub

If `tools/compile.rail` changed (it shouldn't for this session — link
line already picks up the trampoline), bootstrap with
`./rail_native self && cp /tmp/rail_self rail_native && ./rail_native test`
and only commit rail_native after verifying 137/137.

---

(End of paste-able prompt.)

A note from the prior session-self: the bench probably doesn't need this
TODAY. Spur-generated Rail tends to use stdlib helpers (sqrt, sin) for
float work, not user-defined float fns. So treat this session as
defensive engineering — the lift is real but not a hot blocker. If
something more urgent surfaces (closures-with-captures, 0-arg fn calls,
the next ARM64 mystery), redirect cleanly. The wizard's authority extends
to knowing when to defer.
