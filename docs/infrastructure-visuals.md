---
name: infrastructure-visuals
description: 10 detailed ASCII visuals of full RAIL/ANE/MINI/RAZER pipeline architecture and how they connect
type: reference
---

## 1. THE BIG PICTURE — Full System Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        LEDATIC COMPUTE FLEET                                │
│                                                                             │
│  ┌───────────────────────────────────┐      ┌──────────────────────────┐   │
│  │     MAC MINI M4 PRO (24GB)        │      │   RAZER3070 (8GB VRAM)   │   │
│  │     ─────────────────────         │      │   ────────────────────   │   │
│  │  RAIL Compiler (oracle)           │      │                          │   │
│  │  MLX Inference (:8080-:8083)      │ SSH  │  CUDA QLoRA Training     │   │
│  │  ANE Engine (:8082)               │◄────►│  train_cuda.py v5        │   │
│  │  Self-Training Loop               │ SCP  │  Qwen3.5-4B LoRA        │   │
│  │  Waterfall Orchestrator           │      │  Adapter output          │   │
│  │  Fleet Agent (:9101)              │      │  Fleet Agent (:9101)     │   │
│  │  Site Gen + CF Deploy             │      │                          │   │
│  └──────────────┬────────────────────┘      └──────────────────────────┘   │
│                 │ Tailscale VPN (100.x.x.x)              ▲                  │
│                 │                                         │                  │
│  ┌──────────────▼──────────────┐    ┌────────────────────┘                  │
│  │  MACBOOK AIR M1 (8GB)      │    │  Tailscale: 100.109.63.37             │
│  │  ─────────────────────     │    │                                        │
│  │  Keepawake only            │    │  ┌─────────────────────┐              │
│  │  SSH: 100.120.203.70       │    │  │  PI ZERO 2 W        │              │
│  └────────────────────────────┘    │  │  ─────────────      │              │
│                                    │  │  Rail cross-compile  │              │
│                                    │  │  LCD Fleet Display   │              │
│                                    │  │  (pending deploy)    │              │
│                                    │  └─────────────────────┘              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. RAIL COMPILER PIPELINE — Source to Binary

```
                         RAIL COMPILER (tools/compile.rail — 2,320 lines)
                         ══════════════════════════════════════════════

     .rail source file
           │
           ▼
    ┌──────────────┐     Keywords: let, match, if, fun, type, import
    │    LEXER     │     Tokens: strings, idents, operators, \x ->
    │  (inline)    │     Comments: -- (line), handles escape sequences
    └──────┬───────┘
           │ token stream
           ▼
    ┌──────────────┐     ADTs, pattern matching, lambdas, pipes |>
    │    PARSER    │     Let bindings, function defs, type decls
    │              │     Match...with arms, list comprehensions
    └──────┬───────┘
           │ AST
           ▼
    ┌──────────────┐     (lightweight — Rail is dynamically typed
    │ TYPE CHECKER │      at codegen level, structural matching)
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐     ARM64 instructions (Apple Silicon)
    │  ARM64       │     .text + .data sections
    │  CODEGEN     │     System calls: write, read, exit, mmap
    └──────┬───────┘     String literals in data segment
           │ .o object
           ▼
    ┌──────────────┐     Links: runtime/gc.c + runtime/llm.c
    │   LINKER     │     Output: /tmp/rail_out (native binary)
    │  (cc/ld)     │     Size: ~297KB-367KB ARM64
    └──────┬───────┘
           │
           ▼
     /tmp/rail_out        SELF-COMPILE: ./rail_native self
     (executable)         /tmp/rail_self == rail_native (byte-identical fixed point)

     ┌─────────────────────────────────────────────────────┐
     │ RUNTIME COMPONENTS (linked into every Rail binary)  │
     │                                                     │
     │  rt_gc (ARM64 asm) ── 512MB arena + mark-sweep      │
     │  llm.c ─ llm(port, sys, user) → curl → MLX → str  │
     └─────────────────────────────────────────────────────┘
```

---

## 3. SELF-TRAINING FLYWHEEL — The Closed Loop

```
     ┌─────────────────────────────────────────────────────────────────┐
     │                  SELF-TRAINING LOOP (self_train.rail)           │
     │                  25 levels × 10 seeds/level × 3 retries        │
     └─────────────────────────────────────────────────────────────────┘

          ┌──────────────────────┐
          │  CURRICULUM ENGINE   │  Level 1: basic math (7+5=12)
          │  progress.txt:       │  Level 2: lists, fold, recursion
          │   round=1893         │  Level 3: ADTs, pattern matching
          │   level=3            │  Level 4-5: strings, file I/O
          │   harvested=2006     │  Level 6-7: HTTP, JSON, site gen
          │   since_retrain=2006 │  Level 8-9: memory, compilers
          └──────────┬───────────┘  Level 10-25: full programs, APIs
                     │
                     │ pick task + generate prompt
                     ▼
          ┌──────────────────────┐
          │   LLM GENERATION     │  llm(port, sys_prompt, task)
          │   MLX :8080          │  → curl → /v1/chat/completions
          │   Qwen3.5-4B+LoRA   │  → strip <think> tags
          └──────────┬───────────┘  → extract code from fences
                     │
                     │ generated Rail code
                     ▼
          ┌──────────────────────┐
          │  COMPILER ORACLE     │  Write to /tmp/rail_st_test.rail
          │  ./rail_native       │  Compile → run with 5s timeout
          │  (verification)      │  Check output matches expected
          └──────────┬───────────┘
                     │
            ┌────────┴────────┐
            │                 │
         SUCCESS           FAILURE
            │                 │
            ▼                 ▼
   ┌────────────────┐  ┌────────────────┐
   │ harvest.jsonl  │  │ RETRY (3 max)  │
   │ +1 harvested   │  │ feed back error│
   │ +1 since_retrn │  │ + failed code  │
   └────────────────┘  └───────┬────────┘
                               │ if fix works:
                               ▼
                       ┌────────────────┐
                       │ repairs.jsonl  │
                       │ (error→fix)    │
                       └────────────────┘

     AUTO-ADVANCE: 80%+ for 3 consecutive rounds → level++
     FALLBACK:     2 consecutive 0% rounds       → level--
     RETRAIN:      since_retrain >= 2000          → trigger CUDA training
```

---

## 4. DATA PIPELINE — 10 Sources to Training Split

```
     ┌─────────────────── 10 JSONL SOURCES ───────────────────────┐
     │                                                             │
     │  training/train.jsonl ────────────── handwritten examples   │
     │  training/git_harvest.jsonl ──────── real programs (git)    │
     │  training/real_programs.jsonl ────── curated code           │
     │  training/handcrafted_l2_l5.jsonl ─ level 2-5 hand-tuned   │
     │  self_train/harvest_clean.jsonl ─── compiler-verified gen   │
     │  self_train/cloud_harvest.jsonl ─── cloud-generated         │
     │  self_train/cloud_repairs.jsonl ─── cloud error→fix pairs   │
     │  self_train/repairs.jsonl ──────── self-train repairs       │
     │  self_train/synthetic_repairs.jsonl  synthetic variations   │
     │  self_train/session_harvest.jsonl ── session examples       │
     │                                                             │
     └──────────────────────────┬──────────────────────────────────┘
                                │
                                ▼
                  ┌──────────────────────────┐
                  │    SHA-256 DEDUP          │
                  │    harvest_hashes.txt     │
                  │    (297KB hash registry)  │
                  │    ~4,059 unique examples │
                  └────────────┬─────────────┘
                               │
                               ▼
                  ┌──────────────────────────┐
                  │    QUALITY FILTER         │
                  │    - skip <20 char code   │
                  │    - skip >4000 char code │
                  │    - skip no-main garbage │
                  │    - UTF-8 enforced       │
                  └────────────┬─────────────┘
                               │
                   ┌───────────┼───────────┐
                   │           │           │
                   ▼           ▼           ▼
              ┌─────────┐ ┌────────┐ ┌─────────┐
              │ train   │ │ valid  │ │  test   │
              │  90%    │ │  5%    │ │   5%    │
              └─────────┘ └────────┘ └─────────┘
                   │
                   │ SCP via Tailscale
                   ▼
              Razer3070: ~/rail_training/clean_data/
```

---

## 5. MINI ↔ RAZER TRAINING CYCLE — The Two-Node Dance

```
     MAC MINI M4 PRO                              RAZER3070
     ══════════════                                ════════
     (inference + orchestration)                   (CUDA training)

     MLX Server (:8081)                     ┌──────────────────────┐
     Qwen3.5-4B + LoRA v6                  │  RTX 3070 (8GB VRAM) │
           │                                │                      │
           │ generates Rail code            │  train_cuda.py v5    │
           ▼                                │  ─────────────────   │
     self_train.rail                        │  Qwen3.5-4B (4-bit)  │
     (2006 harvested)                       │  LoRA rank-8, α=16   │
           │                                │  3000 iters          │
           │ since_retrain >= 2000          │  batch=1, seq=512    │
           ▼                                │  lr=1.5e-5           │
     ┌────────────────┐                     │  grad checkpoint: ON │
     │ waterfall.rail │                     │                      │
     │    sync        │                     │  Targets:            │
     └───────┬────────┘                     │  ├─ 8 self_attn lyrs │
             │                              │  │  (q/k/v/o_proj)   │
             │  1. dataset.rail prepare     │  └─ 24 DeltaNet lyrs │
             │     (dedup + split)          │     (qkv/z/b/a/out)  │
             │                              │                      │
             │  2. SCP train/valid/test ──────────────►            │
             │     to ~/rail_training/      │                      │
             │                              │  Training: ~10h      │
             │                              │  Save every 500 iter │
             │                              └──────────┬───────────┘
             │                                         │
             │  3. pull_adapter ◄──────────────────────┘
             │     SCP adapters_4b/latest/   (PEFT format)
             │
             ▼
     ┌────────────────┐
     │ PEFT → MLX     │  Key: base_model...layers.N → language_model...layers.N
     │ Conversion     │  Suffix: .lora_A.weight → .lora_a
     │                │  Transpose all weights
     │                │  Scale: α/rank = 16/8 = 2.0
     └───────┬────────┘
             │
             ▼
     adapters_4b_v7_mlx/
             │
             │  restart MLX server
             ▼
     MLX Server (:8081)   ← loop back to self_train
     Qwen3.5-4B + LoRA v7
```

---

## 6. ANE INFERENCE ENGINE — Apple Neural Engine Path

```
     ┌─────────────────────────────────────────────────────────────┐
     │              ANE INFERENCE ENGINE (~/ane-direct/)            │
     │              Qwen2.5-1.5B-Instruct on Apple Silicon         │
     └─────────────────────────────────────────────────────────────┘

     MODEL LOADING (main.m)
     ──────────────────────
     Binary weights file
           │
           ▼
     Config header: dim, hidden, layers, heads,
                    kv_heads, vocab, max_seq, head_dim
           │
           ▼
     Allocate per-layer weights:
     ├── RMS norm weights
     ├── Q/K/V projection matrices
     ├── O projection matrix
     └── MLP gate/up/down weights
           │
           ▼
     Compile ANE kernels (169 kernels per model)
     ├── SDPA (scaled dot-product attention)
     ├── Fused QKV projections
     ├── RMS normalization
     └── MLP activation
           │
           ▼
     ┌─────────────────────────────────────────────┐
     │  PERSISTENT SERVER (ane_server_lib.m)        │
     │                                              │
     │  libane_server.dylib                         │
     │  ├── ane_server_init()  — load + compile     │
     │  ├── ane_server_infer() — run inference      │
     │  └── ane_server_cleanup()                    │
     │                                              │
     │  Global state: g_model, g_initialized        │
     │  Thread mutex: ANE is SINGLE-THREADED        │
     │  Kernels compiled ONCE at startup (no 5s     │
     │  overhead per call)                          │
     └──────────────────┬──────────────────────────┘
                        │ ctypes bridge
                        ▼
     ┌─────────────────────────────────────────────┐
     │  HTTP SERVER (ane_http_server.py)            │
     │  Port: 8082                                 │
     │                                              │
     │  Endpoints:                                  │
     │  ├── /v1/chat/completions (OpenAI-compat)   │
     │  ├── /v1/health                             │
     │  └── /v1/classify                           │
     │                                              │
     │  Tokenizer: Qwen2.5-1.5B-Instruct           │
     │  Max sequence: 512 tokens                   │
     │  _infer_lock: threading lock (serialized)   │
     └─────────────────────────────────────────────┘

     ANE TRAINING (~/ane-direct/training/)
     ─────────────────────────────────────
     ├── forward.h / backward.h    — ANE forward/backward pass
     ├── ane_mil_gen.h             — Metal Intermediate Language gen
     ├── ane_runtime.h             — ANE dispatch runtime
     ├── tiny_train.m              — Small model training
     ├── train_large.m             — Full model training
     └── test_ane_sdpa5.m          — Attention kernel tests
```

---

## 7. PORT MAP + INFERENCE ROUTING

```
     ┌──────────────────────────────────────────────────────────────┐
     │                    MAC MINI M4 PRO                           │
     │                    INFERENCE PORT MAP                         │
     └──────────────────────────────────────────────────────────────┘

     Port    Engine    Model                    Role
     ────    ──────    ─────                    ────

     :8080   MLX       Qwen3.5-9B-6bit         Reasoning + thinking mode
                       + adapters_st            (UNSTABLE under load)
                                                │
     :8081   MLX       Qwen3.5-4B-4bit         PRIMARY: self-training
                       + adapters_4b_v6_mlx     flywheel inference
                                                │
     :8082   ANE       Qwen2.5-1.5B            Fast classify/extract
                       (native Apple Neural     (single-threaded, 512 tok)
                        Engine kernels)          │
                                                │
     :8083   MLX       Qwen3-1.7B-4bit         Fast classify/parse
                       (no adapter)             (~0.3s latency)


     CONSUMERS:
     ──────────
     self_train.rail ──────────► :8080 or :8081  (reads /tmp/rail_st_port.txt)
     bench.rail ───────────────► :8080 (configurable --port)
     agent.rail ───────────────► :8081 (code gen) + :8080 (reasoning)
     llm() builtin ────────────► any port (user-specified)
     gen_site.rail ────────────► :8080 (LLM-assisted content)

     EXTERNAL:
     ─────────
     autonomy/server.py ─┬────► :8080 "reasoning"
                         ├────► :8081 "fast/tiny"
                         └────► Claude Sonnet 4.6 "cloud" (Anthropic SDK)

     FLEET:
     ──────
     :9100 ─── Fleet Dashboard (polls all nodes)
     :9101 ─── Fleet Agent (status + exec API)
```

---

## 8. DEPLOY PIPELINE — Rail Source to Cloudflare Edge

```
     ┌─────────────────────────────────────────────────────────────┐
     │              SITE DEPLOY: ledatic.org                        │
     └─────────────────────────────────────────────────────────────┘

     gen_site.rail (28,435 lines)
     ├── Builds full HTML page
     ├── Interactive charts + diagrams
     ├── Incremental file writes (avoids 1GB OOM)
     │   └── Pattern: write to /tmp/_rc.txt, append via shell
     │
     ▼
     /tmp/ledatic.html
     │
     ▼
     cf_deploy.rail (1,348 lines)
     ├── Reads OAuth token from ~/.wrangler/config/default.toml
     ├── PUT to Cloudflare REST API:
     │   https://api.cloudflare.com/client/v4/accounts/{acct}/
     │     storage/kv/namespaces/{ns}/values/{key}
     │
     ▼
     ┌──────────────────────────────────────────┐
     │  CLOUDFLARE KV (LEDATIC_KV)              │
     │                                           │
     │  Key: "index.html"  → main page (/)      │
     │  Key: "system.html" → mission ctrl (/sys) │
     └──────────────────┬───────────────────────┘
                        │
                        ▼
     ┌──────────────────────────────────────────┐
     │  CLOUDFLARE WORKER ("ledatic")           │
     │                                           │
     │  Request path    →    KV key             │
     │  /               →    index.html         │
     │  /system         →    system.html        │
     │  /{path}         →    {path}             │
     │                                           │
     │  Serves HTML with correct content-type   │
     └──────────────────────────────────────────┘
                        │
                        ▼
                   ledatic.org
                   (Cloudflare Edge, global CDN)


     MISSION CONTROL (separate pipeline):

     gen_mission_control.rail (24,461 lines)
           │
           ▼
     /tmp/mission_control.html
           │
           ▼
     cf_deploy.rail /tmp/mission_control.html system.html
           │
           ▼
     KV key: "system.html" → ledatic.org/system


     DAILY AUTO-DEPLOY:
     com.ledatic.site-deploy (LaunchAgent) → runs at 06:00
```

---

## 9. FLEET MANAGEMENT — Node Communication

```
     ┌────────────────────────────────────────────────────────────────┐
     │                    FLEET ARCHITECTURE                          │
     └────────────────────────────────────────────────────────────────┘

     FLEET DASHBOARD (:9100)
     ┌──────────────────────────────────┐
     │  fleet_dash_gen.rail             │
     │  Static HTML + JS auto-refresh   │
     │  Polls all nodes every 10s       │
     │  VT323 font, grid layout         │
     │  Per-node: status, CPU, MEM,     │
     │            DISK, uptime badges   │
     └──────────┬───────────────────────┘
                │ HTTP GET /status (every 10s)
       ┌────────┼────────────────────┐
       │        │                    │
       ▼        ▼                    ▼
     ┌──────┐ ┌──────┐         ┌──────────┐
     │ MINI │ │  M1  │         │ RAZER    │
     │:9101 │ │:9101 │         │ :9101    │
     │ Rail │ │(down)│         │ Python   │
     └──┬───┘ └──────┘         └──┬───────┘
        │                         │
        │  fleet_agent.rail       │  fleet_agent.py
        │  (ARM64 native)         │  (x86_64/Windows)
        │                         │
        ├── GET /health           ├── GET /health
        │   {"alive":true}        │   {"alive":true}
        │                         │
        ├── GET /status           ├── GET /status
        │   {hostname, cpu,       │   {hostname, cpu,
        │    mem, disk, arch,     │    mem, disk, gpu_name,
        │    train_level,         │    gpu_mem, gpu_temp,
        │    train_round,         │    gpu_util}
        │    train_harvested,     │   (nvidia-smi detected)
        │    services[]}          │
        │                         │
        └── POST /exec            └── POST /exec
            {cmd: "..."}              {cmd: "..."}
            X-Fleet-Token auth        X-Fleet-Token auth
            Whitelist enforced        Whitelist enforced

     AUTH:
     ├── Token: ~/.fleet/token (shared secret)
     ├── Header: X-Fleet-Token: <token>
     └── Whitelist: ~/.fleet/allowed_commands (one cmd per line)

     NETWORK (Tailscale VPN):
     ├── Mini:  localhost / 100.x.x.x
     ├── M1:    100.120.203.70
     ├── Razer: 100.109.63.37
     └── Pi:    (pending — needs reflash + Tailscale)
```

---

## 10. THE COMPLETE FLYWHEEL — Everything Connected

```
     ┌─────────────────────────────────────────────────────────────────────┐
     │                    THE COMPLETE SELF-IMPROVING SYSTEM               │
     │                    ═════════════════════════════════                 │
     └─────────────────────────────────────────────────────────────────────┘

                          ┌──────────────┐
                          │  RAIL        │
                          │  COMPILER    │◄──────── FIXED POINT
                          │  (oracle)    │          (byte-identical
                          └──────┬───────┘           self-compile)
                                 │
                    ┌────────────┼────────────┐
                    │   VERIFY   │   BUILD    │
                    ▼            ▼            ▼
            ┌────────────┐ ┌─────────┐ ┌──────────┐
            │self_train  │ │  bench  │ │gen_site  │
            │(generate   │ │(30-task │ │(deploy   │
            │ + verify)  │ │ eval)   │ │ ledatic) │
            └─────┬──────┘ └────┬────┘ └──────────┘
                  │             │
                  │   HARVEST   │  MEASURE
                  ▼             ▼
            ┌─────────────────────────────────┐
            │        10 JSONL SOURCES          │
            │   ~4,059 unique verified pairs   │
            └──────────────┬──────────────────┘
                           │
                           │  dataset.rail (dedup + split)
                           ▼
                  ┌──────────────────┐
                  │  90/5/5 SPLIT    │
                  │  train/valid/test│
                  └────────┬─────────┘
                           │
                      SCP  │  Tailscale VPN
         ┌─────────────────┘
         │
         ▼
    ┌─────────────────────────────┐
    │  RAZER3070 (CUDA)           │
    │  ───────────────            │
    │  Qwen3.5-4B (4-bit)        │
    │  QLoRA: rank-8, α=16       │
    │  3000 iters, ~10h          │
    │  32 layers targeted         │
    │  (8 self_attn + 24 DeltaNet)│
    └─────────────┬───────────────┘
                  │
                  │  SCP adapter back
                  ▼
    ┌─────────────────────────────┐
    │  PEFT → MLX CONVERSION      │
    │  Key remap + transpose      │
    │  → adapters_4b_vN_mlx/      │
    └─────────────┬───────────────┘
                  │
                  ▼
    ┌─────────────────────────────┐
    │  MLX SERVER (:8081)          │         ┌──────────────┐
    │  Qwen3.5-4B + new LoRA      │◄────────│ ANE (:8082)  │
    │                              │ parallel│ Qwen2.5-1.5B │
    │  Ready for next round        │ path    │ fast classify │
    └─────────────┬───────────────┘         └──────────────┘
                  │
                  │  llm(port, sys, user) → curl → /v1/chat/completions
                  │
                  └──────────────────► BACK TO SELF_TRAIN (loop)


    ┌─────────────────────────────────────────────────────────────┐
    │  FLEET DASHBOARD (:9100) monitors everything:               │
    │                                                             │
    │  [MINI: ONLINE]  [M1: KEEPAWAKE]  [RAZER: TRAINING]       │
    │  CPU: M4 Pro     CPU: M1          GPU: RTX 3070            │
    │  MEM: 24GB       MEM: 8GB         VRAM: 8GB               │
    │  Level: 3        —                Train loss: 0.42         │
    │  Harvested: 2006                  Iter: 2100/3000          │
    │                                                             │
    │  Pi Zero 2 W: [PENDING — LCD fleet display planned]        │
    └─────────────────────────────────────────────────────────────┘
```

---

## Summary of Connections

- **RAIL compiler** is the oracle that verifies everything — self-training, benchmarks, and its own correctness (fixed-point self-compile)
- **Mini** runs inference (MLX on :8081, ANE on :8082) and orchestrates the entire flywheel via waterfall.rail
- **Razer** is the training workhorse — receives data via SCP, trains QLoRA for ~10h, sends adapters back
- **ANE** provides a parallel fast-inference path using native Apple Neural Engine kernels (169 compiled per model)
- **The loop closes**: generate code → compile-verify → harvest → train → deploy better model → generate better code
