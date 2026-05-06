// tools/jit_call.c
// Pre-compiled trampoline for the pure-Rail JIT (Session C). NOT used in
// the shipping path — Session C went with pthread_create as the indirect-
// call mechanism (libSystem auto-links, zero extra build steps). This
// file is retained so a future variant of the JIT can switch to a
// dlopen+dlsym strategy without re-deriving the trampoline.
//
// Build:
//   bash jit/build_trampoline.sh
//
// Use from Rail:
//   foreign jit_call fn arg -> int
//   let r = jit_call page my_int
long jit_call(long (*fn)(long), long arg) { return fn(arg); }
