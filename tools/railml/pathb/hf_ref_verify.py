#!/usr/bin/env python3
# Independent HF fp32 reference for Path-B claim (2). Loads SmolLM2-135M BASE
# in float32, feeds the EXACT prompt ids (no BOS), reports the last-position
# argmax + decoded token. No trust in any Rail-side output.
import os, sys
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL = "HuggingFaceTB/SmolLM2-135M"
PROMPT_IDS = [504, 3575, 282, 4649, 314]  # "The capital of France is", NO BOS

torch.manual_seed(0)
tok = AutoTokenizer.from_pretrained(MODEL)
model = AutoModelForCausalLM.from_pretrained(MODEL, torch_dtype=torch.float32)
model.eval()

# Sanity: re-tokenize the prompt string ourselves and compare to the ids we use.
enc = tok("The capital of France is", add_special_tokens=False)["input_ids"]
print("HF re-tokenized ids :", enc)
print("prompt ids used     :", PROMPT_IDS)
print("tokenization match  :", enc == PROMPT_IDS)

ids = torch.tensor([PROMPT_IDS], dtype=torch.long)
with torch.no_grad():
    out = model(ids)
logits = out.logits[0, -1, :].float()  # last position
argmax = int(torch.argmax(logits).item())
top5 = torch.topk(logits, 5)
print("vocab size          :", logits.shape[0])
print("HF fp32 argmax id   :", argmax)
print("HF fp32 argmax token: %r" % tok.decode([argmax]))
print("HF fp32 argmax logit: %.6f" % float(logits[argmax]))
print("top5 ids            :", [int(x) for x in top5.indices.tolist()])
print("top5 tokens         :", [tok.decode([int(x)]) for x in top5.indices.tolist()])
print("top5 logits         :", ["%.5f" % float(x) for x in top5.values.tolist()])
# Specifically report id 260 and id 0 since those are the contested tokens.
print("logit[260] (' the') :", "%.6f" % float(logits[260]), "token=%r" % tok.decode([260]))
print("logit[0] (eos)      :", "%.6f" % float(logits[0]), "token=%r" % tok.decode([0]))
print("RESULT_ARGMAX_ID=%d" % argmax)
print("RESULT_ARGMAX_TOKEN=%r" % tok.decode([argmax]))
