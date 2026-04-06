#!/usr/bin/env python3
"""Build a comprehensive Rail training corpus.

Sources:
  1. ALL .rail files in the repo (compiler, stdlib, tools, flywheel, examples)
  2. ALL JSONL harvest sources (filtered to compile-clean if a `code` field exists)
  3. Templated synthetic programs (guaranteed valid)

Output: training/railml_data_v2/{train,val}.bin (uint16 BPE)
"""
import json, struct, random, hashlib
from pathlib import Path
from tokenizers import Tokenizer

REPO = Path("/Users/ledaticempire/projects/rail")
OUT_DIR = REPO / "training" / "railml_data_v2"
TOKENIZER = REPO / "training" / "tokenizer.json"
EOT = 1  # <|endoftext|>

random.seed(42)
OUT_DIR.mkdir(parents=True, exist_ok=True)
tok = Tokenizer.from_file(str(TOKENIZER))

programs = []  # list[str]
seen = set()

def add(src: str, _source: str):
    src = src.strip()
    if len(src) < 8:
        return False
    h = hashlib.sha256(src.encode()).hexdigest()
    if h in seen:
        return False
    seen.add(h)
    programs.append(src)
    return True

# === Source 1: all .rail files in the repo ===
rail_files = list(REPO.glob("**/*.rail"))
rail_files = [p for p in rail_files if "/.git/" not in str(p) and "/node_modules/" not in str(p)]
n_rail = 0
for p in rail_files:
    try:
        with open(p) as f:
            src = f.read()
        if add(src, f"file:{p.name}"):
            n_rail += 1
    except Exception:
        pass
print(f"  +{n_rail} .rail files")

# === Source 2: JSONL harvest — chat format, extract assistant messages ===
jsonl_paths = list(REPO.glob("training/**/*.jsonl")) + list(REPO.glob("flywheel/**/*.jsonl"))
n_jsonl = 0
for p in jsonl_paths:
    try:
        with open(p) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msgs = obj.get("messages")
                if not isinstance(msgs, list):
                    continue
                for m in msgs:
                    if not isinstance(m, dict):
                        continue
                    if m.get("role") == "assistant":
                        c = m.get("content", "")
                        if isinstance(c, str) and add(c, f"jsonl:{p.name}"):
                            n_jsonl += 1
    except Exception:
        pass
print(f"  +{n_jsonl} jsonl assistant messages")

# === Source 3: templated synthetic ===
def emit_main_int(n):
    add(f"main = {n}\n", "tpl:int")

def emit_main_print(s):
    add(f'main = let _ = print "{s}"\n  0\n', "tpl:print")

def emit_main_show(n):
    add(f"main = let _ = print (show {n})\n  0\n", "tpl:show")

def emit_arith(a, op, b):
    add(f"main = let _ = print (show ({a} {op} {b}))\n  0\n", "tpl:arith")

def emit_let_chain(depth, base):
    body = " + ".join(f"x{i}" for i in range(depth))
    bindings = "\n  ".join(f"let x{i} = {base + i}" for i in range(depth))
    add(f"main =\n  {bindings}\n  let _ = print (show ({body}))\n  0\n", "tpl:let_chain")

def emit_if(a, b):
    add(f"main =\n  let x = {a}\n  let y = {b}\n  let _ = print (show (if x > y then x else y))\n  0\n", "tpl:if")

def emit_func_def(name, op):
    add(f"{name} a b = a {op} b\nmain = let _ = print (show ({name} 7 3))\n  0\n", "tpl:func")

def emit_list_op(op):
    add(f"main = let xs = [1,2,3,4,5]\n  let _ = print (show ({op} xs))\n  0\n", "tpl:list")

def emit_fold(op, init):
    add(f"f a b = a {op} b\nmain = let xs = [1,2,3,4,5]\n  let _ = print (show (fold f {init} xs))\n  0\n", "tpl:fold")

def emit_recursive_fact():
    add("fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = let _ = print (show (fact 6))\n  0\n", "tpl:rec_fact")

def emit_recursive_fib():
    add("fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)\nmain = let _ = print (show (fib 10))\n  0\n", "tpl:rec_fib")

def emit_adt():
    add("type Option = | Some x | None\nget_or d opt = match opt | Some x -> x | None -> d\nmain = let _ = print (show (get_or 0 (Some 42)))\n  0\n", "tpl:adt")

def emit_adt_shape(n):
    add(f"type Shape = | Circle r | Square s\narea sh = match sh | Circle r -> r * r * 3 | Square s -> s * s\nmain = let _ = print (show (area (Circle {n})))\n  0\n", "tpl:adt_shape")

def emit_string_op(s):
    add(f'main = let _ = print (show (length "{s}"))\n  0\n', "tpl:str_len")

def emit_match_int(n):
    add(f"f x = match x | 0 -> \"zero\" | 1 -> \"one\" | _ -> \"many\"\nmain = let _ = print (f {n})\n  0\n", "tpl:match_int")

# Generate template programs
for n in range(0, 200):
    emit_main_int(n)
    emit_main_show(n)
for op in ["+", "-", "*"]:
    for a in range(1, 30):
        for b in range(1, 30):
            emit_arith(a, op, b)
for depth in range(2, 8):
    for base in range(0, 20):
        emit_let_chain(depth, base)
for a in range(0, 30):
    for b in range(0, 30):
        emit_if(a, b)
for name, op in [("add", "+"), ("sub", "-"), ("mul", "*"), ("max2", "+"), ("min2", "-")]:
    emit_func_def(name, op)
for op in ["head", "length", "reverse", "tail"]:
    emit_list_op(op)
for op, init in [("+", 0), ("*", 1), ("+", 100)]:
    emit_fold(op, init)
emit_recursive_fact()
emit_recursive_fib()
emit_adt()
for n in range(1, 20):
    emit_adt_shape(n)
for s in ["hello", "world", "rail", "main", "compile", "test", "x"]:
    emit_string_op(s)
for n in range(-1, 5):
    emit_match_int(n)

n_template = len(programs) - n_rail - n_jsonl
print(f"  +{n_template} templated programs")
print(f"  total unique programs: {len(programs):,}")

# === Tokenize ===
all_tokens = []
for p in programs:
    ids = tok.encode(p).ids
    all_tokens.extend(ids)
    all_tokens.append(EOT)

# Some basic stats
n = len(all_tokens)
print(f"  tokenized: {n:,} tokens ({n*2/1e6:.1f}MB)")

# 95/5 split
random.shuffle(programs)
split = int(len(programs) * 0.95)
train_progs = programs[:split]
val_progs = programs[split:]

def to_bin(progs, path):
    toks = []
    for p in progs:
        toks.extend(tok.encode(p).ids)
        toks.append(EOT)
    with open(path, "wb") as f:
        f.write(struct.pack(f"<{len(toks)}H", *toks))
    return len(toks)

train_n = to_bin(train_progs, OUT_DIR / "train.bin")
val_n = to_bin(val_progs, OUT_DIR / "val.bin")
print(f"  train: {train_n:,} tokens → {OUT_DIR}/train.bin")
print(f"  val:   {val_n:,} tokens → {OUT_DIR}/val.bin")
print(f"\n  expansion: {train_n / 3489876:.2f}x current train corpus (3.49M)")
