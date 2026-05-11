# Batch=32 trainer fork — design doc (from 2026-05-10 audit)

## Premise

Studio M1 Ultra is at batch=1, single training process. Per
`exhaust_studio_before_renting.md`, batch is the #1 untouched lever.
This doc captures the kernel audit findings + the trainer fork plan
so tomorrow's session can implement directly.

## Kernel audit results (from `batch32_kernel_smoke.rail`)

| Kernel | Status | Caller pattern |
|---|---|---|
| `tensor_add` | batch-safe (flat) | feed (B, S, D) directly |
| `tensor_softmax` | batch-safe (rows = total/last_dim) | feed (B, S, S) directly |
| `rmsnorm_save` | batch-safe (rows = total/last_dim) | feed (B, S, D) directly |
| `matmul_mixed` | rank-2 only | reshape (B, S, D) → (B*S, D), matmul, reshape back |
| `rope_apply` | rank-2 only | loop per batch: slice → rope → write back |
| `apply_causal_mask_loop` | per-(seq,seq) call | loop per batch |

**No kernel patches required.** All batch handling at caller.

## Forward path (per block) — batch-aware

```rail
infer_block_fwd_batched x w_block B seq d =
  -- x: Tensor (B, seq, d)
  let g1 = list_nth 7 w_block
  let g1_f = tensor_of_half g1

  -- RMSNorm: batch-safe, feeds (B, seq, d) directly
  let pack1 = rmsnorm_save x g1_f      -- (B, seq, d)
  let ln1 = head pack1

  -- Linear matmuls via reshape trick
  let ln1_flat = reshape_tensor ln1 (cons (B * seq) (cons d []))
  let q_flat = matmul_mixed ln1_flat w_q    -- (B*seq, d)
  let k_flat = matmul_mixed ln1_flat w_k
  let v_flat = matmul_mixed ln1_flat w_v
  let q = reshape_tensor q_flat (cons B (cons seq (cons d [])))
  let k = reshape_tensor k_flat (cons B (cons seq (cons d [])))
  let v = reshape_tensor v_flat (cons B (cons seq (cons d [])))

  -- RoPE: per-batch slice + apply
  let _ = rope_apply_batched q B seq d
  let _ = rope_apply_batched k B seq d

  -- Attention: per-batch loop (q×kt, mask, softmax, attn×v)
  let attn_val = batched_attention q k v B seq d  -- (B, seq, d)

  -- Output projection via reshape
  let attn_val_flat = reshape_tensor attn_val (cons (B * seq) (cons d []))
  let attn_out_flat = matmul_mixed attn_val_flat w_o
  let attn_out = reshape_tensor attn_out_flat (cons B (cons seq (cons d [])))

  -- Residual + ffn (similar pattern)
  let x_attn = tensor_add x attn_out
  let g2_f = tensor_of_half g2
  let pack2 = rmsnorm_save x_attn g2_f
  let ln2 = head pack2

  let ln2_flat = reshape_tensor ln2 (cons (B * seq) (cons d []))
  let h_gate_flat = matmul_mixed ln2_flat w_gate
  let h_up_flat = matmul_mixed ln2_flat w_up
  let silu_pack = silu_forward h_gate_flat   -- batch-safe (elementwise)
  let h_silu_flat = head silu_pack
  let h_act_flat = tensor_mul h_silu_flat h_up_flat
  let h_out_flat = matmul_mixed h_act_flat w_down
  let h_out = reshape_tensor h_out_flat (cons B (cons seq (cons d [])))
  tensor_add x_attn h_out
```

## Required helpers

### `reshape_tensor t new_shape` — trivial

```rail
reshape_tensor t new_shape = match t
  | Tensor data _ _ ->
    Tensor data new_shape (compute_strides new_shape)
```

Storage is just a flat float_arr; reshape = new shape descriptor.

### `rope_apply_batched x B seq d`

```rail
rope_apply_batched_loop xd B seq d b =
  if b >= B then 0
  else
    -- Apply rope to slice starting at offset b * seq * d.
    -- Need to call rope_positions with the slice's data view.
    -- Simplest: copy slice out, rope_apply on (seq, d) tensor, copy back.
    -- Better: pass offset to rope_positions if we extend it.
    let offset = b * seq * d
    let _ = rope_positions_offset xd seq d 0 1.0 offset
    rope_apply_batched_loop xd B seq d (b + 1)

rope_apply_batched x B seq d = match x
  | Tensor xd _ _ ->
    let _ = rope_apply_batched_loop xd B seq d 0
    x
```

**Implementation note:** `rope_positions` currently takes data + seq + d
+ start_pos + sign. Either (a) add a wrapper that takes offset, or
(b) write a small `rope_apply_slice xd offset seq d` helper.

### `batched_attention q k v B seq d`

```rail
batched_attention q k v B seq d =
  -- Allocate output: (B, seq, d)
  let out_data = float_arr_new (B * seq * d) 0.0
  let _ = batched_attention_loop q k v out_data B seq d 0
  Tensor out_data (cons B (cons seq (cons d []))) (compute_strides ...)

batched_attention_loop q k v out_data B seq d b =
  if b >= B then 0
  else
    -- For each batch:
    --   1. Extract q[b], k[b], v[b] as (seq, d) tensors (slice)
    --   2. kt = transpose k_b
    --   3. scores = matmul q_b kt
    --   4. scaled = scale scores (1/sqrt d)
    --   5. apply_causal_mask
    --   6. attn = softmax scaled
    --   7. attn_val = matmul attn v_b
    --   8. write attn_val into out_data at offset b*seq*d
    ...
    batched_attention_loop q k v out_data B seq d (b + 1)
```

**Implementation note:** Slicing requires either copy-out / copy-back
OR a "view" tensor that points into existing data with offset. Rail's
Tensor ADT doesn't have offset support — adding it is a stdlib change.
For first cut, copy-out / copy-back; profile and decide if a view type
is worth it.

## Backward path

Mirror the forward pattern. Each reshape → reshape. Each per-batch
loop → per-batch backward loop. Gradients accumulate across batches
(divide by B at the end OR keep raw and let Adam handle scale).

Specifically:
- d_x_embed (post-embedding gradient) is (B, seq, d). Per-block backward
  passes it through.
- For matmul gradients (dW = X^T dY), reshape both X and dY to rank-2
  before computing dW. dX = dY @ W^T, also reshape.
- Per-batch attention backward needs B passes; gradients accumulate
  into the linear weight grads (which are batch-independent params).

## Trainer changes

```rail
-- main:
let batch_size = 32  -- new
let x_data = float_arr_new (batch_size * seq * V) 0.0  -- was just (seq * V)
let x = Tensor x_data (cons batch_size (cons seq (cons V []))) ...
let labels_data = float_arr_new (batch_size * seq) 0.0
let labels = Tensor labels_data (cons batch_size (cons seq [])) (cons seq (cons 1 []))

-- sample_chunk now fills batch_size offsets:
sample_chunk_batched batch_ctx V seq batch_size =
  -- Use lcg to draw batch_size random offsets
  -- For each batch b: fill x[b, :, :] with one-hot, labels[b, :] with shifted ids
```

## Numerical sanity

- Train d=256 4-block batch=32 for 200 steps
- Compare val_loss curve to d=256 batch=1 same wall-clock OR same total samples
- Expected: batch=32 at the SAME step-count = LESS data seen, val_loss
  likely WORSE at step 200. The comparison must be at SAME-TOTAL-SAMPLES:
  - batch=1 × 6000 steps = 6M samples
  - batch=32 × 188 steps = 6M samples (or batch=32 × 6000 = 192M samples)
  - First fair comparison: batch=32 × 188 steps vs batch=1 × 6000 steps

- True sample-efficiency win shows up as batch=32 × 188 < batch=1 × 6000
  in val_loss.

## Memory budget

At B=32, seq=1024, d=256, V=130:
- x: B × seq × V = 32 × 1024 × 130 × 8 bytes = ~34 MB
- Activations per layer: B × seq × d = 32 × 1024 × 256 × 8 = 67 MB
- Per block (4 stored activations for backward): ~270 MB
- 4 blocks × 270 MB = ~1 GB activations
- Weights + Adam: unchanged (~50 MB)

Total: ~1 GB. Studio has 64 GB. Plenty of room.

## Stop conditions for the trainer fork

- Smoke test STILL passes after any kernel touched
- 137/137 still green after any stdlib touched
- batch=32 + 200 steps val_loss is sane (not 14, not NaN)
- If val_loss > batch=1 same-step: re-smoke kernels for B>1 bugs
- If wall-clock per step > 10x batch=1: investigate before going overnight

## Order of operations for the next session

1. Re-run `batch32_kernel_smoke.rail` — confirm audit holds.
2. Add `reshape_tensor` to `stdlib/tensor.rail` (likely already implicit
   via direct ADT construction; verify).
3. Add `rope_apply_batched` to `stdlib/transformer.rail`.
4. Add `batched_attention` helper (or extract from `infer_block_fwd_batched`).
5. Fork `lm_v3_chunked_d256_4block_half_6k.rail` →
   `lm_v3_chunked_d256_4block_batch32.rail`.
6. Add `batch_size = 32`, refactor `x_data` allocation.
7. Replace `m_forward` with `m_forward_batched`.
8. Replace `m_train_step` backward path with batched version.
9. Modify `sample_chunk` → `sample_chunk_batched`.
10. Build, run 200 steps. Inspect val_loss.
11. If good, run 3000 steps overnight.
12. Bench resulting ckpt. Compare to v54 13/30.
