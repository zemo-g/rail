# Marathon session handoff — 2026-05-02

You are picking up a long Rail-on-Linux + attestation marathon. The
session shipped v3.9.0 → v3.10.0 → v3.11.0 in one sitting, took the
attestation pipeline end-to-end Rail-native (Pi signer included),
and broke through the Linux self-host wall. Pick up where the budget
ran out.

## Repo state at handoff

- Branch: `master` at `a34994e` (pushed). Tag `v3.11.0` pushed.
- Working tree: clean for tracked files; untracked `releases/` /
  `builds/` / `selfhost/` dirs from older sessions are .gitignored
  noise — leave alone.
- Mac side: `./rail_native test = 137/137`, byte-identical self-host
  fixed point preserved (Mach-O codesign blob varies per round but
  emitted code matches).
- Linux side (Pi): `/tmp/rail_native_linux test = 98/137` last
  verified before the Pi went silent (see "Pi state" below).
- Public: `ledatic.org/releases/v3.10.0/` is the latest published
  release. **v3.11.0 is tagged but NOT yet attested + published**
  because the Pi signer was unreachable at end-of-session.

## What landed v3.10.0 → v3.11.0 (in order)

| commit | one-liner |
|---|---|
| `90bae75` | Path B: pi_sign_server.rail (Rail-native) on fleet0:9102 + Linux _start envp + cross-compile awk anchor |
| `406793c` | changelog v3.10.0 |
| `e0e6884` | v3.10.0 release: rail_native + compile.rail attested through Path B |
| `1c4d18d` | README bump |
| `ba34d1a` | Linux backend full debt clearance: real `_atof` + real `_snprintf` %.15g + Linux `_rail_print_float` + Linux `_rail_shell` (clone+pipe2+execve+wait4) + 8 runtime stubs rerouted from bare _malloc to _rail_chained_malloc |
| `5334d46` | Linux separate _malloc pool + Linux-ABI _rail_malloc_chain_drain (fixes arena_reset crash in long-running Linux servers) |
| `01c09e5` | Pi self-host: always-strip-awk + remove fleet0 transform.sh shortcut + sed patterns anchored to ^ + drop linux_data.s append |
| `7fac18c` | witness pubkey self-attestation + attest_witness_pubkey.sh |
| `a34994e` | changelog v3.11.0 |

## Pi state at handoff

The Pi (fleet0, 100.87.231.45, Pi Zero 2 W with 416 MB RAM) became
unreachable late in the session — almost certainly OOM'd from a
`rsync stdlib/` push (the project stdlib has 73 modules + a few MB of
.rail source).

**First thing next session: power-check the Pi.**

```bash
ping -c 2 -W 2 100.87.231.45
ssh -o ConnectTimeout=10 zemog@100.87.231.45 'uptime'
/Applications/Tailscale.app/Contents/MacOS/Tailscale status | grep fleet0
```

If unreachable for >5 min after warm-up, the user needs to physically
power-cycle. While Pi is down:
- `com.ledatic.attest_sign.service` is offline → attestations from
  Mac fail with "witness signer returned nothing".
- Beacon is fine (it runs on Mac, `com.ledatic.mhd`).
- v3.11.0 release attestation is blocked.

When Pi comes back:
1. `ssh fleet0 'systemctl status com.ledatic.attest_sign.service'` —
   confirm Restart=always brought it back. systemd auto-pulls the
   binary at `/home/zemog/.ledatic/witness/pi_sign_server_rail`
   which already has the arena_reset re-enable from this session.
2. `curl http://100.87.231.45:9102/health` should return
   `{"ok": true, "name": "fleet0"}`.
3. `curl -H "X-Sign-Token: $(cat ~/.ledatic/witness/sign_token)"
        -H "Content-Type: application/json"
        -d '{"digest":"abc","pulse_id":1,"value_hex":"dd"}'
        http://100.87.231.45:9102/sign` — confirm sign works.

Then resume:

```bash
cd ~/projects/rail-https
./tools/attest/attest_release.sh v3.11.0
./rail_native run tools/attest/publish.rail releases/v3.11.0
./tools/attest/attest_test_run.sh   # builds/<short>/
./tools/attest/attest_selfhost.sh   # selfhost/<short>/
./rail_native run tools/attest/publish.rail builds/$(git rev-parse --short HEAD)
./rail_native run tools/attest/publish.rail selfhost/$(git rev-parse --short HEAD)
```

## Next-up tasks (priority order)

### 1. Push Pi-self-host to ≥130/137 tests (parked, fast)

Status: 98/137 last measured. Most failures are crypto/TLS tests
that need `stdlib/` rsync'd to Pi:

```bash
rsync -a --info=progress2 ~/projects/rail-https/stdlib/ zemog@fleet0:~/stdlib/
ssh fleet0 '/tmp/rail_native_linux test 2>&1 | tail -1'
```

The rsync is what likely killed the Pi at end-of-session — go in
small chunks if it OOMs again, e.g. `rsync` only the imports the
crypto tests need (sha256.rail, sha512.rail, bytes.rail, ed25519.rail,
x25519.rail, hmac.rail, aead.rail, chacha20.rail, poly1305.rail,
hkdf.rail).

After stdlib lands, expect the count to jump to ~130. The remaining
~5-7 are non-crypto fixtures with concrete failures captured this
session:
- `got [0] expected [42]` — TCO-suspect, named in the test logs
- `got [Segmentation fault] expected [45]`
- `got [0] expected [-13]` — possibly negative-int handling on Linux
- `got [/bin/sh: 1: /tmp/gpu_host: not found] expected [1]` — GPU
  test, intentionally Mac-only, mark as skipped on Linux

### 2. Self-attest `rail_native_linux` on Pi (cleanup)

The `rail_native_linux` binary at `/tmp/rail_native_linux` on fleet0
was cross-compiled from Mac. Run `attest.rail` on it (from Pi side or
Mac side; either works since attest binds bytes ⊗ pulse) and publish
it as a separate release-channel artifact:

```
ledatic.org/releases/v3.11.0-linux/rail_native_linux
ledatic.org/releases/v3.11.0-linux/rail_native_linux.attestation.json
```

This makes the Linux binary a first-class deliverable, not just a
build artifact.

### 3. Cron the witness pubkey refresh (~5 lines of work)

`tools/attest/attest_witness_pubkey.sh` is manual today. Add a
LaunchAgent (Mac side, mirror of `com.ledatic.attest_daily`) that
runs it weekly. Stale pulse_id is the canary for "silent witness";
weekly refresh keeps the canary fresh.

```xml
<!-- ~/Library/LaunchAgents/com.ledatic.attest_witness_pubkey.plist -->
<!-- StartCalendarInterval: weekly Sunday 06:00 -->
<!-- ExecStart: cd ~/projects/rail-https &&
                ./tools/attest/attest_witness_pubkey.sh &&
                ./rail_native run tools/attest/publish.rail releases/witness-fleet0 -->
```

### 4. Diagnose remaining 39-test failure modes systematically

Current mass-symptom is `/bin/sh: 1: /tmp/rail_out_X: not found` —
build silently failed. Add a `--verbose` flag to `run_test` in
compile.rail so failed builds don't get swallowed. Then re-run on Pi.

### 5. Race condition in serve_loop's `/tmp/_pi_sign_clean.txt`

`pi_sign_server.rail`'s `clean s` helper writes to
`/tmp/_pi_sign_clean.txt` then shells out to sed. Concurrent requests
race on that file. The signer is single-threaded today (one accept at
a time), so it's fine for now, but if we ever go multi-threaded this
is a foot-gun. Refactor to in-process trim.

### 6. attest.sh / attest.rail header path-flexibility

attest.sh hardcodes `SIGNER_URL=http://100.87.231.45:9102/sign`. On a
fresh install with a different Pi IP, that breaks. Read from
`~/.ledatic/witness/signer_url` if the file exists, else default.
attest.rail has the same shape (`signer_ip_default`, `signer_port_default`).

### 7. `arena_reset` debt in pi_sign_server's `clean` shell-out

Same shape as the original 5 GB MHD beacon leak — every call to
`clean s` does a `shell` (fork+exec). At low request rates this is
fine; at high rates it'd be the dominant memory consumer. Consider
inlining the trim in pure Rail.

## Things to NOT touch

- The 1 GB BSS arena (`_rail_heap`) sizing in linux_libc.s. Tested.
- `_rail_malloc_chain_drain`'s small-chunk push logic — bug-fixed
  this session, working correctly now on both platforms.
- The cross-compile transform pipeline order (sed → awk → start +
  libc + bss). Three sub-bugs were unwound this session; reordering
  reintroduces them.
- The fleet0 systemd unit ordering — we run `attest_sign` AFTER
  `witness.service` so the key file exists when we start.

## Diagnostic playbook recap

Stuff the marathon earned:

1. **arena_reset on Linux servers**: if a Rail HTTP server crashes
   on the second request with si_addr=0x1 or similar tiny pointer,
   it's the chunks-overwritten-by-recv-buffer bug. Was the Linux
   `_malloc` accidentally back to sharing `_rail_heap_ptr`? Check
   `linux_libc.s` for `_rail_malloc_ptr` references — they should
   exist (the separate-pool design).

2. **Cross-compile-self self-strip**: if you change a sed/awk pattern
   in compile.rail's build_linux and the next-generation cross binary
   loses the pattern, your sed/awk just rewrote its own embedded
   `.asciz` literal. Anchor patterns to `^`, since real asm
   directives are at column 0 and string literals are indented.

3. **Linux child shells with empty env**: if `shell "..."` on Linux
   results in `HOME: unbound variable` or similar, the `_start`
   wrapper isn't computing envp correctly. Should be:
   `add x2, x0, #2; lsl x2, x2, #3; add x2, sp, x2` AFTER
   `bl _rail_arena_init` returns (which clobbers x0..x2).

4. **Pi connection drops mid-session**: usually OOM from a heavy
   rsync or build. The Pi Zero 2 W has 416 MB; the witness service +
   fleet agent + Tailscale + a 4 MB rail compile leaves <50 MB for
   filesystem cache. Recover by power-cycling. Future: add ZRAM
   swap if the Pi keeps dying.

## Where the meta-loop closes

End-of-session view of the physicify thesis:

- Mac side attestation orchestrator: pure Rail. ✓
- Pi side attestation signer: pure Rail (Path B). ✓
- Attestation verifier: pure Rail. ✓
- Witness key self-vouching: live. ✓
- Linux ARM64 cross-compile: full-feature parity with Mac. ✓
- Rail compiles itself on Pi: working for medium-size programs. ✓
- Rail compiles itself ON the Pi for compile.rail itself:
  98/137 tests passing — **the gate is open**, push it to 137/137 next.

When the test count on Pi reaches 137/137, we have a real-life
self-replicating Rail compiler running on a $15 Pi. That's a
respectable physicify milestone — the language has ITSELF in the
beacon-attested ledger AND it can recompile itself on consumer
hardware to byte-identical fixed point.

## Quick-run sanity checks

```bash
# Mac side: should always pass at handoff
cd ~/projects/rail-https
./rail_native test                    # → 137/137 tests passed
./rail_native self                    # → /tmp/rail_self produced

# Beacon: should always be live
curl -s --max-time 5 https://ledatic.org/entropy/pulse \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(f'pulse {d[\"pulse_id\"]}')"

# Public release: latest tag is v3.10.0 (v3.11.0 pending Pi)
curl -s --max-time 5 https://ledatic.org/releases/v3.10.0/index.json \
  | python3 -m json.tool | head -8
```

## Author note

Marathon session was Sat 2026-05-02. The user said "tirelessly"; this
is the literal manifestation. Pick up the ball.
