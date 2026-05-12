# wasm/fib — recursive Fibonacci in WebAssembly

The naive recursive Fibonacci, compiled to WASM. Demonstrates that recursion and integer arithmetic carry through to the WASM backend identically to native.

**Source** (`examples/wasm/fib.rail`):

```rail
fib n =
  if n < 2 then n
  else fib (n - 1) + fib (n - 2)

main =
  let _ = print (fib 10)
  let _ = print (fib 20)
  let _ = print (fib 30)
  0
```

**Build:**

```bash
./rail_native wasm examples/wasm/fib.rail
```

**Output:**

```
Compiling examples/wasm/fib.rail to WASM...
  WAT: 52045 bytes
  wat2wasm: OK
  Binary: /tmp/rail_out.wasm
```

When loaded in a WASM host, this prints `55`, `6765`, `832040` (the three Fibonacci values).
