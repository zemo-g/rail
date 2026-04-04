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

