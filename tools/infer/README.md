# Deterministic inference in Rail

A transformer inference engine where the same request produces the same
bytes, on three different Apple GPUs, verified by tests that demand exact
equality rather than closeness. Written in Rail, running on Metal, with no
CUDA, no PyTorch, and no Python in the inference path.

This directory is the engine, the kernels it emits, the server, and the
gates that check the claims. Two of those gates need nothing but a Mac and
this clone. The rest are the same claims at production scale on a 138M
model whose weights are not distributed, so treat their exact hashes as
ours and the zeros as the thing that should reproduce for you.

## The claims, and what checks them

**1. Incremental decode is bit-identical to a full forward pass.**
Decoding position by position against a KV cache produces exactly the same
hidden states and logits as running the whole sequence at once. Not close:
identical.

`kv138_gate.rail` runs both paths over a 138M-parameter model (16 blocks,
d=768, 12 heads, 16384 vocab) and requires
`max |full - incremental| == 0.0` across all 98,304 hidden values and the
full 16,384-wide logit row.

```
max |X16_full - X16_inc| over 98304: 0
max |logits_full - logits_inc| last row: 0
argmax full=5101 inc=5101
```

**2. A chunk of K tokens is bit-identical to K sequential steps, caches
included.** This is the keystone. Feeding K tokens through the engine in
one pass gives the same bits, in every K/V cache of every layer, as feeding
them one at a time.

`ng0_keystone_gate.rail` runs 48 tokens both ways (48 single steps versus
6 chunks of 8) with independent buffer sets, and compares the final hidden
row, the full logit row, and all 32 cache buffers:

```
divergent comparisons: 0 (of 34)
```

**3. Therefore speculative decoding cannot change the output.** If
verifying K drafted tokens in one pass is exactly K greedy steps, every
accepted draft is provably a token plain greedy decoding would have
emitted. `ng0_spec.rail` implements n-gram draft-and-verify (no draft
model, no second set of weights, no training) and checks output equality
against plain greedy across three input regimes:

| input regime | drafts accepted | forward passes | output |
|---|---|---|---|
| cycle6 (control) | 0 | 40 of 40 | identical |
| const | 3 | 37 of 40 | identical |
| pair | 20 | **20 of 40, 2.0x** | identical |

Acceptance is a property of the input. Correctness is a property of the
engine. That separation is the point.

Read the table honestly: the `cycle6` row accepts nothing, so it runs one
row per pass and is the same code path as plain greedy. It is a control,
not a third independent test. `pair` is the row that actually exercises
the claim, and `const` is a weak middle. One regime doing real work is
what this table shows.

**3b. The gates fail on a dead engine.** Max-difference alone cannot: an
all-NaN run leaves every running max at 0.0, because IEEE says every
comparison with NaN is false, and an all-zero run agrees perfectly while
proving nothing. Both were live holes until an outside review found them
on 2026-08-27. Every parity gate now counts finite nonzero values first
and fails if the tensor is mostly dead. Verified by removing the weights
file: the gate that used to report `max diff 0.0, argmax 0 == 0, PASS`
now reports `hidden 0/98304 live` and fails.

**4. All of it holds across three chips and three OS versions.**

| machine | chip | macOS | 138M hash |
|---|---|---|---|
| Mac Mini | M4 Pro | 26.3 | `092af18f2b576bd5` |
| Mac Studio | M1 Ultra | 26.4.1 | `092af18f2b576bd5` |
| MacBook Air | M1 | 26.5.1 | `092af18f2b576bd5` |

Each machine compiled its own dylib and its own kernels.

## How the determinism is actually achieved

Two things, both boring, both mandatory.

**fastMath off.** `tgl_fjit_compile` sets `fastMathEnabled = NO`. With fast
math on, the Metal compiler reassociates float arithmetic and substitutes
approximate transcendentals, and reproducibility is gone before you write
a line of model code.

**Pinned reduction order.** Every reduction in these kernels is a single
accumulator walked in a fixed direction with explicit `fma()`, never a
tree and never split. Attention scores, softmax sums, and matmul
accumulations all have one order, so the same inputs give the same bits
regardless of how the work is scheduled.

Then two things that had to be replaced:

**Transcendentals.** `precise::exp` and `precise::tanh` differ across
Apple GPU families. Both are replaced by explicit fma polynomials
(`ep()` and `tp()` in the kernel sources), which are identical everywhere.

**rsqrt.** LayerNorm originally used `rsqrt(var + eps)`. It is not
correctly rounded. `rsqrt_probe.rail` measures the gap:

```
differing elements: 1161 of 4096; max |rsqrt - 1/sqrt| = 4.76837158203125e-07
```

About an ulp, on 28% of values. Both forms are nonetheless byte-identical
across all three machines: Apple ships the same approximation across
generations, so portability was never actually at risk. It is still
replaced with `1.0f/sqrt(x)`, because sqrt and divide are
IEEE-exact-required, which turns an empirical agreement into a
specification-backed one for the price of one ulp of speed.

The probe exists because the Studio briefly appeared to disagree with the
other two machines, which would have killed the central claim. It had
not: it was running a stale copy of the gate, and the check meant to
catch that compared the wrong file. Worth stating plainly, because it is
the strongest argument for binding the compiled kernel source hash, the
OS build, and the Metal compiler version into any receipt. A stale binary
should be detectable rather than silently authoritative, and right now
that binding does not exist.

## What this is not

Being precise about the size of the claim, because it is smaller than it
first looks.

**This is replayability, not verifiability.** Verification costs exactly
what generation cost. A checker needs the weights, matching hardware, and
the same time you spent. That makes it a fraud-proof primitive: useful
when a party who already has your model wants to check what you claimed,
useless as a succinct proof to a stranger. zkML and TEE attestation give a
verifier an asymptotic advantage. This does not.

**Batch-1 is a choice, not a requirement.** This engine serves one request
at a time, which makes the reduction shape constant for free. That is
sufficient for determinism but not necessary: batch-invariant kernels get
you the same guarantee with real throughput, which is the approach
[Thinking Machines documented](https://thinkingmachines.ai/blog/defeating-nondeterminism-in-llm-inference/)
and which vLLM and SGLang have shipped. The keystone gate above is in fact
a batch-invariance proof; this engine simply has not spent it on
throughput yet.

**Greedy only.** The speculation guarantee is for greedy decoding. Standard
speculative sampling preserves the output *distribution* under temperature,
not the realized token for a given seed, and the guarantee here does not
extend to that case without seeded sampling, which is a different and
weaker promise.

**Prior art exists and is good.**
[LLM-42](https://arxiv.org/abs/2601.17768) (Microsoft Research, University
of Washington, IISc) runs this argument in the opposite direction: it keeps
fast nondeterministic kernels and enforces determinism with a
speculation-shaped verify-and-rollback loop, paying overhead only on traffic
that needs it. This engine has determinism by construction and spends it on
making speculation exact, so there is nothing to roll back. Different trade,
same underlying observation.

The honest contribution here is narrow: the *numerical* half. The logical
argument that chunk-equals-sequential implies speculation preserves greedy
output is textbook. Making chunk-equals-sequential true **bitwise**, on
commodity hardware, is the part production engines do not have, and it is
why speculative decoding occasionally flips a greedy token elsewhere.

## Running it

Requires a Mac with Apple Silicon and Xcode command line tools. The dylib
builds automatically on first compile.

**Start here if you have no model weights.** `kv0_gate.rail` proves the
same incremental-equals-full property on a small patterned model with no
files and no downloads, and `rsqrt_probe.rail` needs nothing either. The
138M gates below are the same claims at production scale, on weights that
are not distributed.

```bash
./rail_native run tools/infer/kv0_gate.rail             # no weights needed
./rail_native run tools/infer/rsqrt_probe.rail          # no weights needed
./rail_native run tools/infer/kv138_gate.rail           # needs weights
./rail_native run tools/infer/ng0_keystone_gate.rail    # needs weights
./rail_native run tools/infer/ng0_spec.rail --max 40 --pattern pair
```

The weight-dependent gates read
`/tmp/b75/b9full_init.safetensors`: a 16-block, d=768, 12-head,
FF=3072, 16384-vocab GPT with LayerNorm biases, stored as f32 with keys
`L{i}.{wq,wk,wv,wo,w1,w2,g1,b1,g2,b2,bm1,bm2}`, `lnfg`, `lnfb`, `headw`,
`emb`, `pos`. Any model of that shape works; the hashes above are specific
to the weights they were run on, so expect your own numbers. What should
reproduce is the *zeros*: incremental equals full, chunk equals sequential,
speculation equals greedy.

`f9_engine.rail` is the engine itself and has no `main`. It is imported by
each gate, and by the server in the companion work.

## Files

| file | what it is |
|---|---|
| `f9_engine.rail` | the engine: kernel sources, safetensors loader with exact f32 decode, incremental and chunked decode paths |
| `kv138_gate.rail` | incremental equals full, on a real model |
| `ng0_keystone_gate.rail` | chunk of K equals K sequential steps, caches included |
| `ng0_spec.rail` | n-gram speculative decoding, and the proof it changes nothing |
| `rsqrt_probe.rail` | measures rsqrt against 1/sqrt, and both across machines |
| `kv0_gate.rail` | the same parity claim with **no weights required**: start here |
| `serve_kv.rail` | the serving loop: same request bytes give same response bytes, hash-chained ledger, signed head, live token streaming, prefix cache as a declared input |
| `s0_gate.sh` | 15 checks on the running server, including that a tampered ledger fails verification |
| `agree_check.sh` | sends one request to two machines and compares hashes: disagreement is an alarm |

Built 2026-08-27. Rail is a self-hosting language: the compiler is written
in Rail and compiles itself, with no C dependencies.
