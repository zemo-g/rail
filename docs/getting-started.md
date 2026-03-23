# Getting Started with Rail

Rail is a self-hosting programming language that compiles to native ARM64 binaries. The compiler is written in Rail itself (1,979 lines) and produces byte-identical output when compiling itself -- a fixed point.

## Requirements

- Apple Silicon Mac (ARM64 macOS)
- macOS assembler (`as`) and linker (`ld`) -- included with Xcode Command Line Tools

No other dependencies. No package manager. No runtime.

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
```

That's it. The seed binary (`rail_native`, ~367K) is checked into the repo.

## Hello World

Create a file called `hello.rail`:

```rail
main =
  let _ = print "hello, world"
  0
```

Compile and run it:

```bash
./rail_native run hello.rail
```

Output:

```
hello, world
```

## How Compilation Works

Rail has two modes:

```bash
./rail_native hello.rail          # compile only -> /tmp/rail_out
./rail_native run hello.rail      # compile + execute
```

When you run `./rail_native hello.rail`, the compiler:

1. Reads `hello.rail` and tokenizes it
2. Parses tokens into an AST
3. Checks exhaustiveness of pattern matches (warnings, not errors)
4. Generates ARM64 assembly
5. Calls `as` to assemble into an object file
6. Calls `ld` to link with the C runtime (`runtime/gc.c`, `runtime/llm.c`) into a Mach-O binary
7. Writes the binary to `/tmp/rail_out`

With `run`, it then executes `/tmp/rail_out`.

## A Slightly Bigger Program

```rail
double x = x * 2
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

main =
  let _ = print "hello, rail"
  let _ = print (factorial 10)
  let _ = print (double 21)
  0
```

Output:

```
hello, rail
3628800
42
```

Key things to note:

- Functions are defined **before** `main`
- `main` must exist and must return an integer (the exit code)
- Side effects use `let _ = ...` to discard the result
- `print` outputs a value followed by a newline
- `show` converts an integer to a string (not needed when printing ints directly)

## Running the Test Suite

```bash
./rail_native test
```

This runs 70 built-in tests covering integers, strings, lists, tuples, ADTs, closures, FFI, concurrency, and more. All 70 should pass.

## Self-Compilation

Rail compiles itself. To verify:

```bash
./rail_native self
```

This compiles `tools/compile.rail` (the compiler source) into `/tmp/rail_self`. The output should be byte-identical to `rail_native` itself.

## Rebuilding from Source

If you modify the compiler (`tools/compile.rail`):

```bash
# Step 1: Compile with the old binary
./rail_native self

# Step 2: Install the new binary
cp /tmp/rail_self ./rail_native

# Step 3: Compile with the new binary
./rail_native self

# Step 4: Verify fixed point (output must be empty)
diff /tmp/rail_self /tmp/rail_out

# Step 5: If not identical, repeat steps 2-4 until stable

# Step 6: Run tests
./rail_native test    # should be 70/70
```

## Other Commands

```bash
./rail_native linux hello.rail    # cross-compile for Linux ARM64
./rail_native wasm hello.rail     # compile to WASM (experimental)
./rail_native generate "desc"     # generate code via local LLM
./rail_native get json            # install stdlib package
./rail_native packages            # list installed packages
```

## Project Structure

```
rail/
  rail_native           # seed binary (ARM64, ~367K)
  tools/
    compile.rail        # the compiler (~1,979 lines of Rail)
  runtime/
    gc.c                # garbage collector (conservative mark-sweep)
    llm.c               # LLM builtin implementation
  stdlib/               # 22 standard library modules
  examples/             # example programs
  docs/                 # documentation (you are here)
```

## Next Steps

- [Language Reference](language-reference.md) -- complete syntax guide
- [Builtins](builtins.md) -- every built-in function
- [Standard Library](stdlib.md) -- all 22 stdlib modules
- [Examples](examples.md) -- annotated example programs
