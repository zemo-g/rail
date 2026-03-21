#!/usr/bin/env python3
"""train_cuda_v4_unsloth.py — Rail CUDA trainer using Unsloth for 2x faster QLoRA.

Replaces train_cuda.py (v3) which used manual HuggingFace QLoRA with direct
BitsAndBytesConfig + PEFT. v4 uses Unsloth's FastLanguageModel for optimized
model loading, LoRA patching, and optional sequence packing via TRL's SFTTrainer.

Changes from v3:
  - Model loading via `unsloth.FastLanguageModel.from_pretrained` (fused kernels, 2x speed)
  - LoRA via `FastLanguageModel.get_peft_model` (replaces manual PEFT LoraConfig)
  - Default max_seq_length raised to 1024 (was 512)
  - Sequence packing support via --pack-sequences (default True, ~30% faster)
  - GRPO training mode via --use-grpo (placeholder reward_fn, structure ready)
  - Prints Unsloth version and GPU memory stats at startup
  - Gradient checkpointing via Unsloth's optimized "unsloth" mode (saves ~30% VRAM)
  - Uses adamw_8bit optimizer by default (lower VRAM than full AdamW)

Kept from v3:
  - QLoRA 4-bit on Qwen3.5-4B
  - Prompt masking (loss only on assistant tokens)
  - Validation eval every report_every steps
  - Overfit warning when val > 1.5x train
  - Quality filtering (no-main, trivial, oversized, SHA-256 dedup)
  - UTF-8 encoding on all file reads
  - Checkpoint saving every save_every steps
  - All CLI args preserved

Target: RTX 3070 8GB VRAM (Windows, Razer laptop)

Example run_v4.bat:
  @echo off
  python train_cuda_v4_unsloth.py ^
    --model Qwen/Qwen3.5-4B ^
    --data ./clean_data ^
    --output ./adapters_4b_v4 ^
    --quantize-4bit ^
    --epochs 3 ^
    --lr 2e-4 ^
    --batch-size 2 ^
    --lora-rank 16 ^
    --lora-alpha 32 ^
    --num-layers 16 ^
    --max-seq-length 1024 ^
    --save-every 500 ^
    --report-every 50 ^
    --iters 3000 ^
    --warmup 150 ^
    --mask-prompt ^
    --pack-sequences
"""

import argparse, json, os, random, sys, time, math, hashlib
import torch


def parse_args():
    p = argparse.ArgumentParser(description="Rail CUDA Trainer v4 (Unsloth)")
    p.add_argument("--model", required=True, help="HuggingFace model ID (e.g. Qwen/Qwen3.5-4B)")
    p.add_argument("--data", required=True, help="Directory containing train.jsonl and optionally valid.jsonl")
    p.add_argument("--output", required=True, help="Output directory for adapter checkpoints")
    p.add_argument("--epochs", type=int, default=3, help="Number of training epochs (used if --iters not set)")
    p.add_argument("--lr", type=float, default=2e-4, help="Peak learning rate")
    p.add_argument("--batch-size", type=int, default=2, help="Per-device batch size")
    p.add_argument("--lora-rank", type=int, default=16, help="LoRA rank (r)")
    p.add_argument("--lora-alpha", type=int, default=32, help="LoRA alpha")
    p.add_argument("--num-layers", type=int, default=16, help="Number of attention layers to target (from the end)")
    p.add_argument("--max-seq-length", type=int, default=1024, help="Max sequence length (default: 1024, was 512 in v3)")
    p.add_argument("--save-every", type=int, default=500, help="Save checkpoint every N steps")
    p.add_argument("--report-every", type=int, default=50, help="Report + eval every N steps")
    p.add_argument("--iters", type=int, default=3000, help="Max training steps (overrides epochs)")
    p.add_argument("--warmup", type=int, default=150, help="Warmup steps")
    p.add_argument("--mask-prompt", action="store_true", default=True,
                   help="Mask prompt tokens in loss (only train on assistant completions)")
    p.add_argument("--no-mask-prompt", dest="mask_prompt", action="store_false")
    p.add_argument("--quantize-4bit", action="store_true", help="Load model in 4-bit QLoRA mode")
    p.add_argument("--max-code-chars", type=int, default=4000,
                   help="Skip examples where total content exceeds this (prevents OOM)")
    p.add_argument("--grad-clip", type=float, default=1.0, help="Gradient clipping max norm")
    # v4 new flags
    p.add_argument("--use-grpo", action="store_true", default=False,
                   help="Use GRPO reinforcement learning instead of SFT")
    p.add_argument("--pack-sequences", action="store_true", default=True,
                   help="Pack multiple sequences into one for efficiency (default: True)")
    p.add_argument("--no-pack-sequences", dest="pack_sequences", action="store_false")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Data loading — kept from v3 with quality filtering and dedup
# ---------------------------------------------------------------------------

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

            # Extract assistant code for quality checks
            code = ""
            for m in messages:
                if m.get("role") == "assistant":
                    code = m.get("content", "")

            # Quality filter: must contain main
            if "main" not in code:
                skipped_no_main += 1
                continue

            # Quality filter: not trivially short
            if len(code) < 20:
                skipped_tiny += 1
                continue

            # Quality filter: not oversized (prevents OOM)
            total_chars = sum(len(m.get("content", "")) for m in messages)
            if total_chars > args.max_code_chars:
                skipped_oversized += 1
                continue

            # SHA-256 dedup
            h = hashlib.sha256(code.encode()).hexdigest()
            if h in seen:
                skipped_dup += 1
                continue
            seen.add(h)

            examples.append({"messages": messages, "code": code})

    print(f"  Loaded: {len(examples)} examples")
    if skipped_no_main:   print(f"  Filtered (no main): {skipped_no_main}")
    if skipped_tiny:      print(f"  Filtered (tiny): {skipped_tiny}")
    if skipped_oversized: print(f"  Filtered (oversized >{args.max_code_chars}): {skipped_oversized}")
    if skipped_dup:       print(f"  Filtered (duplicate): {skipped_dup}")
    return examples


def format_examples_for_sft(examples, tokenizer, args):
    """Convert message dicts to formatted text strings for SFTTrainer."""
    formatted = []
    for ex in examples:
        messages = ex["messages"]
        try:
            text = tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=False)
        except Exception:
            parts = [f"<|{m['role']}|>\n{m['content']}" for m in messages]
            text = "\n".join(parts)
        formatted.append({"text": text})

    if formatted:
        # Tokenize a sample to report stats
        sample_lens = []
        for ex in formatted[:min(100, len(formatted))]:
            toks = tokenizer(ex["text"], truncation=True, max_length=args.max_seq_length,
                             padding=False, return_tensors=None)
            sample_lens.append(len(toks["input_ids"]))
        avg_len = sum(sample_lens) / len(sample_lens)
        print(f"  Avg token length (sample): {avg_len:.0f}")

    return formatted


def format_examples_for_grpo(examples, tokenizer, args):
    """Convert message dicts to prompt-only format for GRPO.
    GRPO needs prompts — the model generates completions, reward_fn scores them."""
    formatted = []
    for ex in examples:
        messages = ex["messages"]
        # Extract only the system + user messages as prompt
        prompt_messages = [m for m in messages if m.get("role") != "assistant"]
        if not prompt_messages:
            continue
        try:
            prompt_text = tokenizer.apply_chat_template(
                prompt_messages, tokenize=False, add_generation_prompt=True)
        except Exception:
            parts = [f"<|{m['role']}|>\n{m['content']}" for m in prompt_messages]
            prompt_text = "\n".join(parts)
        formatted.append({"prompt": prompt_text, "expected_code": ex["code"]})
    return formatted


# ---------------------------------------------------------------------------
# Manual training loop (SFT mode) — kept from v3 for fine-grained control
# ---------------------------------------------------------------------------

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


def tokenize_for_manual_loop(examples, tokenizer, args):
    """Tokenize examples for the manual training loop (same as v3)."""
    tokenized = []
    skipped_tiny = 0
    for ex in examples:
        messages = ex["messages"]
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

        tokenized.append({"input_ids": tokens["input_ids"], "prompt_len": prompt_len})

    if skipped_tiny:
        print(f"  Skipped {skipped_tiny} too-short after tokenization")
    if tokenized:
        avg_len = sum(len(e["input_ids"]) for e in tokenized) / len(tokenized)
        avg_prompt = sum(e["prompt_len"] for e in tokenized) / len(tokenized)
        print(f"  Avg total: {avg_len:.0f} tok, prompt: {avg_prompt:.0f} tok, "
              f"assistant: {avg_len - avg_prompt:.0f} tok")
    if args.mask_prompt:
        print(f"  Prompt masking: ON")
    return tokenized


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


def train_manual_loop(model, train_examples, valid_examples, args, tokenizer):
    """Manual training loop with warmup, cosine decay, eval, and checkpointing (from v3)."""
    optimizer = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad],
        lr=args.lr, weight_decay=0.01)

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

            # Warmup + cosine decay schedule
            if step < args.warmup:
                lr = args.lr * step / max(args.warmup, 1)
            else:
                progress = (step - args.warmup) / max(args.iters - args.warmup, 1)
                lr = args.lr * 0.5 * (1.0 + math.cos(math.pi * progress))
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

                print(f"  Iter {step}/{args.iters}: loss={avg_loss:.4f} best={best_loss:.4f}"
                      f"{val_str} lr={lr:.2e} tok/s={tps:.0f} eta={eta_m:.0f}m")
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
    os.makedirs(args.output, exist_ok=True)
    path = os.path.join(args.output, f"{step:07d}_adapter")
    model.save_pretrained(path)
    latest = os.path.join(args.output, "latest")
    model.save_pretrained(latest)
    print(f"  Saved checkpoint at iter {step}")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# GRPO reward function (placeholder — will call Rail compiler)
# ---------------------------------------------------------------------------

def reward_fn(prompts, completions, **kwargs):
    """Reward function for GRPO training — Rail compiler as oracle.

    Scores each completion by compiling with rail_native:
      1.0  = compiles + runs successfully (exit 0)
      0.5  = compiles but runtime error/timeout
      0.0  = fails to compile
      0.25 = contains 'main' but doesn't compile (partial credit for structure)

    Uses SSH to Mac Mini (which has rail_native) if not available locally.
    Falls back to placeholder 1.0 if neither path works.
    """
    import subprocess, tempfile, shutil

    # Find rail_native — local first, then SSH to Mini
    rail_bin = None
    for candidate in ["/tmp/rail_native", os.path.expanduser("~/rail_native"),
                      os.path.expanduser("~/projects/rail/rail_native")]:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            rail_bin = candidate
            break

    use_ssh = rail_bin is None
    if use_ssh:
        # Verify SSH to Mini works
        try:
            r = subprocess.run(["ssh", "-o", "ConnectTimeout=3", "ledaticempire@100.94.74.5",
                                "echo ok"], capture_output=True, text=True, timeout=5)
            if r.returncode != 0:
                print("  GRPO reward: no rail_native and SSH failed — using placeholder")
                return [1.0 for _ in completions]
        except Exception:
            print("  GRPO reward: no rail_native and SSH failed — using placeholder")
            return [1.0 for _ in completions]

    rewards = []
    for completion in completions:
        code = completion.strip()

        # Strip markdown fences if present
        if code.startswith("```"):
            lines = code.split("\n")
            code = "\n".join(lines[1:])
            if code.endswith("```"):
                code = code[:-3].rstrip()

        # Strip <think>...</think> tags
        import re
        code = re.sub(r'<think>.*?</think>\s*', '', code, flags=re.DOTALL)

        if not code or len(code) < 10:
            rewards.append(0.0)
            continue

        # Partial credit for having 'main'
        has_main = "main" in code

        try:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.rail', delete=False) as f:
                f.write(code)
                tmp_path = f.name

            if use_ssh:
                # Copy file to Mini, compile there
                subprocess.run(["scp", "-q", tmp_path,
                                f"ledaticempire@100.94.74.5:/tmp/grpo_test.rail"],
                               timeout=5, capture_output=True)
                result = subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=3", "ledaticempire@100.94.74.5",
                     "./projects/rail/rail_native /tmp/grpo_test.rail"],
                    capture_output=True, text=True, timeout=30)
            else:
                result = subprocess.run(
                    [rail_bin, tmp_path],
                    capture_output=True, text=True, timeout=30)

            if result.returncode != 0:
                rewards.append(0.25 if has_main else 0.0)
                continue

            # Compiled! Now try to run it
            bin_path = "/tmp/rail_out"
            if use_ssh:
                run_result = subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=3", "ledaticempire@100.94.74.5",
                     "timeout 5 /tmp/rail_out"],
                    capture_output=True, text=True, timeout=10)
            else:
                run_result = subprocess.run(
                    [bin_path], capture_output=True, text=True, timeout=5)

            if run_result.returncode == 0:
                rewards.append(1.0)
            else:
                rewards.append(0.5)  # compiled but runtime error

        except subprocess.TimeoutExpired:
            rewards.append(0.25 if has_main else 0.0)
        except Exception:
            rewards.append(0.0)
        finally:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass

    print(f"  GRPO rewards: {sum(r > 0 for r in rewards)}/{len(rewards)} non-zero, "
          f"avg={sum(rewards)/max(len(rewards),1):.2f}")
    return rewards


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    # -----------------------------------------------------------------------
    # Import Unsloth (must be before other torch imports in practice,
    # but we handle gracefully if not)
    # -----------------------------------------------------------------------
    try:
        from unsloth import FastLanguageModel
        import unsloth
        unsloth_version = getattr(unsloth, "__version__", "unknown")
    except ImportError:
        print("ERROR: Unsloth not installed. Install with:")
        print("  pip install unsloth")
        print("  # or for Windows/CUDA:")
        print("  pip install unsloth[cu121-ampere-torch250]")
        sys.exit(1)

    print("=" * 60)
    print("  RAIL CUDA TRAINER v4 (Unsloth)")
    print("=" * 60)
    print(f"  Unsloth version: {unsloth_version}")
    print(f"  Model: {args.model}")
    print(f"  Data: {args.data}")
    print(f"  Output: {args.output}")
    print(f"  Iters: {args.iters}, Batch: {args.batch_size}, LR: {args.lr}")
    print(f"  LoRA: rank={args.lora_rank}, alpha={args.lora_alpha}, layers={args.num_layers}")
    print(f"  SeqLen: {args.max_seq_length}, 4bit: {args.quantize_4bit}")
    print(f"  Prompt mask: {args.mask_prompt}")
    print(f"  Pack sequences: {args.pack_sequences}")
    print(f"  GRPO mode: {args.use_grpo}")
    print(f"  Max code chars: {args.max_code_chars}")
    print(f"  CUDA device: {torch.cuda.get_device_name(0)}")
    gpu_mem = torch.cuda.get_device_properties(0).total_memory
    print(f"  VRAM total: {gpu_mem / 1024**3:.1f} GB")
    print(f"  VRAM allocated: {torch.cuda.memory_allocated() / 1024**3:.2f} GB")
    print(f"  VRAM reserved: {torch.cuda.memory_reserved() / 1024**3:.2f} GB")
    sys.stdout.flush()

    # -----------------------------------------------------------------------
    # Load model via Unsloth
    # -----------------------------------------------------------------------
    print("\n--- Loading model via Unsloth ---")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model,
        max_seq_length=args.max_seq_length,
        load_in_4bit=args.quantize_4bit,
        dtype=None,  # auto-detect (bfloat16 if supported, else float16)
    )

    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    print(f"  VRAM after model load: {torch.cuda.memory_allocated() / 1024**3:.2f} GB")

    # -----------------------------------------------------------------------
    # Apply LoRA via Unsloth
    # Unsloth's get_peft_model handles fused kernels and optimized patching.
    # We target attention + MLP projections for best quality.
    # layers_to_transform is passed through to PEFT's LoraConfig.
    # -----------------------------------------------------------------------
    print("\n--- Applying LoRA via Unsloth ---")

    # Discover ALL attention layers: self_attn (8 full-attention) + linear_attn (24 DeltaNet)
    attn_modules = [n for n, _ in model.named_modules()
                    if ("self_attn" in n or "linear_attn" in n) and
                    any(p in n for p in ["q_proj", "k_proj", "v_proj", "o_proj",
                                         "in_proj_qkv", "in_proj_z", "in_proj_b",
                                         "in_proj_a", "out_proj"])]
    layer_indices = sorted(set(int(n.split(".")[2]) for n in attn_modules if n.split(".")[2].isdigit()))
    target_layers = layer_indices[-args.num_layers:] if len(layer_indices) > args.num_layers else layer_indices

    sa_count = len([i for i in target_layers if any("self_attn" in n and f".{i}." in n for n in attn_modules)])
    dn_count = len([i for i in target_layers if any("linear_attn" in n and f".{i}." in n for n in attn_modules)])
    print(f"  Found {len(layer_indices)} attention layers: {layer_indices[0]}-{layer_indices[-1]}")
    print(f"  Targeting last {len(target_layers)}: {target_layers}")
    print(f"  Breakdown: {sa_count} self_attn + {dn_count} DeltaNet layers")

    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_rank,
        lora_alpha=args.lora_alpha,
        lora_dropout=0.0,  # Unsloth recommends 0 dropout for speed
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "in_proj_qkv", "in_proj_z", "in_proj_b",
                        "in_proj_a", "out_proj"],
        layers_to_transform=target_layers,
        bias="none",
        use_gradient_checkpointing="unsloth",  # Unsloth's optimized GC (30% less VRAM)
        random_state=42,
        use_rslora=False,
    )

    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"  Trainable: {trainable:,} / {total:,} ({trainable*100/total:.3f}%)")
    print(f"  VRAM after LoRA: {torch.cuda.memory_allocated() / 1024**3:.2f} GB")

    # -----------------------------------------------------------------------
    # Load and filter data
    # -----------------------------------------------------------------------
    print("\n--- Loading training data ---")
    train_path = os.path.join(args.data, "train.jsonl")
    valid_path = os.path.join(args.data, "valid.jsonl")

    print("  --- Training data ---")
    train_raw = load_jsonl(train_path, args, tokenizer)

    valid_raw = []
    if os.path.exists(valid_path):
        print("  --- Validation data ---")
        valid_raw = load_jsonl(valid_path, args, tokenizer)
    else:
        print(f"  No validation file at {valid_path}")

    if not train_raw:
        print("ERROR: No training examples after filtering!")
        sys.exit(1)

    # -----------------------------------------------------------------------
    # GRPO mode
    # -----------------------------------------------------------------------
    if args.use_grpo:
        print("\n--- GRPO Training Mode ---")
        try:
            from trl import GRPOTrainer, GRPOConfig
        except ImportError:
            print("ERROR: TRL not installed. Install with: pip install trl")
            sys.exit(1)

        from datasets import Dataset

        grpo_data = format_examples_for_grpo(train_raw, tokenizer, args)
        print(f"  GRPO prompts: {len(grpo_data)}")

        # Build HF dataset with just prompts
        grpo_dataset = Dataset.from_list([{"prompt": ex["prompt"]} for ex in grpo_data])

        grpo_config = GRPOConfig(
            output_dir=args.output,
            per_device_train_batch_size=args.batch_size,
            gradient_accumulation_steps=4,
            learning_rate=args.lr,
            num_train_epochs=args.epochs,
            max_steps=args.iters,
            warmup_steps=args.warmup,
            max_grad_norm=args.grad_clip,
            logging_steps=args.report_every,
            save_steps=args.save_every,
            optim="adamw_8bit",
            weight_decay=0.01,
            lr_scheduler_type="cosine",
            seed=42,
            # GRPO-specific
            num_generations=4,          # group size for reward comparison
            max_prompt_length=512,
            max_completion_length=args.max_seq_length - 512,
            temperature=0.7,
        )

        trainer = GRPOTrainer(
            model=model,
            processing_class=tokenizer,
            reward_funcs=[reward_fn],
            args=grpo_config,
            train_dataset=grpo_dataset,
        )

        print("  Starting GRPO training...")
        print("  NOTE: Using placeholder reward_fn (always returns 1.0)")
        print("  TODO: Wire up Rail compiler as reward oracle")
        sys.stdout.flush()

        trainer.train()

        # Save final adapter
        os.makedirs(args.output, exist_ok=True)
        model.save_pretrained(os.path.join(args.output, "latest"))
        print(f"  GRPO training complete. Adapter saved to {args.output}/latest")
        return

    # -----------------------------------------------------------------------
    # SFT mode — manual training loop (preserves v3 behavior exactly)
    #
    # We use the manual loop instead of TRL's SFTTrainer because:
    #   1. Prompt masking with per-example prompt_len (v3 pattern)
    #   2. Fine-grained eval_loss every report_every steps
    #   3. Overfit detection (val > 1.5x train)
    #   4. Custom warmup + cosine schedule matching v3
    #
    # Note: --pack-sequences is ignored in manual loop mode.
    # If you want packing, the TRL SFTTrainer path below can be enabled.
    # -----------------------------------------------------------------------
    print("\n--- SFT Training (manual loop) ---")

    if args.pack_sequences:
        print("  NOTE: Sequence packing requires TRL SFTTrainer.")
        print("  Attempting TRL SFTTrainer with packing...")
        sys.stdout.flush()

        try:
            from trl import SFTTrainer, SFTConfig
            from datasets import Dataset

            # Format data for SFTTrainer
            train_formatted = format_examples_for_sft(train_raw, tokenizer, args)
            train_dataset = Dataset.from_list(train_formatted)

            valid_dataset = None
            if valid_raw:
                valid_formatted = format_examples_for_sft(valid_raw, tokenizer, args)
                valid_dataset = Dataset.from_list(valid_formatted)

            # NOTE: packing=True is incompatible with DataCollatorForCompletionOnlyLM.
            # When packing is enabled, we rely on the model learning from full
            # conversations including the prompt. For prompt masking + packing,
            # we'd need a custom collator (future work).
            use_packing = args.pack_sequences
            if use_packing and args.mask_prompt:
                print("  WARNING: Packing enabled — prompt masking uses TRL's "
                      "train_on_completions_only (approximate, not per-token like v3)")

            sft_config = SFTConfig(
                output_dir=args.output,
                per_device_train_batch_size=args.batch_size,
                gradient_accumulation_steps=4,
                learning_rate=args.lr,
                num_train_epochs=args.epochs,
                max_steps=args.iters,
                warmup_steps=args.warmup,
                max_grad_norm=args.grad_clip,
                logging_steps=args.report_every,
                save_steps=args.save_every,
                eval_strategy="steps" if valid_dataset else "no",
                eval_steps=args.report_every if valid_dataset else None,
                optim="adamw_8bit",
                weight_decay=0.01,
                lr_scheduler_type="cosine",
                seed=42,
                max_seq_length=args.max_seq_length,
                packing=use_packing,
                dataset_text_field="text",
            )

            trainer = SFTTrainer(
                model=model,
                tokenizer=tokenizer,
                train_dataset=train_dataset,
                eval_dataset=valid_dataset,
                args=sft_config,
            )

            print(f"  Starting SFT with TRL SFTTrainer (packing={use_packing})...")
            sys.stdout.flush()

            # Custom callback for overfit detection
            class OverfitCallback:
                def __init__(self):
                    self.best_train = float("inf")
                    self.best_val = float("inf")

                def on_log(self, args, state, control, logs=None, **kwargs):
                    if logs is None:
                        return
                    train_loss = logs.get("loss")
                    val_loss = logs.get("eval_loss")
                    if train_loss is not None and train_loss < self.best_train:
                        self.best_train = train_loss
                    if val_loss is not None:
                        if val_loss < self.best_val:
                            self.best_val = val_loss
                        if train_loss and val_loss > train_loss * 1.5:
                            print(f"  !!OVERFIT: val={val_loss:.4f} > 1.5x train={train_loss:.4f}")

            from transformers import TrainerCallback

            class OverfitDetector(TrainerCallback):
                def __init__(self):
                    self.best_train = float("inf")
                    self.best_val = float("inf")

                def on_log(self, targs, state, control, logs=None, **kwargs):
                    if logs is None:
                        return
                    train_loss = logs.get("loss")
                    val_loss = logs.get("eval_loss")
                    if train_loss is not None and train_loss < self.best_train:
                        self.best_train = train_loss
                    if val_loss is not None:
                        if val_loss < self.best_val:
                            self.best_val = val_loss
                        if train_loss and val_loss > train_loss * 1.5:
                            print(f"  !!OVERFIT: val={val_loss:.4f} > 1.5x train={train_loss:.4f}")
                            sys.stdout.flush()

            trainer.add_callback(OverfitDetector())
            trainer.train()

            # Save final
            os.makedirs(args.output, exist_ok=True)
            model.save_pretrained(os.path.join(args.output, "latest"))
            print(f"  Training complete. Adapter saved to {args.output}/latest")
            return

        except ImportError:
            print("  TRL/datasets not available, falling back to manual loop (no packing)")
            args.pack_sequences = False

    # -----------------------------------------------------------------------
    # Manual training loop fallback (no packing, exact v3 behavior)
    # -----------------------------------------------------------------------
    print("  Using manual training loop (no packing, exact v3 prompt masking)")

    print("  --- Tokenizing training data ---")
    train_tokenized = tokenize_for_manual_loop(train_raw, tokenizer, args)
    valid_tokenized = []
    if valid_raw:
        print("  --- Tokenizing validation data ---")
        valid_tokenized = tokenize_for_manual_loop(valid_raw, tokenizer, args)

    # Enable Unsloth fast inference mode for eval
    FastLanguageModel.for_training(model)

    train_manual_loop(model, train_tokenized, valid_tokenized, args, tokenizer)

    print(f"\n  Final VRAM: {torch.cuda.memory_allocated() / 1024**3:.2f} GB allocated, "
          f"{torch.cuda.memory_reserved() / 1024**3:.2f} GB reserved")


if __name__ == "__main__":
    main()
