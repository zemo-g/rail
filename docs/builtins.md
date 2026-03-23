# Rail Builtins Reference

Every built-in function available without importing any module. These are compiled directly into the generated ARM64 assembly.

## I/O

### `print`

Print a value to stdout followed by a newline.

```rail
print "hello"           -- prints: hello
print 42                -- prints: 42
print (show (3 + 4))    -- prints: 7
```

Integers are printed as decimal numbers. Strings are printed as-is. For other types, use `show` first.

### `show`

Convert a tagged integer to its string representation.

```rail
show 42      -- returns "42"
show (-7)    -- returns "-7"
show 0       -- returns "0"
```

Also works on floats:

```rail
show 3.14    -- returns "3.14"
show (1.5 + 2.25)  -- returns "3.75"
```

### `read_file`

Read the entire contents of a file as a string. Returns an empty string if the file does not exist.

```rail
let content = read_file "/tmp/data.txt"
```

### `write_file`

Write a string to a file, creating it if it does not exist, overwriting if it does.

```rail
write_file "/tmp/output.txt" "hello, world"
```

### `shell`

Execute a shell command and return its stdout as a string.

```rail
let date = shell "date +%Y-%m-%d"
let files = shell "ls -1 /tmp"
```

The entire stdout output is returned, including trailing newlines. Use `trim` or `split` to clean it up:

```rail
let date = head (split "\n" (shell "date"))
```

### `cat`

Concatenate a list of strings into one string (equivalent to `join "" list`).

```rail
cat ["hello", " ", "world"]    -- returns "hello world"
cat [show 1, "+", show 2]      -- returns "1+2"
```

## Lists

### `head`

Return the first element of a list.

```rail
head [10, 20, 30]    -- returns 10
head ["a", "b"]      -- returns "a"
```

Calling `head` on an empty list is undefined behavior.

### `tail`

Return all elements except the first.

```rail
tail [10, 20, 30]    -- returns [20, 30]
tail [1]             -- returns []
```

### `cons`

Prepend an element to a list.

```rail
cons 1 [2, 3]        -- returns [1, 2, 3]
cons "a" []          -- returns ["a"]
```

### `append`

Concatenate two lists, or concatenate two strings.

```rail
append [1, 2] [3, 4]     -- returns [1, 2, 3, 4]
append "hello" " world"  -- returns "hello world"
```

The `+` operator on strings also calls `append`:

```rail
"foo" + "bar"    -- returns "foobar"
```

### `length`

Return the number of elements in a list, or the number of characters in a string.

```rail
length [1, 2, 3]     -- returns 3
length []            -- returns 0
length "hello"       -- returns 5
```

### `map`

Apply a function to every element of a list.

```rail
double x = x * 2
map double [3, 5, 7]           -- returns [6, 10, 14]
map (\x -> x + 10) [1, 2, 3]  -- returns [11, 12, 13]
```

Lambdas work correctly with `map`.

### `filter`

Keep only elements that satisfy a predicate.

```rail
gt2 x = if x > 2 then true else false
filter gt2 [1, 2, 3, 4, 5]    -- returns [3, 4, 5]
```

**Known limitation**: Inline lambdas in `filter` can segfault. Always use named predicate functions:

```rail
-- BAD: may segfault at runtime
filter (\x -> x > 2) [1, 2, 3, 4, 5]

-- GOOD: use a named function
gt2 x = if x > 2 then true else false
filter gt2 [1, 2, 3, 4, 5]
```

### `fold`

Left fold over a list with an accumulator.

```rail
add a b = a + b
fold add 0 [1, 2, 3, 4, 5]    -- returns 15
```

`fold f init [a, b, c]` computes `f (f (f init a) b) c`.

**Important**: Use named 2-argument functions, not nested lambdas.

### `reverse`

Reverse a list.

```rail
reverse [1, 2, 3]    -- returns [3, 2, 1]
```

### `join`

Join a list of strings with a separator.

```rail
join "-" ["a", "b", "c"]    -- returns "a-b-c"
join ", " ["one", "two"]    -- returns "one, two"
join "" ["hello", "world"]  -- returns "helloworld"
```

### `range`

Generate a list of integers from 0 to N-1.

```rail
range 5     -- returns [0, 1, 2, 3, 4]
range 0     -- returns []
range 1     -- returns [0]
```

## Strings

### `chars`

Split a string into a list of single-character strings.

```rail
chars "abc"    -- returns ["a", "b", "c"]
chars ""       -- returns []
```

### `split`

Split a string by delimiter characters.

```rail
split "," "a,b,c"          -- returns ["a", "b", "c"]
split " " "hello world"    -- returns ["hello", "world"]
split "\n" "line1\nline2"  -- returns ["line1", "line2"]
```

**Important**: `split` treats its first argument as a set of single-character delimiters, not a substring. Each character in the delimiter string is a separate split point:

```rail
split "ab" "xaybz"    -- splits on "a" AND "b" -> ["x", "y", "z"]
```

This is the most common gotcha in Rail. For substring-based splitting, use `shell` with `sed` or `perl`.

### `append` (strings)

Concatenate two strings:

```rail
append "hello" " world"    -- returns "hello world"
```

Also available via the `+` operator on strings.

### `trim`

Remove trailing newlines from a string (returns text up to the first newline).

```rail
trim "hello\nworld"    -- returns "hello"
```

Note: `trim` in the compiler is defined as `head (split "\n" s)`, so it really just returns the first line.

## Math

### `not`

Logical NOT. Flips a boolean value.

```rail
not true     -- returns false
not false    -- returns true
```

### `to_float`

Convert an integer to a float.

```rail
to_float 42       -- returns 42.0
to_float (-5)     -- returns -5.0
```

Required when calling math FFI functions like `sqrt`:

```rail
foreign sqrt x -> float
let result = sqrt (to_float 144)    -- returns 12.0
```

### `to_int`

Convert a float to an integer (truncates toward zero).

```rail
to_int 3.7     -- returns 3
to_int (-2.9)  -- returns -2
```

## Memory

### `arena_mark`

Return the current heap pointer position as an opaque value.

```rail
let mark = arena_mark 0
```

The argument is ignored (pass 0).

### `arena_reset`

Reset the heap pointer to a previously saved position and clear the free list.

```rail
let mark = arena_mark 0
let _ = cons 1 [2, 3]     -- allocate some data
let _ = arena_reset mark   -- free everything since mark
```

**Warning**: All data allocated after the mark becomes invalid.

### `rc_alloc`

Allocate a reference-counted block of the given size in bytes.

```rail
let p = rc_alloc 128
```

### `rc_retain`

Increment the reference count of a block allocated with `rc_alloc`.

```rail
rc_retain p
```

### `rc_release`

Decrement the reference count. Frees the block when it reaches zero.

```rail
rc_release p
```

## Concurrency

### `spawn`

Spawn a fiber running a function. Returns a fiber handle.

```rail
let f = spawn (\x -> some_work x)
```

### `channel`

Create a new channel. The argument is ignored (pass 0).

```rail
let ch = channel 0
```

### `send`

Send a value to a channel.

```rail
send ch 42
```

### `recv`

Receive the next value from a channel.

```rail
let val = recv ch
```

### `fiber_init`

Initialize the fiber runtime. Call once before using spawn.

```rail
let _ = fiber_init
```

### `fiber_yield`

Yield the current fiber, allowing other fibers to run.

```rail
let _ = fiber_yield
```

### `fiber_await`

Wait for a spawned fiber to complete and return its result.

```rail
let result = fiber_await f
```

## System

### `args`

The command-line arguments as a list of strings. The first element is the program name.

```rail
main =
  let a = args
  let _ = print (show (length a))
  0
```

### `import`

Import declarations from another Rail source file:

```rail
import "stdlib/json.rail"
import "stdlib/math.rail" as M
```

See [Language Reference](language-reference.md#import-system) for details.

## GPU

### `gpu_map`

Force GPU execution of a map operation via Metal compute shader.

```rail
let result = gpu_map (\x -> x * 3 + 1) (range 8)
```

The lambda must be GPU-safe: pure arithmetic on the parameter and integer literals only (no function calls, no string operations, no conditionals).
