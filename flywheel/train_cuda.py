#!/usr/bin/env python3
"""train_cuda.py - LoRA training for Rail models on CUDA.
Same JSONL format as MLX training. Drop-in replacement for mlx_lm lora.

Usage:
  python train_cuda.py --model Qwen/Qwen3.5-4B --data ./data --adapter-path ./adapters_4b
  python train_cuda.py --model Qwen/Qwen3.5-2B --data ./data --adapter-path ./adapters_2b
"""

import argparse, json, os, random, sys, time
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, TaskType


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True, help="HuggingFace model ID or local path")
    p.add_argument("--data", required=True, help="Directory with train.jsonl, valid.jsonl")
    p.add_argument("--adapter-path", required=True, help="Where to save LoRA adapter")
    p.add_argument("--iters", type=int, default=2000)
    p.add_argument("--batch-size", type=int, default=1)
    p.add_argument("--learning-rate", type=float, default=1e-5)
    p.add_argument("--lora-rank", type=int, default=8)
    p.add_argument("--lora-alpha", type=int, default=16)
    p.add_argument("--num-layers", type=int, default=16)
    p.add_argument("--max-seq-length", type=int, default=1024)
    p.add_argument("--save-every", type=int, default=250)
    p.add_argument("--report-every", type=int, default=50)
    p.add_argument("--quantize-4bit", action="store_true", help="Use 4-bit QLoRA")
    p.add_argument("--gradient-checkpointing", action="store_true")
    p.add_argument("--resume", action="store_true", help="Resume from latest checkpoint")
    p.add_argument("--warmup-steps", type=int, default=100, help="LR warmup steps")
    p.add_argument("--grad-clip", type=float, default=1.0, help="Gradient clipping max norm")
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
    all_layers = [n for n, _ in model.named_modules()
                  if "self_attn" in n and any(p in n for p in ["q_proj", "k_proj", "v_proj", "o_proj"])]
    layer_indices = sorted(set(int(n.split(".")[2]) for n in all_layers if n.split(".")[2].isdigit()))
    target_layers = layer_indices[-args.num_layers:] if len(layer_indices) > args.num_layers else layer_indices

    config = LoraConfig(
        r=args.lora_rank, lora_alpha=args.lora_alpha, lora_dropout=0.05,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
        layers_to_transform=target_layers,
        task_type=TaskType.CAUSAL_LM)

    model = get_peft_model(model, config)
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"  Trainable: {trainable:,} / {total:,} ({trainable*100/total:.3f}%)")
    print(f"  Target layers: {target_layers[0]}-{target_layers[-1]} ({len(target_layers)} layers)")
    return model


def prepare_data(args, tokenizer):
    train_path = os.path.join(args.data, "train.jsonl")
    examples = []
    skipped = 0
    with open(train_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            messages = obj.get("messages", [])
            try:
                text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
            except Exception:
                parts = []
                for m in messages:
                    parts.append(f"<|{m['role']}|>\n{m['content']}")
                text = "\n".join(parts)

            tokens = tokenizer(text, truncation=True, max_length=args.max_seq_length,
                             padding=False, return_tensors=None)
            if len(tokens["input_ids"]) > 10:
                examples.append(tokens)
            else:
                skipped += 1

    print(f"  Training examples: {len(examples)} (skipped {skipped} tiny)")
    avg_len = sum(len(e["input_ids"]) for e in examples) / max(len(examples), 1)
    print(f"  Avg sequence length: {avg_len:.0f} tokens")
    return examples


def collate_fn(batch, pad_id):
    max_len = max(len(b["input_ids"]) for b in batch)
    input_ids, attention_mask, labels = [], [], []
    for b in batch:
        ids = b["input_ids"]
        pad_len = max_len - len(ids)
        input_ids.append(ids + [pad_id] * pad_len)
        attention_mask.append([1] * len(ids) + [0] * pad_len)
        labels.append(ids + [-100] * pad_len)
    return {
        "input_ids": torch.tensor(input_ids, dtype=torch.long),
        "attention_mask": torch.tensor(attention_mask, dtype=torch.long),
        "labels": torch.tensor(labels, dtype=torch.long),
    }


def get_lr(step, warmup_steps, base_lr, total_steps):
    """Linear warmup then cosine decay."""
    if step < warmup_steps:
        return base_lr * step / max(warmup_steps, 1)
    progress = (step - warmup_steps) / max(total_steps - warmup_steps, 1)
    import math
    return base_lr * 0.5 * (1.0 + math.cos(math.pi * progress))


def train(model, examples, args, tokenizer):
    optimizer = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad],
        lr=args.learning_rate, weight_decay=0.01)

    model.train()
    pad_id = tokenizer.pad_token_id or 0
    start = time.time()
    total_loss = 0
    total_tokens = 0
    step = 0
    best_loss = float("inf")

    while step < args.iters:
        random.shuffle(examples)

        for i in range(0, len(examples), args.batch_size):
            if step >= args.iters:
                break

            # LR schedule
            lr = get_lr(step, args.warmup_steps, args.learning_rate, args.iters)
            for pg in optimizer.param_groups:
                pg["lr"] = lr

            batch = examples[i:i+args.batch_size]
            inputs = collate_fn(batch, pad_id)
            inputs = {k: v.to(model.device) for k, v in inputs.items()}

            outputs = model(**inputs)
            loss = outputs.loss
            loss.backward()

            # Gradient clipping
            torch.nn.utils.clip_grad_norm_(
                [p for p in model.parameters() if p.requires_grad],
                args.grad_clip)

            optimizer.step()
            optimizer.zero_grad()

            loss_val = loss.item()
            total_loss += loss_val
            total_tokens += inputs["attention_mask"].sum().item()
            step += 1

            if step % args.report_every == 0:
                elapsed = time.time() - start
                avg_loss = total_loss / args.report_every
                tps = total_tokens / elapsed
                eta_s = (args.iters - step) * (elapsed / step)
                eta_m = eta_s / 60
                if avg_loss < best_loss:
                    best_loss = avg_loss
                print(f"  Iter {step}/{args.iters}: loss={avg_loss:.4f} best={best_loss:.4f} lr={lr:.2e} tok/s={tps:.0f} eta={eta_m:.0f}m")
                sys.stdout.flush()
                total_loss = 0

            if step % args.save_every == 0:
                save_adapter(model, args, step)

    save_adapter(model, args, step)
    elapsed = time.time() - start
    print(f"  Done. {step} iters in {elapsed:.0f}s ({elapsed/60:.1f}m)")
    print(f"  Best loss: {best_loss:.4f}")


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
    print("=== RAIL CUDA TRAINER ===")
    print(f"  Model: {args.model}")
    print(f"  Data: {args.data}")
    print(f"  Iters: {args.iters}, LR: {args.learning_rate}")
    print(f"  LoRA: rank={args.lora_rank}, alpha={args.lora_alpha}, layers={args.num_layers}")
    print(f"  4bit: {args.quantize_4bit}, GradCkpt: {args.gradient_checkpointing}")
    print(f"  Warmup: {args.warmup_steps}, GradClip: {args.grad_clip}")
    print(f"  CUDA: {torch.cuda.get_device_name(0)}")
    print(f"  VRAM: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")

    model, tokenizer = load_model(args)
    model = apply_lora(model, args)
    examples = prepare_data(args, tokenizer)
    train(model, examples, args, tokenizer)


if __name__ == "__main__":
    main()
