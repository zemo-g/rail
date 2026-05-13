# tco_test — tail call optimization

Two functions that would blow the stack in any non-TCO interpreter. `count_down` recurses 1,000,000 deep; `sum_acc` does the same with an accumulator. Rail compiles these to tight loops with a `subs` and a `b.gt` — no stack growth.

**Source** (`examples/tco_test.rail`):

```rail
-- Tail call optimization test
-- These would stack overflow without TCO

count_down : i32 -> i32
count_down n =
  if n == 0 then 0 else count_down (n - 1)

sum_acc : i32 -> i32 -> i32
sum_acc n acc =
  if n == 0 then acc else sum_acc (n - 1) (acc + n)

main =
  let _ = print (count_down 1000000)
  let _ = print (sum_acc 1000000 0)
  0
```

**Run:**

```bash
./rail_native run examples/tco_test.rail
```

**Output:**

```
0
500000500000
```

`count_down 1000000` reaches 0 and returns it. `sum_acc 1000000 0` computes `1 + 2 + ... + 1,000,000 = 500,000,500,000`. Both run in constant stack space.

The `: i32 -> i32` line is a type-annotation comment hint — Rail's parser tolerates the syntax but the compiler infers types itself.
