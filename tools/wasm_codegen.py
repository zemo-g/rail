#!/usr/bin/env python3
"""
Rail WASM codegen — full pipeline from Rail source to WAT output.
Usage: python3 tools/wasm_codegen.py <file.rail> > /tmp/rail_out.wat

Handles: ints, strings, arithmetic, if/else, let bindings, functions, print, show, append
"""
import sys, os

# ═══════════════════════════════════════════════════════════════════════
# LEXER
# ═══════════════════════════════════════════════════════════════════════

KEYWORDS = {'let', 'if', 'then', 'else', 'foreign'}

def tokenize(src):
    """Tokenize Rail source. Newlines followed by column-0 content emit 'nl' tokens
    to separate top-level declarations. Continuation lines (indented) don't emit 'nl'."""
    tokens = []
    i = 0
    while i < len(src):
        c = src[i]
        # Newline — check if next line starts at column 0
        if c == '\n':
            i += 1
            # Peek at what follows
            if i < len(src) and src[i] not in ' \t\r\n':
                tokens.append(('nl', '\n'))
            # else: continuation line or blank line — skip
        # Whitespace
        elif c in ' \t\r':
            i += 1
        # Comment
        elif c == '-' and i + 1 < len(src) and src[i+1] == '-':
            while i < len(src) and src[i] != '\n':
                i += 1
        # Arrow
        elif c == '-' and i + 1 < len(src) and src[i+1] == '>':
            tokens.append(('ar', '->'))
            i += 2
        # String
        elif c == '"':
            i += 1
            s = []
            while i < len(src) and src[i] != '"':
                if src[i] == '\\' and i + 1 < len(src):
                    nc = src[i+1]
                    if nc == 'n': s.append('\n')
                    elif nc == 't': s.append('\t')
                    elif nc == '\\': s.append('\\')
                    elif nc == '"': s.append('"')
                    else: s.append(nc)
                    i += 2
                else:
                    s.append(src[i])
                    i += 1
            if i < len(src): i += 1  # skip closing "
            tokens.append(('str', ''.join(s)))
        # Number
        elif c.isdigit():
            j = i
            while j < len(src) and src[j].isdigit():
                j += 1
            tokens.append(('int', src[i:j]))
            i = j
        # Identifier / keyword
        elif c.isalpha() or c == '_':
            j = i
            while j < len(src) and (src[j].isalnum() or src[j] == '_'):
                j += 1
            word = src[i:j]
            if word in KEYWORDS:
                tokens.append(('kw', word))
            else:
                tokens.append(('id', word))
            i = j
        # Two-char operators
        elif c == '=' and i + 1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '==')); i += 2
        elif c == '!' and i + 1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '!=')); i += 2
        elif c == '<' and i + 1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '<=')); i += 2
        elif c == '>' and i + 1 < len(src) and src[i+1] == '=':
            tokens.append(('op', '>=')); i += 2
        # Single-char tokens
        elif c == '=': tokens.append(('eq', '=')); i += 1
        elif c == '+': tokens.append(('op', '+')); i += 1
        elif c == '-': tokens.append(('op', '-')); i += 1
        elif c == '*': tokens.append(('op', '*')); i += 1
        elif c == '/': tokens.append(('op', '/')); i += 1
        elif c == '%': tokens.append(('op', '%')); i += 1
        elif c == '<': tokens.append(('op', '<')); i += 1
        elif c == '>': tokens.append(('op', '>')); i += 1
        elif c == '(': tokens.append(('lp', '(')); i += 1
        elif c == ')': tokens.append(('rp', ')')); i += 1
        else:
            i += 1
    tokens.append(('eof', ''))
    return tokens

# ═══════════════════════════════════════════════════════════════════════
# PARSER
# ═══════════════════════════════════════════════════════════════════════

class RailParser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def ct(self):
        return self.tokens[self.pos][0] if self.pos < len(self.tokens) else 'eof'

    def cv(self):
        return self.tokens[self.pos][1] if self.pos < len(self.tokens) else ''

    def advance(self):
        self.pos += 1

    def skip_nl(self):
        while self.ct() == 'nl':
            self.advance()

    def parse_expr(self):
        self.skip_nl()
        if self.ct() == 'kw' and self.cv() == 'let':
            self.advance()
            # let name = val body  OR  let _ = val body
            name = self.cv()
            self.advance()
            if self.ct() == 'eq':
                self.advance()
            val = self.parse_expr()
            body = self.parse_expr()
            return ('D', name, val, body)
        elif self.ct() == 'kw' and self.cv() == 'if':
            self.advance()
            cond = self.parse_expr()
            if self.ct() == 'kw' and self.cv() == 'then':
                self.advance()
            then_e = self.parse_expr()
            if self.ct() == 'kw' and self.cv() == 'else':
                self.advance()
            else_e = self.parse_expr()
            return ('?', cond, then_e, else_e)
        else:
            return self.parse_cmp()

    def parse_cmp(self):
        lhs = self.parse_add()
        if self.ct() == 'op' and self.cv() in ('==', '!=', '<', '>', '<=', '>='):
            op = self.cv()
            self.advance()
            rhs = self.parse_add()
            return ('O', op, lhs, rhs)
        return lhs

    def parse_add(self):
        lhs = self.parse_mul()
        while self.ct() == 'op' and self.cv() in ('+', '-'):
            op = self.cv()
            self.advance()
            rhs = self.parse_mul()
            lhs = ('O', op, lhs, rhs)
        return lhs

    def parse_mul(self):
        lhs = self.parse_app()
        while self.ct() == 'op' and self.cv() in ('*', '/', '%'):
            op = self.cv()
            self.advance()
            rhs = self.parse_app()
            lhs = ('O', op, lhs, rhs)
        return lhs

    def parse_app(self):
        f = self.parse_atom()
        if f[0] == 'V':
            while self.ct() in ('int', 'id', 'lp', 'str'):
                arg = self.parse_atom()
                f = ('A', f, arg)
        return f

    def parse_atom(self):
        self.skip_nl()
        if self.ct() == 'int':
            v = self.cv()
            self.advance()
            return ('I', int(v))
        elif self.ct() == 'str':
            s = self.cv()
            self.advance()
            return ('S', s)
        elif self.ct() == 'id':
            name = self.cv()
            self.advance()
            if name == 'true':
                return ('B', True)
            elif name == 'false':
                return ('B', False)
            return ('V', name)
        elif self.ct() == 'lp':
            self.advance()
            e = self.parse_expr()
            if self.ct() == 'rp':
                self.advance()
            return e
        else:
            return ('I', 0)

    def parse_decl(self):
        self.skip_nl()
        if self.ct() != 'id':
            return None
        name = self.cv()
        self.advance()
        params = []
        # Collect parameters until we hit '='
        while self.ct() == 'id':
            pname = self.cv()
            # Peek ahead: if next is '=' after this id, this id is the last param
            self.advance()
            if self.ct() == 'eq':
                params.append(pname)
                self.advance()
                break
            params.append(pname)
        else:
            # No more ids — check for '='
            if self.ct() == 'eq':
                self.advance()
        body = self.parse_expr()
        return (name, params, body)

    def parse_program(self):
        """Parse top-level declarations.
        A top-level declaration starts at column 0 (after newlines) with an identifier
        followed by optional params and '='.
        """
        decls = []
        while True:
            self.skip_nl()
            if self.ct() == 'eof':
                break
            d = self.parse_decl()
            if d:
                decls.append(d)
            else:
                self.advance()
        return decls

# ═══════════════════════════════════════════════════════════════════════
# CODEGEN
# ═══════════════════════════════════════════════════════════════════════

def flatten_app(node):
    if node[0] == 'A':
        fname, args = flatten_app(node[1])
        return fname, args + [node[2]]
    elif node[0] == 'V':
        return node[1], []
    return '_expr', []

def collect_strings(node):
    tag = node[0]
    if tag == 'S': return [node[1]]
    if tag in ('I', 'B', 'V'): return []
    if tag == 'O': return collect_strings(node[2]) + collect_strings(node[3])
    if tag == '?': return collect_strings(node[1]) + collect_strings(node[2]) + collect_strings(node[3])
    if tag == 'D': return collect_strings(node[2]) + collect_strings(node[3])
    if tag == 'A': return collect_strings(node[1]) + collect_strings(node[2])
    return []

def collect_locals(node):
    tag = node[0]
    if tag == 'D': return [node[1]] + collect_locals(node[2]) + collect_locals(node[3])
    if tag == '?': return collect_locals(node[1]) + collect_locals(node[2]) + collect_locals(node[3])
    if tag == 'O': return collect_locals(node[2]) + collect_locals(node[3])
    if tag == 'A':
        _, args = flatten_app(node)
        r = []
        for a in args: r += collect_locals(a)
        return r
    return []

OP_MAP = {
    '+': '    i64.add\n', '-': '    i64.sub\n',
    '*': '    i64.mul\n', '/': '    i64.div_s\n', '%': '    i64.rem_s\n',
    '==': '    i64.eq\n    i64.extend_i32_u\n',
    '!=': '    i64.ne\n    i64.extend_i32_u\n',
    '<': '    i64.lt_s\n    i64.extend_i32_u\n',
    '>': '    i64.gt_s\n    i64.extend_i32_u\n',
    '<=': '    i64.le_s\n    i64.extend_i32_u\n',
    '>=': '    i64.ge_s\n    i64.extend_i32_u\n',
}

def codegen(node, env, stbl):
    tag = node[0]
    if tag == 'I':
        return f'    i64.const {node[1] * 2 + 1}\n'
    elif tag == 'S':
        s = node[1]
        if s in stbl:
            off, slen = stbl[s]
            return f'    i32.const {off}\n    i32.const {slen}\n    call $__rail_mkstr\n'
        return '    i64.const 0\n'
    elif tag == 'B':
        return '    i64.const 3\n' if node[1] else '    i64.const 1\n'
    elif tag == 'V':
        return f'    local.get ${node[1]}\n' if node[1] in env else '    i64.const 1\n'
    elif tag == 'O':
        op, lhs, rhs = node[1], node[2], node[3]
        u = '    i64.const 1\n    i64.shr_s\n'
        r = '    i64.const 1\n    i64.shl\n    i64.const 1\n    i64.or\n'
        return codegen(lhs, env, stbl) + u + codegen(rhs, env, stbl) + u + OP_MAP.get(op, '    i64.add\n') + r
    elif tag == '?':
        return (codegen(node[1], env, stbl) +
                '    i64.const 1\n    i64.shr_s\n    i32.wrap_i64\n    if (result i64)\n' +
                codegen(node[2], env, stbl) + '    else\n' +
                codegen(node[3], env, stbl) + '    end\n')
    elif tag == 'D':
        name = node[1]
        new_env = dict(env)
        new_env[name] = True
        return codegen(node[2], env, stbl) + f'    local.set ${name}\n' + codegen(node[3], new_env, stbl)
    elif tag == 'A':
        fname, fargs = flatten_app(node)
        if fname == 'print' and fargs:
            return codegen(fargs[0], env, stbl) + '    call $__rail_print\n'
        elif fname == 'show' and fargs:
            return codegen(fargs[0], env, stbl) + '    call $__rail_show\n'
        elif fname == 'append' and len(fargs) >= 2:
            return codegen(fargs[0], env, stbl) + codegen(fargs[1], env, stbl) + '    call $__rail_append\n'
        else:
            r = ''
            for a in fargs: r += codegen(a, env, stbl)
            return r + f'    call ${fname}\n'
    return '    i64.const 1\n'

def escape_wat(s):
    r = []
    for c in s:
        if c == '\n': r.append('\\0a')
        elif c == '\t': r.append('\\09')
        elif c == '\\': r.append('\\\\')
        elif c == '"': r.append('\\22')
        elif ord(c) < 32 or ord(c) > 126: r.append(f'\\{ord(c):02x}')
        else: r.append(c)
    return ''.join(r)

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 tools/wasm_codegen.py <file.rail>", file=sys.stderr)
        sys.exit(1)

    source_path = sys.argv[1]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    runtime_path = os.path.join(script_dir, 'wasm_runtime.wat')

    # Read source
    try:
        with open(source_path) as f:
            src = f.read()
    except (FileNotFoundError, IOError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Lex + Parse
    tokens = tokenize(src)
    parser = RailParser(tokens)
    decls = parser.parse_program()

    # Collect strings
    all_strings = []
    for name, params, body in decls:
        for s in collect_strings(body):
            if s not in all_strings:
                all_strings.append(s)

    # Build string table
    stbl = {}
    off = 256
    for s in all_strings:
        slen = len(s.encode('utf-8'))
        stbl[s] = (off, slen)
        off += slen

    # Data segments
    data_segs = ''
    for s in all_strings:
        soff, slen = stbl[s]
        data_segs += f'  (data (i32.const {soff}) "{escape_wat(s)}")\n'

    # Read runtime
    with open(runtime_path) as f:
        runtime = f.read()

    # Generate functions
    funcs = ''
    for name, params, body in decls:
        ps = ' '.join(f'(param ${p} i64)' for p in params)
        if ps: ps = ' ' + ps
        env = {p: True for p in params}
        locs = list(dict.fromkeys(collect_locals(body)))
        real_locs = [l for l in locs if l not in env]
        ls = ''.join(f'    (local ${l} i64)\n' for l in real_locs)
        bc = codegen(body, env, stbl)
        funcs += f'  (func ${name}{ps} (result i64)\n{ls}{bc}  )\n\n'

    # Assemble WAT
    header = ('(module\n'
              '  (import "wasi_snapshot_preview1" "fd_write" '
              '(func $fd_write (param i32 i32 i32 i32) (result i32)))\n'
              '  (import "wasi_snapshot_preview1" "proc_exit" '
              '(func $proc_exit (param i32)))\n'
              '  (memory (export "memory") 2 256)\n\n')

    start = ('  (func $_start (export "_start")\n'
             '    call $main\n'
             '    i64.const 1\n'
             '    i64.shr_s\n'
             '    i32.wrap_i64\n'
             '    call $proc_exit\n'
             '  )\n')

    sys.stdout.write(header + runtime + '\n' + data_segs + '\n' + funcs + start + ')\n')

if __name__ == '__main__':
    main()
