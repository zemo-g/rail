# wasm/closure — captured locals in WASM

Closures work in the WASM backend, including capturing locals from the enclosing scope. The runtime allocates a closure object on the WASM linear memory; the GC reclaims it when unreferenced.

**Source** (`examples/wasm/closure.rail`):

```rail
apply f x = f x

main =
  let scale = 10
  let mul = \x -> x * scale
  let _ = print (show (apply mul 7))
  let offset = 100
  let add = \x -> x + offset
  let _ = print (show (apply add 42))
  0
```

**Build:**

```bash
./rail_native wasm examples/wasm/closure.rail
```

**Output:**

```
Compiling examples/wasm/closure.rail to WASM...
  WAT: 53555 bytes
  wat2wasm: OK
  Binary: /tmp/rail_out.wasm
```

When loaded in a WASM host, this prints `70` (`7 * 10`) and `142` (`42 + 100`). The two closures each capture their respective local (`scale`, `offset`) at allocation time.
