# Rail Grammar Specification v0.6

## Philosophy
- Pure functional: functions are the only abstraction
- Immutable — no mutable bindings
- Indentation-based scoping (2 spaces)
- No hidden control flow — what you read is what runs
- Effects via perform/handle/resume (algebraic effects)
- Small grammar: ~30 production rules

## Types

```
# Primitives
i32 f64 String Bool

# Compound
[T]           -- list
(T, U)        -- tuple
T -> U        -- function
```

## Functions

```rail
-- Type signature (optional — Hindley-Milner infers)
add : i32 -> i32 -> i32
add x y = x + y

-- Multi-line bodies use indentation
distance : f64 -> f64 -> f64
distance x y =
  let dx = x * x
  let dy = y * y
  sqrt (dx + dy)
```

## String Interpolation

```rail
greet name = print "hello, {name}!"
report n = print "result: {show n}"
```

Expressions in `{}` are evaluated. Non-string values need `show`.

## Pattern Matching

```rail
describe : i32 -> String
describe n =
  match n
    0 -> "zero"
    1 -> "one"
    _ -> "many"
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

## Records

```rail
type Point =
  x: f64
  y: f64

origin = { x: 0.0, y: 0.0 }
```

Access fields with dot notation: `p.x`, `p.y`.

## Let Bindings (always immutable)

```rail
compute : i32 -> i32
compute n =
  let a = n + 1
  let b = a * 2
  b + 10

-- Tuple destructuring
let (x, y) = (10, 20)
```

## Pipe Operator

```rail
process xs =
  xs |> filter (\x -> x > 0) |> map (\x -> x * 2) |> length
```

## Lambdas

```rail
double = \x -> x * 2

transform = \x ->
  let y = x + 1
  y * 2
```

## Algebraic Effects

```rail
effect Ask
  ask : String -> String

interview _ =
  let name = perform ask "name"
  let color = perform ask "color"
  append name " likes " color

main =
  let r = handle (interview ()) with
    ask q -> if q == "name" then resume "Alice" else resume "blue"
  print r
```

## AI Builtins

```rail
-- Single call
let answer = prompt "What is 2+2?"
let answer = prompt_with "system prompt" "user message"

-- Parallel fan-out (batched)
let results = par_prompt "system" [input1, input2, input3]

-- Multi-turn agent loop
let result = agent_loop "system" tools fns "user message"

-- Conversation context
let ctx = context_new "system prompt"
let (ctx, response) = context_prompt ctx "hello"

-- Structured output
let data = prompt_typed "description" "schema" "input"

-- Token tracking
let u = llm_usage ()
print "{u.calls} calls, {u.total_tokens} tokens"
```

## Module System

```rail
import Math (square, gcd, factorial)

main =
  print (square 7)
  print (gcd 12 8)
```

## Comments

```rail
-- single line comment
```

## Operators

`+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `|>` (pipe)

## Reserved Words

let, match, type, module, export, import, if, then, else, effect, perform, handle, with, resume

## What Rail Does NOT Have
- No classes, no objects, no inheritance
- No null (use Option)
- No exceptions (use Result)
- No implicit conversions
- No macros
- No operator overloading
- No mutable state
- No multi-line list literals in blocks where indentation is ambiguous
