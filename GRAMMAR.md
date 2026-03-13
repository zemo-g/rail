# Rail Grammar Specification v0.1

## Philosophy
- Pure functional: functions are the only abstraction
- Immutable by default, explicit mutation via `mut` (rare, discouraged)
- Indentation-based scoping (2 spaces)
- No hidden control flow — what you read is what runs
- Effects are explicit (IO, State marked in types)
- Small grammar: ~30 production rules

## Types

```
# Primitives
i32 i64 f32 f64 bool str

# Compound
[T]           -- list
(T, U)        -- tuple
{key: T}      -- record
T -> U        -- function
T?            -- optional (no null)
T!E           -- result (value or error E)
```

## Functions (the only abstraction)

```rail
-- A function is a name, parameters, return type, and body
add : i32 -> i32 -> i32
add x y =
  x + y

-- Multi-line bodies use indentation
distance : f64 -> f64 -> f64
distance x y =
  let dx = x * x
  let dy = y * y
  sqrt (dx + dy)
```

## Pattern Matching

```rail
describe : i32 -> str
describe n =
  match n
    0 -> "zero"
    1 -> "one"
    _ -> "many"
```

## Records

```rail
type Point =
  x: f64
  y: f64

origin : Point
origin = { x: 0.0, y: 0.0 }
```

## Algebraic Data Types

```rail
type Option T =
  | Some T
  | None

type Result T E =
  | Ok T
  | Err E
```

## Let Bindings (always immutable)

```rail
compute : i32 -> i32
compute n =
  let a = n + 1
  let b = a * 2
  b + 10
```

## Pipe Operator (data flows like a train on rails)

```rail
process : [i32] -> i32
process xs =
  xs
  |> filter (> 0)
  |> map (* 2)
  |> fold 0 (+)
```

## Effects (explicit in types)

```rail
greet : str -> IO ()
greet name =
  print "hello, {name}"

-- Pure functions cannot call IO functions
-- The type system enforces this
```

## Properties (built-in testing)

```rail
prop add_commutative : i32 -> i32 -> bool
prop add_commutative x y =
  add x y == add y x

prop add_identity : i32 -> bool
prop add_identity x =
  add x 0 == x
```

## Module System

```rail
module Math

export sqrt, abs, pow

sqrt : f64 -> f64
sqrt x = ...
```

## Comments

```rail
-- single line comment
```

## Reserved Words (kept minimal)

let, match, type, module, export, import, prop, mut, if, then, else, do

## What Rail Does NOT Have
- No classes, no objects, no inheritance
- No null (use Option)
- No exceptions (use Result)
- No implicit conversions
- No macros (comptime later, maybe)
- No operator overloading
- No variadic arguments
- No global mutable state
