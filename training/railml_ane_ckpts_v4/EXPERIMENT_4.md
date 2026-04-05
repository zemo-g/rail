# Experiment 4: Right-Sized ANE Training

## Config
- Model: custom:256,1024,2,512 (4.2M params)
- Data: BPE tokenized Rail (417K train, 46K val tokens)
- LR: 5e-4, grad_clip: 1.0, loss_scale: default
- Hardware: M4 Pro ANE, 0.15s/step

## Results
- Steps: 10,025 (NaN at 10,025, checkpoint at 10,000)
- Best val loss: 2.83
- Best train loss: 1.70
- Time: 25 minutes
- Gnorm: settled 6-16, spike to 288→386→NaN at step 10K

## Val Curve
- step 0:     9.01
- step 1000:  2.90
- step 2000:  2.85
- step 3000:  2.83 (best)

## Scaling Notes
- 4.2M params on 417K tokens = 10x overparameterized (still high)
- Gnorm spikes are the recurring failure mode across ALL experiments
- Lower LR extends stability but caps learning
- The 10K checkpoint is the best model — use for inference testing

## To Scale Up
1. More data: tokenize ALL 10.8K harvest programs (currently using 9K)
2. Add golden examples (28 bench-targeted programs)
3. Add real_programs.jsonl (1155 programs) + train.jsonl (244 programs)
4. Target: 1M+ BPE tokens → model is NOT overparameterized
5. Then scale model: custom:512,2048,4,512 (~20M params) matched to data

## Checkpoint Format
- RSTK binary: 4-byte magic + config + f32 weights
- File: ckpt_010000.bin (16MB)
- Load with: tools/railml/ane_inference.py
