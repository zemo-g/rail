# Parse-trace auxiliary loss (Tier-A2)

**Hypothesis.** The compiler builds an AST during parsing. Serializing the AST traversal as a parallel token stream and training the model to predict both surface tokens AND AST tokens forces internal grammar awareness without any architectural change. Free signal — the parse tree is already constructed during compilation.

## Token schema

Vocab augmentation: 7 reserved AST control tokens added to the existing BPE vocab.

| Token  | ID range          | Meaning                              |
|--------|-------------------|--------------------------------------|
| `<O:k>`| `V_base + 0..32`  | NODE_OPEN with kind id k             |
| `<C>`  | `V_base + 33`     | NODE_CLOSE                           |
| `<L>`  | `V_base + 34`     | LEAF marker                          |
| `<T:τ>`| `V_base + 35..50` | TYPE annotation (16 base types)      |
| `<S>`  | `V_base + 51`     | STMT separator                       |
| `<E>`  | `V_base + 52`     | EXPR separator                       |
| `<X>`  | `V_base + 53`     | parse error / unknown                |

Where `V_base` is the surface vocab size (currently 256 for byte-level / ~32k for BPE). 32 NODE_KINDs cover the Rail grammar:

```
0  Module        8  IfExpr        16 ListLit       24 TypeAnno
1  Import        9  MatchExpr     17 TupleLit      25 TypeRef
2  FnDef        10  LetExpr       18 StringLit     26 ADTDef
3  Lambda       11  BinOp         19 IntLit        27 ADTCons
4  ParamList    12  UnaryOp       20 FloatLit      28 PatternMatch
5  Body         13  Call          21 Ident         29 Comment
6  Block        14  Pipe          22 Symbol        30 EOF
7  Return       15  FieldAccess   23 Lambda        31 Reserved
```

## Stream format

Pre-order DFS traversal. Per node: `<O:kind>` then children, then `<C>`. Leaves emit `<L>` followed by surface token IDs (the actual identifier / literal bytes).

Example: `add x y`

```
<O:13>          -- Call
  <O:21><L>add<C>     -- Ident "add"
  <O:21><L>x<C>       -- Ident "x"
  <O:21><L>y<C>       -- Ident "y"
<C>
```

## Alignment

Two streams emitted in parallel: surface (S) and trace (T). Per-line alignment:
- Each Rail source line emits a surface line and a trace line.
- Lines synced via `<S>` separator on both streams.
- Trace stream always ≥ surface line in length (more tokens per concept).

Training pass packs both as a 2-channel sequence of length `seq_len`, with channel-id encoded in the high bit of the embedding index. Effective vocab doubles; param count grows by `V × d` for the second embedding. Acceptable at d=256.

## Loss

```
total_loss = ce(surface_pred, surface_target) + λ · ce(trace_pred, trace_target)
```

Start λ=0.3. Anneal to 0.1 by step 2000.

## Compiler implementation (Task #11)

Add `--emit-ast-trace <path>` flag to `tools/compile.rail`. During parse, `parse_node` already constructs AST — instrument it to also append serialized tokens to a buffer. On exit, write buffer to path.

Pseudocode:
```
parse_node ctx kind =
  emit ctx (open_kind kind)
  let result = parse_children ctx
  emit ctx close
  result
```

2-cycle bootstrap per CLAUDE.md: changes the runtime emit, needs cycle 2 to land.

## Validation

Round-trip on 5 corpus programs:
1. Parse program with `--emit-ast-trace`.
2. Re-parse the trace using a separate trace-deserializer.
3. Compare reconstructed AST with original (kind sequence + leaf identifiers).
4. Must be byte-identical.

## Risk register

- **Risk:** Trace stream is 2-3× longer than surface stream, eating sequence budget at fixed seq_len.
  **Mitigation:** Start with λ=0.3 to keep trace contribution bounded; if trace tokens dominate gradient, drop λ further.
- **Risk:** Compiler emits non-deterministic AST under arena state.
  **Mitigation:** Determinism check — emit twice, diff. If non-equal, isolate.
- **Risk:** d=256 embedding × 2× vocab doubles param count for embedding alone.
  **Mitigation:** Acceptable at this scale (~120k extra params); can prune if needed.

## Success criterion

Spur-v2 trained with parse-trace aux loss vs Spur-v1.0 baseline:
- ≥ 3 passes/30 lift on N=20 rerank → A2 confirmed lever
- ≥ 1 pass/30 + quality bump > 1k → directionally promising
- 0 → falsified at this scale; document and continue.
