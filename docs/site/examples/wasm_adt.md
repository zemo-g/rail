# wasm/adt — ADTs and pattern matching in WebAssembly

ADTs and `match` work in the WASM backend just like native. This example defines a `Shape` ADT and pattern-matches over it to compute area.

**Source** (`examples/wasm/adt.rail`):

```rail
type Shape =
  | Circle r
  | Rect w h

area s = match s
  | Circle r -> r * r * 3
  | Rect w h -> w * h

main =
  let _ = print (show (area (Circle 5)))
  let _ = print (show (area (Rect 4 7)))
  let _ = print (show (area (Circle 10)))
  0
```

**Build:**

```bash
./rail_native wasm examples/wasm/adt.rail
```

**Output:**

```
Compiling examples/wasm/adt.rail to WASM...
  WAT: 53735 bytes
  wat2wasm: OK
  Binary: /tmp/rail_out.wasm
```

When the resulting `.wasm` runs in a host, it prints `75`, `28`, `300`.
