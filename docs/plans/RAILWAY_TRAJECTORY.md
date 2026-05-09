# Railway trajectory — substrate-extension tracks parallel to Cortex-M4

The Cortex-M4 backend session pattern (substrate extension that doubles as Spur
bench fodder + corpus material) generalizes. This doc maps the parallel tracks.

## Tier 1 — same shape as Cortex-M4

| Track | Substrate | Bench yield | Continuation |
|---|---|---|---|
| Cortex-M4 v0.7+ (current) | Apollo2 / mps2-an386 | match, mmio, ISR prompts | payload ADTs → drivers → Apollo2 → watchface |
| RISC-V backend | rv32imc / qemu-riscv | rv32 emit prompts, parallel to thumb | qemu-system-riscv32 → Pi Pico 2 / ESP32-C3 / FPGA softcores |
| WASM backend extension | already partly shipped | filter/map/fold WASM emit | full stdlib in browser → REPL on ledatic.org |
| AVR / Cortex-M0+ port | tiny chips, $1-3 hardware | size-tight prompts (no sdiv, 16-bit ints) | Arduino / Tindie distributable Rail builds |

## Tier 2 — language feature tracks

| Track | Unlocks |
|---|---|
| Payload-carrying ADTs (Some int / Ok / Err) | Option/Result, canonical functional toolkit |
| String literals → ROM data section | `print "Hello"` instead of byte-by-byte; demo polish |
| Tail-call optimization (cortexm) | unbounded busy-wait loops without stack growth |
| Effect handlers in cortexm | structured error recovery, replaces try-handler |
| Module system | proper imports → reusable Rail libraries |

## Tier 3 — Garmin trophy track

| Track | Watch-needed? | Risk |
|---|---|---|
| Pass 8 fuzz (Garmin Connect / Express side) | No | Bug-hunt desktop+mobile parsers via Pass 7 persistent payload |
| Stage 6 bootloader probe | Yes (~30 min) | Hold buttons, plug in, diff USB descriptors |
| ROP-chain construction | No (offline) | Combine instinct_rop_gadgets.json with Pass 7 primitive |
| Hardware path (donor watch SWD) | $100 used Instinct | Weeks of bench work; off the soft-path entirely |

## Tier 4 — model/bench tracks

| Track | Goal |
|---|---|
| Comprehension-band corpus | Crack the 6/30 unsolved gap |
| Compiler-feature-parity bench expansion | Each new cortexm feature → new prompt category |
| Compile-loss training integration | Wire maybe_harvest into v0.8 |

## Shared property

Every track is self-contained, ends with a verifiable smoke (`./rail_native
test` or qemu exit code), produces code that exercises the compiler's data
flow, and naturally generates corpus material. A session on any of them
mirrors the Cortex-M4 loop.

## Recommended immediate sequencing

1. Finish Cortex-M4 v0.7 (echo + ISR + payload ADTs) — 80% there
2. Pass 8 fuzz — high-EV, no-watch-needed Garmin work
3. RISC-V backend — natural parallel; copy/paste cortexm structure with rv32 mnemonics
4. Stage 6 bootloader probe when watch is plugged in
5. Payload-carrying ADTs + string literals — language polish for real watchface code
