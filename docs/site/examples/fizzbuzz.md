# fizzbuzz — the classic interview question

Print 1..30 with multiples of 3 → `Fizz`, multiples of 5 → `Buzz`, multiples of 15 → `FizzBuzz`. Rail lacks a `mod` builtin, so the example writes its own using integer division.

**Source** (`examples/fizzbuzz.rail`):

```rail
-- fizzbuzz.rail — the classic interview question
--
-- Demonstrates: recursion, if/then/else, modular arithmetic, string output

mod3 n = n - ((n / 3) * 3)
mod5 n = n - ((n / 5) * 5)

fizzbuzz n =
  if mod3 n == 0 then
    if mod5 n == 0 then "FizzBuzz"
    else "Fizz"
  else if mod5 n == 0 then "Buzz"
  else show n

go i max =
  if i > max then 0
  else let _ = print (fizzbuzz i)
       go (i + 1) max

main =
  let _ = go 1 30
  0
```

**Run:**

```bash
./rail_native run examples/fizzbuzz.rail
```

**Output:**

```
1
2
Fizz
4
Buzz
Fizz
7
8
Fizz
Buzz
11
Fizz
13
14
FizzBuzz
16
17
Fizz
19
Buzz
Fizz
22
23
Fizz
Buzz
26
Fizz
28
29
FizzBuzz
```

The `go` function is the recursive loop. Because the recursive call is in tail position, Rail's TCO turns it into a tight loop (no stack growth).
