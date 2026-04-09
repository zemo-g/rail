---
name: backend-adaptation
description: How Rail's compiler adapts to new hardware — the codegen architecture and porting playbook
type: reference
---

## Rail Backend Adaptation Playbook

### Compiler Architecture (compile.rail)

The compiler is a 4-stage pipeline. Only stage 3 and 4 are hardware-specific:

```
1. tokenize src → tokens          (universal)
2. pprog tokens → AST declarations (universal)
3. compile_funcs decls → assembly  (HARDWARE-SPECIFIC)
4. assemble + link → binary        (HARDWARE-SPECIFIC)
```

### What's Hardware-Specific

**Stage 3 — Codegen** (`compile_funcs` and helpers, ~600 lines):
- `emit_load_int v` — load immediate into register
- Function prologue/epilogue — stack frame setup (x29/sp on ARM64)
- Calling convention — args in x0-x7, return in x0 (ARM64 ABI)
- Branch/compare — `b.eq`, `cmp`, `cset` patterns
- Tagged pointer ops — shift/mask for 63-bit integers (tag bit 0)
- Closure capture — heap allocation + register spills
- Match arms — ADT tag checks + field extraction

**Stage 4 — Build** (~30 lines):
- `compile_program` — assembles header + functions + runtime + data section
- Header: `.section __TEXT,__text` (Mach-O) vs `.text` (ELF)
- Data: format strings, heap pointer, nil sentinel
- `build_macos` — `as` + `ld -lSystem` (Mach-O ARM64)
- `build_linux` — sed transform + `aarch64-elf-as` + `aarch64-elf-ld` (ELF ARM64)

**Runtime** (`rt_core` + `rt_list` + `rt_closure` + `rt_io` + `rt_args` + `rt_arith` + `rt_fiber` + `rt_gpu`, ~170 lines of inline ASM strings):
- `_rail_eq`, `_rail_ne`, `_rail_add`, `_rail_sub`, `_rail_mul`, `_rail_div`
- `_rail_print`, `_rail_show`, `_rail_str_append`
- `_rail_alloc` (bump allocator from `_rail_heap_ptr`)
- `_rail_list_*` (cons, head, tail, length, map, filter, fold, reverse, range)
- `_rail_closure_*` (create, call)
- `_rail_io_*` (read_file, write_file, shell/popen)
- `_rail_fiber_*` (spawn, await, channel, send, recv)

### Porting to x86_64 — Translation Map

| ARM64 | x86_64 | Notes |
|-------|--------|-------|
| `x0-x7` (args) | `rdi, rsi, rdx, rcx, r8, r9` | System V AMD64 ABI |
| `x0` (return) | `rax` | |
| `x29` (frame pointer) | `rbp` | |
| `sp` (stack pointer) | `rsp` | |
| `x30` (link register) | `[rsp]` (return addr on stack) | x86 uses `call`/`ret` |
| `stp x29, x30, [sp, #-16]!` | `push rbp; mov rbp, rsp` | Prologue |
| `ldp x29, x30, [sp], #16` | `pop rbp; ret` | Epilogue |
| `bl _func` | `call _func` | |
| `ret` | `ret` | |
| `ldr x0, [x1, #offset]` | `mov rax, [rcx+offset]` | |
| `str x0, [x1, #offset]` | `mov [rcx+offset], rax` | |
| `cmp x0, x1` | `cmp rax, rcx` | |
| `b.eq label` | `je label` | |
| `cset x0, eq` | `sete al; movzx rax, al` | |
| `asr x0, x0, #1` | `sar rax, 1` | Tag bit shift |
| `lsl x0, x0, #1` | `shl rax, 1` | |
| `orr x0, x0, #1` | `or rax, 1` | Tag bit set |
| `tst x0, #1` | `test rax, 1` | Tag bit check |
| `adrp x0, sym@PAGE` + `add x0, x0, sym@PAGEOFF` | `lea rax, [rip+sym]` | RIP-relative addressing |
| `svc #0` | `syscall` | Linux syscalls |
| `.section __TEXT,__text` | `.text` | ELF sections |
| `.section __DATA,__data` | `.data` | |
| `.zerofill __DATA,__bss,...` | `.bss` + `.space` | |

### Porting Approach (Sandboxed)

1. **Create `tools/x86_codegen.rail`** — standalone file, not modifying compile.rail
2. **Start with subset**: integer arithmetic, print, function calls, if/else
3. **Emit AT&T syntax x86_64 assembly** (GAS format, same as ARM64 uses GAS)
4. **Use `tools/x86_libc.s`** — syscall-based libc (same pattern as linux_libc.s but x86_64 syscall numbers)
5. **Cross-assemble**: install `x86_64-elf-as` + `x86_64-elf-ld` (or use Razer's native `as`)
6. **Test**: `scp /tmp/rail_x86 Detro@100.109.63.37:~ && ssh Detro@100.109.63.37 "./rail_x86"`
7. **Expand**: strings, lists, closures, ADTs, I/O — one feature at a time
8. **Integrate**: add `build_x86` to compile.rail, dispatch via `./rail_native x86 file.rail`

### Key Differences to Watch

- **No link register** — x86 pushes return address on stack via `call`, ARM64 stores in x30
- **Fewer registers** — x86_64 has 16 GPRs vs ARM64's 31. May need more spills to stack
- **No conditional execution** — ARM64 has `csel`/`cset`, x86 uses `cmov` or explicit branches
- **Stack alignment** — System V ABI requires 16-byte alignment before `call`
- **PIC/PIE** — use `[rip+symbol]` for position-independent code
- **Format strings** — `%ld` → `%ld` (same), but `_printf` → `printf` (no underscore on Linux)
- **Syscall numbers differ** — Linux x86_64: write=1, read=0, exit=60 (vs ARM64: write=64, read=63, exit=93)

**Why:** This playbook makes any future backend a mechanical translation, not a research project.
**How to apply:** When starting x86_64, follow the map line by line. Each ARM64 pattern has an exact x86_64 equivalent.
