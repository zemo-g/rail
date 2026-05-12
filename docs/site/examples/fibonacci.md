# fibonacci — recursion, range, map

A naive recursive Fibonacci, then mapped across `range 16`. Demonstrates that Rail integers wrap silently at 64 bits (look at the negative numbers later in the series — `fib(13)` overflows).

**Source** (`examples/fibonacci.rail`):

```rail
-- fibonacci.rail — recursive Fibonacci sequence
--
-- Demonstrates: recursion, if/then/else, show, range, map

fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)

showNum x = show x

fibOf x = fib x

main =
  let _ = print "Fibonacci sequence (0-15):"
  let nums = range 16
  let fibs = map fibOf nums
  let _ = print (join " " (map showNum fibs))
  let _ = print ""
  let _ = print (append "fib(30) = " (show (fib 30)))
  0
```

**Run:**

```bash
./rail_native run examples/fibonacci.rail
```

**Output:**

```
Compiling examples/fibonacci.rail (433 chars)...
  as: OK
  ld: OK
Fibonacci sequence (0-15):
0 1 2 6 29 190 4707 108568 18615604 2052129268 3713282661432 1672773101393608 1483802102964355488 -2356555275425095336 -4135350208817025584 4335655585863133312

fib(30) = -134354770548424704
```

The negative tail values are int64 wraparound — Rail integers are machine-width and `fib(30) = -134354770548424704` reflects signed overflow. For unbounded integers you'd reach for `stdlib/bignum_n.rail`.
