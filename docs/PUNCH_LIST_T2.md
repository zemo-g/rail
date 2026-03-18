# TERMINAL 2 — Constrained Decoding + Training Data

## Read first
- `~/projects/rail/grammar/rail.ebnf` (the grammar for constrained generation)
- `~/projects/rail/tools/compile.rail` (search for `generate_code` function ~line 1100)
- `~/projects/rail/tools/build_training_data.rail` (86 lines, existing data builder)
- `~/projects/rail/research/PROPOSAL_v2.md` (sections on GCD + training)

## Task 1: Check MLX grammar support
MLX server is at :8080. Check if it supports grammar-constrained generation:
```bash
# Check MLX server docs/API
curl -s http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model": "/Users/ledaticempire/models/Qwen3.5-9B-6bit", "messages": [{"role": "user", "content": "hello"}], "max_tokens": 10, "grammar": "root ::= \"hello\""}' | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))"
```
If `grammar` param not supported, check if `response_format` with JSON schema works, or if XGrammar/Outlines can be integrated as middleware.

## Task 2: Wire grammar into rail generate
Update `generate_code` in `compile.rail` to:
1. Read `grammar/rail.ebnf`
2. Pass it as a grammar constraint to the LLM API (if supported)
3. OR: use the EBNF as a system prompt to guide generation
4. Per PROPOSAL_v2: constrain ONLY the final code emission, let model reason freely first

## Task 3: Scale training data to 1,000+ examples
Expand `tools/build_training_data.rail` to generate description→code pairs:

1. For each of the 63 test cases in compile.rail, extract the source code string
2. Generate 10 natural language descriptions per test (use the LLM itself)
3. For each .rail tool file (compile, gpu, brain, speak, etc.), add "explain this code" pairs
4. Add error cases: intentionally broken Rail + fix
5. Target: 1,000+ JSONL entries at `training/rail_pairs.jsonl`

```bash
# Generate training data
cd ~/projects/rail && ./rail_native run tools/build_training_data.rail
```

## Task 4: LoRA training round 2
1. Split data 90/10 train/test
2. Train with MLX LoRA: `python -m mlx_lm.lora --model ... --data training/ --iters 2000`
3. Measure held-out task success rate (target: >60%)
4. Compare vs round 1 (33 examples, loss 0.77 at step 1010)

## Task 5: Overfitting test (from PROPOSAL_v2)
Create 20 novel tasks the model has NEVER seen in training:
- "implement binary search"
- "convert Roman numerals to integers"
- "flatten a nested list"
- etc.
Test: `rail_native generate "implement binary search"` → does it produce correct Rail?
Track pass/fail rate. This is the generalization metric.

## Exit criteria
- Grammar-constrained generation eliminates syntax errors (0% parse failures)
- 1,000+ training examples in JSONL
- Held-out success rate >60%
- Overfitting test documented
