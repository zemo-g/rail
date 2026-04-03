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
      i32.const 131
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

