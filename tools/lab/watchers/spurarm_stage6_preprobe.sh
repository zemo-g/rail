#!/bin/sh
# tools/lab/watchers/spurarm_stage6_preprobe.sh
#
# Stage 6 pre-probe: log p(EOS) and argmax across positions on a v1
# Spur-arm checkpoint. Decides routing among Caps D/E/F per the
# Stage 6 readiness plan rubric.
#
# Run on Studio 2026-05-17 against:
#   - seed314 pretrain (chosen because Stage 5 named it as the v1
#     bench champion at 3/20 argmax)
#   - seed42 SFT       (current spurarm-base-v0_best target)
#
# Smoke harness: tools/spurarm/train/probe_eos.rail
#
# RESULTS (12-step decode, prompt = "Move the arm to point A."):
#
#   seed314 pretrain:
#     step 0  top_id=2   (EOS)  top_p=0.176  p(EOS)=0.176
#     step 1  top_id=66  ("rip") top_p=0.281  p(EOS)=0.015
#     step 2  top_id=148 (" 20")
#     step 3  top_id=103 ("script = [")
#     step 4..6 top_id=63  (newline+indent — cycle)
#     step 7  top_id=103 ("script = [")
#     step 8  top_id=2   (EOS) — second EOS hit
#     step 9-11 top_id=7 (single space — cycle)
#     max p(EOS) over 12 steps: 0.176
#
#   seed42 SFT:
#     step 0  top_id=155 ("MoveTo") top_p=0.135  p(EOS)=0.042
#     step 1  top_id=148 (" 20")
#     step 2-4 top_id=66 ("rip" — cycle)
#     step 5  top_id=7  (space)
#     max p(EOS) over 12 steps: 0.048
#
# Cap routing per readiness plan:
#   "EOS never in argmax       -> Cap E first" -- not us
#   "EOS appears, argmax cycles -> Cap F first" -- matches seed314
#   "Output fine, bench fails   -> Cap D first" -- not us
#   "Inconclusive               -> Cap F"      -- safe default
#
# Cap E FALSIFIED inline: the model has EOS supervision (emits EOS as
# top-1 argmax with p=0.18 at step 0 on the pretrain ckpt). The
# missing-EOS-supervision hypothesis is wrong.
#
# Routing -> Cap F decoding regularization first (chained separately).

cat <<'EOT'
=== Spur-arm Stage 6 pre-probe summary ===

Probe: tools/spurarm/train/probe_eos.rail
Prompt: "Move the arm to point A."
Max steps: 12

seed314 pretrain (Stage 5 v1 champion at 3/20 argmax):
  step 0  top_id=2 (EOS)        top_p=0.176  p(EOS)=0.176
  step 8  top_id=2 (EOS)        top_p=0.142  p(EOS)=0.142
  max p(EOS) over 12 steps: 0.176

seed42 SFT (current spurarm-base-v0_best):
  step 0  top_id=155 (MoveTo)   top_p=0.135  p(EOS)=0.042
  step 4  top_id=66 (rip)        top_p=0.195  p(EOS)=0.048
  max p(EOS) over 12 steps: 0.048

Routing decision (per plan rubric):
  - EOS appears in argmax at step 0 on pretrain ckpt        -> Cap E FALSIFIED
  - Argmax cycles after sep token (id 7 or id 63)            -> Cap F first
  - Cap D (architecture) deferred until Cap F is closed

===RAIL_LAB_COUNTERS===
{"counter": "preprobe_seed314_step0_top_id", "value": 2}
{"counter": "preprobe_seed314_step0_top_p_x1000", "value": 176}
{"counter": "preprobe_seed42_sft_step0_top_id", "value": 155}
{"counter": "preprobe_seed42_sft_step0_top_p_x1000", "value": 135}
{"counter": "preprobe_seed42_sft_max_eos_p_x1000", "value": 48}
{"counter": "cap_e_falsified", "value": 1}
{"counter": "routed_to_cap", "value": 70}
===END===
===VERDICT=== INCONCLUSIVE
EOT
