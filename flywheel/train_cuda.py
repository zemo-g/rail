#!/usr/bin/env python3
"""train_cuda.py - LoRA training for Rail models on CUDA.
Same JSONL format as MLX training. Drop-in replacement for mlx_lm lora.

Usage:
  python train_cuda.py --model Qwen/Qwen3.5-4B --data ./data --adapter-path ./adapters_4b
  python train_cuda.py --model Qwen/Qwen2.5-1.5B-Instruct --data ./data --adapter-path ./adapters_1.5b
"""

import argparse, json, os, sys, time
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, TaskType
from datasets import load_dataset
from torch.utils.data import DataLoader

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True, help="HuggingFace model ID or local path")
    p.add_argument("--data", required=True, help="Directory with train.jsonl, valid.jsonl")
    p.add_argument("--adapter-path", required=True, help="Where to save LoRA adapter")
    p.add_argument("--iters", type=int, default=2000)
    p.add_argument("--batch-size", type=int, default=1)
    p.add_argument("--learning-rate", type=float, default=1e-5)
    p.add_argument("--lora-rank", type=int, default=8)
    p.add_argument("--lora-alpha", type=int, default=20)
    p.add_argument("--num-layers", type=int, default=16)
    p.add_argument("--max-seq-length", type=int, default=1024)
    p.add_argument("--save-every", type=int, default=250)
    p.add_argument("--report-every", type=int, default=50)
    p.add_argument("--quantize-4bit", action="store_true", help="Use 4-bit QLoRA")
    p.add_argument("--gradient-checkpointing", action="store_true")
    return p.parse_args()

def load_model(args):
    print(f"Loading {args.model}...")
    kwargs = {"trust_remote_code": True, "torch_dtype": torch.float16}
    if args.quantize_4bit:
        kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True)
        kwargs["device_map"] = "auto"
    else:
        kwargs["device_map"] = "auto"

    model = AutoModelForCausalLM.from_pretrained(args.model, **kwargs)
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    if args.gradient_checkpointing:
        model.gradient_checkpointing_enable()

    return model, tokenizer

def apply_lora(model, args):
    # Target the last N layers' attention projections
    target_modules = []
    all_layers = [n for n, _ in model.named_modules() if "self_attn" in n and any(p in n for p in ["q_proj", "k_proj", "v_proj", "o_proj"])]
    # Get unique layer indices
    layer_indices = sorted(set(int(n.split(".")[2]) for n in all_layers if n.split(".")[2].isdigit()))
    target_layers = layer_indices[-args.num_layers:] if len(layer_indices) > args.num_layers else layer_indices

    config = LoraConfig(
        r=args.lora_rank, lora_alpha=args.lora_alpha, lora_dropout=0.0,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
        layers_to_transform=target_layers,
        task_type=TaskType.CAUSAL_LM)

    model = get_peft_model(model, config)
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"  Trainable: {trainable:,} / {total:,} ({trainable*100/total:.3f}%)")
    return model

def prepare_data(args, tokenizer):
    train_path = os.path.join(args.data, "train.jsonl")
    examples = []
    with open(train_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            messages = obj.get("messages", [])
            # Build prompt using chat template or manual format
            try:
                text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
            except Exception:
                # Fallback: manual concatenation
                parts = []
                for m in messages:
                    role, content = m["role"], m["content"]
                    parts.append(f"<|{role}|>\n{content}")
                text = "\n".join(parts)

            tokens = tokenizer(text, truncation=True, max_length=args.max_seq_length,
                             padding=False, return_tensors=None)
            if len(tokens["input_ids"]) > 10:  # skip tiny examples
                examples.append(tokens)

    print(f"  Training examples: {len(examples)}")
    return examples

def collate_fn(batch, pad_id):
    max_len = max(len(b["input_ids"]) for b in batch)
    input_ids = []
    attention_mask = []
    labels = []
    for b in batch:
        ids = b["input_ids"]
        pad_len = max_len - len(ids)
        input_ids.append(ids + [pad_id] * pad_len)
        attention_mask.append([1] * len(ids) + [0] * pad_len)
        lab = ids + [-100] * pad_len
        labels.append(lab)
    return {
        "input_ids": torch.tensor(input_ids, dtype=torch.long),
        "attention_mask": torch.tensor(attention_mask, dtype=torch.long),
        "labels": torch.tensor(labels, dtype=torch.long),
    }

def train(model, examples, args, tokenizer):
    optimizer = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad],
        lr=args.learning_rate)

    model.train()
    pad_id = tokenizer.pad_token_id or 0
    start = time.time()
    total_loss = 0
    total_tokens = 0
    step = 0
    epoch = 0

    while step < args.iters:
        # Shuffle each epoch
        import random
        random.shuffle(examples)

        for i in range(0, len(examples), args.batch_size):
            if step >= args.iters:
                break

            batch = examples[i:i+args.batch_size]
            inputs = collate_fn(batch, pad_id)
            inputs = {k: v.to(model.device) for k, v in inputs.items()}

            outputs = model(**inputs)
            loss = outputs.loss
            loss.backward()
            optimizer.step()
            optimizer.zero_grad()

            total_loss += loss.item()
            total_tokens += inputs["attention_mask"].sum().item()
            step += 1

            if step % args.report_every == 0:
                elapsed = time.time() - start
                avg_loss = total_loss / args.report_every
                tps = total_tokens / elapsed
                print(f"  Iter {step}: loss={avg_loss:.4f} tok/s={tps:.0f} elapsed={elapsed:.0f}s")
                sys.stdout.flush()
                total_loss = 0

            if step % args.save_every == 0:
                save_adapter(model, args, step)

        epoch += 1

    # Final save
    save_adapter(model, args, step)
    elapsed = time.time() - start
    print(f"  Done. {step} iters in {elapsed:.0f}s")

def save_adapter(model, args, step):
    os.makedirs(args.adapter_path, exist_ok=True)
    path = os.path.join(args.adapter_path, f"{step:07d}_adapter")
    model.save_pretrained(path)
    # Also save as "latest"
    latest = os.path.join(args.adapter_path, "latest")
    model.save_pretrained(latest)
    print(f"  Saved checkpoint at iter {step}")
    sys.stdout.flush()

def main():
    args = parse_args()
    print(f"=== RAIL CUDA TRAINER ===")
    print(f"  Model: {args.model}")
    print(f"  Data: {args.data}")
    print(f"  Iters: {args.iters}, LR: {args.learning_rate}")
    print(f"  LoRA: rank={args.lora_rank}, layers={args.num_layers}")
    print(f"  4bit: {args.quantize_4bit}, GradCkpt: {args.gradient_checkpointing}")

    model, tokenizer = load_model(args)
    model = apply_lora(model, args)
    examples = prepare_data(args, tokenizer)
    train(model, examples, args, tokenizer)

if __name__ == "__main__":
    main()
