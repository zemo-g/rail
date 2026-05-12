# wasm/hello — Rail to WebAssembly

The same Rail source compiles to ARM64 macOS, ARM64 Linux, x86_64 Linux, WASM, Cortex-M4, and RV32IMC. Here's the smallest WASM target.

**Source** (`examples/wasm/hello.rail`):

```rail
main =
  let _ = print "Hello from Rail!"
  let _ = print "Running as WebAssembly."
  0
```

**Build (compile-only — does not execute on host):**

```bash
./rail_native wasm examples/wasm/hello.rail
```

**Output:**

```
Compiling examples/wasm/hello.rail to WASM...
  WAT: 51277 bytes
  wat2wasm: OK
  Binary: /tmp/rail_out.wasm
```

The driver emits WAT (WebAssembly text), then runs `wat2wasm` to produce the binary at `/tmp/rail_out.wasm`. Drop that file into the playground at https://ledatic.org or load it in any WASM runtime that supplies the small `env` import set (`print`, etc.).
