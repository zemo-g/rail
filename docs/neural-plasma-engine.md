# Neural Plasma Engine — Session Report

**Date:** 2026-04-05/06
**Duration:** ~8 hours
**Commits:** 9 to `zemo-g/rail`
**Language:** Rail (self-hosting), C/Objective-C, Metal Shading Language

---

## Summary

Built a working pipeline that trains a neural network surrogate of an MHD plasma simulator, then renders the trained model as a real-time physics engine. Along the way, fixed a class of float register bugs in the Rail compiler.

The single-step physics is genuinely accurate. The multi-step stability is the open research question. The compiler upgrade is permanent and durable.

---

## What Was Built

### 1. 3D Metal MHD Simulator
**Files:** `tools/plasma/plasma_3d.{metal,m,rail}`

128³ grid, 8 conserved MHD variables (ρ, ρv, B, E), Lax-Friedrichs scheme on GPU compute kernels. Volume raymarcher renders three channels: density (blue), magnetic pressure |B|² (amber), current density |∇×B|² (pink). Cocoa app with orbit camera, auto-rotate, pause. One command launch via Rail.

**Status:** Works. Visible MHD shock structure in real-time.

### 2. Neural MHD Surrogates

**Linear (pure Rail):** `tools/plasma/neural_mhd.rail`
- 30 → 6 (5-cell stencil × 6 fields → next center cell)
- Analytical backprop in pure Rail
- Loss: 4.45 → 0.03 over 500 steps
- Conservation: mass error 0.027%, energy error 5×10⁻⁵
- Verified reproducible

**MLP (pure Rail):** `tools/plasma/neural_mhd_v2.rail`
- 30 → 32 (ReLU) → 6
- 1190 parameters, analytical backprop through ReLU
- Loss: 4.03 → 0.55
- Discovered several Rail float codegen workarounds in the process

**MLP (Metal GPU):** `tools/plasma/neural_mhd_gpu_host.m` + `neural_mhd_gpu.metal`
- 30 → 128 → 6
- 10 GPU kernels: tiled matmul, transposed matmuls, ReLU, MSE grad, SGD, sum_rows
- 204,800 examples from 64×64 MHD sim, 50 timesteps
- Trains in ~60 seconds (~85× faster than CPU Rail)
- Single-step mass error: 0.5% consistently
- Residual prediction + input/output normalization

**Renderer:** `tools/plasma/neural_renderer.{m,rail}`
- Loads trained weights, runs MLP forward pass per cell per frame
- 64×64 density heatmap at 30fps in a Metal window
- The neural network IS the physics engine — no PDE solver at runtime
- 0.7 output damping for autoregressive stability

### 3. Compiler Upgrade — d8 Callee-Saved Float Support
**File:** `tools/compile.rail` (3 surgical changes)

ARM64 float register d8 is now saved/restored in the prologue/epilogue of any function whose body contains float operations. This reserves a callee-saved float register that survives function calls.

The `all_params_int` guard no longer blocks self-loop optimization for functions with float operations in the body — they can now get the fast tail-call-as-loop optimization as long as their parameters are integers used in arithmetic.

**Verified:**
- Self-compile produces byte-identical fixed point
- 91/92 tests pass (the one failure is pre-existing, ffi_getenv)
- All 7 float TCO stress tests pass (`tools/plasma/float_bug_test.rail`)
- 5/5 d8-specific tests pass (`tools/plasma/d8_test.rail`)
- Inspected assembly: `str d8, [x29, #40]` in prologue, `ldr d8, ...` in epilogue
- Functions like `sum_squares_loop`, `leibniz_loop`, `geomean_loop` all get the d8 save

**What this unlocks:** Future float-heavy Rail programs (more neural net code, physics simulators, ML training loops) can use d8 as a callee-saved register without manually wrapping floats in `float_arr`. The current binary op codegen still uses the stack-push pattern (because nested float expressions would clobber d8), but the foundation for nested float register allocation is now in place.

---

## What Works (Verified by Audit)

| Component | Status | Evidence |
|---|---|---|
| Compiler self-compile | ✓ | Byte-identical fixed point |
| Compiler test suite | ✓ | 91/92 (baseline preserved) |
| Float TCO tests | ✓ | 7/7 pass |
| d8 callee-save | ✓ | Verified in generated assembly |
| Linear neural surrogate | ✓ | Loss 4.45→0.03, mass_err 0.027% |
| MLP analytical backprop (Rail) | ✓ | Loss 4.03→0.55 |
| Metal GPU training | ✓ | 60-second training, weights saved |
| 3D MHD Metal simulator | ✓ | Binary + metallib + Cocoa app |
| Neural renderer | ✓ | Real-time 30fps density heatmap |
| Neural vs LxF visualization | ✓ | Side-by-side comparison plot |

## What Doesn't Work (Honest)

**Multi-step neural simulation stability is seed-dependent.**

The trained model's behavior under autoregression depends heavily on the random weight initialization. Some training runs produce models that stay stable for 100+ steps; others diverge after 50. The 0.7 output damping helps but doesn't guarantee stability across runs.

The single-step physics is genuinely accurate (mass error well under 1% per step). The accumulated error over many steps is what produces the variability.

**Why this happens:** A neural PDE surrogate trained only on single-step prediction doesn't learn its own spectral properties. The Lax-Friedrichs operator has spectral radius exactly 1 (marginally stable). The neural model's spectral radius varies with initialization — sometimes slightly > 1 (amplifies errors) and sometimes slightly < 1 (damps).

**The proper fixes (not yet implemented):**
1. **Multi-step training (BPTT)** — train on K-step rollouts so the model learns to be stable under autoregression
2. **Spectral normalization** — explicitly constrain weight matrices to have spectral norm ≤ 1
3. **Conservation loss** — penalize global mass/energy/divergence errors during training

Any of these would likely close the stability gap. They are the natural next steps.

---

## Conservation Gap (The Research Direction)

Comparing single-step prediction:

|  | Mass Error | Energy Error |
|---|---|---|
| Lax-Friedrichs (truth) | 0 | 4×10⁻¹⁶ (machine precision) |
| Linear neural surrogate | 0.027% | 5×10⁻⁵ |
| MLP neural surrogate (CPU) | 0.39% | 0.72% |
| MLP neural surrogate (GPU) | 0.5% | 1% (varies) |

LxF preserves conservation laws by construction. Neural surrogates don't — they're trained to minimize MSE on the next state, with no explicit constraint that mass and energy be preserved.

This gap is the research question worth exploring: **can we train neural PDE surrogates that conserve physical quantities by construction?** Adding conservation penalties to the loss is one approach. Adding hard constraints via projection is another. Either approach requires the kind of self-hosted, fast-iteration, end-to-end-controllable system this session built.

---

## Rail Compiler Workarounds Discovered

These are documented as part of the audit. Some are bugs we fixed; others are constraints to work within.

| Issue | Workaround |
|---|---|
| Float division by literal in TCO loops produces wrong results | Multiply by reciprocal instead |
| Float locals don't survive across function calls in TCO | Store intermediate floats in `float_arr` |
| Memory corruption when many buffers allocated near a tight loop | Pre-allocate all buffers in main, pass via context array |
| `body_has_float` blocked self-loop optimization (FIXED) | d8 callee-saved support added |
| Loss computed in training loop reads wrong value after backward pass | Print loss BEFORE backward pass |
| Nested float binary ops would clobber d8 (UNFIXED) | Keep stack-push pattern for now; needs depth counter |

---

## What This Session Proves

1. **Rail can do real machine learning.** Linear surrogate training and MLP backprop both work in pure Rail. The CPU is slower than C, but the language is expressive enough.

2. **Rail's compiler is hackable.** A 3-line change to a 4,400-line self-hosting compiler unlocks a category of float optimizations. The compiler self-compiles and tests still pass.

3. **End-to-end physics + ML in one stack is possible.** No PyTorch, no NumPy, no Python — just Rail, ObjC bridges, and Metal kernels. The whole pipeline is one repo, one binary, no external services.

4. **The conservation gap is real and measurable.** 0.5% per step compounds. This is the right problem for the next session.

---

## Reproducing the Results

```bash
cd ~/projects/rail

# Compiler tests
./rail_native test                              # 91/92
./rail_native run tools/plasma/d8_test.rail     # 5/5
./rail_native run tools/plasma/float_bug_test.rail  # 7/7

# Pure Rail neural surrogate
./rail_native run tools/plasma/neural_mhd.rail  # ~30 sec, loss → 0.03

# Metal GPU training + renderer
./rail_native run tools/plasma/neural_mhd_gpu.rail   # ~60 sec, saves weights
./rail_native run tools/plasma/neural_renderer.rail  # opens window

# 3D Metal MHD simulator
./rail_native run tools/plasma/plasma_3d.rail        # opens 3D viewer

# Visual comparison (after training)
python3 /tmp/neural_mhd_viz.py                       # neural vs LxF frames
```

---

## Files Inventory

```
tools/plasma/
├── 3D MHD simulator
│   ├── plasma_3d.metal           Metal compute + render kernels
│   ├── plasma_3d_host.m          Cocoa Metal app
│   └── plasma_3d.rail            Build + launch
│
├── Neural surrogates (pure Rail)
│   ├── neural_mhd.rail           Linear, analytical gradients
│   └── neural_mhd_v2.rail        MLP (30→32→6), backprop
│
├── Metal GPU training
│   ├── neural_mhd_gpu.metal      10 compute kernels
│   ├── neural_mhd_gpu_host.m     ObjC training app
│   └── neural_mhd_gpu.rail       Build + launch
│
├── Neural renderer (real-time)
│   ├── neural_renderer.m         Cocoa Metal app, loads weights
│   └── neural_renderer.rail      Build + launch
│
├── Data
│   ├── mhd.rail                  2D MHD sim (Orszag-Tang)
│   └── gen_mhd_data.rail         Large dataset generator
│
├── Tests
│   ├── d8_test.rail              5 compiler tests for d8 fix
│   └── float_bug_test.rail       7 float TCO stress tests
│
└── Other
    ├── arc.rail                  Arc discharge sim
    ├── plasma_lab.html           Interactive plasma lab
    └── viz.py                    Frame visualization
```

---

## Acknowledgments

Built in one session by user + Claude Opus 4.6. The user pushed at every step — pivoting from "let's continue" to "fix the compiler permanently" to "let's audit the base." That direction is what made this real instead of demo-ware.
