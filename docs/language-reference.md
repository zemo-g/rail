# Rail Language Reference

Complete syntax and semantics reference for Rail v1.4.0.

## Program Structure

A Rail program consists of:

1. Zero or more `import` declarations
2. Zero or more `type` declarations
3. Zero or more `foreign` declarations
4. Zero or more function definitions
5. A `main` function that returns an integer

```rail
import "stdlib/math.rail"

type Option = | Some x | None

foreign strlen s

double x = x * 2

main =
  let _ = print (show (double 21))
  0
```

## Comments

Line comments start with `--`:

```rail
-- This is a comment
main = 42  -- inline comment
```

There are no block comments.

## Values and Types

### Integers

64-bit signed integers. Internally stored as tagged values (shifted left by 1, low bit set).

```rail
42
-7
0
100000
```

Negative literals use the `-` prefix: `-42`. In expressions where this is ambiguous, use parentheses: `10 + (-3)`.

### Floats

64-bit floating point (IEEE 754 double). Stored as heap-allocated tagged objects (tag 6).

```rail
3.14
2.0
0.5
```

Float arithmetic uses the same operators as integers. The compiler dispatches to float operations when it detects float operands.

### Booleans

```rail
true
false
```

Booleans are represented as tagged integers: `true` is 3, `false` is 1.

### Strings

Null-terminated C strings (pointers into the data segment or heap).

```rail
"hello, world"
"line one\nline two"
"tab\there"
"quote: \""
"backslash: \\"
"braces: \{and\}"
```

Escape sequences: `\n` (newline), `\t` (tab), `\\` (backslash), `\"` (double quote), `\{` and `\}` (literal braces).

String length is measured by `length`, which counts characters.

### Null

```rail
null
```

Represented as 0. Primarily used in FFI contexts.

### Lists

Cons-cell linked lists. `[]` is the empty list (nil).

```rail
[1, 2, 3]
["a", "b", "c"]
[]
```

Lists are homogeneous by convention but not enforced. Internally, each cons cell is a heap object with tag 1 containing a head and tail pointer. Nil has tag 2.

### Tuples

Fixed-size heterogeneous containers. Heap-allocated with tag 3.

```rail
(10, 20)
("hello", 42, true)
(1, 2, 3)
```

Tuple destructuring:

```rail
let (a, b) = (10, 32)
let (x, y, z) = (1, 2, 3)
```

### Algebraic Data Types (ADTs)

User-defined sum types with constructors. Heap-allocated with tag 5.

```rail
type Option = | Some x | None
type Either = | Left a | Right b
type Tree = | Leaf | Node val left right
type Color = | Red | Green | Blue
```

Constructors are capitalized by convention. Each constructor can take zero or more arguments.

## Functions

Functions are defined at the top level, before `main`. Parameters follow the function name, separated by spaces:

```rail
double x = x * 2
add a b = a + b
greet name = cat ["Hello, ", name, "!"]
```

Functions with no parameters:

```rail
answer = 42
```

Recursive functions work naturally:

```rail
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

fib n =
  if n <= 1 then n
  else fib (n - 1) + fib (n - 2)
```

### Tail-Call Optimization

The compiler performs tail-call optimization for self-recursive calls in tail position. This means recursive loops run in constant stack space:

```rail
-- This will NOT stack overflow, even with n = 1000000
loop n = if n == 0 then 42 else loop (n - 1)

-- Accumulator-style recursion is also optimized
sum_acc n acc =
  if n == 0 then acc
  else sum_acc (n - 1) (acc + n)
```

### The `main` Function

`main` is the entry point. It must return an integer (used as the process exit code):

```rail
main =
  let _ = print "hello"
  0
```

If `main` returns a non-zero value, the process exits with that code.

## Let Bindings

`let` binds a value to a name. The binding is followed by the body expression on the next line (indented):

```rail
main =
  let x = 42
  let y = x + 1
  let _ = print (show y)
  0
```

There is no `in` keyword -- the body is simply the next expression after the binding.

Use `let _ = expr` to execute an expression for its side effects and discard the result.

### Tuple Destructuring in Let

```rail
main =
  let (a, b) = (10, 32)
  a + b
```

## Operators

### Arithmetic

| Operator | Description |
|----------|-------------|
| `+` | Addition (integers and strings) |
| `-` | Subtraction |
| `*` | Multiplication |
| `/` | Integer division |
| `%` | Modulo |

The `+` operator on strings performs concatenation (same as `append`).

### Comparison

| Operator | Description |
|----------|-------------|
| `==` | Equal |
| `!=` | Not equal |
| `<` | Less than |
| `>` | Greater than |
| `<=` | Less than or equal |
| `>=` | Greater than or equal |

Comparison works on integers, floats, and strings (string comparison is byte-wise).

### Logical

| Operator | Description |
|----------|-------------|
| `&&` | Logical AND |
| `\|\|` | Logical OR |
| `not` | Logical NOT (builtin function) |

**Important**: `&&` and `||` do **not** short-circuit. Both sides are always evaluated. For short-circuit behavior, use nested `if`/`else`:

```rail
-- This evaluates both sides (no short-circuit):
x > 0 && y / x > 2

-- Use this instead for safety:
if x > 0 then y / x > 2 else false
```

### Pipe Operator

The pipe operator `|>` passes the left-hand value as the last argument to the right-hand function:

```rail
-- x |> f  is equivalent to  f x
[1, 2, 3] |> reverse |> head |> show
```

Pipes chain left to right, enabling a fluent data-flow style.

## Control Flow

### If-Then-Else

```rail
if condition then true_branch else false_branch
```

Both branches are required. `if`/`then`/`else` is an expression that returns a value:

```rail
let result = if x > 0 then "positive" else "non-positive"
```

Multi-line form:

```rail
classify n =
  if n > 0 then "positive"
  else if n < 0 then "negative"
  else "zero"
```

### Pattern Matching

`match` destructures a value against patterns. There is **no** `with` keyword:

```rail
type Option = | Some x | None

getOr opt default = match opt
  | Some x -> x
  | None -> default
```

Each arm starts with `|`, followed by a pattern, `->`, and the body expression.

#### Constructor Patterns

Match against ADT constructors:

```rail
type Tree = | Leaf | Node val left right

depth tree = match tree
  | Leaf -> 0
  | Node val left right -> 1 + max (depth left) (depth right)
```

#### Integer Patterns

```rail
describe n = match n
  | 0 -> "zero"
  | 1 -> "one"
  | _ -> "other"
```

#### String Patterns

```rail
greet lang = match lang
  | "en" -> "Hello"
  | "es" -> "Hola"
  | _ -> "Hi"
```

#### Wildcard Pattern

`_` matches anything:

```rail
type Color = | Red | Green | Blue

is_red c = match c
  | Red -> true
  | _ -> false
```

#### Guards

Match arms can have `if` guards:

```rail
classify n = match n
  | 0 -> "zero"
  | _ if n > 0 -> "positive"
  | _ -> "negative"
```

#### Exhaustiveness Checking

The compiler warns (but does not error) on non-exhaustive matches against ADTs:

```rail
type Option = | Some x | None

-- WARNING: non-exhaustive match -- missing: None
get opt = match opt
  | Some x -> x
```

## Lambdas and Closures

Anonymous functions use `\param -> body` syntax:

```rail
\x -> x + 1
\name -> cat ["Hello, ", name]
```

### Nested Lambdas

Nested lambdas are supported and are flattened into multi-parameter closures:

```rail
\a -> \b -> a + b
\x -> \y -> \z -> x + y + z
```

Direct application is beta-reduced at compile time:

```rail
(\a -> \b -> a + b) 3 4    -- evaluates to 7
```

### Closures

Lambdas can capture variables from their enclosing scope (up to 4 captured variables):

```rail
main =
  let offset = 100
  let f = \x -> x + offset
  f 42    -- returns 142
```

### Known Limitation: Lambdas in `filter`

Single lambdas passed directly to `filter` can segfault at runtime due to a dispatch bug. Use named predicate functions instead:

```rail
-- BAD: may segfault
filter (\x -> x > 3) [1, 2, 3, 4, 5]

-- GOOD: use a named function
gt3 x = if x > 3 then true else false
filter gt3 [1, 2, 3, 4, 5]
```

This does not affect `map` or `fold`, where lambdas work correctly.

## Import System

Import another Rail file's public definitions:

```rail
import "stdlib/json.rail"
import "stdlib/math.rail"
```

The imported file is tokenized, parsed, and its declarations are spliced into the current compilation. Functions whose names start with `_` are considered private and are not exported.

### Qualified Imports

Use `as` to prefix all imported names:

```rail
import "stdlib/math.rail" as M

main =
  let _ = print (show (M_abs_int (-5)))
  0
```

All functions from the imported module get the prefix `M_`.

### Link Pragma

The `link` keyword is reserved for future use with external C libraries:

```rail
link "-lsqlite3"
```

Currently, link pragmas are parsed but not acted upon.

## Foreign Function Interface (FFI)

Declare C functions for use from Rail:

```rail
foreign abs n
foreign strlen s
foreign getenv name -> str
foreign sqrt x -> float
foreign pow x y -> float
```

Syntax: `foreign <name> <params...> [-> <return_type>]`

Return types:
- Default (no `->` clause): returns a tagged integer
- `-> str` or `-> ptr`: returns a raw pointer (no tagging)
- `-> float`: returns a float (boxed into a Rail float object)

Integer arguments are automatically untagged before the C call. Float arguments are unboxed from their heap objects.

The foreign function must be available in the linked libraries (libSystem by default, which includes libc and libm).

## Concurrency

### Spawn

`spawn` creates a new fiber that runs a function concurrently:

```rail
work x = x * 2

main =
  let f = spawn (\x -> work 21)
  fiber_await f    -- returns 42
```

### Channels

Channels provide communication between fibers:

```rail
main =
  let ch = channel 0
  let _ = send ch 10
  let _ = send ch 20
  let a = recv ch
  let b = recv ch
  a + b    -- returns 30
```

- `channel 0` creates a new channel
- `send ch val` sends a value to the channel
- `recv ch` receives the next value from the channel

### Fibers

Low-level fiber primitives:

- `fiber_init` -- initialize the fiber system
- `fiber_yield` -- yield the current fiber
- `fiber_await f` -- wait for fiber `f` to complete and return its result

## Memory Management

### Garbage Collector

Rail uses a conservative mark-sweep garbage collector (`runtime/gc.c`). The GC:

1. Scans ARM64 stack frames via the x29 frame chain
2. Identifies heap pointers (aligned, within heap bounds)
3. Traces tagged objects (Cons, Tuple, Closure, ADT, Float)
4. Sweeps unmarked objects into a free list

The GC is triggered automatically when the 1GB bump allocator runs out of space. Programs can allocate well beyond 1GB total because the GC reclaims dead objects.

### Arena Mark/Reset

For manual memory management in performance-critical loops:

```rail
main =
  let mark = arena_mark 0     -- snapshot the heap pointer
  let _ = cons 1 [2, 3]       -- allocate some data
  let _ = arena_reset mark     -- reset heap to snapshot
  42
```

`arena_mark` returns the current heap pointer position. `arena_reset` resets the heap pointer back to that position and clears the free list. This is useful for long-running loops where you want to avoid GC pressure.

**Warning**: Any data allocated after the mark is invalidated by `arena_reset`. Do not use references to data allocated between mark and reset.

## The `llm` Builtin

Rail has a native LLM builtin that calls a local inference server:

```rail
main =
  let response = llm 8080 "You are helpful." "What is 2+2?"
  let _ = print response
  0
```

Signature: `llm port system_prompt user_prompt` returns a string.

The builtin (`runtime/llm.c`) sends an HTTP POST to `localhost:<port>/v1/chat/completions` with the system and user messages, parses the JSON response, and returns the content string. It supports both standard responses and thinking-mode responses (with `<think>` tags).

## Compile-Time Code Generation

The `#generate` directive invokes a local LLM at compile time:

```rail
#generate "factorial function"

main =
  let _ = print (show (fact 10))
  0
```

The compiler calls the LLM to generate Rail code for the description, then splices the generated declarations into the program.

## Tagged Pointer Representation

Understanding the internal representation helps when debugging:

| Value Type | Representation |
|-----------|---------------|
| Integer | `(value << 1) \| 1` (bit 0 = 1) |
| Heap object | Raw pointer (bit 0 = 0, 8-byte aligned) |
| true | 3 (integer 1, tagged) |
| false | 1 (integer 0, tagged) |
| null | 0 |

Heap objects have an 8-byte size header, followed by a tag word:

| Tag | Object Type |
|-----|------------|
| 1 | Cons cell (head, tail) |
| 2 | Nil (empty list) |
| 3 | Tuple (elements...) |
| 4 | Closure (code pointer, capture count, captures...) |
| 5 | ADT (constructor index, fields...) |
| 6 | Float (IEEE 754 double) |

The GC mark bit is stored at bit 63 of the tag word.

## Backends

| Backend | Command | Status |
|---------|---------|--------|
| ARM64 native (macOS) | `./rail_native run file.rail` | Stable |
| ARM64 native (Linux) | `./rail_native linux file.rail` | Cross-compile from macOS |
| Metal GPU | Auto-dispatched for `map` on large lists | Working |
| WASM | `./rail_native wasm file.rail` | Compiles, runtime segfaults |
| x86_64 | Sandboxed subset in `tools/x86_codegen.rail` | Experimental |

### GPU Auto-Dispatch

When `map` is called with a GPU-safe lambda (pure arithmetic on the parameter and integer literals) on a list of 50,000+ elements, the compiler automatically dispatches to a Metal compute shader:

```rail
-- Auto-dispatched to GPU if list is large enough
let result = map (\x -> x * 2 + 1) (range 100000)
```

You can also force GPU execution with `gpu_map`:

```rail
let result = gpu_map (\x -> x * 3 + 1) (range 8)
```

### Map Fusion

The optimizer fuses nested `map` calls:

```rail
-- map f (map g xs)  ->  map (f . g) xs
let result = map double (map triple [1, 2, 3])
-- Equivalent to: map (\x -> double (triple x)) [1, 2, 3]
```

## Known Limitations

1. **`split` is single-character only**: `split "abc" s` splits on each of `a`, `b`, and `c` individually, not on the substring `"abc"`.

2. **Lambdas in `filter` segfault**: Use named predicate functions instead.

3. **WASM backend**: Compiles but segfaults at runtime due to heap limits.

4. **Closure capture limit**: Closures can capture up to 4 variables from the enclosing scope.

5. **No type inference**: The language is dynamically typed at the compilation level. Type annotations (like `i32 -> i32`) are parsed but ignored by the native compiler.

6. **No module system**: `import` is textual inclusion. Name collisions are not checked.
