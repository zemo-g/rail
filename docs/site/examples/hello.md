# hello — first Rail program

The smallest meaningful Rail program: define two functions before `main`, call them, print the results. `main` is the entry point and must return an int (0 = success).

**Source** (`examples/hello.rail`):

```rail
-- hello.rail — first Rail program (compiles natively)

double x = x * 2
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

main =
  let _ = print "hello, rail"
  let _ = print (factorial 10)
  let _ = print (double 21)
  0
```

**Run:**

```bash
./rail_native run examples/hello.rail
```

**Output:**

```
Compiling examples/hello.rail (244 chars)...
  as: OK
  ld: OK
hello, rail
3628800
42
```

The first three lines come from the compiler driver (`as` = assembler, `ld` = linker). Everything below is the program output: the greeting, `10! = 3628800`, and `21 * 2 = 42`.
