  ;; Heap bump allocator
  (global $heap_ptr (mut i32) (i32.const 65536))
  (func $alloc (param $size i32) (result i32)
    (local $ptr i32)
    global.get $heap_ptr
    local.set $ptr
    global.get $heap_ptr
    local.get $size
    i32.add
    global.set $heap_ptr
    local.get $ptr
  )

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
    i32.const 24
    call $alloc
    local.set $ptr
    local.get $ptr
    i64.const 1
    i64.store
    local.get $ptr
    i32.const 8
    i32.add
    local.get $hd
    i64.store
    local.get $ptr
    i32.const 16
    i32.add
    local.get $tl
    i64.store
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

