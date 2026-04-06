#!/usr/bin/env python3
"""Build expanded Rail corpus by combining old curated tokens + aggressive templates.

Strategy:
  1. Keep all 3.49M tokens from railml_data_curated (already proven)
  2. Append a fresh batch of larger, more varied templated programs
  3. Save as railml_data_v3
"""
import struct, random, hashlib
from pathlib import Path
from tokenizers import Tokenizer

REPO = Path("/Users/ledaticempire/projects/rail")
OLD = REPO / "training" / "railml_data_curated"
OUT = REPO / "training" / "railml_data_v3"
TOK = REPO / "training" / "tokenizer.json"
EOT = 1

random.seed(20260406)
OUT.mkdir(parents=True, exist_ok=True)
tok = Tokenizer.from_file(str(TOK))

# === Load old corpus tokens (uint16 LE) ===
def load_bin(path):
    with open(path, "rb") as f:
        data = f.read()
    return list(struct.unpack(f"<{len(data)//2}H", data))

old_train = load_bin(OLD / "train.bin")
old_val = load_bin(OLD / "val.bin")
print(f"  old curated: {len(old_train):,} train, {len(old_val):,} val tokens")

# === Aggressive template generator ===
# Each template emits a multi-function program (50-300 tokens) that compiles.

VARS = ["a", "b", "c", "x", "y", "z", "n", "m", "k", "i", "j", "p", "q"]
NAMES = ["foo", "bar", "baz", "calc", "go", "run", "do_it", "step", "next", "prev",
         "compute", "transform", "apply", "process", "handle", "f", "g", "h", "k1"]
OPS = ["+", "-", "*"]

def rand_int(lo=-20, hi=50):
    return random.randint(lo, hi)

def rand_var():
    return random.choice(VARS)

def rand_name():
    return random.choice(NAMES) + str(random.randint(0, 99))

def expr(depth=2):
    """Random simple expression."""
    if depth <= 0 or random.random() < 0.3:
        if random.random() < 0.4:
            return str(rand_int())
        return rand_var()
    op = random.choice(OPS)
    return f"({expr(depth-1)} {op} {expr(depth-1)})"

def func_def(name, n_params=2):
    params = random.sample(VARS, n_params)
    body = expr(2)
    return f"{name} {' '.join(params)} = {body}"

def emit_multi_func():
    """Multiple functions + main that calls them."""
    n_funcs = random.randint(2, 5)
    funcs = []
    used_names = []
    for _ in range(n_funcs):
        name = rand_name()
        if name in used_names:
            continue
        used_names.append(name)
        funcs.append(func_def(name))
    main_var = used_names[0] if used_names else "f"
    main = f"main = let _ = print (show ({main_var} {rand_int(1,10)} {rand_int(1,10)}))\n  0"
    return "\n".join(funcs) + "\n" + main + "\n"

def emit_let_program():
    """Long let-chain with arithmetic."""
    n = random.randint(3, 8)
    bindings = []
    used = []
    for i in range(n):
        v = f"x{i}"
        used.append(v)
        if i < 2:
            bindings.append(f"  let {v} = {rand_int(1, 30)}")
        else:
            a = random.choice(used[:i])
            b = random.choice(used[:i])
            op = random.choice(OPS)
            bindings.append(f"  let {v} = {a} {op} {b}")
    body = "\n".join(bindings)
    final = used[-1]
    return f"main =\n{body}\n  let _ = print (show {final})\n  0\n"

def emit_recursive():
    """Random recursive function."""
    funcs = [
        "fact n = if n < 2 then 1 else n * fact (n - 1)",
        "fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)",
        "sum_to n = if n < 1 then 0 else n + sum_to (n - 1)",
        "pow b e = if e < 1 then 1 else b * pow b (e - 1)",
        "gcd a b = if b == 0 then a else gcd b (a - (a / b) * b)",
        "count_down n = if n < 1 then 0 else 1 + count_down (n - 1)",
    ]
    f = random.choice(funcs)
    name = f.split()[0]
    arg = rand_int(2, 12)
    return f"{f}\nmain = let _ = print (show ({name} {arg}))\n  0\n"

def emit_adt_match():
    """Random ADT + match."""
    progs = [
        ("type Op = | Add x y | Sub x y | Mul x y\neval e = match e | Add x y -> x + y | Sub x y -> x - y | Mul x y -> x * y",
         lambda: f"main = let _ = print (show (eval (Add {rand_int(1,30)} {rand_int(1,30)})))\n  0"),
        ("type Tree = | Leaf | Node v l r\nsize t = match t | Leaf -> 0 | Node v l r -> 1 + size l + size r",
         lambda: "main = let t = Node 1 (Node 2 Leaf Leaf) (Node 3 Leaf Leaf)\n  let _ = print (show (size t))\n  0"),
        ("type Color = | Red | Green | Blue\nname c = match c | Red -> \"red\" | Green -> \"green\" | Blue -> \"blue\"",
         lambda: "main = let _ = print (name Green)\n  0"),
        ("type Maybe = | Just x | Nothing\nfrom_maybe d m = match m | Just x -> x | Nothing -> d",
         lambda: f"main = let _ = print (show (from_maybe {rand_int(0,99)} (Just {rand_int(1,99)})))\n  0"),
    ]
    body, mk_main = random.choice(progs)
    return body + "\n" + mk_main() + "\n"

def emit_list_pipeline():
    n = random.randint(3, 7)
    nums = [rand_int(1, 20) for _ in range(n)]
    lst = "[" + ", ".join(str(x) for x in nums) + "]"
    pipelines = [
        f"main = let xs = {lst}\n  let _ = print (show (length xs))\n  0",
        f"main = let xs = {lst}\n  let _ = print (show (head xs))\n  0",
        f"main = let xs = {lst}\n  let _ = print (show (length (tail xs)))\n  0",
        f"add a b = a + b\nmain = let xs = {lst}\n  let _ = print (show (fold add 0 xs))\n  0",
        f"mul a b = a * b\nmain = let xs = {lst}\n  let _ = print (show (fold mul 1 xs))\n  0",
        f"main = let xs = {lst}\n  let ys = reverse xs\n  let _ = print (show (head ys))\n  0",
    ]
    return random.choice(pipelines) + "\n"

def emit_if_chain():
    n = random.randint(2, 5)
    var = "n"
    val = rand_int(0, 30)
    branches = []
    for i in range(n):
        thresh = rand_int(0, 30)
        out = rand_int(0, 100)
        branches.append((thresh, out))
    branches.sort()
    body = "0"
    for thresh, out in reversed(branches):
        body = f"if {var} < {thresh} then {out} else {body}"
    return f"main =\n  let {var} = {val}\n  let _ = print (show ({body}))\n  0\n"

def emit_string_program():
    strings = ["hello", "rail", "main", "code", "test", "fast", "build", "run"]
    s1 = random.choice(strings)
    s2 = random.choice(strings)
    progs = [
        f'main = let s = "{s1}"\n  let _ = print s\n  0',
        f'main = let s = "{s1} {s2}"\n  let _ = print (show (length s))\n  0',
        f'main = let _ = print (cat ["{s1}", " ", "{s2}"])\n  0',
        f'main = let parts = split " " "{s1} {s2}"\n  let _ = print (show (length parts))\n  0',
    ]
    return random.choice(progs) + "\n"

def emit_combined():
    """Combine 2-3 of the above into one bigger program."""
    parts = []
    funcs_used = set()
    for _ in range(random.randint(2, 4)):
        kind = random.choice(["recursive", "func", "func"])
        if kind == "recursive":
            parts.append(emit_recursive().rstrip())
        else:
            name = rand_name()
            if name in funcs_used:
                continue
            funcs_used.add(name)
            parts.append(func_def(name))
    main = f"main = let _ = print (show {rand_int(1, 100)})\n  0"
    return "\n".join(parts) + "\n" + main + "\n"

# Generate
generators = [
    emit_multi_func, emit_let_program, emit_recursive, emit_adt_match,
    emit_list_pipeline, emit_if_chain, emit_string_program, emit_combined,
]

new_progs = []
seen_hashes = set()
target = 8000
attempts = 0
while len(new_progs) < target and attempts < target * 5:
    attempts += 1
    g = random.choice(generators)
    src = g()
    h = hashlib.sha256(src.encode()).hexdigest()
    if h in seen_hashes:
        continue
    seen_hashes.add(h)
    new_progs.append(src)

print(f"  generated {len(new_progs):,} unique template programs ({attempts} attempts)")

# Tokenize new programs
new_tokens = []
for p in new_progs:
    new_tokens.extend(tok.encode(p).ids)
    new_tokens.append(EOT)
print(f"  new template tokens: {len(new_tokens):,}")

# Combine: old + new
combined_train = old_train + new_tokens
combined_val = old_val
print(f"  combined train: {len(combined_train):,} tokens ({len(combined_train)*2/1e6:.1f}MB)")
print(f"  combined val:   {len(combined_val):,} tokens")
print(f"  expansion: {len(combined_train) / len(old_train):.2f}x")

with open(OUT / "train.bin", "wb") as f:
    f.write(struct.pack(f"<{len(combined_train)}H", *combined_train))
with open(OUT / "val.bin", "wb") as f:
    f.write(struct.pack(f"<{len(combined_val)}H", *combined_val))

print(f"\n  saved → {OUT}")
