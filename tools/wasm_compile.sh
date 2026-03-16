#!/bin/bash
# wasm_compile.sh — Compile a simple Rail program to WASM
# Usage: tools/wasm_compile.sh <file.rail>
# Supports: main = <int>, arithmetic, if/else, let, functions, print
set -e

INPUT="$1"
if [ -z "$INPUT" ]; then
  echo "Usage: tools/wasm_compile.sh <file.rail>"
  exit 1
fi

# Use Python to parse Rail and emit WAT (much faster than bootstrapping)
/opt/homebrew/bin/python3.11 - "$INPUT" << 'PYTHON'
import sys, re

src = open(sys.argv[1]).read()

# Minimal Rail tokenizer
tokens = []
i = 0
while i < len(src):
    c = src[i]
    if c in ' \t':
        i += 1
    elif c == '\n':
        tokens.append(('nl', '\n')); i += 1
    elif c == '-' and i+1 < len(src) and src[i+1] == '-':
        while i < len(src) and src[i] != '\n': i += 1
    elif c == '-' and i+1 < len(src) and src[i+1] == '>':
        tokens.append(('ar', '->')); i += 2
    elif c == '-':
        tokens.append(('op', '-')); i += 1
    elif c == '=' and i+1 < len(src) and src[i+1] == '=':
        tokens.append(('op', '==')); i += 2
    elif c == '!':
        if i+1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '!=')); i += 2
        else: i += 1
    elif c == '<':
        if i+1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '<=')); i += 2
        else: tokens.append(('op', '<')); i += 1
    elif c == '>':
        if i+1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '>=')); i += 2
        else: tokens.append(('op', '>')); i += 1
    elif c == '=':
        tokens.append(('eq', '=')); i += 1
    elif c in '+-*/%':
        tokens.append(('op', c)); i += 1
    elif c == '(':
        tokens.append(('lp', '(')); i += 1
    elif c == ')':
        tokens.append(('rp', ')')); i += 1
    elif c == '"':
        i += 1; s = ''
        while i < len(src) and src[i] != '"':
            if src[i] == '\\' and i+1 < len(src):
                n = src[i+1]
                s += {'n':'\n','t':'\t','\\':'\\','"':'"'}.get(n, n)
                i += 2
            else:
                s += src[i]; i += 1
        i += 1  # skip closing "
        tokens.append(('str', s))
    elif c.isdigit():
        j = i
        while j < len(src) and src[j].isdigit(): j += 1
        tokens.append(('int', src[i:j])); i = j
    elif c.isalpha() or c == '_':
        j = i
        while j < len(src) and (src[j].isalnum() or src[j] == '_'): j += 1
        w = src[i:j]
        kw = {'let','if','then','else','foreign'}
        tokens.append(('kw' if w in kw else 'id', w)); i = j
    else:
        i += 1
tokens.append(('eof', ''))

# Parser
pos = 0
def peek(): return tokens[pos] if pos < len(tokens) else ('eof','')
def advance():
    global pos; t = tokens[pos]; pos += 1; return t
def skip_nl():
    while peek()[0] == 'nl': advance()
def expect(typ):
    t = advance()
    assert t[0] == typ, f"expected {typ}, got {t}"
    return t[1]

def parse_expr():
    skip_nl()
    t = peek()
    if t == ('kw', 'let'):
        advance()
        name = expect('id')
        expect('eq')
        val = parse_expr()
        body = parse_expr()
        return ('let', name, val, body)
    elif t == ('kw', 'if'):
        advance()
        cond = parse_expr()
        skip_nl()
        if peek() == ('kw', 'then'): advance()
        then_e = parse_expr()
        skip_nl()
        if peek() == ('kw', 'else'): advance()
        else_e = parse_expr()
        return ('if', cond, then_e, else_e)
    else:
        return parse_cmp()

def parse_cmp():
    lhs = parse_add()
    if peek()[0] == 'op' and peek()[1] in ('==','!=','<','>','<=','>='):
        op = advance()[1]
        rhs = parse_add()
        return ('op', op, lhs, rhs)
    return lhs

def parse_add():
    lhs = parse_mul()
    while peek()[0] == 'op' and peek()[1] in ('+', '-'):
        op = advance()[1]
        rhs = parse_mul()
        lhs = ('op', op, lhs, rhs)
    return lhs

def parse_mul():
    lhs = parse_app()
    while peek()[0] == 'op' and peek()[1] in ('*', '/', '%'):
        op = advance()[1]
        rhs = parse_app()
        lhs = ('op', op, lhs, rhs)
    return lhs

def parse_app():
    f = parse_atom()
    if f[0] == 'var':
        while peek()[0] in ('int', 'id', 'lp', 'str'):
            arg = parse_atom()
            f = ('app', f, arg)
    return f

def parse_atom():
    skip_nl()
    t = peek()
    if t[0] == 'int': advance(); return ('int', int(t[1]))
    if t[0] == 'str': advance(); return ('str', t[1])
    if t[0] == 'id':
        advance()
        if t[1] == 'true': return ('bool', True)
        if t[1] == 'false': return ('bool', False)
        return ('var', t[1])
    if t[0] == 'lp':
        advance()
        e = parse_expr()
        if peek()[0] == 'rp': advance()
        return e
    advance()
    return ('int', 0)

def parse_decl():
    skip_nl()
    name = expect('id')
    params = []
    while peek()[0] == 'id':
        params.append(advance()[1])
    expect('eq')
    body = parse_expr()
    return (name, params, body)

decls = []
while peek()[0] != 'eof':
    skip_nl()
    if peek()[0] == 'eof': break
    decls.append(parse_decl())

# WASM codegen
def flatten_app(node):
    if node[0] == 'app':
        name, args = flatten_app(node[1])
        return name, args + [node[2]]
    if node[0] == 'var':
        return node[1], []
    return '_expr', []

def collect_locals(node):
    if node[0] == 'let':
        return [node[1]] + collect_locals(node[2]) + collect_locals(node[3])
    if node[0] == 'if':
        return collect_locals(node[1]) + collect_locals(node[2]) + collect_locals(node[3])
    if node[0] == 'op':
        return collect_locals(node[2]) + collect_locals(node[3])
    if node[0] == 'app':
        _, args = flatten_app(node)
        locs = []
        for a in args: locs += collect_locals(a)
        return locs
    return []

def codegen(node, env):
    t = node[0]
    if t == 'int':
        return f"    i64.const {node[1]*2+1}\n"
    if t == 'bool':
        return f"    i64.const {3 if node[1] else 1}\n"
    if t == 'str':
        return "    i64.const 1\n"  # strings not yet supported
    if t == 'var':
        if node[1] in env:
            return f"    local.get ${node[1]}\n"
        return "    i64.const 1\n"
    if t == 'op':
        op_map = {
            '+': 'i64.add', '-': 'i64.sub', '*': 'i64.mul',
            '/': 'i64.div_s', '%': 'i64.rem_s',
            '==': 'i64.eq\n    i64.extend_i32_u',
            '!=': 'i64.ne\n    i64.extend_i32_u',
            '<': 'i64.lt_s\n    i64.extend_i32_u',
            '>': 'i64.gt_s\n    i64.extend_i32_u',
            '<=': 'i64.le_s\n    i64.extend_i32_u',
            '>=': 'i64.ge_s\n    i64.extend_i32_u',
        }
        u = "    i64.const 1\n    i64.shr_s\n"
        r = "    i64.const 1\n    i64.shl\n    i64.const 1\n    i64.or\n"
        return codegen(node[2], env) + u + codegen(node[3], env) + u + f"    {op_map[node[1]]}\n" + r
    if t == 'if':
        return (codegen(node[1], env) +
                "    i64.const 1\n    i64.shr_s\n    i32.wrap_i64\n    if (result i64)\n" +
                codegen(node[2], env) +
                "    else\n" +
                codegen(node[3], env) +
                "    end\n")
    if t == 'let':
        env2 = dict(env)
        env2[node[1]] = True
        return codegen(node[2], env) + f"    local.set ${node[1]}\n" + codegen(node[3], env2)
    if t == 'app':
        fname, args = flatten_app(node)
        if fname == 'print':
            return codegen(args[0], env) + "    call $__rail_print\n    i64.const 1\n"
        if fname == 'show':
            return codegen(args[0], env) if args else "    i64.const 1\n"
        code = ''
        for a in args: code += codegen(a, env)
        return code + f"    call ${fname}\n"
    return "    i64.const 1\n"

# Emit WAT
rt = open('tools/wasm_runtime.wat').read()
out = "(module\n"
out += '  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))\n'
out += '  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))\n'
out += "  (memory (export \"memory\") 1 256)\n\n"
out += rt + "\n"

for name, params, body in decls:
    p = ' '.join(f'(param ${p} i64)' for p in params)
    env = {p: True for p in params}
    locs = list(dict.fromkeys(collect_locals(body)))
    locs = [l for l in locs if l not in params]
    ld = ''.join(f'    (local ${l} i64)\n' for l in locs)
    code = codegen(body, env)
    out += f"  (func ${name} {p} (result i64)\n{ld}{code}  )\n\n"

out += "  (func $_start (export \"_start\")\n"
out += "    call $main\n"
out += "    i64.const 1\n    i64.shr_s\n    i32.wrap_i64\n"
out += "    call $proc_exit\n"
out += "  )\n)\n"

with open('/tmp/rail_out.wat', 'w') as f:
    f.write(out)
print("  wat: OK")
PYTHON

echo "  Assembling..."
wat2wasm /tmp/rail_out.wat -o /tmp/rail_out.wasm 2>&1
echo "  wat2wasm: OK"
echo "  Binary: /tmp/rail_out.wasm"
echo -n "  Output: "
wasmtime /tmp/rail_out.wasm 2>&1
