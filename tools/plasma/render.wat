(module
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 32 32)
  (export "vorticity" (func $vorticity))
  (export "current_density" (func $current_density))
  (export "schlieren" (func $schlieren))
  (export "total_kinetic_energy" (func $total_kinetic_energy))
  (export "total_magnetic_energy" (func $total_magnetic_energy))
  (export "max_divb" (func $max_divb))
  (export "mean_vorticity" (func $mean_vorticity))
  (export "seed_ot" (func $seed_ot))
  (export "float_arr_new" (func $float_arr_new))
  (export "float_arr_get" (func $float_arr_get))
  (export "float_arr_set" (func $float_arr_set))
  (export "float_arr_len" (func $float_arr_len))
  (export "arena_mark" (func $arena_mark))
  (export "arena_reset" (func $arena_reset))
  (export "lic" (func $lic))
  (export "particle_step" (func $particle_step))
  (export "chamber_render" (func $chamber_render))

  (type $clos_t (func (param i64 i64) (result i64)))
  (table 1 funcref)
  (elem (i32.const 0))

  ;; ─── Memory layout (1 MB total, 16 pages) ────────────────────
  ;;   0x000000 .. 0x010000  (64K)  — WAT data segments + nil sentinel
  ;;   0x010000 .. 0x014000  (16K)  — shadow stack (2K i64 root slots)
  ;;   0x014000 .. 0x020000  (48K)  — string heap (no GC, monotonic)
  ;;   0x020000 .. 0x090000  (448K) — from-space (active GC heap)
  ;;   0x090000 .. 0x100000  (448K) — to-space (inactive)
  ;; Structured objects (cons/closure/ADT/float_arr) live in the GC
  ;; heap; strings live in the string heap and are never moved or
  ;; reclaimed.  Cross-region pointers (cons-of-string, closure-with-
  ;; string-fv) are safe — the collector only forwards pointers that
  ;; lie within the active semi-space.

  (global $shadow_ptr (mut i32) (i32.const 0x10000))
  (global $str_ptr    (mut i32) (i32.const 0x14000))
  (global $obj_ptr    (mut i32) (i32.const 0x20000))
  (global $from_base  (mut i32) (i32.const 0x20000))
  (global $from_end   (mut i32) (i32.const 0x90000))
  (global $to_base    (mut i32) (i32.const 0x90000))
  (global $to_end     (mut i32) (i32.const 0x100000))
  (global $gc_count   (mut i32) (i32.const 0))

  ;; alloc_str — bump a string-heap region.  Strings have an i32
  ;; length prefix only (no GC header) and are referenced by tagged
  ;; pointers like any other heap value, but the collector ignores
  ;; them because they lie outside [from_base, from_end).
  (func $alloc_str (param $size i32) (result i32)
    (local $p i32)
    global.get $str_ptr
    local.tee $p
    local.get $size
    i32.add
    global.set $str_ptr
    local.get $p
  )

  ;; alloc_obj — bump in active semi-space; trigger GC if full.
  ;; Every structured object's first i64 word is a header of the form
  ;;   (size_in_bytes << 8) | kind
  ;; with kind ∈ { 1=cons, 2=nil, 4=closure, 5=ADT, 7=float_arr }.
  ;; The collector reads bottom byte to dispatch and bits 8..31 for
  ;; the object size.  Bit 63 is the forwarding-pointer flag.
  (func $alloc_obj (param $size i32) (result i32)
    (local $p i32)
    global.get $obj_ptr
    local.get $size
    i32.add
    global.get $from_end
    i32.gt_u
    if
      call $gc_collect
      ;; After GC, retry once.  If still over budget, the loop demo
      ;; outgrew 448K live data — accept OOM (out-of-memory trap).
      global.get $obj_ptr
      local.get $size
      i32.add
      global.get $from_end
      i32.gt_u
      if
        unreachable
      end
    end
    global.get $obj_ptr
    local.tee $p
    local.get $size
    i32.add
    global.set $obj_ptr
    local.get $p
  )

  ;; Back-compat $alloc — defaults to the string heap so any caller
  ;; that doesn't need GC tracking (string buffers, scratch, float
  ;; arrays of raw f64 bits) keeps working unchanged.  Structured
  ;; objects (cons / closure / ADT) call $alloc_obj explicitly.
  (func $alloc (param $size i32) (result i32)
    local.get $size
    call $alloc_str
  )

  ;; Arena mark/reset — operate on the string heap only.  Structured
  ;; objects survive across resets (the GC owns them).  Used by long
  ;; loops that build up scratch strings.
  (func $arena_mark (param $dummy i64) (result i64)
    global.get $str_ptr
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
  )

  (func $arena_reset (param $mk i64) (result i64)
    local.get $mk
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    global.set $str_ptr
    i64.const 3
  )

  ;; ─── Cheney copying collector ────────────────────────────────
  ;; Walk shadow-stack [0x10000 .. $shadow_ptr) as i64 root array.
  ;; For each tagged root (low bit 0) that points into from-space,
  ;; forward the pointed object to to-space.  Then scan to-space
  ;; objects breadth-first, forwarding their interior pointers.
  ;; Finally swap from/to and reset $obj_ptr.

  (func $gc_forward (param $tagged i64) (result i64)
    (local $addr i32)
    (local $hdr i64)
    (local $size i32)
    (local $new i32)
    (local $i i32)
    ;; Skip integers (low bit 1).
    local.get $tagged
    i64.const 1
    i64.and
    i64.const 1
    i64.eq
    if
      local.get $tagged
      return
    end
    ;; Untagged address.
    local.get $tagged
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    local.set $addr
    ;; Outside from-space: do not forward (string, nil sentinel,
    ;; static data, or already in to-space).
    local.get $addr
    global.get $from_base
    i32.lt_u
    if
      local.get $tagged
      return
    end
    local.get $addr
    global.get $from_end
    i32.ge_u
    if
      local.get $tagged
      return
    end
    ;; Read header.
    local.get $addr
    i64.load
    local.set $hdr
    ;; Already forwarded? (bit 63 set) — return forwarded address tagged.
    local.get $hdr
    i64.const 0
    i64.lt_s
    if
      local.get $hdr
      i64.const 0x7fffffffffffffff
      i64.and
      i64.const 1
      i64.shl
      return
    end
    ;; Extract size from header bits 8..31.
    local.get $hdr
    i64.const 8
    i64.shr_u
    i64.const 0xffffff
    i64.and
    i32.wrap_i64
    local.set $size
    ;; Bump-allocate in to-space.
    global.get $obj_ptr
    local.set $new
    global.get $obj_ptr
    local.get $size
    i32.add
    global.set $obj_ptr
    ;; Copy size bytes from $addr to $new (8-byte chunks).
    i32.const 0
    local.set $i
    block $cpd
      loop $cpl
        local.get $i
        local.get $size
        i32.ge_u
        br_if $cpd
        local.get $new
        local.get $i
        i32.add
        local.get $addr
        local.get $i
        i32.add
        i64.load
        i64.store
        local.get $i
        i32.const 8
        i32.add
        local.set $i
        br $cpl
      end
    end
    ;; Install forwarding pointer in old header (bit 63 + new addr).
    local.get $addr
    local.get $new
    i64.extend_i32_u
    i64.const 0x8000000000000000
    i64.or
    i64.store
    ;; Return tagged new address.
    local.get $new
    i64.extend_i32_u
    i64.const 1
    i64.shl
  )

  (func $gc_scan_object (param $addr i32)
    (local $hdr i64)
    (local $kind i32)
    (local $size i32)
    (local $off i32)      ;; current field offset within object
    (local $faddr i32)    ;; absolute address of current field
    (local $val i64)
    (local $newval i64)
    local.get $addr
    i64.load
    local.set $hdr
    local.get $hdr
    i64.const 0xff
    i64.and
    i32.wrap_i64
    local.set $kind
    local.get $hdr
    i64.const 8
    i64.shr_u
    i64.const 0xffffff
    i64.and
    i32.wrap_i64
    local.set $size
    ;; Determine first interior-field offset by kind.
    ;;   1 (cons):    fields at +8, +16
    ;;   4 (closure): fields at +16 .. +size  (skip lambda_idx at +8)
    ;;   5 (ADT):     fields at +16 .. +size  (skip ctor_idx at +8)
    ;;   7 (float):   no scan (raw f64 bits)
    ;;   else:        no scan
    local.get $kind
    i32.const 1
    i32.eq
    if
      i32.const 8
      local.set $off
    else
      local.get $kind
      i32.const 4
      i32.eq
      local.get $kind
      i32.const 5
      i32.eq
      i32.or
      if
        i32.const 16
        local.set $off
      else
        return
      end
    end
    block $scd
      loop $scl
        local.get $off
        local.get $size
        i32.ge_u
        br_if $scd
        local.get $addr
        local.get $off
        i32.add
        local.set $faddr
        local.get $faddr
        i64.load
        local.set $val
        local.get $val
        call $gc_forward
        local.set $newval
        local.get $faddr
        local.get $newval
        i64.store
        local.get $off
        i32.const 8
        i32.add
        local.set $off
        br $scl
      end
    end
  )

  (func $gc_collect
    (local $root i32)
    (local $scan i32)
    (local $tagged i64)
    (local $newtag i64)
    ;; Swap from/to (XOR-style would need locals; simpler: gather then assign).
    global.get $from_base
    global.get $to_base
    global.set $from_base   ;; from_base := old to_base
    global.set $to_base     ;; to_base   := old from_base
    global.get $from_end
    global.get $to_end
    global.set $from_end    ;; from_end := old to_end
    global.set $to_end      ;; to_end   := old from_end
    ;; Reset obj_ptr to (new) from_base — we'll bump as we copy.
    global.get $from_base
    global.set $obj_ptr
    ;; Scan shadow stack.
    i32.const 0x10000
    local.set $root
    block $rd
      loop $rl
        local.get $root
        global.get $shadow_ptr
        i32.ge_u
        br_if $rd
        local.get $root
        i64.load
        local.set $tagged
        local.get $tagged
        call $gc_forward
        local.set $newtag
        local.get $root
        local.get $newtag
        i64.store
        local.get $root
        i32.const 8
        i32.add
        local.set $root
        br $rl
      end
    end
    ;; Cheney scan: walk newly-copied objects in to-space (now $from).
    global.get $from_base
    local.set $scan
    block $sd
      loop $sl
        local.get $scan
        global.get $obj_ptr
        i32.ge_u
        br_if $sd
        local.get $scan
        call $gc_scan_object
        ;; Advance scan by object size.
        local.get $scan
        i64.load
        i64.const 8
        i64.shr_u
        i64.const 0xffffff
        i64.and
        i32.wrap_i64
        local.get $scan
        i32.add
        local.set $scan
        br $sl
      end
    end
    global.get $gc_count
    i32.const 1
    i32.add
    global.set $gc_count
  )

  ;; Note: a shadow-stack frame helper for user functions would live
  ;; here.  We don't yet emit prologue/epilogue spills in user-function
  ;; codegen — currently only $cons spills its operand-stack roots,
  ;; which is sufficient for the loop-allocation stress test (n + nil
  ;; are not heap pointers).  Programs that hold heap-pointer locals
  ;; across a GC-triggering call would lose those roots; that is a
  ;; documented limitation, addressed by adding per-function frames in
  ;; a follow-up pass.

  ;; ─── Float intrinsics and conversions ────────────────────────
  ;; All floats travel as raw f64 bits stored in i64 (matches the
  ;; ARM64 ABI; matches what FL literals + float arithmetic emit).

  ;; ─── Transcendentals (Taylor polyfills) ──────────────────────
  ;; WASM has no native sin/cos/exp/log.  We implement them via
  ;; range-reduction + Taylor series.  Accuracy target: ~1e-6 on
  ;; the typical input range.  All take/return raw f64 bits as i64.

  ;; sin(x) — range-reduce to [-π/2, π/2] then Taylor with 12 terms
  ;; (Horner-form factors x²/(2k(2k+1)), k=1..6).  Worst-case error
  ;; at x = π/2: x^13/13! ≈ 6e-10 → ~9-digit accuracy.
  (func $sin (param $x_bits i64) (result i64)
    (local $x f64)
    (local $k f64)
    (local $x2 f64)
    (local $term f64)
    local.get $x_bits
    f64.reinterpret_i64
    local.set $x
    local.get $x
    f64.const 0.15915494309189535
    f64.mul
    f64.nearest
    local.set $k
    local.get $x
    local.get $k
    f64.const 6.283185307179586
    f64.mul
    f64.sub
    local.set $x
    local.get $x
    f64.const 1.5707963267948966
    f64.gt
    if
      f64.const 3.141592653589793
      local.get $x
      f64.sub
      local.set $x
    end
    local.get $x
    f64.const -1.5707963267948966
    f64.lt
    if
      f64.const -3.141592653589793
      local.get $x
      f64.sub
      local.set $x
    end
    local.get $x
    local.get $x
    f64.mul
    local.set $x2
    ;; Innermost: 1 - x²/(12·13)  = 1 - x²/156
    f64.const 1
    local.get $x2
    f64.const 156
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(10·11) * term    = 1 - x²/110 * term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 110
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(8·9) * term      = 1 - x²/72 * term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 72
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(6·7) * term      = 1 - x²/42 * term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 42
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(4·5) * term      = 1 - x²/20 * term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 20
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(2·3) * term      = 1 - x²/6 * term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 6
    f64.div
    f64.sub
    local.set $term
    local.get $x
    local.get $term
    f64.mul
    i64.reinterpret_f64
  )

  ;; cos(x) — own Taylor series (so cos(0) is exact).  Range-reduce
  ;; to [-π/2, π/2] using cos(π - x) = -cos(x), then Horner with 6
  ;; pairs.  Worst-case error at x = π/2: x^14/14! ≈ 4e-11.
  (func $cos (param $x_bits i64) (result i64)
    (local $x f64)
    (local $k f64)
    (local $sign f64)
    (local $x2 f64)
    (local $term f64)
    local.get $x_bits
    f64.reinterpret_i64
    local.set $x
    local.get $x
    f64.const 0.15915494309189535
    f64.mul
    f64.nearest
    local.set $k
    local.get $x
    local.get $k
    f64.const 6.283185307179586
    f64.mul
    f64.sub
    local.set $x
    f64.const 1
    local.set $sign
    local.get $x
    f64.const 1.5707963267948966
    f64.gt
    if
      f64.const 3.141592653589793
      local.get $x
      f64.sub
      local.set $x
      f64.const -1
      local.set $sign
    end
    local.get $x
    f64.const -1.5707963267948966
    f64.lt
    if
      f64.const -3.141592653589793
      local.get $x
      f64.sub
      local.set $x
      f64.const -1
      local.set $sign
    end
    local.get $x
    local.get $x
    f64.mul
    local.set $x2
    ;; Innermost: 1 - x²/(11·12) = 1 - x²/132
    f64.const 1
    local.get $x2
    f64.const 132
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(9·10)*term       = 1 - x²/90*term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 90
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(7·8)*term        = 1 - x²/56*term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 56
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(5·6)*term        = 1 - x²/30*term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 30
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(3·4)*term        = 1 - x²/12*term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 12
    f64.div
    f64.sub
    local.set $term
    ;; 1 - x²/(1·2)*term        = 1 - x²/2*term
    f64.const 1
    local.get $x2
    local.get $term
    f64.mul
    f64.const 2
    f64.div
    f64.sub
    local.set $term
    local.get $sign
    local.get $term
    f64.mul
    i64.reinterpret_f64
  )

  ;; tanh(x) — using identity tanh(x) = (e^(2x) - 1) / (e^(2x) + 1).
  ;; Saturates at ±1 for |x| > 20 to avoid overflow.
  (func $tanh (param $x_bits i64) (result i64)
    (local $x f64)
    (local $e f64)
    local.get $x_bits
    f64.reinterpret_i64
    local.set $x
    ;; Saturate
    local.get $x
    f64.const 20
    f64.gt
    if
      f64.const 1
      i64.reinterpret_f64
      return
    end
    local.get $x
    f64.const -20
    f64.lt
    if
      f64.const -1
      i64.reinterpret_f64
      return
    end
    local.get $x
    f64.const 2
    f64.mul
    i64.reinterpret_f64
    call $exp
    f64.reinterpret_i64
    local.set $e
    local.get $e
    f64.const 1
    f64.sub
    local.get $e
    f64.const 1
    f64.add
    f64.div
    i64.reinterpret_f64
  )

  ;; exp(x) — split x = k*ln(2) + r where r in [-ln(2)/2, ln(2)/2],
  ;; compute exp(r) by Taylor (8 terms), multiply by 2^k via bit
  ;; construction of the f64 exponent field.
  (func $exp (param $x_bits i64) (result i64)
    (local $x f64)
    (local $kf f64)
    (local $r f64)
    (local $k i64)
    (local $term f64)
    (local $expk i64)
    (local $two_k f64)
    local.get $x_bits
    f64.reinterpret_i64
    local.set $x
    ;; k = nearest(x / ln(2))
    local.get $x
    f64.const 1.4426950408889634  ;; 1 / ln(2)
    f64.mul
    f64.nearest
    local.set $kf
    ;; r = x - k * ln(2)
    local.get $x
    local.get $kf
    f64.const 0.6931471805599453   ;; ln(2)
    f64.mul
    f64.sub
    local.set $r
    ;; Taylor exp(r) = 1 + r(1 + r/2(1 + r/3(1 + r/4(1 + r/5(1 + r/6(1 + r/7(1 + r/8))))))).
    f64.const 1
    local.get $r
    f64.const 8
    f64.div
    f64.add
    local.set $term
    ;; * r/7 + 1
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.const 7
    f64.div
    f64.add
    local.set $term
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.const 6
    f64.div
    f64.add
    local.set $term
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.const 5
    f64.div
    f64.add
    local.set $term
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.const 4
    f64.div
    f64.add
    local.set $term
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.const 3
    f64.div
    f64.add
    local.set $term
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.const 2
    f64.div
    f64.add
    local.set $term
    f64.const 1
    local.get $r
    local.get $term
    f64.mul
    f64.add
    local.set $term
    ;; 2^k via bit construction of the f64 exponent.  bias=1023.
    local.get $kf
    i64.trunc_f64_s
    local.set $k
    local.get $k
    i64.const 1023
    i64.add
    i64.const 52
    i64.shl
    local.set $expk
    local.get $expk
    f64.reinterpret_i64
    local.set $two_k
    ;; Result = exp(r) * 2^k
    local.get $term
    local.get $two_k
    f64.mul
    i64.reinterpret_f64
  )

  ;; log(x) — decompose x = m * 2^k with m in [√(0.5), √2], then
  ;; Taylor on log(1+t) where t = m - 1 (small).
  ;; log(x) = k * ln(2) + log(m).
  ;; For x ≤ 0 returns NaN-like 0 (caller responsibility).
  (func $log (param $x_bits i64) (result i64)
    (local $x f64)
    (local $bits i64)
    (local $exp_bits i64)
    (local $k i64)
    (local $m_bits i64)
    (local $m f64)
    (local $t f64)
    (local $sum f64)
    (local $tn f64)
    local.get $x_bits
    f64.reinterpret_i64
    local.set $x
    ;; Edge: x <= 0 → 0 (we don't propagate NaN cleanly).
    local.get $x
    f64.const 0
    f64.le
    if
      f64.const 0
      i64.reinterpret_f64
      return
    end
    ;; Extract exponent bits.  exp_field = (bits >> 52) & 0x7FF
    local.get $x_bits
    local.set $bits
    local.get $bits
    i64.const 52
    i64.shr_u
    i64.const 2047
    i64.and
    local.set $exp_bits
    local.get $exp_bits
    i64.const 1023
    i64.sub
    local.set $k
    ;; m_bits: clear exponent and set to 1023 (gives m in [1, 2)).
    local.get $bits
    i64.const -9218868437227405313  ;; ~0x7FF0000000000000
    i64.and
    i64.const 1023
    i64.const 52
    i64.shl
    i64.or
    local.set $m_bits
    local.get $m_bits
    f64.reinterpret_i64
    local.set $m
    ;; Optional further reduction: if m > √2, divide by 2 and bump k.
    local.get $m
    f64.const 1.4142135623730951
    f64.gt
    if
      local.get $m
      f64.const 2
      f64.div
      local.set $m
      local.get $k
      i64.const 1
      i64.add
      local.set $k
    end
    ;; t = m - 1, in [√(0.5)-1, √2-1] ≈ [-0.293, 0.414]
    local.get $m
    f64.const 1
    f64.sub
    local.set $t
    ;; Taylor: log(1+t) = t - t²/2 + t³/3 - t⁴/4 + ... (10 terms).
    local.get $t
    local.set $sum
    local.get $t
    local.set $tn
    ;; tn := tn * t (now t²); subtract tn / 2
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 2
    f64.div
    f64.sub
    local.set $sum
    ;; tn := tn * t (t³); add tn / 3
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 3
    f64.div
    f64.add
    local.set $sum
    ;; t⁴ / 4 sub
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 4
    f64.div
    f64.sub
    local.set $sum
    ;; t⁵ / 5 add
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 5
    f64.div
    f64.add
    local.set $sum
    ;; t⁶ / 6 sub
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 6
    f64.div
    f64.sub
    local.set $sum
    ;; t⁷ / 7 add
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 7
    f64.div
    f64.add
    local.set $sum
    ;; t⁸ / 8 sub
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 8
    f64.div
    f64.sub
    local.set $sum
    ;; t⁹ / 9 add
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 9
    f64.div
    f64.add
    local.set $sum
    ;; t¹⁰ / 10 sub
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 10
    f64.div
    f64.sub
    local.set $sum
    ;; t¹¹ / 11 add
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 11
    f64.div
    f64.add
    local.set $sum
    ;; t¹² / 12 sub
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 12
    f64.div
    f64.sub
    local.set $sum
    ;; t¹³ / 13 add
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 13
    f64.div
    f64.add
    local.set $sum
    ;; t¹⁴ / 14 sub
    local.get $tn
    local.get $t
    f64.mul
    local.set $tn
    local.get $sum
    local.get $tn
    f64.const 14
    f64.div
    f64.sub
    local.set $sum
    ;; Result = k * ln(2) + sum
    local.get $k
    f64.convert_i64_s
    f64.const 0.6931471805599453
    f64.mul
    local.get $sum
    f64.add
    i64.reinterpret_f64
  )

  ;; pow(x, y) = exp(y * log(x)).  Edge: x = 0 returns 0.
  (func $pow (param $x_bits i64) (param $y_bits i64) (result i64)
    (local $x f64)
    (local $y f64)
    (local $log_x f64)
    local.get $x_bits
    f64.reinterpret_i64
    local.set $x
    local.get $y_bits
    f64.reinterpret_i64
    local.set $y
    ;; x == 0 → 0
    local.get $x
    f64.const 0
    f64.eq
    if
      f64.const 0
      i64.reinterpret_f64
      return
    end
    local.get $x_bits
    call $log
    f64.reinterpret_i64
    local.set $log_x
    local.get $y
    local.get $log_x
    f64.mul
    i64.reinterpret_f64
    call $exp
  )

  ;; sqrt(x) via WASM's native f64.sqrt intrinsic.
  (func $sqrt (param $x i64) (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.sqrt
    i64.reinterpret_f64
  )

  ;; fabs(x) via f64.abs.
  (func $fabs (param $x i64) (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.abs
    i64.reinterpret_f64
  )

  ;; floor(x) — float-in, float-out.
  (func $floor (param $x i64) (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.floor
    i64.reinterpret_f64
  )

  ;; ceil(x) — float-in, float-out.
  (func $ceil (param $x i64) (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.ceil
    i64.reinterpret_f64
  )

  ;; int_to_float: tagged-int → raw f64 bits as i64.
  (func $int_to_float (param $x i64) (result i64)
    local.get $x
    i64.const 1
    i64.shr_s
    f64.convert_i64_s
    i64.reinterpret_f64
  )

  ;; float_to_int: raw f64 bits → tagged int (truncated).
  (func $float_to_int (param $x i64) (result i64)
    local.get $x
    f64.reinterpret_i64
    i64.trunc_f64_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
  )

  ;; to_float: alias for int_to_float.
  (func $to_float (param $x i64) (result i64)
    local.get $x
    call $int_to_float
  )

  ;; ─── float_arr: layout matches ARM64.
  ;; Bytes [0..7]: length (raw i64, NOT tagged).
  ;; Bytes [8..]:  f64 doubles, 8 bytes each.
  ;; The handle returned to Rail code is (ptr_i32 << 1) so the LSB
  ;; tag bit reads as 0 (pointer), matching cons cells.

  (func $float_arr_new (param $size_t i64) (param $init i64) (result i64)
    (local $size i64)
    (local $bytes i32)
    (local $ptr i32)
    (local $i i64)
    (local $addr i32)
    ;; Untag size.
    local.get $size_t
    i64.const 1
    i64.shr_s
    local.set $size
    ;; Allocate 8 (length) + size*8 bytes.
    local.get $size
    i64.const 8
    i64.mul
    i64.const 8
    i64.add
    i32.wrap_i64
    local.set $bytes
    local.get $bytes
    call $alloc
    local.set $ptr
    ;; Store length.
    local.get $ptr
    local.get $size
    i64.store
    ;; Fill with init (already raw f64 bits).
    i64.const 0
    local.set $i
    (block $done
      (loop $fill
        local.get $i
        local.get $size
        i64.ge_s
        br_if $done
        local.get $ptr
        i32.const 8
        i32.add
        local.get $i
        i32.wrap_i64
        i32.const 3
        i32.shl
        i32.add
        local.set $addr
        local.get $addr
        local.get $init
        i64.store
        local.get $i
        i64.const 1
        i64.add
        local.set $i
        br $fill
      )
    )
    ;; Return tagged pointer.
    local.get $ptr
    i64.extend_i32_u
    i64.const 1
    i64.shl
  )

  (func $float_arr_get (param $arr i64) (param $idx_t i64) (result i64)
    (local $ptr i32)
    (local $idx i64)
    local.get $arr
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    local.set $ptr
    local.get $idx_t
    i64.const 1
    i64.shr_s
    local.set $idx
    local.get $ptr
    i32.const 8
    i32.add
    local.get $idx
    i32.wrap_i64
    i32.const 3
    i32.shl
    i32.add
    i64.load
  )

  (func $float_arr_set (param $arr i64) (param $idx_t i64) (param $val i64) (result i64)
    (local $ptr i32)
    (local $idx i64)
    local.get $arr
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    local.set $ptr
    local.get $idx_t
    i64.const 1
    i64.shr_s
    local.set $idx
    local.get $ptr
    i32.const 8
    i32.add
    local.get $idx
    i32.wrap_i64
    i32.const 3
    i32.shl
    i32.add
    local.get $val
    i64.store
    ;; Return tagged 1 (Rail's "0" success sentinel).
    i64.const 3
  )

  (func $float_arr_len (param $arr i64) (result i64)
    (local $ptr i32)
    local.get $arr
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    local.set $ptr
    local.get $ptr
    i64.load
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
  )

  ;; show_float — minimal f64 → string formatter.
  ;; Strategy: split into integer and fractional parts.  Print the
  ;; integer part via the existing $show_int (delegating to a tiny
  ;; conversion), append a '.', then 6 decimal digits.  Negative
  ;; values get a leading '-'.  No scientific notation, no rounding
  ;; — adequate for verifying float math from WASM stdout.
  (func $show_float (param $x i64) (result i64)
    (local $f f64)
    (local $neg i32)
    (local $int_part i64)
    (local $frac f64)
    (local $i i32)
    (local $digit i32)
    (local $bufp i32)
    (local $cur i32)
    ;; Allocate header (4-byte len prefix) + 32 bytes for digits.
    i32.const 36
    call $alloc
    local.set $bufp
    local.get $bufp
    i32.const 4
    i32.add
    local.set $cur
    ;; Load the f64 value.
    local.get $x
    f64.reinterpret_i64
    local.set $f
    ;; Negative?  Emit '-' and flip sign.
    i32.const 0
    local.set $neg
    local.get $f
    f64.const 0
    f64.lt
    if
      i32.const 1
      local.set $neg
      local.get $f
      f64.neg
      local.set $f
      local.get $cur
      i32.const 45  ;; '-'
      i32.store8
      local.get $cur
      i32.const 1
      i32.add
      local.set $cur
    end
    ;; Integer part = floor(f).
    local.get $f
    f64.floor
    i64.trunc_f64_s
    local.set $int_part
    ;; Subtract integer part to get the fractional remainder.
    local.get $f
    local.get $int_part
    f64.convert_i64_s
    f64.sub
    local.set $frac
    ;; Emit integer-part digits via $emit_u64 helper.
    local.get $cur
    local.get $int_part
    call $emit_u64
    local.set $cur
    ;; Decimal point.
    local.get $cur
    i32.const 46  ;; '.'
    i32.store8
    local.get $cur
    i32.const 1
    i32.add
    local.set $cur
    ;; 9 decimal digits.
    i32.const 0
    local.set $i
    (block $dec_done
      (loop $dec_loop
        local.get $i
        i32.const 9
        i32.ge_s
        br_if $dec_done
        local.get $frac
        f64.const 10
        f64.mul
        local.set $frac
        local.get $frac
        f64.floor
        i64.trunc_f64_s
        i32.wrap_i64
        local.set $digit
        local.get $cur
        local.get $digit
        i32.const 48
        i32.add
        i32.store8
        local.get $cur
        i32.const 1
        i32.add
        local.set $cur
        local.get $frac
        local.get $digit
        f64.convert_i32_s
        f64.sub
        local.set $frac
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $dec_loop
      )
    )
    ;; Write length prefix.
    local.get $bufp
    local.get $cur
    local.get $bufp
    i32.sub
    i32.const 4
    i32.sub
    i32.store
    ;; Return tagged string ptr.
    local.get $bufp
    i64.extend_i32_u
    i64.const 1
    i64.shl
  )

  ;; emit_u64: writes the decimal digits of `n` (>=0) at `cur` and
  ;; returns the new cur.  Helper for $show_float's integer part.
  (func $emit_u64 (param $cur i32) (param $n i64) (result i32)
    (local $tmpbuf i32)
    (local $tmplen i32)
    (local $q i64)
    (local $r i64)
    ;; Special-case zero.
    local.get $n
    i64.const 0
    i64.eq
    if
      local.get $cur
      i32.const 48
      i32.store8
      local.get $cur
      i32.const 1
      i32.add
      return
    end
    ;; Reserve a 24-byte scratch buffer for reverse digits.
    i32.const 24
    call $alloc
    local.set $tmpbuf
    i32.const 0
    local.set $tmplen
    (block $div_done
      (loop $div_loop
        local.get $n
        i64.const 0
        i64.eq
        br_if $div_done
        local.get $n
        i64.const 10
        i64.div_u
        local.set $q
        local.get $n
        i64.const 10
        i64.rem_u
        local.set $r
        local.get $tmpbuf
        local.get $tmplen
        i32.add
        local.get $r
        i32.wrap_i64
        i32.const 48
        i32.add
        i32.store8
        local.get $tmplen
        i32.const 1
        i32.add
        local.set $tmplen
        local.get $q
        local.set $n
        br $div_loop
      )
    )
    ;; Reverse-copy into cur.
    (block $cp_done
      (loop $cp_loop
        local.get $tmplen
        i32.const 0
        i32.le_s
        br_if $cp_done
        local.get $tmplen
        i32.const 1
        i32.sub
        local.set $tmplen
        local.get $cur
        local.get $tmpbuf
        local.get $tmplen
        i32.add
        i32.load8_u
        i32.store8
        local.get $cur
        i32.const 1
        i32.add
        local.set $cur
        br $cp_loop
      )
    )
    local.get $cur
  )

  ;; Nil sentinel at offset 144
  (data (i32.const 144) "\02\00\00\00\00\00\00\00")

  (func $nil (result i64)
    i64.const 288
  )

  (func $cons (param $hd i64) (param $tl i64) (result i64)
    (local $ptr i32)
    (local $hd_slot i32)
    (local $tl_slot i32)
    ;; Spill operand-stack args to shadow stack so GC (triggered inside
    ;; $alloc_obj) sees them as roots.  The slots live above the
    ;; caller's frame; we restore $shadow_ptr before returning so they
    ;; are reclaimed automatically.
    global.get $shadow_ptr
    local.tee $hd_slot
    local.get $hd
    i64.store
    global.get $shadow_ptr
    i32.const 8
    i32.add
    local.tee $tl_slot
    local.get $tl
    i64.store
    global.get $shadow_ptr
    i32.const 16
    i32.add
    global.set $shadow_ptr
    i32.const 24
    call $alloc_obj
    local.set $ptr
    local.get $ptr
    i64.const 6145  ;; (24 << 8) | 1
    i64.store
    local.get $ptr
    i32.const 8
    i32.add
    local.get $hd_slot
    i64.load
    i64.store
    local.get $ptr
    i32.const 16
    i32.add
    local.get $tl_slot
    i64.load
    i64.store
    local.get $hd_slot
    global.set $shadow_ptr
    local.get $ptr
    i64.extend_i32_u
    i64.const 1
    i64.shl
  )

  (func $head (param $lst i64) (result i64)
    (local $ptr i32)
    local.get $lst
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    local.set $ptr
    local.get $ptr
    i64.load
    i64.const 2
    i64.eq
    if (result i64)
      i64.const 1
    else
      local.get $ptr
      i32.const 8
      i32.add
      i64.load
    end
  )

  (func $tail (param $lst i64) (result i64)
    (local $ptr i32)
    local.get $lst
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    local.set $ptr
    local.get $ptr
    i64.load
    i64.const 2
    i64.eq
    if (result i64)
      call $nil
    else
      local.get $ptr
      i32.const 16
      i32.add
      i64.load
    end
  )

  (func $length (param $lst i64) (result i64)
    (local $ptr i32) (local $count i64)
    i64.const 0
    local.set $count
    block $done
      loop $loop
        local.get $lst
        i64.const 1
        i64.and
        i64.const 1
        i64.eq
        br_if $done
        local.get $lst
        i64.const 1
        i64.shr_u
        i32.wrap_i64
        local.set $ptr
        local.get $ptr
        i64.load
        i64.const 2
        i64.eq
        br_if $done
        local.get $count
        i64.const 1
        i64.add
        local.set $count
        local.get $ptr
        i32.const 16
        i32.add
        i64.load
        local.set $lst
        br $loop
      end
    end
    local.get $count
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
  )

  ;; append two strings → new string on heap
  (func $append (param $a i64) (param $b i64) (result i64)
    (local $pa i32) (local $pb i32) (local $la i32) (local $lb i32)
    (local $ptr i32) (local $i i32)
    ;; untag pointers
    local.get $a
    i32.wrap_i64
    i32.const 1
    i32.shr_u
    local.set $pa
    local.get $b
    i32.wrap_i64
    i32.const 1
    i32.shr_u
    local.set $pb
    ;; load lengths
    local.get $pa
    i32.load
    local.set $la
    local.get $pb
    i32.load
    local.set $lb
    ;; allocate new string: 4 (len) + la + lb
    local.get $la
    local.get $lb
    i32.add
    i32.const 4
    i32.add
    call $alloc
    local.set $ptr
    ;; store combined length
    local.get $ptr
    local.get $la
    local.get $lb
    i32.add
    i32.store
    ;; copy string a
    i32.const 0
    local.set $i
    block $da
      loop $la_loop
        local.get $i
        local.get $la
        i32.ge_u
        br_if $da
        local.get $ptr
        i32.const 4
        i32.add
        local.get $i
        i32.add
        local.get $pa
        i32.const 4
        i32.add
        local.get $i
        i32.add
        i32.load8_u
        i32.store8
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $la_loop
      end
    end
    ;; copy string b
    i32.const 0
    local.set $i
    block $db
      loop $lb_loop
        local.get $i
        local.get $lb
        i32.ge_u
        br_if $db
        local.get $ptr
        i32.const 4
        i32.add
        local.get $la
        i32.add
        local.get $i
        i32.add
        local.get $pb
        i32.const 4
        i32.add
        local.get $i
        i32.add
        i32.load8_u
        i32.store8
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $lb_loop
      end
    end
    ;; return tagged pointer
    local.get $ptr
    i64.extend_i32_u
    i64.const 1
    i64.shl
  )

  ;; show: convert tagged int to heap string
  (func $show (param $val i64) (result i64)
    (local $n i64) (local $neg i32) (local $pos i32) (local $len i32)
    (local $ptr i32) (local $digit i32)
    ;; check if string (even, not tagged int)
    local.get $val
    i64.const 1
    i64.and
    i64.const 0
    i64.eq
    if (result i64)
      ;; already a string/pointer — pass through
      local.get $val
    else
      ;; integer: untag
      local.get $val
      i64.const 1
      i64.shr_s
      local.set $n
      ;; check negative
      local.get $n
      i64.const 0
      i64.lt_s
      local.set $neg
      local.get $neg
      if
        i64.const 0
        local.get $n
        i64.sub
        local.set $n
      end
      ;; write digits backwards into temp buffer at 150
      i32.const 170
      local.set $pos
      block $done
        loop $loop
          local.get $n
          i64.const 10
          i64.rem_s
          i32.wrap_i64
          i32.const 48
          i32.add
          local.set $digit
          local.get $pos
          local.get $digit
          i32.store8
          local.get $pos
          i32.const 1
          i32.sub
          local.set $pos
          local.get $n
          i64.const 10
          i64.div_s
          local.set $n
          local.get $n
          i64.const 0
          i64.gt_s
          br_if $loop
        end
      end
      ;; add minus sign
      local.get $neg
      if
        local.get $pos
        i32.const 45
        i32.store8
        local.get $pos
        i32.const 1
        i32.sub
        local.set $pos
      end
      ;; length = 170 - pos
      i32.const 170
      local.get $pos
      i32.sub
      local.set $len
      ;; allocate heap string
      local.get $len
      i32.const 4
      i32.add
      call $alloc
      local.set $ptr
      local.get $ptr
      local.get $len
      i32.store
      ;; copy digits
      i32.const 0
      local.set $digit  ;; reuse as index
      block $cpd
        loop $cpl
          local.get $digit
          local.get $len
          i32.ge_u
          br_if $cpd
          local.get $ptr
          i32.const 4
          i32.add
          local.get $digit
          i32.add
          local.get $pos
          i32.const 1
          i32.add
          local.get $digit
          i32.add
          i32.load8_u
          i32.store8
          local.get $digit
          i32.const 1
          i32.add
          local.set $digit
          br $cpl
        end
      end
      ;; return tagged pointer
      local.get $ptr
      i64.extend_i32_u
      i64.const 1
      i64.shl
    end
  )

  ;; join: join list of strings with separator
  ;; ─── File I/O stubs ──────────────────────────────────────────
  ;; WASM standalone has no file system without WASI host wiring.
  ;; These stubs let Rail programs that call write_file / append_file
  ;; / read_file compile and run; they're no-ops returning empty.
  ;; Useful for porting compute kernels (e.g. MHD) where the file
  ;; dumps are diagnostic-only.

  (func $write_file (param $path i64) (param $content i64) (result i64)
    i64.const 3  ;; tagged 1
  )

  (func $append_file (param $path i64) (param $content i64) (result i64)
    i64.const 3
  )

  (func $read_file (param $path i64) (result i64)
    ;; Return empty string (4-byte len=0 header).
    (local $p i32)
    i32.const 4
    call $alloc
    local.tee $p
    i32.const 0
    i32.store
    local.get $p
    i64.extend_i32_u
    i64.const 1
    i64.shl
  )

  (func $shell (param $cmd i64) (result i64)
    local.get $cmd
    call $read_file  ;; same empty-string shape
  )

  ;; cat lst — equivalent to join "" lst.  Builds an empty-string sep
  ;; on the heap and dispatches to $join.  Used everywhere Rail code
  ;; writes `cat [a, b, c]` for string concatenation.
  (func $cat (param $lst i64) (result i64)
    (local $sep_ptr i32)
    (local $sep i64)
    i32.const 4
    call $alloc
    local.tee $sep_ptr
    i32.const 0
    i32.store
    local.get $sep_ptr
    i64.extend_i32_u
    i64.const 1
    i64.shl
    local.set $sep
    local.get $sep
    local.get $lst
    call $join
  )

  (func $join (param $sep i64) (param $lst i64) (result i64)
    (local $ptr i32) (local $result i64) (local $first i32)
    ;; start with empty string: alloc 4 bytes, length=0
    i32.const 4
    call $alloc
    local.tee $ptr
    i32.const 0
    i32.store
    local.get $ptr
    i64.extend_i32_u
    i64.const 1
    i64.shl
    local.set $result
    i32.const 1
    local.set $first
    block $done
      loop $loop
        ;; check if lst is tagged int (nil check)
        local.get $lst
        i64.const 1
        i64.and
        i64.const 1
        i64.eq
        br_if $done
        ;; untag list pointer, check tag
        local.get $lst
        i64.const 1
        i64.shr_u
        i32.wrap_i64
        local.set $ptr
        local.get $ptr
        i64.load
        i64.const 2
        i64.eq
        br_if $done
        ;; if not first, append separator
        local.get $first
        i32.eqz
        if
          local.get $result
          local.get $sep
          call $append
          local.set $result
        end
        i32.const 0
        local.set $first
        ;; append head element
        local.get $result
        local.get $ptr
        i32.const 8
        i32.add
        i64.load
        call $append
        local.set $result
        ;; advance to tail
        local.get $ptr
        i32.const 16
        i32.add
        i64.load
        local.set $lst
        br $loop
      end
    end
    local.get $result
  )

  ;; reverse a list
  (func $reverse (param $lst i64) (result i64)
    (local $ptr i32) (local $acc i64)
    call $nil
    local.set $acc
    block $done
      loop $loop
        local.get $lst
        i64.const 1
        i64.and
        i64.const 1
        i64.eq
        br_if $done
        local.get $lst
        i64.const 1
        i64.shr_u
        i32.wrap_i64
        local.set $ptr
        local.get $ptr
        i64.load
        i64.const 2
        i64.eq
        br_if $done
        ;; cons (head lst) acc
        local.get $ptr
        i32.const 8
        i32.add
        i64.load
        local.get $acc
        call $cons
        local.set $acc
        ;; lst = tail lst
        local.get $ptr
        i32.const 16
        i32.add
        i64.load
        local.set $lst
        br $loop
      end
    end
    local.get $acc
  )

  ;; ─── map / filter / fold ─────────────────────────────────────
  ;; Closure signature (in $clos_t): (closure, arg) → result.
  ;; Calls the closure tagged-pointer by loading its fn index
  ;; from offset 8 of the unshifted heap address.
  (func $call_closure (param $clos i64) (param $arg i64) (result i64)
    local.get $clos
    local.get $arg
    local.get $clos
    i64.const 1
    i64.shr_u
    i32.wrap_i64
    i32.const 8
    i32.add
    i64.load
    i32.wrap_i64
    call_indirect (type $clos_t)
  )

  ;; map f xs — build a new list by applying f to each element.
  ;; Builds result reversed then reverses at the end to preserve
  ;; input order.
  (func $map (param $f i64) (param $lst i64) (result i64)
    (local $ptr i32) (local $acc i64) (local $hd i64)
    call $nil
    local.set $acc
    block $done
      loop $loop
        local.get $lst
        i64.const 1
        i64.and
        i64.const 1
        i64.eq
        br_if $done
        local.get $lst
        i64.const 1
        i64.shr_u
        i32.wrap_i64
        local.set $ptr
        local.get $ptr
        i64.load
        i64.const 2
        i64.eq
        br_if $done
        local.get $ptr
        i32.const 8
        i32.add
        i64.load
        local.set $hd
        local.get $f
        local.get $hd
        call $call_closure
        local.get $acc
        call $cons
        local.set $acc
        local.get $ptr
        i32.const 16
        i32.add
        i64.load
        local.set $lst
        br $loop
      end
    end
    local.get $acc
    call $reverse
  )

  ;; filter p xs — keep elements where p returns a truthy tagged
  ;; int (anything ≠ tagged 0 / tagged-int 1).  Truthy here means
  ;; the tagged-int result is NOT equal to 1 (= tagged 0).
  (func $filter (param $p i64) (param $lst i64) (result i64)
    (local $ptr i32) (local $acc i64) (local $hd i64) (local $res i64)
    call $nil
    local.set $acc
    block $done
      loop $loop
        local.get $lst
        i64.const 1
        i64.and
        i64.const 1
        i64.eq
        br_if $done
        local.get $lst
        i64.const 1
        i64.shr_u
        i32.wrap_i64
        local.set $ptr
        local.get $ptr
        i64.load
        i64.const 2
        i64.eq
        br_if $done
        local.get $ptr
        i32.const 8
        i32.add
        i64.load
        local.set $hd
        local.get $p
        local.get $hd
        call $call_closure
        local.set $res
        local.get $res
        i64.const 1
        i64.ne
        if
          local.get $hd
          local.get $acc
          call $cons
          local.set $acc
        end
        local.get $ptr
        i32.const 16
        i32.add
        i64.load
        local.set $lst
        br $loop
      end
    end
    local.get $acc
    call $reverse
  )

  ;; fold f init xs — left fold: result = f (… (f (f init x0) x1) …) xN.
  ;; The 2-arg closure is curried at the Rail level as `\acc -> \x -> ...`,
  ;; which compiles to a nested closure.  We implement the Rail calling
  ;; convention: call(f, acc) returns a 1-arg closure, then call that
  ;; with x to get the next acc.
  (func $fold (param $f i64) (param $init i64) (param $lst i64) (result i64)
    (local $ptr i32) (local $acc i64) (local $hd i64) (local $inner i64)
    local.get $init
    local.set $acc
    block $done
      loop $loop
        local.get $lst
        i64.const 1
        i64.and
        i64.const 1
        i64.eq
        br_if $done
        local.get $lst
        i64.const 1
        i64.shr_u
        i32.wrap_i64
        local.set $ptr
        local.get $ptr
        i64.load
        i64.const 2
        i64.eq
        br_if $done
        local.get $ptr
        i32.const 8
        i32.add
        i64.load
        local.set $hd
        local.get $f
        local.get $acc
        call $call_closure
        local.set $inner
        local.get $inner
        local.get $hd
        call $call_closure
        local.set $acc
        local.get $ptr
        i32.const 16
        i32.add
        i64.load
        local.set $lst
        br $loop
      end
    end
    local.get $acc
  )

  (func $str_eq (param $a i64) (param $b i64) (result i32)
    (local $pa i32) (local $pb i32) (local $la i32) (local $i i32)
    local.get $a
    i32.wrap_i64
    i32.const 1
    i32.shr_u
    local.set $pa
    local.get $b
    i32.wrap_i64
    i32.const 1
    i32.shr_u
    local.set $pb
    local.get $pa
    i32.load
    local.set $la
    local.get $la
    local.get $pb
    i32.load
    i32.ne
    if
      i32.const 0
      return
    end
    i32.const 0
    local.set $i
    block $done
      loop $loop
        local.get $i
        local.get $la
        i32.ge_u
        br_if $done
        local.get $pa
        i32.const 4
        i32.add
        local.get $i
        i32.add
        i32.load8_u
        local.get $pb
        i32.const 4
        i32.add
        local.get $i
        i32.add
        i32.load8_u
        i32.ne
        if
          i32.const 0
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    i32.const 1
  )

  (func $__rail_print (param $val i64)
    (local $n i64) (local $pos i32) (local $neg i32) (local $digit i32)
    (local $sptr i32) (local $slen i32)
    local.get $val
    i64.const 1
    i64.and
    i64.const 1
    i64.eq
    if
      ;; Integer: untag and print
      local.get $val
      i64.const 1
      i64.shr_s
      local.set $n
      local.get $n
      i64.const 0
      i64.lt_s
      local.set $neg
      local.get $neg
      if
        i64.const 0
        local.get $n
        i64.sub
        local.set $n
      end
      i32.const 130
      local.set $pos
      local.get $pos
      i32.const 10
      i32.store8
      local.get $pos
      i32.const 1
      i32.sub
      local.set $pos
      block $done
        loop $loop
          local.get $n
          i64.const 10
          i64.rem_s
          i32.wrap_i64
          i32.const 48
          i32.add
          local.set $digit
          local.get $pos
          local.get $digit
          i32.store8
          local.get $pos
          i32.const 1
          i32.sub
          local.set $pos
          local.get $n
          i64.const 10
          i64.div_s
          local.set $n
          local.get $n
          i64.const 0
          i64.gt_s
          br_if $loop
        end
      end
      local.get $neg
      if
        local.get $pos
        i32.const 45
        i32.store8
        local.get $pos
        i32.const 1
        i32.sub
        local.set $pos
      end
      i32.const 0
      local.get $pos
      i32.const 1
      i32.add
      i32.store
      i32.const 4
      i32.const 130
      local.get $pos
      i32.sub
      i32.store
      i32.const 1
      i32.const 0
      i32.const 1
      i32.const 8
      call $fd_write
      drop
    else
      ;; String: val is (offset * 2), offset has 4-byte len + data
      local.get $val
      i32.wrap_i64
      i32.const 1
      i32.shr_u
      local.set $sptr
      local.get $sptr
      i32.load
      local.set $slen
      ;; Write string data
      i32.const 0
      local.get $sptr
      i32.const 4
      i32.add
      i32.store
      i32.const 4
      local.get $slen
      i32.store
      i32.const 1
      i32.const 0
      i32.const 1
      i32.const 8
      call $fd_write
      drop
      ;; Print newline
      i32.const 0
      i32.const 140
      i32.store
      i32.const 4
      i32.const 1
      i32.store
      i32.const 140
      i32.const 10
      i32.store8
      i32.const 1
      i32.const 0
      i32.const 1
      i32.const 8
      call $fd_write
      drop
    end
  )

  (func $nn  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 257
  )

  (func $nn2  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 32769
  )

  (func $nfields  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 13
  )

  (func $state_size  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 196609
  )

  (func $f_rho  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 1
  )

  (func $f_vx  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 3
  )

  (func $f_vy  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 5
  )

  (func $f_p  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 7
  )

  (func $f_bx  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 9
  )

  (func $f_by  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 11
  )

  (func $wrap (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 1
    i64.const 1
    i64.shr_s
    i64.lt_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    else
    local.get $i
    end
    end
  )

  (func $idx (param $f i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $f
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    local.get $y
    call $wrap
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    local.get $x
    call $wrap
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
  )

  (func $sget (param $state i64) (param $f i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $state
    local.get $f
    local.get $x
    local.get $y
    call $idx
    call $float_arr_get
  )

  (func $sset (param $state i64) (param $f i64) (param $x i64) (param $y i64) (param $v i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $state
    local.get $f
    local.get $x
    local.get $y
    call $idx
    local.get $v
    call $float_arr_set
  )

  (func $seed_ot_cell (param $state i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $xp i64)
    (local $yp i64)
    (local $rho i64)
    (local $vx i64)
    (local $vy i64)
    (local $bx i64)
    (local $by i64)
    (local $p i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $x
    call $to_float
    f64.reinterpret_i64
    f64.const 0.04908738521234052
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $xp
    local.get $y
    call $to_float
    f64.reinterpret_i64
    f64.const 0.04908738521234052
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $yp
    f64.const 2.77777777777778
    i64.reinterpret_f64
    local.set $rho
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $yp
    call $sin
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $vx
    local.get $xp
    call $sin
    local.set $vy
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $yp
    call $sin
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $bx
    f64.const 2.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $xp
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    call $sin
    local.set $by
    f64.const 1.6666666666666667
    i64.reinterpret_f64
    local.set $p
    local.get $state
    call $f_rho
    local.get $x
    local.get $y
    local.get $rho
    call $sset
    local.set $_
    local.get $state
    call $f_vx
    local.get $x
    local.get $y
    local.get $vx
    call $sset
    local.set $_
    local.get $state
    call $f_vy
    local.get $x
    local.get $y
    local.get $vy
    call $sset
    local.set $_
    local.get $state
    call $f_p
    local.get $x
    local.get $y
    local.get $p
    call $sset
    local.set $_
    local.get $state
    call $f_bx
    local.get $x
    local.get $y
    local.get $bx
    call $sset
    local.set $_
    local.get $state
    call $f_by
    local.get $x
    local.get $y
    local.get $by
    return_call $sset
  )

  (func $seed_ot (param $state i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $state
    local.get $i
    call $seed_ot_cell
    local.set $_
    local.get $state
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $seed_ot
    end
  )

  (func $vort_at (param $state i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $vy_xp i64)
    (local $vy_xm i64)
    (local $vx_yp i64)
    (local $vx_ym i64)
    local.get $state
    call $f_vy
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $vy_xp
    local.get $state
    call $f_vy
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $vy_xm
    local.get $state
    call $f_vx
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $vx_yp
    local.get $state
    call $f_vx
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $vx_ym
    local.get $vy_xp
    f64.reinterpret_i64
    local.get $vy_xm
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vx_yp
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vx_ym
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
  )

  (func $vorticity_loop (param $state i64) (param $out i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $out
    local.get $i
    local.get $state
    local.get $x
    local.get $y
    call $vort_at
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $out
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $vorticity_loop
    end
  )

  (func $vorticity (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $out i64)
    (local $_ i64)
    call $nn2
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $out
    local.get $state
    local.get $out
    i64.const 1
    call $vorticity_loop
    local.set $_
    local.get $out
  )

  (func $jmag_at (param $state i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $by_xp i64)
    (local $by_xm i64)
    (local $bx_yp i64)
    (local $bx_ym i64)
    (local $j i64)
    local.get $state
    call $f_by
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $by_xp
    local.get $state
    call $f_by
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $by_xm
    local.get $state
    call $f_bx
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $bx_yp
    local.get $state
    call $f_bx
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $bx_ym
    local.get $by_xp
    f64.reinterpret_i64
    local.get $by_xm
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $bx_yp
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $bx_ym
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $j
    local.get $j
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $j
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    else
    local.get $j
    end
  )

  (func $current_density_loop (param $state i64) (param $out i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $out
    local.get $i
    local.get $state
    local.get $x
    local.get $y
    call $jmag_at
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $out
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $current_density_loop
    end
  )

  (func $current_density (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $out i64)
    (local $_ i64)
    call $nn2
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $out
    local.get $state
    local.get $out
    i64.const 1
    call $current_density_loop
    local.set $_
    local.get $out
  )

  (func $schlieren_at (param $state i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $r_xp i64)
    (local $r_xm i64)
    (local $r_yp i64)
    (local $r_ym i64)
    (local $dx i64)
    (local $dy i64)
    local.get $state
    call $f_rho
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $r_xp
    local.get $state
    call $f_rho
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $r_xm
    local.get $state
    call $f_rho
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $r_yp
    local.get $state
    call $f_rho
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $r_ym
    local.get $r_xp
    f64.reinterpret_i64
    local.get $r_xm
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $dx
    local.get $r_yp
    f64.reinterpret_i64
    local.get $r_ym
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $dy
    local.get $dx
    f64.reinterpret_i64
    local.get $dx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dy
    f64.reinterpret_i64
    local.get $dy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $sqrt
  )

  (func $schlieren_loop (param $state i64) (param $out i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $out
    local.get $i
    local.get $state
    local.get $x
    local.get $y
    call $schlieren_at
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $out
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $schlieren_loop
    end
  )

  (func $schlieren (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $out i64)
    (local $_ i64)
    call $nn2
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $out
    local.get $state
    local.get $out
    i64.const 1
    call $schlieren_loop
    local.set $_
    local.get $out
  )

  (func $ke_acc_loop (param $state i64) (param $acc i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $r i64)
    (local $vx i64)
    (local $vy i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $acc
    i64.const 1
    call $float_arr_get
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $state
    call $f_rho
    local.get $x
    local.get $y
    call $sget
    local.set $r
    local.get $state
    call $f_vx
    local.get $x
    local.get $y
    call $sget
    local.set $vx
    local.get $state
    call $f_vy
    local.get $x
    local.get $y
    call $sget
    local.set $vy
    local.get $acc
    i64.const 1
    local.get $acc
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $r
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vx
    f64.reinterpret_i64
    local.get $vx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vy
    f64.reinterpret_i64
    local.get $vy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $acc
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $ke_acc_loop
    end
  )

  (func $me_acc_loop (param $state i64) (param $acc i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $bx i64)
    (local $by i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $acc
    i64.const 1
    call $float_arr_get
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $state
    call $f_bx
    local.get $x
    local.get $y
    call $sget
    local.set $bx
    local.get $state
    call $f_by
    local.get $x
    local.get $y
    call $sget
    local.set $by
    local.get $acc
    i64.const 1
    local.get $acc
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $bx
    f64.reinterpret_i64
    local.get $bx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $by
    f64.reinterpret_i64
    local.get $by
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $acc
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $me_acc_loop
    end
  )

  (func $divb_max_loop (param $state i64) (param $acc i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $bxp i64)
    (local $bxm i64)
    (local $byp i64)
    (local $bym i64)
    (local $div i64)
    (local $absdiv i64)
    (local $cur i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $acc
    i64.const 1
    call $float_arr_get
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $state
    call $f_bx
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $bxp
    local.get $state
    call $f_bx
    local.get $x
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $y
    call $sget
    local.set $bxm
    local.get $state
    call $f_by
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $byp
    local.get $state
    call $f_by
    local.get $x
    local.get $y
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $sget
    local.set $bym
    local.get $bxp
    f64.reinterpret_i64
    local.get $bxm
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $byp
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $bym
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $div
    local.get $div
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $div
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    else
    local.get $div
    end
    local.set $absdiv
    local.get $acc
    i64.const 1
    call $float_arr_get
    local.set $cur
    local.get $absdiv
    f64.reinterpret_i64
    local.get $cur
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $acc
    i64.const 1
    local.get $absdiv
    call $float_arr_set
    else
    i64.const 1
    end
    local.set $_
    local.get $state
    local.get $acc
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $divb_max_loop
    end
  )

  (func $vort_mean_loop (param $state i64) (param $acc i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $acc
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    f64.const 16384.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $acc
    i64.const 1
    local.get $acc
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    local.get $state
    local.get $x
    local.get $y
    call $vort_at
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $acc
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $vort_mean_loop
    end
  )

  (func $total_kinetic_energy (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $acc i64)
    i64.const 3
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $acc
    local.get $state
    local.get $acc
    i64.const 1
    return_call $ke_acc_loop
  )

  (func $total_magnetic_energy (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $acc i64)
    i64.const 3
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $acc
    local.get $state
    local.get $acc
    i64.const 1
    return_call $me_acc_loop
  )

  (func $max_divb (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $acc i64)
    i64.const 3
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $acc
    local.get $state
    local.get $acc
    i64.const 1
    return_call $divb_max_loop
  )

  (func $mean_vorticity (param $state i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $acc i64)
    i64.const 3
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $acc
    local.get $state
    local.get $acc
    i64.const 1
    return_call $vort_mean_loop
  )

  (func $sign_f (param $x i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 3
    else
    local.get $x
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    else
    i64.const 1
    end
    end
  )

  (func $noise_get (param $noise i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $noise
    local.get $y
    call $wrap
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    local.get $x
    call $wrap
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
  )

  (func $lic_walk (param $state i64) (param $noise i64) (param $acc_arr i64) (param $x i64) (param $y i64) (param $dx i64) (param $dy i64) (param $n i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $xn i64)
    (local $yn i64)
    (local $nval i64)
    (local $_ i64)
    (local $vx i64)
    (local $vy i64)
    (local $ndx i64)
    (local $ndy i64)
    local.get $n
    i64.const 1
    i64.shr_s
    i64.const 1
    i64.const 1
    i64.shr_s
    i64.le_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $x
    i64.const 1
    i64.shr_s
    local.get $dx
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $wrap
    local.set $xn
    local.get $y
    i64.const 1
    i64.shr_s
    local.get $dy
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $wrap
    local.set $yn
    local.get $noise
    local.get $xn
    local.get $yn
    call $noise_get
    local.set $nval
    local.get $acc_arr
    i64.const 1
    local.get $acc_arr
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    local.get $nval
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $state
    call $f_vx
    local.get $xn
    local.get $yn
    call $sget
    local.set $vx
    local.get $state
    call $f_vy
    local.get $xn
    local.get $yn
    call $sget
    local.set $vy
    local.get $vx
    call $sign_f
    local.set $ndx
    local.get $vy
    call $sign_f
    local.set $ndy
    local.get $state
    local.get $noise
    local.get $acc_arr
    local.get $xn
    local.get $yn
    local.get $ndx
    local.get $ndy
    local.get $n
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $lic_walk
    end
  )

  (func $lic_at (param $state i64) (param $noise i64) (param $acc_arr i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $vx i64)
    (local $vy i64)
    (local $dx i64)
    (local $dy i64)
    (local $_ i64)
    local.get $acc_arr
    i64.const 1
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $state
    call $f_vx
    local.get $x
    local.get $y
    call $sget
    local.set $vx
    local.get $state
    call $f_vy
    local.get $x
    local.get $y
    call $sget
    local.set $vy
    local.get $vx
    call $sign_f
    local.set $dx
    local.get $vy
    call $sign_f
    local.set $dy
    local.get $state
    local.get $noise
    local.get $acc_arr
    local.get $x
    local.get $y
    local.get $dx
    local.get $dy
    i64.const 25
    call $lic_walk
    local.set $_
    local.get $state
    local.get $noise
    local.get $acc_arr
    local.get $x
    local.get $y
    i64.const 1
    i64.const 1
    i64.shr_s
    local.get $dx
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.const 1
    i64.shr_s
    local.get $dy
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 25
    call $lic_walk
    local.set $_
    local.get $acc_arr
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    f64.const 0.04166666666666667
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
  )

  (func $lic_loop (param $state i64) (param $noise i64) (param $out i64) (param $acc_arr i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $x i64)
    (local $y i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn2
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $x
    local.get $i
    i64.const 1
    i64.shr_s
    call $nn
    i64.const 1
    i64.shr_s
    i64.div_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $y
    local.get $out
    local.get $i
    local.get $state
    local.get $noise
    local.get $acc_arr
    local.get $x
    local.get $y
    call $lic_at
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $noise
    local.get $out
    local.get $acc_arr
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $lic_loop
    end
  )

  (func $lic (param $state i64) (param $noise i64) (param $out i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $acc_arr i64)
    (local $_ i64)
    i64.const 3
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $acc_arr
    local.get $state
    local.get $noise
    local.get $out
    local.get $acc_arr
    i64.const 1
    call $lic_loop
    local.set $_
    local.get $out
  )

  (func $wrap_f (param $x i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $x
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.ge
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    else
    local.get $x
    end
    end
  )

  (func $vsample_vx (param $state i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $xi i64)
    (local $yi i64)
    local.get $x
    call $float_to_int
    local.set $xi
    local.get $y
    call $float_to_int
    local.set $yi
    local.get $state
    call $f_vx
    local.get $xi
    local.get $yi
    return_call $sget
  )

  (func $vsample_vy (param $state i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $xi i64)
    (local $yi i64)
    local.get $x
    call $float_to_int
    local.set $xi
    local.get $y
    call $float_to_int
    local.set $yi
    local.get $state
    call $f_vy
    local.get $xi
    local.get $yi
    return_call $sget
  )

  (func $particle_step_one (param $state i64) (param $particles i64) (param $dt_arr i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $dt i64)
    (local $xi i64)
    (local $yi i64)
    (local $vx0 i64)
    (local $vy0 i64)
    (local $xm i64)
    (local $ym i64)
    (local $vxm i64)
    (local $vym i64)
    (local $xn i64)
    (local $yn i64)
    (local $_ i64)
    local.get $dt_arr
    i64.const 1
    call $float_arr_get
    local.set $dt
    local.get $particles
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    local.set $xi
    local.get $particles
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    local.set $yi
    local.get $state
    local.get $xi
    local.get $yi
    call $vsample_vx
    local.set $vx0
    local.get $state
    local.get $xi
    local.get $yi
    call $vsample_vy
    local.set $vy0
    local.get $xi
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vx0
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $wrap_f
    local.set $xm
    local.get $yi
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vy0
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $wrap_f
    local.set $ym
    local.get $state
    local.get $xm
    local.get $ym
    call $vsample_vx
    local.set $vxm
    local.get $state
    local.get $xm
    local.get $ym
    call $vsample_vy
    local.set $vym
    local.get $xi
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    local.get $vxm
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $wrap_f
    local.set $xn
    local.get $yi
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    local.get $vym
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $wrap_f
    local.set $yn
    local.get $particles
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $xn
    call $float_arr_set
    local.set $_
    local.get $particles
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $yn
    call $float_arr_set
  )

  (func $particle_step_loop (param $state i64) (param $particles i64) (param $dt_arr i64) (param $k i64) (param $i i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $_ i64)
    local.get $i
    i64.const 1
    i64.shr_s
    local.get $k
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $state
    local.get $particles
    local.get $dt_arr
    local.get $i
    call $particle_step_one
    local.set $_
    local.get $state
    local.get $particles
    local.get $dt_arr
    local.get $k
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $particle_step_loop
    end
  )

  (func $particle_step (param $state i64) (param $particles i64) (param $k i64) (param $dt_arr i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $_ i64)
    local.get $state
    local.get $particles
    local.get $dt_arr
    local.get $k
    i64.const 1
    call $particle_step_loop
    local.set $_
    local.get $particles
  )

  (func $img_w  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 257
  )

  (func $img_h  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 257
  )

  (func $img_n  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 32769
  )

  (func $img_bytes  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 98305
  )

  (func $march_steps  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    i64.const 49
  )

  (func $cam_ox  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 96.0
    i64.reinterpret_f64
  )

  (func $cam_oy  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 96.0
    i64.reinterpret_f64
  )

  (func $cam_oz  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 50.0
    i64.reinterpret_f64
  )

  (func $cam_fwd_x  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.6635
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
  )

  (func $cam_fwd_y  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.6635
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
  )

  (func $cam_fwd_z  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.3456
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
  )

  (func $cam_right_x  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.7071
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
  )

  (func $cam_right_y  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.7071
    i64.reinterpret_f64
  )

  (func $cam_right_z  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
  )

  (func $cam_up_x  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.244
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
  )

  (func $cam_up_y  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.244
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
  )

  (func $cam_up_z  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 0.939
    i64.reinterpret_f64
  )

  (func $view_extent  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 100.0
    i64.reinterpret_f64
  )

  (func $cyl_radius  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 50.0
    i64.reinterpret_f64
  )

  (func $cyl_halfh  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    f64.const 30.0
    i64.reinterpret_f64
  )

  (func $plane_sample (param $state i64) (param $f i64) (param $x i64) (param $y i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $xw i64)
    (local $yw i64)
    (local $xi i64)
    (local $yi i64)
    (local $xn i64)
    (local $yn i64)
    (local $fx i64)
    (local $fy i64)
    (local $v00 i64)
    (local $v10 i64)
    (local $v01 i64)
    (local $v11 i64)
    (local $v0 i64)
    (local $v1 i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $x
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.ge
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    else
    local.get $x
    end
    end
    local.set $xw
    local.get $y
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $y
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $y
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.ge
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $y
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    else
    local.get $y
    end
    end
    local.set $yw
    local.get $xw
    call $floor
    call $float_to_int
    local.set $xi
    local.get $yw
    call $floor
    call $float_to_int
    local.set $yi
    local.get $xi
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $xn
    local.get $yi
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.rem_s
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $yn
    local.get $xw
    f64.reinterpret_i64
    local.get $xi
    call $to_float
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $fx
    local.get $yw
    f64.reinterpret_i64
    local.get $yi
    call $to_float
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $fy
    local.get $state
    local.get $f
    local.get $xi
    local.get $yi
    call $sget
    local.set $v00
    local.get $state
    local.get $f
    local.get $xn
    local.get $yi
    call $sget
    local.set $v10
    local.get $state
    local.get $f
    local.get $xi
    local.get $yn
    call $sget
    local.set $v01
    local.get $state
    local.get $f
    local.get $xn
    local.get $yn
    call $sget
    local.set $v11
    local.get $v00
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $fx
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $v10
    f64.reinterpret_i64
    local.get $fx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $v0
    local.get $v01
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $fx
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $v11
    f64.reinterpret_i64
    local.get $fx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $v1
    local.get $v0
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $fy
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $v1
    f64.reinterpret_i64
    local.get $fy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
  )

  (func $viridis_r (param $t i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $tt i64)
    local.get $t
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    else
    local.get $t
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 1.0
    i64.reinterpret_f64
    else
    local.get $t
    end
    end
    local.set $tt
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.267
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.231
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.267
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.50
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.231
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.129
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.231
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.75
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.129
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.365
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.129
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.50
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    f64.const 0.365
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.992
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.365
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.75
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    end
    end
    end
  )

  (func $viridis_g (param $t i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $tt i64)
    local.get $t
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    else
    local.get $t
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 1.0
    i64.reinterpret_f64
    else
    local.get $t
    end
    end
    local.set $tt
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.004
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.322
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.004
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.50
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.322
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.565
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.322
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.75
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.565
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.788
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.565
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.50
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    f64.const 0.788
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.906
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.788
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.75
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    end
    end
    end
  )

  (func $viridis_b (param $t i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $tt i64)
    local.get $t
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    else
    local.get $t
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 1.0
    i64.reinterpret_f64
    else
    local.get $t
    end
    end
    local.set $tt
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.329
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.545
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.329
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.50
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.545
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.553
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.545
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.75
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.553
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.388
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.553
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.50
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    else
    f64.const 0.388
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.145
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.388
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $tt
    f64.reinterpret_i64
    f64.const 0.75
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    end
    end
    end
  )

  (func $aces_curve (param $x i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $xx i64)
    (local $num i64)
    (local $den i64)
    (local $r i64)
    local.get $x
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    else
    local.get $x
    end
    local.set $xx
    local.get $xx
    f64.reinterpret_i64
    f64.const 2.51
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $xx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.03
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $num
    local.get $xx
    f64.reinterpret_i64
    f64.const 2.43
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $xx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.59
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.14
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $den
    local.get $num
    f64.reinterpret_i64
    local.get $den
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    local.set $r
    local.get $r
    f64.reinterpret_i64
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 1.0
    i64.reinterpret_f64
    else
    local.get $r
    end
  )

  (func $intersect_cylinder (param $ray_arr i64) (param $result_arr i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $ox i64)
    (local $oy i64)
    (local $oz i64)
    (local $dx i64)
    (local $dy i64)
    (local $dz i64)
    (local $radius2 i64)
    (local $halfh i64)
    (local $a i64)
    (local $b i64)
    (local $c i64)
    (local $disc i64)
    (local $sqd i64)
    (local $t_in_xy i64)
    (local $t_out_xy i64)
    (local $t_z1 i64)
    (local $t_z2 i64)
    (local $t_zmin i64)
    (local $t_zmax i64)
    (local $t_enter i64)
    (local $t_exit i64)
    (local $_ i64)
    local.get $ray_arr
    i64.const 1
    call $float_arr_get
    local.set $ox
    local.get $ray_arr
    i64.const 3
    call $float_arr_get
    local.set $oy
    local.get $ray_arr
    i64.const 5
    call $float_arr_get
    local.set $oz
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.6635
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $dx
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.6635
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $dy
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.3456
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $dz
    f64.const 2500.0
    i64.reinterpret_f64
    local.set $radius2
    f64.const 30.0
    i64.reinterpret_f64
    local.set $halfh
    local.get $dx
    f64.reinterpret_i64
    local.get $dx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dy
    f64.reinterpret_i64
    local.get $dy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $a
    f64.const 2.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $ox
    f64.reinterpret_i64
    local.get $dx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $oy
    f64.reinterpret_i64
    local.get $dy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $b
    local.get $ox
    f64.reinterpret_i64
    local.get $ox
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $oy
    f64.reinterpret_i64
    local.get $oy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $radius2
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $c
    local.get $b
    f64.reinterpret_i64
    local.get $b
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 4.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $a
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $c
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $disc
    local.get $disc
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $result_arr
    i64.const 5
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    else
    local.get $disc
    call $sqrt
    local.set $sqd
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $b
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $sqd
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 2.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $a
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    local.set $t_in_xy
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $b
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $sqd
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 2.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $a
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    local.set $t_out_xy
    local.get $halfh
    f64.reinterpret_i64
    local.get $oz
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dz
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    local.set $t_z1
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $halfh
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $oz
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dz
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    local.set $t_z2
    local.get $t_z1
    f64.reinterpret_i64
    local.get $t_z2
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $t_z1
    else
    local.get $t_z2
    end
    local.set $t_zmin
    local.get $t_z1
    f64.reinterpret_i64
    local.get $t_z2
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $t_z2
    else
    local.get $t_z1
    end
    local.set $t_zmax
    local.get $t_in_xy
    f64.reinterpret_i64
    local.get $t_zmin
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $t_in_xy
    else
    local.get $t_zmin
    end
    local.set $t_enter
    local.get $t_out_xy
    f64.reinterpret_i64
    local.get $t_zmax
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $t_out_xy
    else
    local.get $t_zmax
    end
    local.set $t_exit
    local.get $t_enter
    f64.reinterpret_i64
    local.get $t_exit
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    local.get $t_exit
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $result_arr
    i64.const 1
    local.get $t_enter
    call $float_arr_set
    local.set $_
    local.get $result_arr
    i64.const 3
    local.get $t_exit
    call $float_arr_set
    local.set $_
    local.get $result_arr
    i64.const 5
    f64.const 1.0
    i64.reinterpret_f64
    call $float_arr_set
    else
    local.get $result_arr
    i64.const 5
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    end
    end
  )

  (func $march_loop (param $state i64) (param $acc_arr i64) (param $ray_arr i64) (param $n i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $fx i64)
    (local $fy i64)
    (local $ox i64)
    (local $oy i64)
    (local $t i64)
    (local $dt i64)
    (local $px i64)
    (local $py i64)
    (local $xs i64)
    (local $ys i64)
    (local $rho i64)
    (local $vx i64)
    (local $vy i64)
    (local $bx i64)
    (local $by i64)
    (local $rho_n i64)
    (local $cr i64)
    (local $cg i64)
    (local $cb i64)
    (local $vort_proxy i64)
    (local $tr i64)
    (local $tg i64)
    (local $er i64)
    (local $eg i64)
    (local $eb i64)
    (local $sigma i64)
    (local $sigma_pos i64)
    (local $alpha_step i64)
    (local $one_minus_a i64)
    (local $weight i64)
    (local $_ i64)
    local.get $n
    i64.const 1
    i64.shr_s
    i64.const 1
    i64.const 1
    i64.shr_s
    i64.le_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.6635
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $fx
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.6635
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $fy
    local.get $ray_arr
    i64.const 1
    call $float_arr_get
    local.set $ox
    local.get $ray_arr
    i64.const 3
    call $float_arr_get
    local.set $oy
    local.get $ray_arr
    i64.const 7
    call $float_arr_get
    local.set $t
    local.get $ray_arr
    i64.const 9
    call $float_arr_get
    local.set $dt
    local.get $ox
    f64.reinterpret_i64
    local.get $t
    f64.reinterpret_i64
    local.get $fx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $px
    local.get $oy
    f64.reinterpret_i64
    local.get $t
    f64.reinterpret_i64
    local.get $fy
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $py
    local.get $px
    f64.reinterpret_i64
    f64.const 64.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $xs
    local.get $py
    f64.reinterpret_i64
    f64.const 64.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $ys
    local.get $state
    call $f_rho
    local.get $xs
    local.get $ys
    call $plane_sample
    local.set $rho
    local.get $state
    call $f_vx
    local.get $xs
    local.get $ys
    call $plane_sample
    local.set $vx
    local.get $state
    call $f_vy
    local.get $xs
    local.get $ys
    call $plane_sample
    local.set $vy
    local.get $state
    call $f_bx
    local.get $xs
    local.get $ys
    call $plane_sample
    local.set $bx
    local.get $state
    call $f_by
    local.get $xs
    local.get $ys
    call $plane_sample
    local.set $by
    local.get $rho
    f64.reinterpret_i64
    f64.const 0.2
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.25
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $rho_n
    local.get $rho_n
    call $viridis_r
    local.set $cr
    local.get $rho_n
    call $viridis_g
    local.set $cg
    local.get $rho_n
    call $viridis_b
    local.set $cb
    local.get $vx
    f64.reinterpret_i64
    local.get $by
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $vy
    f64.reinterpret_i64
    local.get $bx
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $vort_proxy
    local.get $vort_proxy
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.7
    i64.reinterpret_f64
    else
    f64.const 1.0
    i64.reinterpret_f64
    end
    local.set $tr
    local.get $vort_proxy
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.gt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 1.0
    i64.reinterpret_f64
    else
    f64.const 0.7
    i64.reinterpret_f64
    end
    local.set $tg
    local.get $cr
    f64.reinterpret_i64
    local.get $tr
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $er
    local.get $cg
    f64.reinterpret_i64
    local.get $tg
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $eg
    local.get $cb
    f64.reinterpret_i64
    f64.const 0.95
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $eb
    local.get $rho
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.025
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $sigma
    local.get $sigma
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    f64.const 0.0
    i64.reinterpret_f64
    else
    local.get $sigma
    end
    local.set $sigma_pos
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $sigma_pos
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    call $exp
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $alpha_step
    f64.const 1.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $acc_arr
    i64.const 7
    call $float_arr_get
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $one_minus_a
    local.get $alpha_step
    f64.reinterpret_i64
    local.get $one_minus_a
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.set $weight
    local.get $acc_arr
    i64.const 1
    local.get $acc_arr
    i64.const 1
    call $float_arr_get
    f64.reinterpret_i64
    local.get $er
    f64.reinterpret_i64
    local.get $weight
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $acc_arr
    i64.const 3
    local.get $acc_arr
    i64.const 3
    call $float_arr_get
    f64.reinterpret_i64
    local.get $eg
    f64.reinterpret_i64
    local.get $weight
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $acc_arr
    i64.const 5
    local.get $acc_arr
    i64.const 5
    call $float_arr_get
    f64.reinterpret_i64
    local.get $eb
    f64.reinterpret_i64
    local.get $weight
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $acc_arr
    i64.const 7
    local.get $acc_arr
    i64.const 7
    call $float_arr_get
    f64.reinterpret_i64
    local.get $weight
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $ray_arr
    i64.const 7
    local.get $t
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $acc_arr
    local.get $ray_arr
    local.get $n
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.sub
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $march_loop
    end
  )

  (func $put_rgb (param $out_rgb i64) (param $i i64) (param $r i64) (param $g i64) (param $b i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $_ i64)
    local.get $out_rgb
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $r
    call $float_arr_set
    local.set $_
    local.get $out_rgb
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $g
    call $float_arr_set
    local.set $_
    local.get $out_rgb
    local.get $i
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $b
    call $float_arr_set
  )

  (func $chamber_pixel (param $state i64) (param $out_rgb i64) (param $acc_arr i64) (param $isect_arr i64) (param $ray_arr i64) (param $px i64) (param $py i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $cam_ox_l i64)
    (local $cam_oy_l i64)
    (local $cam_oz_l i64)
    (local $right_x i64)
    (local $right_y i64)
    (local $up_x i64)
    (local $up_y i64)
    (local $up_z i64)
    (local $extent i64)
    (local $u i64)
    (local $v i64)
    (local $ox i64)
    (local $oy i64)
    (local $oz i64)
    (local $hit i64)
    (local $t_enter i64)
    (local $t_exit i64)
    (local $dt i64)
    (local $_ i64)
    (local $r_lin i64)
    (local $g_lin i64)
    (local $b_lin i64)
    (local $r_t i64)
    (local $g_t i64)
    (local $b_t i64)
    f64.const 96.0
    i64.reinterpret_f64
    local.set $cam_ox_l
    f64.const 96.0
    i64.reinterpret_f64
    local.set $cam_oy_l
    f64.const 50.0
    i64.reinterpret_f64
    local.set $cam_oz_l
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.7071
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $right_x
    f64.const 0.7071
    i64.reinterpret_f64
    local.set $right_y
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.244
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $up_x
    f64.const 0.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.244
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $up_y
    f64.const 0.939
    i64.reinterpret_f64
    local.set $up_z
    f64.const 100.0
    i64.reinterpret_f64
    local.set $extent
    local.get $px
    call $to_float
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $u
    local.get $py
    call $to_float
    f64.reinterpret_i64
    f64.const 128.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    local.set $v
    local.get $cam_ox_l
    f64.reinterpret_i64
    local.get $u
    f64.reinterpret_i64
    local.get $extent
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $right_x
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $v
    f64.reinterpret_i64
    local.get $extent
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $up_x
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $ox
    local.get $cam_oy_l
    f64.reinterpret_i64
    local.get $u
    f64.reinterpret_i64
    local.get $extent
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $right_y
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $v
    f64.reinterpret_i64
    local.get $extent
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $up_y
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $oy
    local.get $cam_oz_l
    f64.reinterpret_i64
    local.get $v
    f64.reinterpret_i64
    local.get $extent
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $up_z
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    local.set $oz
    local.get $ray_arr
    i64.const 1
    local.get $ox
    call $float_arr_set
    local.set $_
    local.get $ray_arr
    i64.const 3
    local.get $oy
    call $float_arr_set
    local.set $_
    local.get $ray_arr
    i64.const 5
    local.get $oz
    call $float_arr_set
    local.set $_
    local.get $ray_arr
    local.get $isect_arr
    call $intersect_cylinder
    local.set $_
    local.get $isect_arr
    i64.const 5
    call $float_arr_get
    local.set $hit
    local.get $hit
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.lt
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    local.get $out_rgb
    local.get $py
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    local.get $px
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    f64.const 8.0
    i64.reinterpret_f64
    f64.const 14.0
    i64.reinterpret_f64
    f64.const 28.0
    i64.reinterpret_f64
    return_call $put_rgb
    else
    local.get $isect_arr
    i64.const 1
    call $float_arr_get
    local.set $t_enter
    local.get $isect_arr
    i64.const 3
    call $float_arr_get
    local.set $t_exit
    local.get $t_exit
    f64.reinterpret_i64
    local.get $t_enter
    f64.reinterpret_i64
    f64.sub
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.const 12.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.div
    i64.reinterpret_f64
    local.set $dt
    local.get $acc_arr
    i64.const 1
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $acc_arr
    i64.const 3
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $acc_arr
    i64.const 5
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $acc_arr
    i64.const 7
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $ray_arr
    i64.const 7
    local.get $t_enter
    f64.reinterpret_i64
    f64.const 0.5
    i64.reinterpret_f64
    f64.reinterpret_i64
    local.get $dt
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.add
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $ray_arr
    i64.const 9
    local.get $dt
    call $float_arr_set
    local.set $_
    local.get $state
    local.get $acc_arr
    local.get $ray_arr
    i64.const 25
    call $march_loop
    local.set $_
    local.get $acc_arr
    i64.const 1
    call $float_arr_get
    local.set $r_lin
    local.get $acc_arr
    i64.const 3
    call $float_arr_get
    local.set $g_lin
    local.get $acc_arr
    i64.const 5
    call $float_arr_get
    local.set $b_lin
    local.get $r_lin
    call $aces_curve
    local.set $r_t
    local.get $g_lin
    call $aces_curve
    local.set $g_t
    local.get $b_lin
    call $aces_curve
    local.set $b_t
    local.get $out_rgb
    local.get $py
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    local.get $px
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.get $r_t
    f64.reinterpret_i64
    f64.const 255.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.get $g_t
    f64.reinterpret_i64
    f64.const 255.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    local.get $b_t
    f64.reinterpret_i64
    f64.const 255.0
    i64.reinterpret_f64
    f64.reinterpret_i64
    f64.mul
    i64.reinterpret_f64
    return_call $put_rgb
    end
  )

  (func $chamber_loop_x (param $state i64) (param $out_rgb i64) (param $acc_arr i64) (param $isect_arr i64) (param $ray_arr i64) (param $py i64) (param $px i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $_ i64)
    local.get $px
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $state
    local.get $out_rgb
    local.get $acc_arr
    local.get $isect_arr
    local.get $ray_arr
    local.get $px
    local.get $py
    call $chamber_pixel
    local.set $_
    local.get $state
    local.get $out_rgb
    local.get $acc_arr
    local.get $isect_arr
    local.get $ray_arr
    local.get $py
    local.get $px
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $chamber_loop_x
    end
  )

  (func $chamber_loop_y (param $state i64) (param $out_rgb i64) (param $acc_arr i64) (param $isect_arr i64) (param $ray_arr i64) (param $py i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $_ i64)
    local.get $py
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.ge_s
    i64.extend_i32_u
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    if (result i64)
    i64.const 1
    else
    local.get $state
    local.get $out_rgb
    local.get $acc_arr
    local.get $isect_arr
    local.get $ray_arr
    local.get $py
    i64.const 1
    call $chamber_loop_x
    local.set $_
    local.get $state
    local.get $out_rgb
    local.get $acc_arr
    local.get $isect_arr
    local.get $ray_arr
    local.get $py
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    return_call $chamber_loop_y
    end
  )

  (func $chamber_render (param $state i64) (param $out_rgb i64) (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $acc_arr i64)
    (local $isect_arr i64)
    (local $ray_arr i64)
    (local $_ i64)
    i64.const 9
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $acc_arr
    i64.const 7
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $isect_arr
    i64.const 11
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $ray_arr
    local.get $state
    local.get $out_rgb
    local.get $acc_arr
    local.get $isect_arr
    local.get $ray_arr
    i64.const 1
    call $chamber_loop_y
    local.set $_
    local.get $out_rgb
  )

  (func $main  (result i64)
    (local $__ptr i64)
    (local $__scrut i64)
    (local $state i64)
    (local $ke i64)
    (local $me i64)
    (local $div_max i64)
    (local $vort_mean i64)
    (local $test_in i64)
    (local $test_arr i64)
    (local $chamber_buf i64)
    (local $cidx i64)
    (local $cidx2 i64)
    (local $_ i64)
    i64.const 512
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 602
    call $__rail_print
    i64.const 1
    local.set $_
    call $state_size
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $state
    local.get $state
    i64.const 1
    call $seed_ot
    local.set $_
    i64.const 724
    call $__rail_print
    i64.const 1
    local.set $_
    local.get $state
    call $total_kinetic_energy
    local.set $ke
    local.get $state
    call $total_magnetic_energy
    local.set $me
    local.get $state
    call $max_divb
    local.set $div_max
    local.get $state
    call $mean_vorticity
    local.set $vort_mean
    i64.const 1688
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 786
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 876
    local.get $ke
    call $show_float
    i64.const 922
    call $nil
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 974
    local.get $me
    call $show_float
    i64.const 1020
    call $nil
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1064
    local.get $div_max
    call $show_float
    i64.const 1162
    call $nil
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1116
    local.get $vort_mean
    call $show_float
    i64.const 1162
    call $nil
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1688
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1200
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 7
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $test_in
    local.get $test_in
    i64.const 1
    f64.const 96.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $test_in
    i64.const 3
    f64.const 96.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    local.get $test_in
    i64.const 5
    f64.const 50.0
    i64.reinterpret_f64
    call $float_arr_set
    local.set $_
    i64.const 7
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $test_arr
    local.get $test_in
    local.get $test_arr
    call $intersect_cylinder
    local.set $_
    i64.const 1280
    local.get $test_arr
    i64.const 5
    call $float_arr_get
    call $show_float
    i64.const 1300
    local.get $test_arr
    i64.const 1
    call $float_arr_get
    call $show_float
    i64.const 1322
    local.get $test_arr
    i64.const 3
    call $float_arr_get
    call $show_float
    call $nil
    call $cons
    call $cons
    call $cons
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1688
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1342
    call $__rail_print
    i64.const 1
    local.set $_
    call $img_bytes
    f64.const 0.0
    i64.reinterpret_f64
    call $float_arr_new
    local.set $chamber_buf
    i64.const 1436
    call $__rail_print
    i64.const 1
    local.set $_
    local.get $state
    local.get $chamber_buf
    call $chamber_render
    local.set $_
    i64.const 1498
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 129
    i64.const 1
    i64.shr_s
    i64.const 257
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 129
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    local.set $cidx
    i64.const 1556
    local.get $chamber_buf
    local.get $cidx
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    call $show_float
    i64.const 1676
    local.get $chamber_buf
    local.get $cidx
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    call $show_float
    i64.const 1676
    local.get $chamber_buf
    local.get $cidx
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    call $show_float
    call $nil
    call $cons
    call $cons
    call $cons
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1
    local.set $cidx2
    i64.const 1616
    local.get $chamber_buf
    local.get $cidx2
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    call $show_float
    i64.const 1676
    local.get $chamber_buf
    local.get $cidx2
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 3
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    call $show_float
    i64.const 1676
    local.get $chamber_buf
    local.get $cidx2
    i64.const 1
    i64.shr_s
    i64.const 7
    i64.const 1
    i64.shr_s
    i64.mul
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    i64.const 1
    i64.shr_s
    i64.const 5
    i64.const 1
    i64.shr_s
    i64.add
    i64.const 1
    i64.shl
    i64.const 1
    i64.or
    call $float_arr_get
    call $show_float
    call $nil
    call $cons
    call $cons
    call $cons
    call $cons
    call $cons
    call $cons
    call $cat
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1688
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1696
    call $__rail_print
    i64.const 1
    local.set $_
    i64.const 1
  )

  (func $_start (export "_start")
    call $main
    i64.const 1
    i64.shr_s
    i32.wrap_i64
    call $proc_exit
  )

  (data (i32.const 256) "\29\00\00\00\72\65\6e\64\65\72\2e\72\61\69\6c\20\e2\80\94\20\52\61\69\6c\2d\57\41\53\4d\20\63\6f\6d\70\75\74\65\20\6b\65\72\6e\65\6c\73")
  (data (i32.const 301) "\39\00\00\00\53\65\65\64\69\6e\67\20\4f\72\73\7a\61\67\2d\54\61\6e\67\20\69\6e\69\74\69\61\6c\20\63\6f\6e\64\69\74\69\6f\6e\20\28\31\32\38\c2\b2\20\c3\97\20\36\20\66\69\65\6c\64\73\29")
  (data (i32.const 362) "\1b\00\00\00\43\6f\6d\70\75\74\69\6e\67\20\64\65\72\69\76\65\64\20\66\69\65\6c\64\73\2e\2e\2e")
  (data (i32.const 393) "\29\00\00\00\e2\94\80\e2\94\80\e2\94\80\e2\94\80\20\64\65\72\69\76\65\64\20\6d\65\74\72\69\63\73\20\e2\94\80\e2\94\80\e2\94\80\e2\94\80")
  (data (i32.const 438) "\13\00\00\00\6b\69\6e\65\74\69\63\20\65\6e\65\72\67\79\20\20\20\3d\20")
  (data (i32.const 461) "\16\00\00\00\20\20\20\20\28\65\78\70\65\63\74\20\7e\32\32\37\35\35\2e\35\36\29")
  (data (i32.const 487) "\13\00\00\00\6d\61\67\6e\65\74\69\63\20\65\6e\65\72\67\79\20\20\3d\20")
  (data (i32.const 510) "\12\00\00\00\20\20\20\20\28\65\78\70\65\63\74\20\7e\38\31\39\32\29")
  (data (i32.const 532) "\16\00\00\00\6d\61\78\20\7c\e2\88\87\c2\b7\42\7c\20\20\20\20\20\20\20\20\3d\20")
  (data (i32.const 558) "\13\00\00\00\6d\65\61\6e\20\76\6f\72\74\69\63\69\74\79\20\20\20\3d\20")
  (data (i32.const 581) "\0f\00\00\00\20\20\20\20\28\65\78\70\65\63\74\20\7e\30\29")
  (data (i32.const 600) "\24\00\00\00\e2\94\80\e2\94\80\20\69\73\65\63\74\20\73\6d\6f\6b\65\20\74\65\73\74\20\e2\94\80\e2\94\80\e2\94\80\e2\94\80")
  (data (i32.const 640) "\06\00\00\00\20\20\68\69\74\3d")
  (data (i32.const 650) "\07\00\00\00\20\65\6e\74\65\72\3d")
  (data (i32.const 661) "\06\00\00\00\20\65\78\69\74\3d")
  (data (i32.const 671) "\2b\00\00\00\e2\94\80\e2\94\80\20\63\68\61\6d\62\65\72\20\72\65\6e\64\65\72\20\28\54\69\65\72\20\34\29\20\e2\94\80\e2\94\80\e2\94\80\e2\94\80")
  (data (i32.const 718) "\1b\00\00\00\20\20\72\65\6e\64\65\72\69\6e\67\20\31\32\38\c2\b2\20\70\69\78\65\6c\73\2e\2e\2e")
  (data (i32.const 749) "\19\00\00\00\20\20\64\6f\6e\65\2e\20\20\73\61\6d\70\6c\69\6e\67\20\6f\75\74\70\75\74\3a")
  (data (i32.const 778) "\1a\00\00\00\20\20\20\20\63\65\6e\74\65\72\20\28\36\34\2c\36\34\29\3a\20\72\67\62\20\3d\20")
  (data (i32.const 808) "\1a\00\00\00\20\20\20\20\63\6f\72\6e\65\72\20\28\30\2c\30\29\3a\20\20\20\72\67\62\20\3d\20")
  (data (i32.const 838) "\02\00\00\00\2c\20")
  (data (i32.const 844) "\00\00\00\00")
  (data (i32.const 848) "\49\00\00\00\e2\94\80\e2\94\80\20\72\65\61\64\79\20\66\6f\72\20\57\41\53\4d\20\62\75\69\6c\64\3a\20\20\2e\2f\72\61\69\6c\5f\6e\61\74\69\76\65\20\77\61\73\6d\20\74\6f\6f\6c\73\2f\70\6c\61\73\6d\61\2f\72\65\6e\64\65\72\2e\72\61\69\6c")
)
