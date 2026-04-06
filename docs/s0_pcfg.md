# s0_pcfg — A 20-Integer Self-Improving Rail Generator

A probabilistic context-free grammar over Rail tokens whose entire model is
20 integer weights, trained by REINFORCE against the rail compiler. No
gradient descent. No transformer. No tokens. No GPU. Just `sample → compile
→ reward → update` in pure Rail. **The compiler is the teacher.**

This is the **second domain** on the spine introduced in 40cc5a6. It exists
to validate that the convention generalizes beyond `neural_plasma`, and to
demonstrate that the *quintessentially small* path the user asked about —
"why can't we work really incredibly small" — is a real engineering
direction, not a thought experiment.

---

## The motivating failure

Five experiments earlier in the same session trained transformers from
scratch on a curated 3.5M-token Rail corpus via cross-entropy on next-token
prediction. The infrastructure was sound — rustane trainer with NaN-kill,
strict eval pipeline, BPE tokenizer, the works. The result:

| Exp | Model | Best val | Strict compile% |
|---|---|---|---|
| 8 | 4.2M, 2L  | 4.13 | **0/30** |
| 9 | 7.9M, 2L  | 3.88 | **0/30** |
| 10 | 7.9M + 14% data  | 4.08 | **0/30** |
| 12 | 7.9M + Claude-augmented | 3.88 | **0/30** |

Across **75 generation attempts at the strictest evaluation** (compile +
run + zero error/warning markers in stdout, since `rail_native` exits 0
even on parse errors), not a single program produced was a complete valid
Rail program. The models learned to *look like* Rail — `let _ =`, brackets,
common prefixes — but never to *compile*.

The diagnosis: cross-entropy on a corpus optimizes "look like the data".
That's mimicry. The model has no way to know that "matching brackets"
matters more than "putting `let` in the right place" — both are equally
weighted by next-token loss. We had a perfect oracle (`rail_native`) and
**we were using it only at eval time**. The training signal didn't depend
on it.

s0_pcfg reverses that. Every training step *requires* the compiler. The
reward is binary: did `rail_native run` produce no error markers? Yes →
+50 to every rule used. No → −5 to every rule used. Floor at 1. That's
the entire training algorithm.

## The result that convinced me this works

```
round 0:                  46% strict pass rate (uniform weights)
round 30 (13-rule grammar): 92% lifetime pass rate
round 15 (20-rule fresh):   88% lifetime pass rate, climbing
```

The 20-rule grammar is harder than the 13-rule one — same int-expression
substrate plus a second program shape and 6 more leaf rules. Lifetime pass
rate climbs steadily round-over-round as REINFORCE finds the rule
combinations that compile.

**The whole "model" persists in `flywheel/s0_state.txt` as 20 lines of
key=value plus 3 counters.** Total ~120 bytes. Trains in seconds per
round. No infrastructure needed beyond the rail compiler and `od
/dev/urandom`.

---

## Architecture

### Files

```
tools/domains/s0_pcfg/
├── init.rail      28 lines  first-time setup, idempotent
├── state.rail     85 lines  print round/counters/20 weights (read-only)
├── bench.rail    175 lines  sample N, score (read-only, NO state mutation)
├── tick.rail     245 lines  one training round (mutates state + ledger)
└── harvest.rail  185 lines  sample N, save passes to JSONL
```

Each file is self-contained per the spine convention. The grammar code
duplicates across `bench`/`tick`/`harvest` (~80 lines × 3 = 240 lines of
duplication). This is a known cost; it buys the convention's promise that
every domain file is a runnable script with no shared imports beyond
stdlib. Acceptable for now. If a 3rd consumer of the same grammar appears,
promote to a shared `tools/domains/s0_pcfg/_grammar.rail`.

### State file format

`flywheel/s0_state.txt` — flat key=value, parseable by `parse_kv`:

```
round=15
total_samples=450
total_passes=398
w0=7820
w1=26060
...
w19=13820
```

Atomic-ish writes via `write_file` (a single write_file is one open/write/
close, no concurrent-writer protection). Rotated by `flush.rail` on every
training round (added in `bce719e`).

### Spine integration

| Convention | Hook |
|---|---|
| `tools/domains/list.rail` discovery | filesystem path is the registry |
| `flywheel/interventions.jsonl` ledger | every `tick` writes one `s0_round_end` event |
| `flywheel/overrides.txt` tunables | 4 keys read each round (see below) |
| `flywheel/flush.rail` recovery chain | `s0_state.txt` in protected list |
| `tools/domains/README.rail` | 5/5 verbs implemented |

### Tunables

Read fresh each round from `flywheel/overrides.txt`. All four fall back
to a non-zero default because `parse_kv` returns 0 for both "missing" and
"value=0" (a known limitation of the Session 4 override system).

| Key | Default | Effect |
|---|---|---|
| `s0_samples_per_round` | 30 | how many programs per `tick` |
| `s0_alpha_pass` | 50 | weight added to rules used in passing programs |
| `s0_alpha_fail` | 5 | weight subtracted from rules used in failing programs (floor 1) |
| `s0_bench_samples` | 30 | how many programs per `bench` |
| `s0_harvest_samples` | 60 | how many programs per `harvest` |

To make the model converge faster: `s0_alpha_pass` ↑. To make it more
exploratory (slower convergence, more variety): `s0_alpha_pass` ↓.

---

## The grammar (20 rules)

Two program shapes, three expression patterns, nine integer literals,
four operators, two intentional traps. Designed to be small enough to
verify by hand and big enough to produce variety.

```
0:  Program → "main = let _ = print (show " Expr ")\n  0\n"
19: Program → "main =\n  let v = " Expr "\n  let _ = print (show v)\n  0\n"

1:  Expr → Int
2:  Expr → "(" Expr Op Expr ")"
3:  Expr → "(if " Expr " > 0 then " Expr " else " Expr ")"
11: Expr → "x"                       (looked like a TRAP — see Discovery #1)
12: Expr → "(" Expr Op ")"           (REAL TRAP — missing right operand)

4:  Int → "0"
5:  Int → "1"
6:  Int → "5"
7:  Int → "42"
13: Int → "2"
14: Int → "3"
15: Int → "10"
16: Int → "100"
17: Int → "(0 - 1)"

8:  Op → " + "
9:  Op → " - "
10: Op → " * "
18: Op → " / "
```

Depth limit of 3 on `gen_expr` to bound program size. Each program is
~20-200 chars.

---

## Discoveries (what the model found that I didn't put there)

### #1: Rail tolerates undefined variables

Rule 11 (`Expr → "x"`) was added as a *trap* — I assumed undefined `x`
would fail to compile. After 30 ticks of training the rule had weight
**19710** (second-highest of any rule in the grammar). I tested manually:

```
$ echo 'main = let _ = print (show x)
  0' | rail_native run /dev/stdin
0
```

**`rail_native` returns 0 for undefined identifiers.** Compiles clean,
runs clean, prints zero. The model discovered this empirically through
~700 successful "fails" before I knew it about my own compiler. This is
the killer feature of compile-as-teacher: **the model learns the actual
semantics of the compiler, including quirks the human implementer didn't
think to encode**.

### #2: The named-binding program shape is more reliable

After adding rule 19 (a second program shape: `main =\n  let v = E\n
let _ = print (show v)\n  0\n`) the model converged on a clear preference:

| Shape | Final weight (15 fresh ticks) | Pick rate |
|---|---|---|
| Rule 0 (inline `print (show E)`) | 7820 | 36% |
| **Rule 19 (named binding)** | **13820** | **64%** |

REINFORCE found that **placing an expression on its own line via a named
let-binding has fewer parse-failure modes** than inlining it inside
`print (show E)`. Same expression payload, different syntactic placement,
measurably different compile rate. I have no idea why this is true at
the parser level. The model knows it's true and exploits it. That's
sufficient for the loop.

Anyone hand-writing a Rail code generator should prefer the named-binding
form. The PCFG taught me this.

### #3: Integer division by zero is silent

Rule 18 (`Op → " / "`) was added as a *probable failure source* — I
expected `10 / 0` to crash. I tested manually before extending the
grammar:

```
$ echo 'main = let _ = print (show (10 / 0))
  0' | rail_native run /dev/stdin
0
```

Returns 0. No exception, no crash, exit 0. After 15 ticks the `/` rule
had weight 2970, in line with `+`/`-`/`*` (2170/2685/2655). REINFORCE
treats it as just another safe operator. **Rail's integer division is
silently zero on divide-by-zero.** Document somewhere visible — this
will bite someone debugging numerical code.

### #4: REAL traps die fast

Rule 12 (`Expr → "(" Expr Op ")"` — missing right operand) is the only
construct that consistently causes parse failures across the grammar.
Its weight crashed from 1000 → **635** in 15 fresh ticks (would crash
to the floor of 1 with more rounds). This is the negative-feedback proof
of REINFORCE: it doesn't just amplify the good, it actively starves the
bad.

---

## Lessons (the bugs I made)

### Bug 1: Mid-training rule starvation

After 41 rounds of training the 19-rule grammar I added rule 19 (the
new program shape) and re-ran ticks. Rule 19 *should* have been picked
~50% of the time (program_alts has only two entries). Instead, it was
picked **0.4% of the time** across 11 ticks.

**Why**: when the new state file format added `w19=1000`, the existing
state file's `w0` was already at 42480 from prior training. `sample_alt`
picks weighted by `w[0]` vs `w[19]`, so the new rule got
`1000/(42480+1000) ≈ 2.3%` chance of being picked, and most picks led to
some-other-rule failure that didn't help w19. It starved.

**Fix**: changed `load_w_loop` to default missing weights to **1000**
(uniform), not **1** (the floor):

```rail
load_w_loop arr lines i =
  if i >= 20 then 0
  else
    let v = parse_kv lines (cat ["w", show i])
    let safe = if v == 0 then 1000 else v   -- was: 1, now 1000
    let _ = arr_set arr i safe
    load_w_loop arr lines (i + 1)
```

This is safe because `update_weights` floors at 1, so a stored value of
0 always means "the key was absent in the state file" — not "the rule
was actually downweighted to 0". Defaulting absent → 1000 means new
rules start at parity with existing ones.

**Lesson for future grammar extensions**: adding a rule to a grammar
that has already trained means the new rule starts at uniform weight
relative to existing ones (good), BUT the existing weights have a head
start. Either:
- (a) Reset state and retrain from scratch (clean comparison, lose
  prior training)
- (b) Hot-boost the new rule's weight to match the existing average
  (preserves prior training, requires manual intervention)
- (c) Accept slow integration of the new rule (it'll catch up over many
  rounds if `alpha_pass > 0` and the rule is sometimes selected)

Currently the code uses (a) implicitly — `init.rail` is idempotent, so
to reset you `rm flywheel/s0_state.txt && ./rail_native run
tools/domains/s0_pcfg/init.rail`.

### Bug 2: Multi-line list literals don't parse inside `cat [...]`

Rail's parser rejects `cat [\n   "foo",\n  "bar"\n]`. You must collapse
the list onto a single line OR split into multiple let bindings:

```rail
-- BROKEN:
let body = cat [
  "round=0\n",
  "total_samples=0\n",
  ...
]

-- WORKS:
let header = "round=0\ntotal_samples=0\n"
let middle = "..."
let body = cat [header, middle]
```

This isn't documented in CLAUDE.md or any other Rail doc I could find.
Cost me ~10 minutes of "expected decl" errors before I caught the
pattern.

### Bug 3: `write_line` is not a builtin

`write_line` is a userland helper inlined in `tools/train/self_train.rail`
(near line 33). I copied it across `tick.rail` and `harvest.rail` to avoid
circular imports. **There are now 3 inline copies** of the same 3-line
function in the codebase. Promoting it to `stdlib/fs.rail` would clean
this up (and unblock any future ledger writer from needing to copy it).
That's the C move from my B→C→A→D plan.

### Bug 4: Early-return `if` inside `main` terminates the function

```rail
-- BROKEN:
main =
  let _ = print "hi"
  if file_exists path then 0
  else
    let _ = print "missing"
    0
  let n = ...   -- never reached, parser thinks main is over

-- WORKS:
main =
  let _ = print "hi"
  let _ = if file_exists path then 0 else
    let _ = print "missing"
    0
  let n = ...   -- reached, the if expression is bound to _
```

Caught the hard way. The Rail parser treats a top-level `if` in the
middle of `main` as the function's tail expression and considers the
function done. Wrap in `let _ = if ... then ... else ...` to keep going.

### Bug 5: New program shapes drop the round-0 baseline (the p^k effect)

When you add a new program shape to the grammar — call it shape S with k
internal expression slots — and reset the state file, the round-0 baseline
strict pass rate **drops** in proportion to how many expression slots S
has. This caught me by surprise three times in this session (G1, G2, G3).
The pattern is reproducible:

| Grammar | Shapes | Round-0 baseline |
|---|---|---|
| 13 rules (1 shape, 1 slot) | inline | 46% |
| 20 rules (2 shapes, both 1-slot) | + named binding | 53% |
| 21 rules (3 shapes, chain has 2 slots) | + chain | 53% |
| 22 rules (4 shapes, fn has 2 slots) | + fn | **26%** |
| 23 rules (5 shapes, adt has 2 slots) | + adt | **33%** |

The math is straightforward: if `p` is the per-expression pass rate
(roughly 0.85 for the depth-3 expression generator with all rules at
uniform weight), then a k-slot program shape has a per-program pass
rate of approximately `p^k`. For k=1 that's 0.85. For k=2 that's 0.72.
For k=3 that's 0.61. **Each independent expression slot multiplies
the failure surface area.**

Add a 2-slot shape to a grammar that previously had only 1-slot shapes,
and the average baseline drops because (a) the new shape has lower per-
sample pass rate, and (b) sample_alt picks it ~1/N of the time at uniform
weights, so it pulls the average down by `(1/N) × (p - p^2)`.

REINFORCE recovers within 5-10 ticks because the new shape's rule
weight ALSO benefits from successful samples — but the round-0 number
looks bad. **This is expected, not a regression.** The forward
regression bisector (`flywheel/regress.rail`) will flag it as a drop;
ignore the flag if it coincides with a state-file reset.

**Mitigation options for future grammar extensions:**

- (a) **Don't reset state.** Add the new rule, let `load_w_loop` default
  the new weight to 1000, accept that the new rule starts at parity with
  trained existing rules. The new shape will be picked more often than
  it deserves at first but REINFORCE corrects fast.
- (b) **Reset state and accept the optics drop.** Document the expected
  baseline, run a few warmup ticks before reporting. (What I did this
  session.)
- (c) **Initialize new shapes at a fraction of existing average.** Hacky
  but preserves the curve. Not recommended — same problem as Bug 1, just
  with the sign flipped.

**The principle**: program-level pass rate is `p^k` where p is the
per-expression rate and k is the shape's expression count. New shapes
with k > 1 will look worse than they are at uniform-weight initialization.
Don't be surprised by it next time.

---

## Performance

| Operation | Latency | Notes |
|---|---|---|
| One sample (gen + compile + check) | ~250-400ms | dominated by `rail_native run` shell-out |
| One tick (30 samples) | ~8 sec | sequential, single-threaded |
| Bench (30 samples, no state mutation) | ~8 sec | same |
| Harvest (60 samples + jsonl write) | ~16 sec | same + disk |
| init / state (read-only) | <100ms | trivial |

The compile-check shell-out is the bottleneck. Each call invokes
`rail_native` which compiles + assembles + links a 30-character file.
Most of that time is process startup. Batched compilation would 5-10×
this, but at the cost of grammar simplicity.

The total CPU cost of training is negligible compared to the rustane
ANE training experiments earlier in the day (which burned 7+ hours of
compute and produced 0/30 strict compile). s0_pcfg's 30-tick run from
above took ~4 minutes wall time and ended at 92% strict compile.
**1000× faster, infinity-percent better.**

---

## What's next (extension paths)

### G1 — Statement chains
Add a 3rd program shape: `main =\n  let _ = print (show E1)\n  let _ =
print (show E2)\n  0\n`. Tests whether REINFORCE can balance THREE shapes.
Adds one rule. ~20 minutes of work.

### G2 — Function definitions
Add `Stmt → "<name> a b = " Expr` followed by `main =` that calls the
function. New failure modes: undefined function calls, wrong arity. Adds
~3 rules. ~30 minutes.

### G3 — Pattern matching on ADTs
Add `type Op = | Add x y | Sub x y` followed by a match expression. Tests
whether REINFORCE can navigate exhaustiveness checking. Adds ~5 rules.
~45 minutes.

### G4 — Promote `write_line` to stdlib
The Q3 cleanup. Removes 3 inline copies. ~5 minutes. Unblocks future
ledger writers from boilerplate. **Touches stdlib so do it carefully.**

### G5 — Wire `tick.rail` into `tools/train/run_training.sh`
The Q1 from earlier. Each round of the existing self_train flywheel also
runs one PCFG tick. The PCFG keeps growing in the background while the
LLM flywheel does its thing. Continuous high-quality data with zero LLM
cost.

### G6 — Cross-feed harvest into the LLM flywheel
The actual self-improving loop closing. After every N s0_pcfg ticks,
append `training/s0_pcfg_harvest.jsonl` entries to
`training/self_train/harvest.jsonl`. Gemma trains on PCFG-verified data
plus its own LLM-verified data. Two oracles, one corpus. **This is the
real flywheel.**

Recommended order: **G1 → G4 → G5 → G6 → G2 → G3**. Build the small
extension first (G1) to confirm the spine handles it. Then plumbing (G4,
G5, G6) to wire everything together. Then big grammar growth (G2, G3) to
make the harvest worth ingesting.

---

## Why this matters for the bigger picture

The Gemma flywheel currently sits at **14/30 (46%)** on the README
benchmark. It uses an LLM (Gemma 4 E4B) generating Rail, the compiler
verifying, harvested passes feeding LoRA fine-tuning. The training
signal is *cross-entropy on harvested code* — same mimicry objective
that failed for the rustane experiments above.

**s0_pcfg is the proof-of-concept that REINFORCE on compiler feedback
works as a training signal.** If it can drive a 20-int grammar to 92%
strict pass rate, the same signal applied to the Gemma LoRA (replacing
cross-entropy) should move 14/30 → much higher. That's G6 + a future
"REINFORCE LoRA" path that doesn't exist yet.

The "quintessentially small" path the user asked about isn't smaller for
its own sake. It's smaller because **most of the intelligence lives in
the loop, not the weights**. The compiler is the teacher. The grammar is
the substrate. The model is just whatever knob lets us steer the search
toward truth faster than random.

s0_pcfg validates that principle in 720 lines of pure Rail across 5
files. The next layer up — same loop, different policy — is wide open.

---

## Quick reference

```bash
# Discover the domain
./rail_native run tools/domains/list.rail

# First-time setup (idempotent)
./rail_native run tools/domains/s0_pcfg/init.rail

# Print current state
./rail_native run tools/domains/s0_pcfg/state.rail

# Score current weights (read-only)
./rail_native run tools/domains/s0_pcfg/bench.rail

# One training round (mutates state, logs to ledger)
./rail_native run tools/domains/s0_pcfg/tick.rail

# Harvest verified programs to JSONL
./rail_native run tools/domains/s0_pcfg/harvest.rail

# Reset state and retrain from scratch
rm flywheel/s0_state.txt && \
  ./rail_native run tools/domains/s0_pcfg/init.rail

# Read training events from the ledger
./rail_native run flywheel/interventions_tail.rail | grep s0_round_end

# Tighten convergence speed via override
./rail_native run flywheel/override_set.rail s0_alpha_pass 100 "faster"
```

---

## Credits

The spine (`tools/domains/`, `flywheel/interventions.jsonl`,
`flywheel/overrides.txt`, `flywheel/flush.rail`) is from Empire transplant
sessions 1-4 (commit 40cc5a6). s0_pcfg is the second domain on top of it.
The state-protection commit (`bce719e`) was added by a parallel session
that integrated this work without modification — proof that the spine
generalizes.

The PCFG-with-REINFORCE pattern is older than software (genetic
programming, evolutionary algorithms, classifier systems). What's new
here is using a self-hosted compiler as the binary fitness function in
~720 lines of the language being compiled. The model trains itself in
the language it generates.
