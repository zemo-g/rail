(module
  ;; mhd_wasm.wat — 2D Ideal MHD Simulator in WebAssembly
  ;; Orszag-Tang vortex, Lax-Friedrichs scheme, periodic boundaries
  ;; Same algorithm as mhd.rail, compiled to WASM by hand
  ;;
  ;; Memory layout (64-bit floats / f64):
  ;;   Page 0-5:   state[6 * NN * NN]  (current)
  ;;   Page 6-11:  ns[6 * NN * NN]     (next state)
  ;;   Page 12:    scratch (flux buffers, accumulators)
  ;;
  ;; Exports: init, step, get_state_ptr, get_nn, get_field_ptr

  (import "math" "sin" (func $sin (param f64) (result f64)))
  (import "math" "cos" (func $cos (param f64) (result f64)))
  (import "math" "sqrt" (func $sqrt (param f64) (result f64)))

  (memory (export "memory") 30)  ;; 30 pages = ~2MB (state + next_state + scratch)

  ;; Constants
  (global $nn (mut i32) (i32.const 128))
  (global $nn2 (mut i32) (i32.const 16384))
  (global $state_size (mut i32) (i32.const 98304))
  (global $gamma f64 (f64.const 1.6666666666666667))
  (global $gamma_m1 f64 (f64.const 0.6666666666666667))

  ;; State offset: 0
  ;; Next state offset: state_size * 8
  (global $ns_offset (mut i32) (i32.const 786432))  ;; 98304 * 8

  ;; Diagnostics
  (global $total_mass (mut f64) (f64.const 0.0))
  (global $total_energy (mut f64) (f64.const 0.0))
  (global $max_divb (mut f64) (f64.const 0.0))
  (global $min_rho (mut f64) (f64.const 0.0))
  (global $sim_time (mut f64) (f64.const 0.0))
  (global $step_count (mut i32) (i32.const 0))
  (global $last_dt (mut f64) (f64.const 0.0))

  ;; dx = 2*pi/128
  (global $dx f64 (f64.const 0.04908738521234052))
  (global $two_dx f64 (f64.const 0.09817477042468104))
  (global $cfl f64 (f64.const 0.2))

  ;; ── Grid access ──

  (func $wrap (param $i i32) (result i32)
    local.get $i
    i32.const 0
    i32.lt_s
    if (result i32)
      local.get $i
      global.get $nn
      i32.add
    else
      local.get $i
      global.get $nn
      i32.ge_s
      if (result i32)
        local.get $i
        global.get $nn
        i32.sub
      else
        local.get $i
      end
    end
  )

  (func $idx (param $f i32) (param $x i32) (param $y i32) (result i32)
    local.get $f
    global.get $nn2
    i32.mul
    local.get $y
    call $wrap
    global.get $nn
    i32.mul
    i32.add
    local.get $x
    call $wrap
    i32.add
  )

  (func $get (param $base i32) (param $f i32) (param $x i32) (param $y i32) (result f64)
    local.get $base
    local.get $f
    local.get $x
    local.get $y
    call $idx
    i32.const 8
    i32.mul
    i32.add
    f64.load
  )

  (func $put (param $base i32) (param $f i32) (param $x i32) (param $y i32) (param $v f64)
    local.get $base
    local.get $f
    local.get $x
    local.get $y
    call $idx
    i32.const 8
    i32.mul
    i32.add
    local.get $v
    f64.store
  )

  ;; ── Init: Orszag-Tang vortex ──

  (func $init_cell (param $x i32) (param $y i32)
    (local $xp f64) (local $yp f64)
    (local $rho f64) (local $vx f64) (local $vy f64)
    (local $bx f64) (local $by f64) (local $p f64)
    (local $ke f64) (local $me f64) (local $e f64)

    local.get $x
    f64.convert_i32_s
    global.get $dx
    f64.mul
    local.set $xp

    local.get $y
    f64.convert_i32_s
    global.get $dx
    f64.mul
    local.set $yp

    f64.const 2.77777777777778
    local.set $rho

    ;; vx = -sin(y)
    f64.const 0.0
    local.get $yp
    call $sin
    f64.sub
    local.set $vx

    ;; vy = sin(x)
    local.get $xp
    call $sin
    local.set $vy

    ;; bx = -sin(y)
    f64.const 0.0
    local.get $yp
    call $sin
    f64.sub
    local.set $bx

    ;; by = sin(2x)
    f64.const 2.0
    local.get $xp
    f64.mul
    call $sin
    local.set $by

    ;; p = 5/3
    f64.const 1.6666666666666667
    local.set $p

    ;; ke = 0.5 * rho * (vx^2 + vy^2)
    f64.const 0.5
    local.get $rho
    f64.mul
    local.get $vx
    local.get $vx
    f64.mul
    local.get $vy
    local.get $vy
    f64.mul
    f64.add
    f64.mul
    local.set $ke

    ;; me = 0.5 * (bx^2 + by^2)
    f64.const 0.5
    local.get $bx
    local.get $bx
    f64.mul
    local.get $by
    local.get $by
    f64.mul
    f64.add
    f64.mul
    local.set $me

    ;; e = p / (gamma-1) + ke + me
    local.get $p
    global.get $gamma_m1
    f64.div
    local.get $ke
    f64.add
    local.get $me
    f64.add
    local.set $e

    ;; Store fields: put(base, f, x, y, v)
    i32.const 0  i32.const 0  local.get $x  local.get $y  local.get $rho  call $put
    i32.const 0  i32.const 1  local.get $x  local.get $y
      local.get $rho  local.get $vx  f64.mul  call $put
    i32.const 0  i32.const 2  local.get $x  local.get $y
      local.get $rho  local.get $vy  f64.mul  call $put
    i32.const 0  i32.const 3  local.get $x  local.get $y  local.get $bx  call $put
    i32.const 0  i32.const 4  local.get $x  local.get $y  local.get $by  call $put
    i32.const 0  i32.const 5  local.get $x  local.get $y  local.get $e   call $put
  )

  (func (export "init")
    (local $i i32)
    (local $x i32)
    (local $y i32)

    global.get $nn2
    i32.const 8
    i32.mul
    i32.const 6
    i32.mul
    global.set $ns_offset

    i32.const 0
    local.set $i
    block $done
      loop $loop
        local.get $i
        global.get $nn2
        i32.ge_s
        br_if $done

        local.get $i
        global.get $nn
        i32.rem_s
        local.set $x
        local.get $i
        global.get $nn
        i32.div_s
        local.set $y

        local.get $x
        local.get $y
        call $init_cell

        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end

    f64.const 0.0
    global.set $sim_time
    i32.const 0
    global.set $step_count
    call $compute_diagnostics
  )

  ;; ── Pressure ──

  (func $pressure (param $base i32) (param $x i32) (param $y i32) (result f64)
    (local $rho f64) (local $mx f64) (local $my f64)
    (local $bx f64) (local $by f64) (local $e f64)
    (local $v2 f64) (local $b2 f64) (local $p f64)

    local.get $base  i32.const 0  local.get $x  local.get $y  call $get  local.set $rho
    local.get $base  i32.const 1  local.get $x  local.get $y  call $get  local.set $mx
    local.get $base  i32.const 2  local.get $x  local.get $y  call $get  local.set $my
    local.get $base  i32.const 3  local.get $x  local.get $y  call $get  local.set $bx
    local.get $base  i32.const 4  local.get $x  local.get $y  call $get  local.set $by
    local.get $base  i32.const 5  local.get $x  local.get $y  call $get  local.set $e

    ;; v2 = (mx^2 + my^2) / rho^2
    local.get $mx  local.get $mx  f64.mul
    local.get $my  local.get $my  f64.mul
    f64.add
    local.get $rho  local.get $rho  f64.mul
    f64.div
    local.set $v2

    ;; b2 = bx^2 + by^2
    local.get $bx  local.get $bx  f64.mul
    local.get $by  local.get $by  f64.mul
    f64.add
    local.set $b2

    ;; p = (gamma-1) * (e - 0.5*rho*v2 - 0.5*b2)
    global.get $gamma_m1
    local.get $e
    f64.const 0.5  local.get $rho  f64.mul  local.get $v2  f64.mul
    f64.sub
    f64.const 0.5  local.get $b2  f64.mul
    f64.sub
    f64.mul
    local.set $p

    local.get $p
    f64.const 1e-10
    f64.lt
    if (result f64)
      f64.const 1e-10
    else
      local.get $p
    end
  )

  ;; ── Wave speed ──

  (func $cell_speed (param $base i32) (param $x i32) (param $y i32) (result f64)
    (local $rho f64) (local $mx f64) (local $my f64)
    (local $bx f64) (local $by f64) (local $p f64)
    (local $vx f64) (local $vy f64) (local $b2 f64)
    (local $a2 f64) (local $va2 f64)

    local.get $base  i32.const 0  local.get $x  local.get $y  call $get  local.set $rho
    local.get $base  i32.const 1  local.get $x  local.get $y  call $get  local.set $mx
    local.get $base  i32.const 2  local.get $x  local.get $y  call $get  local.set $my
    local.get $base  i32.const 3  local.get $x  local.get $y  call $get  local.set $bx
    local.get $base  i32.const 4  local.get $x  local.get $y  call $get  local.set $by
    local.get $base  local.get $x  local.get $y  call $pressure  local.set $p

    local.get $mx  local.get $rho  f64.div  local.set $vx
    local.get $my  local.get $rho  f64.div  local.set $vy

    local.get $bx  local.get $bx  f64.mul
    local.get $by  local.get $by  f64.mul
    f64.add
    local.set $b2

    ;; a2 = gamma * p / rho
    global.get $gamma  local.get $p  f64.mul  local.get $rho  f64.div  local.set $a2
    ;; va2 = b2 / rho
    local.get $b2  local.get $rho  f64.div  local.set $va2

    ;; |v| + cf
    local.get $vx  local.get $vx  f64.mul
    local.get $vy  local.get $vy  f64.mul
    f64.add
    call $sqrt
    local.get $a2  local.get $va2  f64.add  call $sqrt
    f64.add
  )

  (func $max_speed (param $base i32) (result f64)
    (local $i i32) (local $smax f64) (local $s f64)
    f64.const 0.0
    local.set $smax
    i32.const 0
    local.set $i
    block $done
      loop $loop
        local.get $i
        global.get $nn2
        i32.ge_s
        br_if $done

        local.get $base
        local.get $i  global.get $nn  i32.rem_s
        local.get $i  global.get $nn  i32.div_s
        call $cell_speed
        local.set $s

        local.get $s  local.get $smax  f64.gt
        if
          local.get $s  local.set $smax
        end

        local.get $i  i32.const 1  i32.add  local.set $i
        br $loop
      end
    end
    local.get $smax
  )

  ;; ── Lax-Friedrichs update ──

  (func $lxf_update (param $src i32) (param $dst i32) (param $dt f64)
    (local $i i32) (local $x i32) (local $y i32) (local $f i32)
    (local $cx f64) (local $cy f64)
    (local $rho f64) (local $mx f64) (local $my f64)
    (local $bx f64) (local $by f64) (local $e f64)
    (local $vx f64) (local $vy f64) (local $b2 f64) (local $p f64) (local $pt f64) (local $vdb f64)
    (local $fxr f64) (local $fxl f64) (local $fyu f64) (local $fyd f64)
    (local $avg f64) (local $val f64)
    ;; Right/left/up/down flux components (6 each, stored as locals for the hot field)
    (local $rho_r f64) (local $mx_r f64) (local $my_r f64) (local $bx_r f64) (local $by_r f64) (local $e_r f64)
    (local $rho_l f64) (local $mx_l f64) (local $my_l f64) (local $bx_l f64) (local $by_l f64) (local $e_l f64)
    (local $rho_u f64) (local $mx_u f64) (local $my_u f64) (local $bx_u f64) (local $by_u f64) (local $e_u f64)
    (local $rho_d f64) (local $mx_d f64) (local $my_d f64) (local $bx_d f64) (local $by_d f64) (local $e_d f64)

    ;; cx = dt / (2*dx)
    local.get $dt  global.get $two_dx  f64.div  local.set $cx
    local.get $dt  global.get $two_dx  f64.div  local.set $cy

    i32.const 0
    local.set $i
    block $done
      loop $cell_loop
        local.get $i
        global.get $nn2
        i32.ge_s
        br_if $done

        local.get $i  global.get $nn  i32.rem_s  local.set $x
        local.get $i  global.get $nn  i32.div_s  local.set $y

        ;; For each field f = 0..5:
        i32.const 0
        local.set $f
        block $fdone
          loop $floop
            local.get $f
            i32.const 6
            i32.ge_s
            br_if $fdone

            ;; avg = (U[x-1,y] + U[x+1,y] + U[x,y-1] + U[x,y+1]) / 4
            local.get $src  local.get $f  local.get $x  i32.const 1  i32.sub  local.get $y  call $get
            local.get $src  local.get $f  local.get $x  i32.const 1  i32.add  local.get $y  call $get
            f64.add
            local.get $src  local.get $f  local.get $x  local.get $y  i32.const 1  i32.sub  call $get
            f64.add
            local.get $src  local.get $f  local.get $x  local.get $y  i32.const 1  i32.add  call $get
            f64.add
            f64.const 4.0
            f64.div
            local.set $avg

            ;; Compute x-flux at (x+1,y) for field f
            local.get $src  local.get $x  i32.const 1  i32.add  local.get $y  local.get $f
            call $flux_x_component
            local.set $fxr

            ;; x-flux at (x-1,y)
            local.get $src  local.get $x  i32.const 1  i32.sub  local.get $y  local.get $f
            call $flux_x_component
            local.set $fxl

            ;; y-flux at (x,y+1)
            local.get $src  local.get $x  local.get $y  i32.const 1  i32.add  local.get $f
            call $flux_y_component
            local.set $fyu

            ;; y-flux at (x,y-1)
            local.get $src  local.get $x  local.get $y  i32.const 1  i32.sub  local.get $f
            call $flux_y_component
            local.set $fyd

            ;; val = avg - cx*(fxr - fxl) - cy*(fyu - fyd)
            local.get $avg
            local.get $cx
            local.get $fxr  local.get $fxl  f64.sub
            f64.mul
            f64.sub
            local.get $cy
            local.get $fyu  local.get $fyd  f64.sub
            f64.mul
            f64.sub
            local.set $val

            ;; Store to dst
            local.get $dst  local.get $f  local.get $x  local.get $y  local.get $val  call $put

            local.get $f  i32.const 1  i32.add  local.set $f
            br $floop
          end
        end

        local.get $i  i32.const 1  i32.add  local.set $i
        br $cell_loop
      end
    end
  )

  ;; ── X-flux component for field f at position (x,y) ──
  (func $flux_x_component (param $base i32) (param $x i32) (param $y i32) (param $f i32) (result f64)
    (local $rho f64) (local $mx f64) (local $my f64)
    (local $bx f64) (local $by f64) (local $e f64)
    (local $vx f64) (local $vy f64) (local $b2 f64) (local $p f64) (local $pt f64) (local $vdb f64)

    local.get $base  i32.const 0  local.get $x  local.get $y  call $get  local.set $rho
    local.get $base  i32.const 1  local.get $x  local.get $y  call $get  local.set $mx
    local.get $base  i32.const 2  local.get $x  local.get $y  call $get  local.set $my
    local.get $base  i32.const 3  local.get $x  local.get $y  call $get  local.set $bx
    local.get $base  i32.const 4  local.get $x  local.get $y  call $get  local.set $by
    local.get $base  i32.const 5  local.get $x  local.get $y  call $get  local.set $e

    local.get $mx  local.get $rho  f64.div  local.set $vx
    local.get $my  local.get $rho  f64.div  local.set $vy
    local.get $bx  local.get $bx  f64.mul  local.get $by  local.get $by  f64.mul  f64.add  local.set $b2
    local.get $base  local.get $x  local.get $y  call $pressure  local.set $p
    local.get $p  f64.const 0.5  local.get $b2  f64.mul  f64.add  local.set $pt
    local.get $vx  local.get $bx  f64.mul  local.get $vy  local.get $by  f64.mul  f64.add  local.set $vdb

    ;; f=0: mx
    local.get $f  i32.const 0  i32.eq
    if (result f64)  local.get $mx
    else local.get $f  i32.const 1  i32.eq
    if (result f64)  local.get $mx  local.get $vx  f64.mul  local.get $pt  f64.add  local.get $bx  local.get $bx  f64.mul  f64.sub
    else local.get $f  i32.const 2  i32.eq
    if (result f64)  local.get $mx  local.get $vy  f64.mul  local.get $bx  local.get $by  f64.mul  f64.sub
    else local.get $f  i32.const 3  i32.eq
    if (result f64)  f64.const 0.0
    else local.get $f  i32.const 4  i32.eq
    if (result f64)  local.get $vx  local.get $by  f64.mul  local.get $vy  local.get $bx  f64.mul  f64.sub
    else
      ;; f=5: (e + pt) * vx - bx * vdb
      local.get $e  local.get $pt  f64.add  local.get $vx  f64.mul
      local.get $bx  local.get $vdb  f64.mul  f64.sub
    end end end end end
  )

  ;; ── Y-flux component for field f at position (x,y) ──
  (func $flux_y_component (param $base i32) (param $x i32) (param $y i32) (param $f i32) (result f64)
    (local $rho f64) (local $mx f64) (local $my f64)
    (local $bx f64) (local $by f64) (local $e f64)
    (local $vx f64) (local $vy f64) (local $b2 f64) (local $p f64) (local $pt f64) (local $vdb f64)

    local.get $base  i32.const 0  local.get $x  local.get $y  call $get  local.set $rho
    local.get $base  i32.const 1  local.get $x  local.get $y  call $get  local.set $mx
    local.get $base  i32.const 2  local.get $x  local.get $y  call $get  local.set $my
    local.get $base  i32.const 3  local.get $x  local.get $y  call $get  local.set $bx
    local.get $base  i32.const 4  local.get $x  local.get $y  call $get  local.set $by
    local.get $base  i32.const 5  local.get $x  local.get $y  call $get  local.set $e

    local.get $mx  local.get $rho  f64.div  local.set $vx
    local.get $my  local.get $rho  f64.div  local.set $vy
    local.get $bx  local.get $bx  f64.mul  local.get $by  local.get $by  f64.mul  f64.add  local.set $b2
    local.get $base  local.get $x  local.get $y  call $pressure  local.set $p
    local.get $p  f64.const 0.5  local.get $b2  f64.mul  f64.add  local.set $pt
    local.get $vx  local.get $bx  f64.mul  local.get $vy  local.get $by  f64.mul  f64.add  local.set $vdb

    ;; f=0: my
    local.get $f  i32.const 0  i32.eq
    if (result f64)  local.get $my
    else local.get $f  i32.const 1  i32.eq
    if (result f64)  local.get $my  local.get $vx  f64.mul  local.get $bx  local.get $by  f64.mul  f64.sub
    else local.get $f  i32.const 2  i32.eq
    if (result f64)  local.get $my  local.get $vy  f64.mul  local.get $pt  f64.add  local.get $by  local.get $by  f64.mul  f64.sub
    else local.get $f  i32.const 3  i32.eq
    if (result f64)  local.get $vy  local.get $bx  f64.mul  local.get $vx  local.get $by  f64.mul  f64.sub
    else local.get $f  i32.const 4  i32.eq
    if (result f64)  f64.const 0.0
    else
      ;; f=5: (e + pt) * vy - by * vdb
      local.get $e  local.get $pt  f64.add  local.get $vy  f64.mul
      local.get $by  local.get $vdb  f64.mul  f64.sub
    end end end end end
  )

  ;; ── Step: compute dt, advance, swap buffers ──

  (func (export "step") (result f64)
    (local $smax f64) (local $dt f64) (local $i i32)

    ;; dt = CFL * dx / max_speed
    i32.const 0
    call $max_speed
    local.set $smax

    local.get $smax
    f64.const 1e-15
    f64.lt
    if
      f64.const 0.001
      local.set $dt
    else
      global.get $cfl
      global.get $dx
      f64.mul
      local.get $smax
      f64.div
      local.set $dt
    end

    local.get $dt
    global.set $last_dt

    ;; Lax-Friedrichs update: state → ns
    i32.const 0
    global.get $ns_offset
    local.get $dt
    call $lxf_update

    ;; Copy ns back to state
    i32.const 0
    local.set $i
    block $done
      loop $loop
        local.get $i
        global.get $state_size
        i32.ge_s
        br_if $done

        local.get $i
        i32.const 8
        i32.mul
        ;; load from ns
        global.get $ns_offset
        local.get $i
        i32.const 8
        i32.mul
        i32.add
        f64.load
        ;; store to state
        f64.store

        local.get $i  i32.const 1  i32.add  local.set $i
        br $loop
      end
    end

    ;; Update time
    global.get $sim_time
    local.get $dt
    f64.add
    global.set $sim_time

    global.get $step_count
    i32.const 1
    i32.add
    global.set $step_count

    local.get $dt
  )

  ;; ── Diagnostics ──

  (func $compute_diagnostics (export "compute_diagnostics")
    (local $i i32) (local $mass f64) (local $energy f64)
    (local $rho f64) (local $min_r f64)

    f64.const 0.0  local.set $mass
    f64.const 0.0  local.set $energy
    f64.const 1e30  local.set $min_r

    i32.const 0
    local.set $i
    block $done
      loop $loop
        local.get $i
        global.get $nn2
        i32.ge_s
        br_if $done

        ;; mass
        local.get $i  i32.const 8  i32.mul  f64.load
        local.set $rho
        local.get $mass  local.get $rho  f64.add  local.set $mass

        ;; energy
        local.get $energy
        i32.const 5  ;; f_en
        global.get $nn2
        i32.mul
        local.get $i
        i32.add
        i32.const 8
        i32.mul
        f64.load
        f64.add
        local.set $energy

        ;; min rho
        local.get $rho  local.get $min_r  f64.lt
        if
          local.get $rho  local.set $min_r
        end

        local.get $i  i32.const 1  i32.add  local.set $i
        br $loop
      end
    end

    local.get $mass  global.set $total_mass
    local.get $energy  global.set $total_energy
    local.get $min_r  global.set $min_rho
  )

  ;; ── Exports for JS to read ──

  (func (export "get_time") (result f64) global.get $sim_time)
  (func (export "get_step") (result i32) global.get $step_count)
  (func (export "get_dt") (result f64) global.get $last_dt)
  (func (export "get_mass") (result f64) global.get $total_mass)
  (func (export "get_energy") (result f64) global.get $total_energy)
  (func (export "get_min_rho") (result f64) global.get $min_rho)
  (func (export "get_nn") (result i32) global.get $nn)
  (func (export "get_nn2") (result i32) global.get $nn2)
  (func (export "get_state_size") (result i32) global.get $state_size)

  ;; Add a density perturbation at (x,y) — for interactive "click to blast"
  (func (export "perturb") (param $cx i32) (param $cy i32) (param $strength f64)
    (local $x i32) (local $y i32) (local $dx i32) (local $dy i32)
    (local $r2 f64) (local $amp f64) (local $cur f64)

    i32.const -3
    local.set $dx
    block $xdone
      loop $xloop
        local.get $dx  i32.const 4  i32.ge_s  br_if $xdone

        i32.const -3
        local.set $dy
        block $ydone
          loop $yloop
            local.get $dy  i32.const 4  i32.ge_s  br_if $ydone

            local.get $cx  local.get $dx  i32.add  local.set $x
            local.get $cy  local.get $dy  i32.add  local.set $y

            ;; r2 = dx^2 + dy^2
            local.get $dx  f64.convert_i32_s  local.get $dx  f64.convert_i32_s  f64.mul
            local.get $dy  f64.convert_i32_s  local.get $dy  f64.convert_i32_s  f64.mul
            f64.add
            local.set $r2

            ;; amp = strength * exp(-r2/2)
            local.get $strength
            f64.const 0.0
            local.get $r2
            f64.const 2.0
            f64.div
            f64.sub
            ;; no exp in imports — use Gaussian approximation: 1 - r2/2 + r2^2/8
            ;; Actually just use (1 - r2/9) clamped
            drop  drop
            local.get $strength
            f64.const 1.0
            local.get $r2
            f64.const 9.0
            f64.div
            f64.sub
            f64.mul
            local.set $amp

            local.get $amp  f64.const 0.0  f64.gt
            if
              ;; Add to density
              i32.const 0  i32.const 0  local.get $x  local.get $y  call $get
              local.set $cur
              i32.const 0  i32.const 0  local.get $x  local.get $y
              local.get $cur  local.get $amp  f64.add
              call $put

              ;; Add to energy
              i32.const 0  i32.const 5  local.get $x  local.get $y  call $get
              local.set $cur
              i32.const 0  i32.const 5  local.get $x  local.get $y
              local.get $cur  local.get $amp  f64.const 3.0  f64.mul  f64.add
              call $put
            end

            local.get $dy  i32.const 1  i32.add  local.set $dy
            br $yloop
          end
        end

        local.get $dx  i32.const 1  i32.add  local.set $dx
        br $xloop
      end
    end
  )
)
