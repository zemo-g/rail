# Types in Rail

Rail's code generator decides how to represent every value: a tagged int, a heap pointer,
or a raw double in a register. Until now it decided by **guessing**, with more than a thousand lines of
heuristic passes in `tools/compile.rail` (`__argf_`, `__float_ret_`, `hofpos`, the `rmap`
fixpoint). Many entries in `tools/fuzz/known/` are places where a guess was wrong and the
program printed a wrong answer without an error.

`tools/types.rail` is the replacement's first stage: Hindley-Milner type inference with a
`dyn` escape hatch. No annotations are needed.

```
./rail_native types program.rail
```

prints a type for every top-level function, every place the program cannot have one, and,
when the program type-checks, every place the proven types disagree with codegen's guesses.
**Stage 0 is observe-only: codegen does not read these types yet**, so compiled binaries are
unchanged.

## The type language

`int float str bool dyn`, lists `[t]`, tuples `(t1, t2)`, n-ary functions `(t1, t2) -> r`
(Rail has no partial application, so a function's arity is part of its type), named ADTs,
arrays `arr t`, float arrays `farr`, foreign pointers `ptr`.

Top-level functions are generalized per strongly connected group of the call graph, callees
first, so helpers are polymorphic:

```
rev_acc : ([a], [a]) -> [a]
compose : (a -> b, c -> a) -> c -> b
efind   : (a, [(a, int)]) -> int
tokenize : str -> [(str, str)]
```

## Where `dyn` comes from, and why it wins merges

Rail is dynamically typed at run time, and a lot of real Rail code relies on it. `dyn` is how
the checker says "this is only known at run time":

- **A merge is a join; passing an argument only needs consistency.** When two possible values
  meet (the branches of an `if` or `match`, the elements of a list literal, the values written
  into an array), the result is the least precise of the two, so a string on one side and
  `dyn` on the other is `dyn`. When an argument is passed, `dyn` is simply accepted. Using
  consistency for merges would let the first concrete type win and claim a type the value
  does not have.
- **A list or array whose elements differ is `[dyn]` / `arr dyn`**, counted in the report as a
  heterogeneous literal, not an error.
- **ADT fields and foreign arguments are `dyn`** (neither declares a type), except that a
  foreign function returning `float` takes floats, because codegen converts every argument
  of such a call to a double.
- **`arr_new n 0` says nothing about the element type.** `0` is Rail's null; the array's
  writes decide.
- **An int promotes into a float context.** `0.0 +. n` with `n` an int is legal Rail, so a float
  operand never forces the variable next to it to be float (`half x = x /. 2.0` is
  `a -> float`). An int literal does pin a variable to int (`n <= 1`), which keeps counters
  precise (`fact : int -> int`).

## What stage 0 found (2026-09-22, every tracked `.rail` file)

- **297 of 485 files type-check with no errors.** Across them, 89% of function signatures
  (53,112 of 59,543, counting imported modules once per importer) are fully static.
- **The compiler itself** (`tools/compile.rail`, 1,339 functions, about 18 s with
  `RAIL_ARENA_MB=6000`): 1,250 signatures are fully static, and of its 1,685 type errors,
  1,533 are one idiom. The AST is lists like `["O", op, left, right]` that mix a string tag
  with sub-trees, so a function that reads `head node == "O"` and later passes an element on
  as a node cannot have a type. That code is dynamically typed as written; typing it means
  giving the AST an ADT.
- The other recurring idiom is **an array used as a record** (slot 0 an array, slot 2 an
  int), read at different types in one function.
- **In every program that type-checks, codegen's parameter guesses agree with the proven
  types.** The only disagreements left are 31 functions whose results are proven float but
  which codegen returns boxed: correct, slower (the MHD kernel's `mk_pressure`, called per
  cell by its flux functions, is one).

## What comes next

Each stage lands behind the suite, the known-miscompile corpus, the semantic fuzzer and the
byte-identical self-compile, and changes what compiles only when it is proposed as such:

1. **Check.** Type errors in code that type-checks everywhere else become compile errors instead
   of wrong answers or segfaults. Code that relies on dynamic idioms stays accepted until it
   opts in.
2. **Codegen from types.** Float and int representation decided by proven types, removing the
   heuristic passes one at a time; the 31 boxed float returns become raw.
3. **What types make possible.** Structural `==` on lists, tuples and ADTs (today it compares
   tag bytes), constructors as function values (today a crash), partial application, `show`
   on anything, and error messages that name types.
