# Path A base run — full execution checklist (2026-07-08)

Legend: [box] Mini|Studio · (gate) must-pass before proceeding · ⚠ known landmine

## DONE tonight
- [x] Digit-consistent tokenizer built + proven (digittok.merges; every number -> digit tokens)
- [x] Corpus scale confirmed: 55,795 docs ≈ 4.9B tokens, processed, on disk
- [x] Resident-optimizer trainer ~5x faster, byte-identical
- [x] Honest sizing: ~240-300M Chinchilla-justified for 4.9B tokens

## Phase 0 — Lock decisions & config [Mini]
- [ ] Lock model size + arch: d, n_layers, n_heads, d_ff, ctx, vocab=15577, tied/untied head
- [ ] VRAM-fit proof on Studio ⚠ s337m OOM'd at ctx1024·bs32·24L/64GB → pick ctx(512?), batch, grad-ckpt
- [ ] Trainer choice: MLX-prove-then-Rail-ship vs pure-Rail-Metal from start (resident trainer now viable)
- [ ] Val split % + bench-leak guard rule
- [ ] Init seed (attested)

## Phase 1 — Finalize tokenizer [Mini]
- [ ] finalize_tokenizer.rail: emit Rail-loadable base-vocab + digit merges
- [ ] (gate) pure-Rail tok.rail encode == Python bit-identical WITH digit merges
- [ ] Confirm base vocab has all 10 digits; freeze + sha256 the tokenizer

## Phase 2 — Retokenize corpus with digit tokenizer [Studio] ⚠ heavy
- [ ] tokenize_parallel.py --vocab-prefix=digittok, 16 shards -> train.bin / val.bin (uint16 ok, vocab<65536)
- [ ] Bench-leak guard: skip docs overlapping the frozen eval
- [ ] Verify token count, max id < 15577, dtype
- [ ] (gate) Compute unigram entropy floor on NEW tokenization ⚠ measure FIRST (feedback_lm_unigram_floor)

## Phase 3 — Attest the corpus [Mini + Pi]
- [ ] records.py -> per-doc provenance (pd_basis; Strand-F = source-cleared ⚠ never "fully PD model")
- [ ] merkle.py -> root; recompute in rail_native (RAIL_ARENA_MB=8000 ⚠ GC-thrash >10k leaves)
- [ ] sign.py -> Pi fleet0:9102 Ed25519 ⚠ curl not urllib; Pi flaky/reboot-loops -> retries
- [ ] (gate) verify_corpus.py ALL 5 checks pass (py = rail = signed)
- [ ] Bind corpus_sha + gen + seed + oracle b02dd228 + tokenizer_sha into ledger record 0

## Phase 4 — Freeze success criteria BEFORE training ⚠ retro rule #1 [Mini]
- [ ] Write strict eval + FREEZE/hash it: (a) copy@arbitrary-number >90% (the thing we're fixing);
      (b) compile@1 on frozen bench >=30%; (c) held-out val bpc < unigram floor
- [ ] Define ABORT conditions (compile@1==0 or copy@number==0 past first checkpoint)
- [ ] Held-out bench leak check vs training corpus

## Phase 5 — Prove-small go/no-go [Mini] (gate for the whole run)
- [ ] MLX pilot tiny scale -> FIRST checkpoint; run strict eval
- [ ] (gate) copy@number climbs off 0 AND compile@1 off 0 -> GO; else ABORT (don't start Studio weeks)

## Phase 6 — Provision Studio [Studio]
- [ ] ssh studio (TB) up; 64GB; >=50GB free
- [ ] Pause MLX servers (launchctl bootout, reversible) -> GPU dedicated
- [ ] Wi-Fi above Thunderbolt in service order ⚠ else WAN blackholes
- [ ] rsync project + digit tokenizer + train.bin + oracle + eval harness over TB
- [ ] Studio smoke (tiny onramp) passes

## Phase 7 — The training run [Studio] ⚠ heavy, never load-test on Mini
- [ ] Init weights (seed, attested); config the ~240-300M model
- [ ] Launch detached (nohup); monitor from Mini w/ Slack alerts ⚠ Studio-reboot kills nohup (resume script)
- [ ] Checkpoint + hash-chain each checkpoint (attested lineage)
- [ ] Mid-run eval gates every N steps ⚠ not end-only; ABORT on regression/zero (800-step lesson)

## Phase 8 — Evaluate vs frozen criteria [Mini/Studio]
- [ ] Final checkpoint: strict eval temp-0 deterministic
- [ ] copy@number, compile@1, held-out bpc vs bars
- [ ] Compare to 138M baseline: does 300M+digit-tok beat it on copy AND generalization?

## Phase 9 — Run in Rail (close the loop) [Mini]
- [ ] Wire digit tokenizer into tok.rail
- [ ] (gate) pure-Rail integer-exact forward reproduces MLX argmax BIT-EXACT (twin discipline)
- [ ] rail-gpt generate --prompt works with new model + tokenizer
- [ ] (gate) a number-copy prompt actually copies (the payoff proven end-to-end)

## Phase 10 — Attest the run [Mini + Pi]
- [ ] Hash-chain training ledger: corpus root -> gen -> seed -> oracle -> tokenizer -> checkpoints -> final sha
- [ ] Pi-sign ledger root (beacon pulse bound)
- [ ] (gate) 3rd party can reproduce the headline eval number

## Phase 11 — Ship [Mini]
- [ ] Export final -> safetensors (write_all_st, all tensors, round-trip validated)
- [ ] Integrate into rail-gpt CLI (infer/generate/train/eval/witness/verify/export)
- [ ] Update canonical model pointer ⚠ weights stay OFF the public repo
- [ ] bf16 weight/opt option if memory-bound

## Phase 12 — Bank [Mini]
- [ ] Update memory (rail-gpt-unification, attested-base-model-build)
- [ ] HANDOFF + findings + retro (what the digit-tok + scale actually bought)

## Critical path (longest pole)
Phase 2 retokenize (multi-hr) -> Phase 5 prove-small (gate) -> Phase 7 train (multi-DAY) -> Phase 8 eval.
Everything else parallelizes around these.
