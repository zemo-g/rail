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

