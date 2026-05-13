# pattern_matching — ADTs and `match`

Rail's algebraic data types: declare with `type`, destructure with `match` (no `with` keyword). Non-exhaustive matches are a compile-time error.

**Source** (`examples/pattern_matching.rail`):

```rail
-- pattern_matching.rail — showcase ADTs and pattern matching
--
-- Demonstrates: multiple ADT types, pattern matching, exhaustive handling

type Color = | Red | Green | Blue

type Shape = | Circle r | Rect w h | Point

colorName c = match c
  | Red -> "red"
  | Green -> "green"
  | Blue -> "blue"

area s = match s
  | Circle r -> r * r * 3
  | Rect w h -> w * h
  | Point -> 0

describe s = match s
  | Circle r -> "circle"
  | Rect w h -> "rectangle"
  | Point -> "point"

type Option = | Some x | None

getOr opt d = match opt
  | Some x -> x
  | None -> d

main =
  -- Colors
  let _ = print (colorName Red)
  let _ = print (colorName Green)
  let _ = print (colorName Blue)

  -- Shapes
  let c = Circle 5
  let r = Rect 3 4
  let p = Point
  let _ = print (describe c)
  let _ = print (show (area c))
  let _ = print (describe r)
  let _ = print (show (area r))
  let _ = print (describe p)
  let _ = print (show (area p))

  -- Option
  let a = Some 42
  let b = None
  let _ = print (show (getOr a 0))
  let _ = print (show (getOr b 99))

  0
```

**Run:**

```bash
./rail_native run examples/pattern_matching.rail
```

**Output:**

```
red
green
blue
circle
75
rectangle
12
point
0
42
99
```

`area (Circle 5) = 5*5*3 = 75` (pi rounded to 3). `area (Rect 3 4) = 12`. `getOr (Some 42) 0 = 42`. `getOr None 99 = 99`.
