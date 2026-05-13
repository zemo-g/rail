# lists — cons, map, fold, filter, range

A tour of Rail's list builtins: literal syntax, `cons`/`head`/`tail`/`length`/`reverse`/`append`/`range`, then `map`/`fold`/`filter` with named helpers (Rail prefers named functions over inline lambdas for fold to keep type inference happy).

**Source** (`examples/lists.rail`):

```rail
-- lists.rail — list operations
--
-- Demonstrates: cons, head, tail, length, reverse, append, range,
--               map, fold, filter, join

double x = x * 2
showNum x = show x
add a b = a + b
isEven x = x - ((x / 2) * 2) == 0

doubleAll xs = map double xs
showAll xs = map showNum xs

main =
  -- Building lists
  let xs = [1, 2, 3, 4, 5]
  let _ = print (join " " (showAll xs))

  -- cons, head, tail
  let ys = cons 0 xs
  let _ = print (show (head ys))
  let _ = print (show (length ys))

  -- reverse
  let _ = print (join " " (showAll (reverse xs)))

  -- append
  let zs = append [10, 20] [30, 40]
  let _ = print (join " " (showAll zs))

  -- range
  let _ = print (join " " (showAll (range 8)))

  -- map
  let _ = print (join " " (showAll (doubleAll xs)))

  -- fold (sum)
  let _ = print (show (fold add 0 xs))

  -- filter
  let evens = filter isEven (range 10)
  let _ = print (show (length evens))

  0
```

**Run:**

```bash
./rail_native run examples/lists.rail
```

**Output:**

```
1 2 3 4 5
0
6
5 4 3 2 1
10 20 30 40
0 1 2 3 4 5 6 7
2 4 6 8 10
15
5
```

Each line corresponds to one `print` call in `main`, in order.
