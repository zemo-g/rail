# tools/desk — owned macOS desktop tooling

Pure-Rail (with a thin Objective-C bridge) replacements for third-party desktop
utilities. Everything in this directory exists so we don't ship customer-facing
infrastructure that depends on Rust/Qt/Electron tools we can't audit.

## Status — 2026-05-09

**Sketch.** The bridge dylib (`libquartz_bridge.dylib`) and stdlib bindings
(`stdlib/quartz.rail`) are skeletons. The bridge compiles; what's missing is a
real-world test (Accessibility permission grant, sustained event flow), and the
KVM server/client binaries that consume the bindings.

## Architecture

```
                   ┌──────────────────────────────────────┐
                   │  Rail program (rail_kvm_server.rail) │
                   │                                      │
                   │   import "stdlib/quartz.rail"        │
                   │   qz_init qz_mask_all                │
                   │   loop:                              │
                   │     ev = qz_next_event 50            │
                   │     match ev | EvMouseMove ...       │
                   └─────────────┬────────────────────────┘
                                 │  foreign qb_* calls
                                 ▼
                ┌───────────────────────────────────────┐
                │  libquartz_bridge.dylib (this dir)    │
                │                                       │
                │  • CGEventTap on a runloop thread     │
                │  • thread-safe ring buffer            │
                │  • CGEventCreate*Event injectors      │
                │  • CGDisplayBounds for geometry       │
                └─────────────┬─────────────────────────┘
                              │  CGEvent*, CFRunLoop*
                              ▼
                  CoreGraphics / AppKit (system frameworks)
```

The bridge is the smallest possible Objective-C surface — just enough to handle
the C-callback-from-runloop case that's awkward from pure Rail FFI today. Any
other macOS framework we want (NSPasteboard, NSScreen, IOKit) follows the same
pattern: tiny `.m` shim, Rail decls in stdlib.

## Files

| File | Purpose |
|---|---|
| `quartz_bridge.m` | Objective-C bridge: CGEventTap install, ring buffer, injection helpers |
| `build_quartz_bridge.sh` | One-shot build: produces `libquartz_bridge.dylib` next to the source |
| `../../stdlib/quartz.rail` | Rail-side `foreign` decls + ADT decoding + Rail-friendly wrappers |
| `rail_kvm_server.rail` | (TODO) — runs on Studio. Captures input via `qz_next_event`, ships frames over TCP to the client when cursor crosses an edge. |
| `rail_kvm_client.rail` | (TODO) — runs on Air. Listens, injects via `qz_move_to` / `qz_key` / `qz_click`. |

## Build

```sh
./tools/desk/build_quartz_bridge.sh
```

Produces `tools/desk/libquartz_bridge.dylib`. The Rail compiler currently
expects shared libraries to be findable via `-install_name`; this script bakes
the absolute path so it Just Works for local builds. (For a portable
distribution we'd switch to `@rpath` and ship a launcher.)

## First-run permission

CGEventTap requires Accessibility permission. The first time you run a Rail
binary that calls `qz_init`, macOS will pop a System Settings dialog asking you
to allow `rail_native` (or whatever binary you used). Grant it once; it sticks.

If the permission isn't granted, `qb_init` returns -1 and no events are
delivered. You can re-prompt by toggling the entry off and on in System
Settings → Privacy & Security → Accessibility.

## What still needs to land before this is "done"

1. **Bridge ↔ Rail link path.** Either teach `compile.rail` to add a
   `-L tools/desk -lquartz_bridge` flag when the program imports
   `stdlib/quartz.rail`, or use `stdlib/dlopen.rail` to load the dylib at
   runtime and resolve symbols dynamically. The Metal stack (`stdlib/tensor
   .rail` ↔ `tools/metal/libtensor_gpu.dylib`) is the existing template.
2. **A 50-line smoke binary.** `tools/desk/quartz_smoke.rail` that calls
   `qz_init`, prints 100 events, then `qz_shutdown`. Confirms the round-trip
   without any KVM logic.
3. **`rail_kvm_server.rail` and `rail_kvm_client.rail`.** See protocol sketch
   below.
4. **TLS over the link** (optional for v1 — LAN-only, plain TCP is fine to
   start). When we ship to a stranger we'd wrap with `stdlib/tls.rail`.

## Protocol sketch (for rail_kvm_server ↔ rail_kvm_client)

Length-prefixed binary frames over TCP. One byte type, then payload.

```
frame  := <u8 type> <u8 reserved> <u16 payload_len> <payload>

type 0x01 mouse_move    payload = [f64 dx, f64 dy]                               (16 B)
type 0x02 mouse_button  payload = [u8 button, u8 down]                           (2 B)
type 0x03 key           payload = [u16 keycode, u8 down, u8 mods]                (4 B)
type 0x04 scroll        payload = [f64 dx, f64 dy]                               (16 B)
type 0x10 take_focus    payload = []                  -- "you have the cursor"   (0 B)
type 0x11 release_focus payload = []                  -- "give it back"          (0 B)
type 0x20 hello         payload = [u8 client_id_len, ...]                        (variable)
```

Server-side state machine:

```
INIT   → SERVING (server has cursor)
SERVING:
  on edge crossing toward Air → send take_focus, transition to FORWARDING
FORWARDING (cursor virtually on Air):
  every event from qz_next_event → forward to Air's client
  on cursor moving back to local edge → send release_focus, transition to SERVING
```

While in `FORWARDING`, the server's tap callback returns `NULL` instead of the
event, so local apps don't see the keystrokes (the cursor is "gone" to them).
That's the one place the existing `tap_callback` needs to consult shared state.

Client-side: dumber. Read frames, dispatch to `qz_*_inject_*` calls.

## Why this exists

Same reason `stdlib/tls.rail` and `stdlib/sha256.rail` exist: at some point you
either own your stack or you're a wrapper over someone else's. For the
production tooling that backs Provenance Tier we already chose "own it." For
the desktop tooling that we use every day to *develop* that production
tooling, choosing differently is incoherent.

It's also the answer to "how is this different from a normal AI consultancy"
— at every layer, including the keyboard input on the laptop drafting this
README, it's Rail.
