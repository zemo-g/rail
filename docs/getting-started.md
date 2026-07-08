# Getting Started with Rail

Rail is a self-hosting programming language that compiles to native ARM64 binaries. The compiler is written in Rail itself (~9,200 lines) and produces byte-identical output when compiling itself -- a fixed point.

## Requirements

- Apple Silicon Mac (ARM64 macOS)

That's the whole list. As of v5.2.0, Rail assembles, links, and code-signs its own binaries in-process -- no `as`, no `ld`, no `codesign`, no Xcode toolchain. No package manager. No runtime. No C.

## Install

```bash
git clone https://github.com/zemo-g/rail
cd rail
```

That's it. The seed binary (`rail_native`, ~870K) is checked into the repo.

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
5. Assembles, links, and ad-hoc code-signs it into a Mach-O binary -- **in-process, in pure Rail** (no `as`, `ld`, `codesign`, or C runtime)
6. Writes the binary to `/tmp/rail_out`

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

This runs 178 built-in tests covering integers, strings, lists, tuples, ADTs, closures, FFI, concurrency, and more. All 178 should pass.

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
./rail_native test    # should be 178/178
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
  rail_native           # seed binary (ARM64, ~870K)
  tools/
    compile.rail        # the compiler (~9,200 lines of Rail; GC + runtime are ARM64 asm inside it)
  stdlib/               # 101 standard library modules
  examples/             # example programs
  docs/                 # documentation (you are here)
```

## Next Steps

- [Language Reference](language-reference.md) -- complete syntax guide
- [Builtins](builtins.md) -- every built-in function
- [Standard Library](stdlib.md) -- the core stdlib modules (101 total in `stdlib/`)
- [Examples](examples.md) -- annotated example programs
