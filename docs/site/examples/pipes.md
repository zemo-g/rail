# pipes — the `|>` operator

`x |> f` desugars to `f x`. Chains read left-to-right, which is friendlier for transformation pipelines than nested calls.

**Source** (`examples/pipes.rail`):

```rail
-- pipes.rail — the pipe operator
--
-- Demonstrates: |> operator, chaining transformations, reverse, head, tail

double x = x * 2
triple x = x * 3
inc x = x + 1
negate x = 0 - x
showNum x = show x

showAll xs = map showNum xs

main =
  -- Basic pipe: 5 |> double |> inc = 11
  let r1 = 5 |> double |> inc
  let _ = print (show r1)

  -- Chain more: 3 |> inc |> triple |> double = 24
  let r2 = 3 |> inc |> triple |> double
  let _ = print (show r2)

  -- Pipes with lists: reverse and take head
  let xs = [10, 20, 30, 40, 50]
  let last = xs |> reverse |> head
  let _ = print (show last)

  -- Pipe into length
  let n = [1, 2, 3, 4, 5, 6, 7] |> length
  let _ = print (show n)

  -- Pipe with negate
  let r3 = 42 |> negate
  let _ = print (show r3)

  0
```

**Run:**

```bash
./rail_native run examples/pipes.rail
```

**Output:**

```
11
24
50
7
-42
```

`5 |> double |> inc` = `inc (double 5)` = `inc 10` = `11`. `xs |> reverse |> head` grabs the last element of a list.
