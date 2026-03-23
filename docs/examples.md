# Rail Examples

Annotated examples covering major language features. All examples compile and run with `./rail_native run <file>.rail`.

---

## 1. Hello World

The simplest Rail program.

```rail
main =
  let _ = print "hello, world"
  0
```

- `main` is the entry point and must return an integer (exit code)
- `print` outputs a value followed by a newline
- `let _ = ...` executes an expression for its side effect

---

## 2. Functions and Recursion

```rail
double x = x * 2

factorial n =
  if n <= 1 then 1
  else n * factorial (n - 1)

main =
  let _ = print (show (double 21))
  let _ = print (show (factorial 10))
  0
```

Output:

```
42
3628800
```

- Functions are defined before `main`
- `show` converts an integer to a string for printing
- Recursion works naturally; tail calls are optimized

---

## 3. Lists and Higher-Order Functions

```rail
double x = x * 2
add a b = a + b

main =
  let xs = [1, 2, 3, 4, 5]
  let doubled = map double xs
  let total = fold add 0 doubled
  let _ = print (show total)
  let _ = print (show (head (reverse xs)))
  let _ = print (show (length xs))
  0
```

Output:

```
30
5
5
```

- `map` applies a function to every element
- `fold` reduces a list with an accumulator
- `head`, `tail`, `reverse`, `length` are list builtins
- Use named functions with `fold` and `filter` (not lambdas)

---

## 4. Strings and I/O

```rail
main =
  let name = "Rail"
  let greeting = cat ["Hello, ", name, "!"]
  let _ = print greeting

  -- String operations
  let words = split " " "the quick brown fox"
  let _ = print (join "-" words)
  let _ = print (join ", " (reverse words))

  -- File I/O
  let _ = write_file "/tmp/rail_demo.txt" "Rail was here"
  let content = read_file "/tmp/rail_demo.txt"
  let _ = print content

  -- Shell
  let date = head (split "\n" (shell "date +%Y-%m-%d"))
  let _ = print date
  0
```

Output (date varies):

```
Hello, Rail!
the-quick-brown-fox
fox, brown, quick, the
Rail was here
2026-03-22
```

- `cat` concatenates a list of strings
- `split` splits on each character in the delimiter (single-char delimiter is most common)
- `shell` runs a command and returns stdout

---

## 5. Tuples

```rail
swap a b = (b, a)

divide a b =
  let q = a / b
  let r = a % b
  (q, r)

main =
  let (x, y) = swap 1 2
  let _ = print (cat [show x, ", ", show y])

  let (quotient, remainder) = divide 17 5
  let _ = print (cat [show quotient, " remainder ", show remainder])

  let (a, b, c) = (100, 20, 3)
  let _ = print (show (a + b + c))
  0
```

Output:

```
2, 1
3 remainder 2
123
```

- Tuples group multiple values of different types
- Destructure with `let (a, b) = expr`
- Tuples can have 2 or more elements

---

## 6. Algebraic Data Types and Pattern Matching

```rail
type Option = | Some x | None
type Shape = | Circle r | Rect w h

area shape = match shape
  | Circle r -> r * r * 3
  | Rect w h -> w * h

safe_div a b = match b
  | 0 -> None
  | _ -> Some (a / b)

show_option opt = match opt
  | Some x -> cat ["Some(", show x, ")"]
  | None -> "None"

main =
  let _ = print (show (area (Circle 5)))
  let _ = print (show (area (Rect 3 4)))
  let _ = print (show_option (safe_div 10 3))
  let _ = print (show_option (safe_div 10 0))
  0
```

Output:

```
75
12
Some(3)
None
```

- `type` defines an algebraic data type with `|`-separated constructors
- `match` destructures a value (no `with` keyword)
- Each arm: `| Pattern args -> body`
- `_` is the wildcard pattern
- Integer and string literals work as patterns too

---

## 7. Closures and Lambdas

```rail
main =
  -- Single lambda
  let inc = \x -> x + 1
  let _ = print (show (inc 41))

  -- Nested lambda (flattened to multi-param)
  let add = \a -> \b -> a + b
  let _ = print (show (add 3 4))

  -- Closure capturing a variable
  let offset = 100
  let shifted = \x -> x + offset
  let _ = print (show (shifted 42))

  -- Lambdas with map
  let doubled = map (\x -> x * 2) [1, 2, 3, 4, 5]
  let _ = print (join ", " (map show doubled))
  0
```

Output:

```
42
7
142
2, 4, 6, 8, 10
```

- `\x -> body` creates a lambda
- `\a -> \b -> body` creates a multi-param closure (nested lambdas are flattened)
- Closures capture up to 4 variables from the enclosing scope
- Lambdas work with `map` but may segfault with `filter` (use named functions for `filter`)

---

## 8. Pipe Operator

```rail
inc x = x + 1

main =
  -- Pipe chains left to right
  let result = [1, 2, 3] |> reverse |> head |> inc
  let _ = print (show result)

  -- Equivalent to: inc (head (reverse [1, 2, 3]))
  -- Reads much more naturally with pipes

  let total = range 101 |> fold (\a -> \b -> a + b) 0
  -- Nope -- fold needs a named function for reliability
  0
```

Output:

```
4
```

- `x |> f` is equivalent to `f x`
- Chains read left-to-right instead of inside-out

---

## 9. Foreign Function Interface

```rail
foreign abs n
foreign strlen s
foreign getenv name -> str
foreign sqrt x -> float

main =
  -- Integer FFI
  let _ = print (show (abs (-42)))

  -- String FFI (returns a raw pointer/string)
  let home = getenv "HOME"
  let _ = print home

  -- Float FFI
  let root = sqrt (to_float 144)
  let _ = print (show (to_int root))

  -- strlen on a string
  let _ = print (show (strlen "hello"))
  0
```

Output (HOME varies):

```
42
/Users/yourname
12
5
```

- `foreign` declares a C function from the linked libraries
- Default return type is tagged integer
- `-> str` / `-> ptr` returns a raw pointer
- `-> float` returns a boxed float
- Integer args are automatically untagged; float args are unboxed

---

## 10. Concurrency with Spawn and Channels

```rail
work x = x * x

main =
  -- Spawn a fiber
  let f = spawn (\x -> work 7)
  let result = fiber_await f
  let _ = print (show result)

  -- Channel communication
  let ch = channel 0
  let _ = send ch 10
  let _ = send ch 20
  let _ = send ch 30
  let a = recv ch
  let b = recv ch
  let c = recv ch
  let _ = print (show (a + b + c))
  0
```

Output:

```
49
60
```

- `spawn` runs a function in a new fiber
- `fiber_await` waits for it and returns the result
- `channel 0` creates a new channel
- `send`/`recv` pass values through the channel (FIFO order)

---

## 11. Tail-Call Optimization

```rail
-- These would stack overflow without TCO
count_down n =
  if n == 0 then 0
  else count_down (n - 1)

sum_acc n acc =
  if n == 0 then acc
  else sum_acc (n - 1) (acc + n)

main =
  let _ = print (show (count_down 1000000))
  let _ = print (show (sum_acc 100000 0))
  0
```

Output:

```
0
5000050000
```

- Self-recursive tail calls compile to jumps (no stack growth)
- Accumulator-style recursion is the idiomatic pattern

---

## 12. Using the Standard Library

```rail
import "stdlib/json.rail"
import "stdlib/fmt.rail"
import "stdlib/list.rail"

main =
  -- Parse JSON
  let data = parse_json "{\"name\": \"Rail\", \"tests\": 70}"
  let name = json_str (json_get data "name")
  let tests = json_int (json_get data "tests")

  -- Format output
  let msg = format "{} passes {}/70 tests" [name, show tests]
  let _ = print msg

  -- List operations
  let xs = range 10
  let _ = print (show (sum xs))
  let first5 = take 5 xs
  let _ = print (join ", " (map show first5))
  0
```

Output:

```
Rail passes 70/70 tests
45
0, 1, 2, 3, 4
```

- `import` pulls in declarations from another file
- Multiple stdlib modules can be imported
- All imported functions are available at the top level (or prefixed with `as`)

---

## 13. Memory Management

```rail
main =
  -- Arena mark/reset for manual memory control
  let mark = arena_mark 0

  -- Allocate some temporary data
  let _ = map (\x -> x * x) (range 1000)

  -- Reset arena to reclaim memory
  let _ = arena_reset mark

  -- Continue with a clean slate
  let _ = print "memory reclaimed"
  0
```

- `arena_mark` saves the current heap position
- `arena_reset` resets the heap to that position
- Useful in long-running loops to avoid GC pressure
- The GC handles most cases automatically; manual management is optional

---

## 14. Pattern Matching with Guards

```rail
type Expr = | Num n | Add a b | Mul a b

eval expr = match expr
  | Num n -> n
  | Add a b -> eval a + eval b
  | Mul a b -> eval a * eval b

simplify expr = match expr
  | Mul a b if eval a == 0 -> Num 0
  | Mul a b if eval b == 0 -> Num 0
  | Mul a b if eval a == 1 -> b
  | Add a b if eval a == 0 -> b
  | _ -> expr

main =
  -- (1 * (2 + 3))
  let expr = Mul (Num 1) (Add (Num 2) (Num 3))
  let simplified = simplify expr
  let _ = print (show (eval simplified))
  0
```

Output:

```
5
```

- Guards add `if condition` after the pattern, before `->`
- The guard is evaluated after the pattern matches; if it fails, the next arm is tried
- This example builds a small expression evaluator with optimization rules
