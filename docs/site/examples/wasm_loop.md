# wasm/loop — GC stress test in 1 MB heap

The WASM build runs in a tight 1 MB heap. This program allocates a `cons` cell per iteration for 100,000 iterations — that's about 2.4 MB of garbage. The Cheney-style copying GC reclaims them and the program completes.

**Source** (`examples/wasm/loop.rail`):

```rail
-- GC stress test: allocate a cons cell each iteration, drop it.
-- Without GC, 100,000 iterations × 24 bytes = 2.4 MB → OOM in 1 MB heap.
-- With shadow-stack rooted Cheney GC, garbage cells are reclaimed and
-- the program completes.

loop n =
  if n == 0 then 0
  else
    let _ = cons n []
    loop (n - 1)

main =
  let _ = print "GC stress: allocating 100000 cons cells in 1MB heap..."
  let _ = loop 100000
  let _ = print "Done — GC reclaimed garbage."
  0
```

**Build:**

```bash
./rail_native wasm examples/wasm/loop.rail
```

**Output:**

```
Compiling examples/wasm/loop.rail to WASM...
  WAT: 52104 bytes
  wat2wasm: OK
  Binary: /tmp/rail_out.wasm
```

Run in any WASM host with the standard `print` import to see both lines.
