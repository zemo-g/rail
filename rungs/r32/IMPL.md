# Rung 32 — Compile-Bound Utterance: Outputs ARE Rail That Runs (PAOS Stage-3 entry)

**Status: VALIDATE-READY.** Code complete, all new helpers + the spoken-program compile/run path +
the binary-identity pin + the foreign re-compile path independently verified light-weight. The single
heavy step (the ~7k-line transformer+crypto harness compile, then the training run) is deferred to
the orchestrator's serial `validate.sh` per compute discipline — it was **not** run here.

## What rung 32 proves (from ATTESTED_LADDER.md)

> The artifact binds not only *what* the model said but the proof that the saying **compiles and
> runs**: the ledger commits source t_hex, the `ld: OK` verdict, the SHA-256 of stdout, and the
> **pinned compiler binary hash**; a foreign witness re-runs `rail_native` to reproduce them.

**Gate.** UTTER contains `compiled=1`, `src_hex`, `out_hex`; the program compiles clean and stdout
SHA-256 == `out_hex`; the foreign witness re-decodes the source, invokes the pinned compiler,
reproduces `compiled=1` + identical `out_hex`. **Dead-output guard:** the held-out *prompt*
constrains behavior (a committed required-stdout property) so `compiled=1`+`out_hex` certifies a
*non-trivial* saying, not `main = 0`.

**Falsifier.** Tamper `out_hex` one nibble → sig fails. A broken completion → `compiled=0` → no PASS.
Swap a different `rail_native` (hash ≠ pinned) → verifier aborts before trusting the verdict.

## Artifacts

| File | Role |
|---|---|
| `tools/bitexact/cbutter_corpus.txt` | the pinned corpus: a **complete, runnable** Rail program `main = let _ = print (show (7)) in 0` (36 bytes, vocab 20) — the model memorizes a program that **prints a non-trivial prompt-derived value (7)**, not `main = 0`. |
| `rungs/r32/compile_bound_utterance.rail` | the harness: `attested_utterance.rail` verbatim through line 857 (the proven rung-21 transformer + attested-utterance pipeline) + new compile-binding helpers + a new `main`. |
| `rungs/r32/cbutter_foreign_check.py` | the foreign (Python big-integer) cross-language re-verifier — reuses `lm10_foreign_check`, re-derives weights, re-decodes source, **re-invokes the pinned compiler, re-runs the binary**, reproduces `compiled=1` + identical `out_hex`, verifies the sig, rejects a tampered `out_hex`, aborts on compiler-pin mismatch. |
| `rungs/r32/validate.sh` | the exact validate command the orchestrator runs serially. |

## How it extends the proven pipeline (reuse, don't reinvent)

The harness is **`attested_utterance.rail` lines 1–857 byte-for-byte** — the lm10 transformer
(Q.24 exact-integer, 2 multi-head RoPE blocks, exact-int Adam, GPU readout `gpu_matvec`), the
SHA-256/Ed25519 hash-chain (`lm4_ckpt`/`lm4_chain`), the canonical serialization (`lm4_canon17`,
`bnd_wp_ser/deser`), the D0 re-run (`lm4_chain_d0`), and greedy decode (`lm4_gen`). The foreign
verifier **reuses `lm10_foreign_check`'s** `rederive`/`forward`/`canon_mat`/`ed25519_verify`
unchanged. **Nothing in the model or crypto changed.** Rung 32 adds exactly one layer on top of the
proven *attested utterance*: it binds the **compile + run** of the spoken words.

What is new (all in the trailing helpers + `main`, ~150 lines):

1. **The model speaks a runnable program, not a fragment.** Corpus is a full `main = … in 0` program.
   Held-out prompt `main = let _ = print (show (` stops *right before the printed value*, so the model
   must supply the value and complete a program that compiles and prints something.
2. **Compile-bind.** After decode, the harness writes the spoken source to `out/cbutter_emitted.rail`,
   invokes the **pinned** compiler via `shell("./rail_native --out-prefix out/cbutter_prog … 2>&1")`
   (Rail `shell()` does not inherit env/PATH → explicit `./path`; **`shell()` returns captured
   stdout** — confirmed against `_rail_shell` runtime + test `t31`), parses `ld: OK` → `compiled=1`,
   runs the produced binary, captures its stdout (`run_out`), and commits `out_hex = SHA256(run_out)`.
3. **Compiler-identity pin** (`cc_hex`). The whole `rail_native` binary's SHA-256, committed in the
   link. Computed via `shasum` through `shell()` because Rail's `read_file`/`sha256` stop at the first
   NUL byte (C-string strlen) — an in-Rail hash would cover only a prefix, letting an adversary swap a
   permissive tail. The system `shasum` hashes the **entire** binary; the foreign verifier computes
   `hashlib.sha256(open('rail_native','rb').read())` and they agree (verified: `295c66d1…`).
4. **Dead-output guard** (`prop_hex`). The link commits `prop_hex = SHA256("7")` — the required
   prompt-derived stdout property. The program's *stripped* stdout must hash to it. `main = 0` prints
   nothing → stripped `""` ≠ committed property → reject. (Raw `out_hex` is over `"7\n"`; the
   property check is over the stripped `"7"` — two distinct, both-required commitments.)
5. **The UTTER link binds all of it before signing:**
   `prev|UTTER|prompt_hex|cwin|gcap|w_hex|t_hex|compiled|src_hex|out_hex|cc_hex|prop_hex`, then
   `usig = Ed25519(seed, SHA256(link))`. One signature covers the words *and* the proof they run.

## Soundness argument

The signature is over `SHA256(link)` where `link` contains `compiled`, `src_hex`, `out_hex`,
`cc_hex`, `prop_hex`. Therefore:

- **No party can claim a different stdout for the saying.** `out_hex` is in the signed link; any
  change to the program's output changes `out_hex`, which changes the link, which the recorded sig no
  longer covers (falsifier a, tested below).
- **`compiled=1` is a *real* verdict, not an assertion.** The foreign witness re-invokes the
  *same pinned compiler* on the *same re-derived source* and must itself observe `ld: OK`. A harness
  that lied about `compiled` would be caught when the foreign party fails to reproduce it.
- **The compiler cannot be silently swapped.** `cc_hex` pins the entire binary. The foreign verifier
  **aborts** if `cc_hex` ≠ the local `rail_native`'s true hash — it refuses to trust a verdict from an
  unknown compiler (falsifier c). A permissive compiler that accepts garbage has a different hash.
- **The certified saying is non-trivial.** `prop_hex` ties the run to a *specific, prompt-derived*
  output value. `compiled=1` + `out_hex` alone could be satisfied by `main = 0` (empty stdout); the
  property check forecloses that — the program must actually print the value the prompt set up.
- **The whole thing is reproducible from data+config+seed.** The training trajectory, the weights, the
  decode, the source, the compile, and the run are all deterministic and re-derived bit-for-bit by an
  independent implementation in a *different language*. The bound between weights → words → running
  program is cryptographic, not narrated.

**Honest scope (from the ladder).** *"The real difficulty lives upstream in rung 24 (genuinely
valid, not parse-passing, Rail)."* Here the model is a memorizing toy: it speaks one program it was
trained on. Rung 32's contribution is the **binding mechanism** — that the artifact now includes a
verifiable compile+run proof, pinned to a specific compiler — not held-out *generalization* to novel
valid Rail (that is rung 24's job, gated upstream of rung 35). The pin, the verdict-capture, the
stdout commitment, the dead-output guard, and the cross-language re-compile are all real and falsify.

## Falsification tests (all wired into the gate, each can fail)

| Falsifier | Mechanism | Where |
|---|---|---|
| (a) tamper `out_hex` one nibble | re-build the link with a flipped first nibble; recorded `usig` must **not** verify → `okForgeOut` | Rail `main` + Python `forge_reject` |
| (b) broken completion → `compiled=0` | compile a deliberately-broken source (`main = let _ = print (show (`) with the *same* pinned compiler; it must **not** produce `ld: OK` → `okBrokenRejected` | Rail `main` (verified: broken src → parse error, 0× `ld: OK`) |
| (c) swap a different `rail_native` | foreign verifier compares `cc_hex` to the local binary's true hash; mismatch → **ABORT** before trusting any verdict | Python `cc_ok` gate |
| forged weights cannot reproduce | zero the readout → different words → `t_hex` diverges → `okForgeWeights` | Rail `main` (inherited from the proven pipeline) |
| dead output (`main=0`) | stripped stdout `""` ≠ `prop_hex` → `okStdoutProp=0` | Rail `main` + Python `prop_ok` |

## Light verification performed here (no heavy build)

- New helpers compile + behave: `cbu_strip "   7  \n"` → `"7"`; `cbu_compiled "…ld: OK…"` → 1,
  `cbu_compiled "…Undefined…"` → 0. (`./rail_native run` on an isolated helper file.)
- The spoken program compiles clean and runs: `cp corpus /tmp/x.rail && ./rail_native … && /tmp/prog`
  → stdout `7\n` (2 bytes `37 0a`); `SHA256("7\n")=10159baf…`, `SHA256("7")=7902699b…`.
- Broken completion → parse error, `0× ld: OK` (falsifier b is real).
- Compiler-identity pin via `shasum` matches the reference: `295c66d1…` (and Rail `read_file`+`sha256`
  does **not** — it truncates at the first NUL — which is exactly why the shell-`shasum` pin is used).
- Foreign verifier: `lm10_foreign_check` imports resolve, `repo_root` → repo root, corpus pin agrees
  (`ec2c4bd6…`), and the foreign compile+run path reproduces `out_hex=10159baf…` + `prop_ok=True`.
- Harness structure audited: no duplicate defs, no real ≥30-arg call (the wide lines are `cons`-nests
  / `cat` literals), `lm4_chain` at 23 args (matches the proven harness), `main` terminates correctly.

## EXACT validate command (orchestrator runs this serially, from repo root)

```bash
bash rungs/r32/validate.sh
```

It (1) builds `rungs/r32/compile_bound_utterance.rail` → `out/cbutter_bin`, (2) runs it with
`RAIL_ARENA_MB=8192` (lm10 needs a multi-GB arena or it GC-thrashes — required, per the proven
pipeline), which trains → speaks → compiles → runs → attests and writes the signed ledger
`out/cbutter_chain.txt`, and (3) runs `python3 rungs/r32/cbutter_foreign_check.py out/cbutter_chain.txt`.
Green gate = the Rail harness exits 0 with `PASS` **and** the foreign verifier prints `CBU-CHECK PASS`
and exits 0; `validate.sh` then prints `VALIDATE PASS` and exits 0.
