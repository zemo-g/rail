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
    ;; 6 decimal digits.
    i32.const 0
    local.set $i
    (block $dec_done
      (loop $dec_loop
        local.get $i
        i32.const 6
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

