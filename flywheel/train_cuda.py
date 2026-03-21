#!/usr/bin/env python3
"""train_cuda.py v3 — Rail CUDA trainer with validation, quality filtering, and audit fixes.

Changes from v2:
  - Default max_seq_length raised to 512 (was 256 — truncated 31% of data)
  - Validation eval every report_every steps (was: no eval at all)
  - Data quality filtering: skip no-main, skip trivial (<20 chars code), skip oversized
  - Inline SHA-256 dedup at load time
  - UTF-8 encoding on all file reads (was: system default, broke on Windows)
  - LoRA layer discovery logs actual matched layers (was: silent mismatch)
  - Overfitting warning when val_loss > 1.5x train_loss
  - Defaults tuned for 8GB VRAM RTX 3070 (batch=1, seq=512, grad_ckpt)

Usage:
  python train_cuda_v3.py --model Qwen/Qwen3.5-4B --data ./clean_data --adapter-path ./adapters
"""

import argparse, json, os, random, sys, time, math, hashlib
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, TaskType


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--data", required=True)
    p.add_argument("--adapter-path", required=True)
    p.add_argument("--iters", type=int, default=3000)
    p.add_argument("--batch-size", type=int, default=1)
    p.add_argument("--learning-rate", type=float, default=1.5e-5)
    p.add_argument("--lora-rank", type=int, default=8)
    p.add_argument("--lora-alpha", type=int, default=16)
    p.add_argument("--num-layers", type=int, default=16)
    p.add_argument("--max-seq-length", type=int, default=512)
    p.add_argument("--save-every", type=int, default=500)
    p.add_argument("--report-every", type=int, default=50)
    p.add_argument("--quantize-4bit", action="store_true")
    p.add_argument("--gradient-checkpointing", action="store_true")
    p.add_argument("--warmup-steps", type=int, default=150)
    p.add_argument("--grad-clip", type=float, default=1.0)
    p.add_argument("--mask-prompt", action="store_true", default=True)
    p.add_argument("--no-mask-prompt", dest="mask_prompt", action="store_false")
    p.add_argument("--max-code-chars", type=int, default=4000,
                   help="Skip examples where total content exceeds this (prevents OOM)")
    return p.parse_args()


def load_model(args):
    print(f"Loading {args.model}...")
    compute_dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    kwargs = {"trust_remote_code": True, "dtype": compute_dtype}
    if args.quantize_4bit:
        kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_compute_dtype=compute_dtype,
            bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True)
    kwargs["device_map"] = "auto"
    model = AutoModelForCausalLM.from_pretrained(args.model, **kwargs)
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    if args.gradient_checkpointing:
        model.gradient_checkpointing_enable()
    return model, tokenizer


def apply_lora(model, args):
    # Discover ALL attention layers: self_attn (8 full-attention) + linear_attn (24 DeltaNet)
    attn_modules = [n for n, _ in model.named_modules()
                    if ("self_attn" in n or "linear_attn" in n) and
                    any(p in n for p in ["q_proj", "k_proj", "v_proj", "o_proj",
                                         "in_proj_qkv", "in_proj_z", "in_proj_b",
                                         "in_proj_a", "out_proj"])]
    layer_indices = sorted(set(int(n.split(".")[2]) for n in attn_modules if n.split(".")[2].isdigit()))
    target_layers = layer_indices[-args.num_layers:] if len(layer_indices) > args.num_layers else layer_indices

    # Count by type for diagnostics
    sa_count = len([i for i in target_layers if any("self_attn" in n and f".{i}." in n for n in attn_modules)])
    dn_count = len([i for i in target_layers if any("linear_attn" in n and f".{i}." in n for n in attn_modules)])
    print(f"  Found {len(layer_indices)} attention layers: {layer_indices[0]}-{layer_indices[-1]}")
    print(f"  Targeting last {len(target_layers)}: {target_layers}")
    print(f"  Breakdown: {sa_count} self_attn + {dn_count} DeltaNet layers")

    config = LoraConfig(
        r=args.lora_rank, lora_alpha=args.lora_alpha, lora_dropout=0.05,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "in_proj_qkv", "in_proj_z", "in_proj_b",
                        "in_proj_a", "out_proj"],
        layers_to_transform=target_layers,
        task_type=TaskType.CAUSAL_LM)
    model = get_peft_model(model, config)
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"  Trainable: {trainable:,} / {total:,} ({trainable*100/total:.3f}%)")
    return model


def load_jsonl(path, args, tokenizer):
    """Load JSONL with quality filtering and inline dedup."""
    examples = []
    skipped_tiny = 0
    skipped_no_main = 0
    skipped_oversized = 0
    skipped_dup = 0
    seen = set()

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            messages = obj.get("messages", [])
            if len(messages) < 2:
                continue

            code = ""
            for m in messages:
                if m.get("role") == "assistant":
                    code = m.get("content", "")

            if "main" not in code:
                skipped_no_main += 1
                continue

            if len(code) < 20:
                skipped_tiny += 1
                continue

            total_chars = sum(len(m.get("content", "")) for m in messages)
            if total_chars > args.max_code_chars:
                skipped_oversized += 1
                continue

            h = hashlib.sha256(code.encode()).hexdigest()
            if h in seen:
                skipped_dup += 1
                continue
            seen.add(h)

            try:
                full_text = tokenizer.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=False)
            except Exception:
                parts = [f"<|{m['role']}|>\n{m['content']}" for m in messages]
                full_text = "\n".join(parts)

            tokens = tokenizer(full_text, truncation=True, max_length=args.max_seq_length,
                               padding=False, return_tensors=None)

            if len(tokens["input_ids"]) <= 10:
                skipped_tiny += 1
                continue

            prompt_len = 0
            if args.mask_prompt and len(messages) >= 3:
                try:
                    prompt_text = tokenizer.apply_chat_template(
                        messages[:2], tokenize=False, add_generation_prompt=True)
                except Exception:
                    parts = [f"<|{m['role']}|>\n{m['content']}" for m in messages[:2]]
                    prompt_text = "\n".join(parts)
                prompt_tokens = tokenizer(prompt_text, truncation=True,
                                          max_length=args.max_seq_length,
                                          padding=False, return_tensors=None)
                prompt_len = len(prompt_tokens["input_ids"])

            examples.append({"input_ids": tokens["input_ids"], "prompt_len": prompt_len})

    print(f"  Loaded: {len(examples)} examples")
    if skipped_no_main:   print(f"  Filtered (no main): {skipped_no_main}")
    if skipped_tiny:      print(f"  Filtered (tiny): {skipped_tiny}")
    if skipped_oversized: print(f"  Filtered (oversized >{args.max_code_chars}): {skipped_oversized}")
    if skipped_dup:       print(f"  Filtered (duplicate): {skipped_dup}")

    if examples:
        avg_len = sum(len(e["input_ids"]) for e in examples) / len(examples)
        avg_prompt = sum(e["prompt_len"] for e in examples) / len(examples)
        print(f"  Avg total: {avg_len:.0f} tok, prompt: {avg_prompt:.0f} tok, assistant: {avg_len - avg_prompt:.0f} tok")
    if args.mask_prompt:
        print(f"  Prompt masking: ON")
    return examples


def prepare_data(args, tokenizer):
    train_path = os.path.join(args.data, "train.jsonl")
    valid_path = os.path.join(args.data, "valid.jsonl")

    print("  --- Training data ---")
    train_examples = load_jsonl(train_path, args, tokenizer)

    valid_examples = []
    if os.path.exists(valid_path):
        print("  --- Validation data ---")
        valid_examples = load_jsonl(valid_path, args, tokenizer)
    else:
        print(f"  No validation file at {valid_path}")

    return train_examples, valid_examples


def collate_fn(batch, pad_id, mask_prompt):
    max_len = max(len(b["input_ids"]) for b in batch)
    input_ids, attention_mask, labels = [], [], []
    for b in batch:
        ids = b["input_ids"]
        plen = b["prompt_len"]
        pad_len = max_len - len(ids)
        input_ids.append(ids + [pad_id] * pad_len)
        attention_mask.append([1] * len(ids) + [0] * pad_len)
        if mask_prompt and plen > 0:
            lbl = [-100] * plen + ids[plen:] + [-100] * pad_len
        else:
            lbl = ids + [-100] * pad_len
        labels.append(lbl)
    return {
        "input_ids": torch.tensor(input_ids, dtype=torch.long),
        "attention_mask": torch.tensor(attention_mask, dtype=torch.long),
        "labels": torch.tensor(labels, dtype=torch.long),
    }


@torch.no_grad()
def eval_loss(model, examples, args, tokenizer):
    """Average loss on validation set."""
    if not examples:
        return None
    model.eval()
    pad_id = tokenizer.pad_token_id or 0
    total_loss = 0.0
    count = 0
    for i in range(0, len(examples), args.batch_size):
        batch = examples[i:i + args.batch_size]
        inputs = collate_fn(batch, pad_id, args.mask_prompt)
        inputs = {k: v.to(model.device) for k, v in inputs.items()}
        outputs = model(**inputs)
        total_loss += outputs.loss.item() * len(batch)
        count += len(batch)
    model.train()
    return total_loss / max(count, 1)


def train(model, train_examples, valid_examples, args, tokenizer):
    optimizer = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad],
        lr=args.learning_rate, weight_decay=0.01)

    model.train()
    pad_id = tokenizer.pad_token_id or 0
    start = time.time()
    total_loss = 0.0
    step = 0
    best_loss = float("inf")
    best_val_loss = float("inf")

    while step < args.iters:
        random.shuffle(train_examples)
        for i in range(0, len(train_examples), args.batch_size):
            if step >= args.iters:
                break

            if step < args.warmup_steps:
                lr = args.learning_rate * step / max(args.warmup_steps, 1)
            else:
                progress = (step - args.warmup_steps) / max(args.iters - args.warmup_steps, 1)
                lr = args.learning_rate * 0.5 * (1.0 + math.cos(math.pi * progress))
            for pg in optimizer.param_groups:
                pg["lr"] = lr

            batch = train_examples[i:i + args.batch_size]
            inputs = collate_fn(batch, pad_id, args.mask_prompt)
            inputs = {k: v.to(model.device) for k, v in inputs.items()}

            outputs = model(**inputs)
            loss = outputs.loss
            loss.backward()

            torch.nn.utils.clip_grad_norm_(
                [p for p in model.parameters() if p.requires_grad], args.grad_clip)

            optimizer.step()
            optimizer.zero_grad()

            total_loss += loss.item()
            step += 1

            if step % args.report_every == 0:
                elapsed = time.time() - start
                avg_loss = total_loss / args.report_every
                tps = sum(len(e["input_ids"]) for e in train_examples) * step / (len(train_examples) * elapsed)
                eta_m = (args.iters - step) * (elapsed / step) / 60
                if avg_loss < best_loss:
                    best_loss = avg_loss

                val_str = ""
                if valid_examples:
                    val_loss = eval_loss(model, valid_examples, args, tokenizer)
                    if val_loss is not None:
                        if val_loss < best_val_loss:
                            best_val_loss = val_loss
                        val_str = f" val={val_loss:.4f}"
                        if val_loss > avg_loss * 1.5:
                            val_str += " !!OVERFIT"
                        # Collapse detection: val loss diverging from best
                        if val_loss > best_val_loss * 2.0 and step > args.warmup_steps:
                            val_str += " !!COLLAPSE_RISK"

                # Log entropy of last batch logits (collapse = entropy → 0)
                with torch.no_grad():
                    logits = outputs.logits[:, -1, :]
                    probs = torch.softmax(logits, dim=-1)
                    entropy = -(probs * torch.log(probs + 1e-10)).sum(dim=-1).mean().item()
                entropy_str = f" entropy={entropy:.2f}"
                if entropy < 1.0 and step > args.warmup_steps:
                    entropy_str += " !!LOW"

                print(f"  Iter {step}/{args.iters}: loss={avg_loss:.4f} best={best_loss:.4f}{val_str} lr={lr:.2e} tok/s={tps:.0f}{entropy_str} eta={eta_m:.0f}m")
                sys.stdout.flush()
                total_loss = 0.0

            if step % args.save_every == 0:
                save_adapter(model, args, step)

    save_adapter(model, args, step)
    elapsed = time.time() - start
    print(f"  Done. {step} iters in {elapsed:.0f}s ({elapsed/60:.1f}m)")
    print(f"  Best train loss: {best_loss:.4f}")
    if valid_examples:
        print(f"  Best val loss:   {best_val_loss:.4f}")


def save_adapter(model, args, step):
    os.makedirs(args.adapter_path, exist_ok=True)
    path = os.path.join(args.adapter_path, f"{step:07d}_adapter")
    model.save_pretrained(path)
    latest = os.path.join(args.adapter_path, "latest")
    model.save_pretrained(latest)
    print(f"  Saved checkpoint at iter {step}")
    sys.stdout.flush()


def main():
    args = parse_args()
    print("=== RAIL CUDA TRAINER v3 ===")
    print(f"  Model: {args.model}")
    print(f"  Data: {args.data}")
    print(f"  Iters: {args.iters}, Batch: {args.batch_size}, LR: {args.learning_rate}")
    print(f"  LoRA: rank={args.lora_rank}, alpha={args.lora_alpha}, layers={args.num_layers}")
    print(f"  SeqLen: {args.max_seq_length}, 4bit: {args.quantize_4bit}")
    print(f"  Prompt mask: {args.mask_prompt}")
    print(f"  Max code chars: {args.max_code_chars}")
    print(f"  CUDA: {torch.cuda.get_device_name(0)}")
    print(f"  VRAM: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")
    sys.stdout.flush()

    model, tokenizer = load_model(args)
    model = apply_lora(model, args)
    train_examples, valid_examples = prepare_data(args, tokenizer)
    train(model, train_examples, valid_examples, args, tokenizer)


if __name__ == "__main__":
    main()
