  (func $__rail_print (param $val i64)
    (local $n i64) (local $pos i32) (local $neg i32) (local $digit i32)
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
  )

