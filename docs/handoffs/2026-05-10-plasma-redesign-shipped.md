# 2026-05-10 — plasma redesign shipped (follow-up session plan)

100% plasma viewer work. Per `feedback_workflow_split.md`, the
compile.rail / CPU-substrate re-bench from `docs/plans/HANDOFF_NEXT_SESSION.md`
is a separate session. Don't mix.

Goal: take the design pass that just shipped from "consistent and clean"
to "polished and self-explanatory." Each phase is concrete and bounded
so the session doesn't sprawl into model land or shader-fiddling.

---

## Phase 0 — pre-flight (5 min, hard cap)

```bash
# 1. State check.
cd ~/projects/rail && git log --oneline -10 && git status -sb

# 2. Verify all required KV keys still serve.
for u in /mobile.html /live4k.html /holo.html \
         /_shared/viewer.css /_shared/wasm_render.js \
         /render.wasm; do
  printf "%-30s " "$u"
  curl -s -o /dev/null -w "%{http_code}  %{size_download}B  %{content_type}\n" \
    "https://ledatic.org$u?cb=$RANDOM"
done

# 3. Open all three viewers side by side.
for v in mobile live4k holo; do
  open "https://ledatic.org/${v}.html?cb=$RANDOM"
done
```

**Stop if:** any viewer's KV key returns ≠200, or any viewer renders
blank. Investigate before proceeding to polish work.

---

## Phase 1 — cross-browser audit (30 min, P0)

Safari was the dev-loop browser this session. Chrome and Firefox have
different WebGPU/WebGL2 implementations and may surface real issues.

### 1a. Chrome desktop

```bash
open -a "Google Chrome" "https://ledatic.org/holo.html?cb=$RANDOM"
open -a "Google Chrome" "https://ledatic.org/live4k.html?cb=$RANDOM"
open -a "Google Chrome" "https://ledatic.org/mobile.html?cb=$RANDOM"
```

Check on each:
- Plasma renders (volumetric / WebGL2 / Canvas 2D respectively)
- `i` opens drawer; `esc` closes; click-outside closes
- Mode pill cycles correctly between viewers
- Verify link href = `/verify/<actual-hash>` (not the placeholder)
- Pulse pill BR ticks every 2s
- Holo: camera presets work; auto-orbit kicks in after 3.5s idle

### 1b. Firefox desktop (if installed)

Same checklist. Firefox needs `dom.webgpu.enabled` in `about:config`
for holo; without it the page should redirect to /live4k.html.

### 1c. iOS Safari (via Tailnet IP, optional)

If iPhone handy, hit `https://ledatic.org/holo.html` from it. Should
auto-redirect to `/mobile.html` per the touch/coarse-pointer guard.

**Output:** a short "what's broken in $browser" list. File findings
under "Phase 1 findings" at the bottom of this doc; fix in Phase 3 if
small, defer if architectural.

---

## Phase 2 — empty-state polish (20 min, P1)

Before the first beacon frame arrives, all three viewers show a black
canvas with chrome floating over nothing. The pulse pill says `…`.
Looks like the page is broken.

```bash
# Repro by throttling the network in DevTools or by opening the page
# while the entropy beacon is briefly down.
```

Options (pick one, ship it, don't over-engineer):

**Option A — subtle "warming up" indicator.** Replace the `…` placeholders
with a soft pulsing dot animation. Cheap; 10 lines of CSS.

**Option B — pre-paint a static viridis frame on first load.** The
mobile + live4k LUTs already exist. Render a single still gradient
on `DOMContentLoaded` so the canvas isn't black even before the
beacon poll completes. ~30 lines per viewer.

**Option C — leave it.** If the beacon's reliable (which it is), the
empty state lasts ≤2s. Maybe not worth code.

**Recommendation:** A. Smallest blast radius, biggest perceived-quality
win. Live the change for one session before considering B.

---

## Phase 3 — wire up `/verify/<value_hex>` (15 min, P1)

The drawer's verify link points at `/verify/<value_hex>`. Need to
confirm that route actually exists on the worker.

```bash
# Pick a current value_hex.
HASH=$(curl -s https://ledatic.org/entropy/pulse | python3 -c 'import sys,json;print(json.load(sys.stdin)["value_hex"])')
echo "current value_hex: $HASH"

# Probe the route.
curl -s -o /dev/null -w "%{http_code}\n" "https://ledatic.org/verify/$HASH"
```

**If 200:** done. Verify the rendered page actually shows verification
data (not a 404 page styled to look like 200).

**If 404:** the drawer link is broken. Two fixes:
1. Wire the route in `worker/worker.js` (rail repo? ledatic-site repo?
   Check both.)
2. Or change the drawer's verify-link target to `/verify?hash=<hex>`
   if that's the actual contract.

Decide which based on how `/verify` is currently structured. Look for
`verify.html` in ledatic-site.

---

## Phase 4 — dead code + drift cleanup (10 min, P2)

Now that the design pass is closed, sweep the viewer files for
leftovers:

```bash
cd ~/projects/rail/tools/plasma

# mobile.html: drawChamber() is unused after chamber-bytes path was
# disabled (commit 56212bd). Delete the function and the _srcCanvas
# helpers. ~30 lines net deletion.
grep -n "drawChamber\|_srcCanvas\|_srcCtx\|_srcImgData" mobile.html

# live4k.html: anything still referencing the old #errlog overlay
# CSS that lived inline (now in drawer)?
grep -n "errlog\|.has-entries" live4k.html

# holo.html: ANNOTS, updateAnnotations, vsub/vdot/vlen/vnorm/vcross
# should all be gone.  Verify.
grep -n "ANNOTS\|updateAnnotations\|vsub\|vdot\|vlen\|vcross\|vnorm" holo.html

# Demo file shouldn't be referenced from production viewers.
grep -rn "_demo/" tools/plasma/{mobile,live4k,holo}.html
```

Delete what's truly dead. Keep the bootstrap-cycle pattern in mind
(per CLAUDE.md): if a deletion touches runtime asm strings, you'd
need 2 cycles — but viewer HTML/JS isn't compiled, so this is just
a delete-and-deploy.

---

## Phase 5 — handoff write + commit (10 min)

```bash
# Commit the polish + cleanup as one or two commits.
cd ~/projects/rail && git add tools/plasma/ && git commit -m "..."
git push origin next

# Deploy any changed viewer files to KV.
# Pattern from plasma_viewer_deploy.md.

# If viewer.css changed, BUMP the ?v= hash in every consumer first.
# Otherwise the edge cache serves stale CSS for an hour.
```

Update `~/.claude/projects/-Users-user/memory/session_handoff.md` with:
- Cross-browser findings (which browsers work / break)
- Empty-state behavior (what we shipped)
- Verify-link route status (200 / 404 / fixed)
- What got cleaned up

---

## What NOT to do this session

- **Don't re-bench Spur ckpts.** That's the parallel session's
  HANDOFF_NEXT_SESSION.md. Different workflow per
  `feedback_workflow_split.md`.
- **Don't iterate on shaders.** Color tweaks, strand intensity, etc.
  are infinite. The design pass is closed. If something's actually
  wrong in a browser, fix the bug; don't rebalance the look.
- **Don't redesign the drawer.** It works. Slide-from-right on desktop,
  bottom-sheet on phone (per viewer.css media query). If polish
  surfaces real issues, address; don't pre-emptively iterate.
- **Don't add new viewer modes.** Three is the answer.
- **Don't re-deploy `wasm_render.js`** unless KV explicitly cleared.

---

## Open invariants (the floor)

- All 5 KV keys live at 200: `mobile.html`, `live4k.html`, `holo.html`,
  `_shared/viewer.css`, `_shared/wasm_render.js`
- Holo `#diag` strip stays hidden (no errors firing)
- Mode pill on each viewer highlights the current page
- `i` / `?` / `esc` / click-outside all toggle the drawer correctly
- Pulse pill ticks every 2s, flashes red on network failure
- 137/137 + JIT suites still green

If any of these break, fix before continuing.

---

## Phase 1 findings

(Fill in during Phase 1; this section is the worklist for Phase 3
fixes.)

- Chrome desktop: …
- Firefox desktop: …
- iOS Safari: …

---

## Stretch (only if Phase 0-5 done early — extras, not commitments)

- Add a `?v=<sha8>` cache-bust to `live4k.html` and `holo.html`
  stylesheet links (currently only mobile has it). One-line fix per
  viewer; protects the next CSS deploy.
- Drawer keyboard-shortcut footer: small monospace line at the bottom
  of the drawer listing `i ?  esc  click outside`. Discoverability
  win for power users.
- Mobile.html PiP top-down: drawer parity with holo. Mobile already
  computes density via the LUT; could expose a small drawer canvas
  the same way holo does.

These are nice-to-haves. Don't start them if Phase 1-3 produced any
real bugs to fix.
