# Types in Rail

Rail's code generator decides how to represent every value: a tagged int, a heap pointer,
or a raw double in a register. Until 2026-09-22 it decided by **guessing**, with more than
a thousand lines of call-site heuristics in `tools/compile.rail` (`argf_scan`, `hofpos`,
the `rmap` fixpoint). Many entries in `tools/fuzz/known/` are places where a guess was wrong
and the program printed a wrong answer without an error.

Those passes are gone. `tools/types.rail` infers types (Hindley-Milner with a `dyn` escape
hatch, no annotations needed), and codegen reads its representation decisions from them.

```
./rail_native types program.rail
```

prints a type for every top-level function, every place the program cannot have one, and a
line saying how many parameters and results codegen gives a static representation:

```
--- examples/quicksort.rail ---
  showNum : a -> str
  filterLeq : ([a], a) -> [a]
  filterGt : ([a], a) -> [a]
  qsort : [a] -> [a]
  main : () -> int
functions: 5, fully static: 5, type errors: 0, heterogeneous literals: 0
codegen: settled after 2 rounds; 3 of 6 parameters and 5 of 5 results have a static representation
```

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
- **An ADT field declared by a plain name is `dyn`** (`| Box v` declares nothing), and so is a
  foreign argument, except that a foreign function returning `float` takes floats, because
  codegen converts every argument of such a call to a double. A field that names a type is
  that type (next section).
- **An array's element type is a variable that a store can widen.** A read returns that
  variable itself, not a copy of what it holds, so a value read before a store of another
  kind follows the array to `dyn`. An array handed to a function is checked both ways (the
  callee may store into it), and one that reaches `dyn` can be written with anything, so its
  element type becomes `dyn`. `arr_new n 0` says nothing about the element type (`0` is Rail's
  null).
- **An int promotes into a float context.** `0.0 +. n` with `n` an int is legal Rail, so a float
  operand never forces the variable next to it to be float (`half x = x /. 2.0` is
  `a -> float`). An int literal does pin a variable to int (`n <= 1`), which keeps counters
  precise (`fact : int -> int`). A float operand makes any arithmetic a float whatever the other
  side holds (the runtime reads a string as 0.0); an int beside `dyn` may be a float, so it is
  `dyn`.

## Typed constructor fields

A field may name its type: `int`, `float`, `str`, `bool`, `dyn`, a type the program declares,
`[t]` for a list of `t`, `(arr t)` for an array of `t`, or `(t1, t2)` for a tuple.

```rail
type Expr = | Num int | Add Expr Expr | Neg Expr | Many [Expr] | Name str
eval e = match e
  | Num n -> n
  | Add a b -> eval a + eval b
  ...
```

infers `eval : Expr -> int`: a match binds each field at its declared type. Every construction
is a flow into the fields' types, checked like an argument; one that passes another type is a
type error, and the field falls back to `dyn` for codegen, so the program runs as before. A
constructor named as a value (`map Num xs`) builds through a closure the checks cannot see, so
its fields are forced to `dyn`. No declaration in the tree used type names as fields before
this, so existing programs keep `dyn` fields.

## How codegen uses the types

Each parameter gets a **kind**: float (it arrives as raw float bits), int, a heap value, or
anything. A parameter whose type is concrete takes that type's kind. A polymorphic one
(`square x = x * x : a -> a`) takes the join of what its direct call sites pass, where an
argument whose type is the calling function's own polymorphic parameter contributes that
parameter's kind: one compiled body serves every call. A result is raw float bits when its
type is float, or when it is a parameter's variable and that parameter's kind is float.

A claim codegen acts on must hold for every value that can reach it, because the garbage
collector skips a slot it believes holds an int and a raw-float parameter reads its bits as a
double. So inference runs in **rounds**. After each round every flow of a value into a typed
slot is checked: arguments into parameters, a function's body into its result, and, inside a
function type, the other way round (whoever holds a closure calls it with its own values).
Where `dyn`, or a clashing type, reaches a slot that claims a type, the slot's owner is forced
to `dyn` and the program is inferred again:

| what reaches the slot | what is forced |
|---|---|
| a user fn's parameter | that parameter |
| a lambda's parameter | that lambda's parameters |
| a builtin or closure call whose result depends on its arguments | that call's result |
| a function's result, from its body | that result |
| a user fn named as a value (it is called with generic arguments) | all its parameters |
| an array made by `arr_new`, from a callee that stores into it | that array |
| a constructor's declared field | that field |

Rounds stop when one forces nothing new. When they do not settle (a cap of 60), every
parameter is generic and no result is raw: the generic representation is always correct.
Type errors are handled by the same check, since a clash is a bad flow.

## What changed when codegen moved to the types (2026-09-22)

- **The self-compile takes about 5 s instead of 20.** The call-site passes cost 16.6 s of it;
  inference with its rounds takes 1.6 s on the compiler's own source (11 rounds).
- **`float_arr_map` with a named function works.** Naming a float-returning function was read as
  naming a float constant, so the closure pointer was boxed as a double before the call (a bus
  error, t219). Float constants now carry their own marker.
- **Results the types prove float leave as raw bits** even when the body's code does not produce
  them raw (`head` of a `[float]`); the MHD kernel's `mk_pressure`, which its flux functions
  call per cell, is one.
- **Where `dyn` reaches a parameter, it stays generic.** The call-site passes called `lr * wd`
  an int (arithmetic on two unknowns defaulted to int) and `x - 1` on a value out of an
  untyped list an int; the types say `dyn`, which is what those values are.
- **The compiled output is unchanged in behaviour.** 104 runnable programs in the tree (every
  file whose code and imports stay inside the process) print the same with both compilers;
  the suite, the known-miscompile corpus and the semantic fuzzer's CI seed pass; four wider
  fuzzer seeds failed the same cases with both compilers (a lambda applied straight to a float,
  and `%` on floats), fixed right after, and now pass 464 of 464 each. 148 of the 474 files that
  compile produce byte-identical assembly.

## What the types find (2026-09-22, every tracked `.rail` file)

- **301 of 487 files type-check with no errors.** Across all files, 87.7% of function signatures
  (53,524 of 61,058, counting imported modules once per importer) are fully static. (The
  stage-0 figure, 89%, was also counted across all files.)
- **Codegen gives a static representation to 47% of parameters and 86% of results** across
  the tree. 209 files settle in one round; the most any file needs is 18.
- **The compiler itself** (`tools/compile.rail`, 1,349 functions): 1,227 signatures are fully
  static, and it has 1,720 type errors (stage 0 traced 91% of its 1,685 to one idiom). The AST is lists like
  `["O", op, left, right]` that mix a string tag with sub-trees, so a function that reads
  `head node == "O"` and later passes an element on as a node cannot have a type. That code is
  dynamically typed as written; typing it means giving the AST an ADT. Codegen settles after
  11 rounds with 1,161 of 3,106 parameters static.
- The other recurring idiom is **an array used as a record** (slot 0 an array, slot 2 an
  int), read at different types in one function.

## What comes next

1. **Type the compiler.** The AST becomes an ADT with typed fields, and
   `rail types tools/compile.rail` reaches zero errors. Under way: `tools/ast.rail` declares the
   tree and the parser builds it, the type checker reads it and is typed throughout
   (`rail types tools/types.rail`: zero errors), and so do all five code generators (ARM64,
   x86, wasm, Cortex-M, RISC-V), `rail safe` and the checks. The optimizer and the AD and auth
   synthesis move over next; two adapters convert between the typed tree and the older list
   form until the last one does.
2. **Check.** Type errors in code that type-checks everywhere else become compile errors instead
   of wrong answers or segfaults. Code that relies on dynamic idioms stays accepted until it
   opts in.
3. **What types make possible.** Structural `==` on lists, tuples and ADTs (today it compares
   tag bytes), constructors as function values (today a crash), partial application, `show`
   on anything, float parameters through closures, and error messages that name types.
