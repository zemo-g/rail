# Security Deferred Items — User-Side Runbook (2026-05-12)

These five items require **your hands on the keyboard** (sudo, OAuth, System Settings clicks, disruptive restarts). Swarm Agents 1-4 closed the autonomous lanes; this is what is left for you.

## Recommended order

1. **ARDAgent off** (5 min, low risk, *but verify item below before clicking*).
2. **AirPlay Receiver off** (5 min, low risk, no active session detected).
3. **`gh auth login`** (5 min, OAuth in browser).
4. **GitHub branch protection** — *only after* Swarm Agent 4's H10 force-push has landed. If the force-push is still pending, do the force-push first, then enable protection.
5. **Colima virtfs scope-down** (quiet window, ~10 min, disruptive — kills any running containers).
6. **Token rotation** — see Swarm Agent 3's `token_rotation_runbook_2026-05-12.md` after the above.

**Active-session warning**: `screensharingd` (PID 12496) has been running 1d 5h 59m. This is plausibly **your current Screen Sharing/VNC session into Studio**. If you're driving Studio over Screen Sharing right now, turning ARD/Remote Management off will cut you off. SSH (`ssh studio`) will keep working. Re-confirm before clicking "off".

---

## 1. AirPlay Receiver off (`*:5000`, `*:7000`)

**Current state**: `ControlCenter` (PID 410) holds both 5000 and 5000/IPv6 + 7000 and 7000/IPv6 in LISTEN. `com.apple.AirPlayUIAgent` (PID 547) and `AirPlayXPCHelper` (PID 162) are loaded under launchd. **No active AirPlay session** — no ESTABLISHED connections on either port, no mirroring process holding a stream.

**Action steps (GUI — recommended)**:
1. System Settings → General → AirDrop & Handoff.
2. Toggle **AirPlay Receiver** off.
3. Verify: `lsof -nP -iTCP:5000 -sTCP:LISTEN` and `lsof -nP -iTCP:7000 -sTCP:LISTEN` both return empty.

**Command-line note**: `sudo launchctl unload /System/Library/LaunchDaemons/com.apple.AirPlayXPCHelper.plist` is blocked by SIP on modern macOS (system LaunchDaemons are read-only). The supported path is the System Settings toggle. Do **not** try to delete or chmod the plist — that gets you a corrupted SIP-protected directory and no working AirPlay if you ever turn it back on.

**Risk**: Other Macs/iPhones on your network can no longer cast/mirror to Studio. If you use AirPlay to mirror an iPad onto Studio for any workflow, this breaks it.

**When**: Now. No active session detected.

---

## 2. Apple Remote Desktop / ARDAgent off (`*:3283`)

**Status as of 2026-05-12 21:30**: VNC peer check empty (`lsof -nP -iTCP:5900 -sTCP:ESTABLISHED` returns nothing; `lsof -p 12496` shows zero open network sockets; no Screen-Sharing entry in `who`). PID 12496 is still alive 1d 8h 23m though, so an idle/dropped client cannot be 100% ruled out. **Not auto-executing.** One-shot script staged at `~/projects/rail/notes/ard_off_after_session.sh` (chmod +x, includes cached-sudo + ESTABLISHED-5900 pre-flight checks). User action sequence: (1) move all work to SSH (`ssh studio`), (2) close any Screen Sharing client window from Air/laptop, (3) `sudo -v` in the same shell to cache creds, (4) run `bash ~/projects/rail/notes/ard_off_after_session.sh`, (5) verify `lsof -nP -iTCP:3283 -sTCP:LISTEN` is empty. Script self-verifies and prints OK + timestamp on success.

**Current state**: `ARDAgent` (PID 636) listening on `*:3283` IPv6. `com.apple.RemoteManagementAgent` loaded under launchd (last-exit -9, currently re-running). **Active Screen Sharing session present**: `screensharingd` PID 12496 + `ScreensharingAgent` PID 12497, both up 1d 5h 59m. Confirm whether this is **your** session before deactivating — if you're remoted into Studio via Screen Sharing right now, you will be disconnected.

**Detect (run from a logged-in shell with sudo cached)**:
```
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -status
```

**Action steps (GUI — recommended)**:
1. System Settings → General → Sharing.
2. Toggle **Remote Management** off (and **Screen Sharing** off if you're also done with VNC).
3. Verify: `lsof -nP -iTCP:3283 -sTCP:LISTEN` returns empty.

**Command-line equivalent**:
```
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -configure -access -off
```

**Risk**:
- If you use ARD or Screen Sharing for remote support / driving Studio from Air, you lose that path. SSH via Tailscale (`ssh studio`) still works.
- If `screensharingd` PID 12496 is your current session, clicking off **will cut you off mid-task**.

**When**: Now, **after** confirming you're not the screensharingd client. If you are, schedule for after you've moved to SSH-only.

---

## 3. `gh auth login` + GitHub branch protection

**Current state**: `gh auth status` returns "not logged into any GitHub hosts." `gh` is installed but unauthenticated. Branch protection cannot be set without auth.

### 3a. Authenticate

```
gh auth login
```
Pick: `github.com` → `HTTPS` → `Y` to authenticate Git with credentials → `Login with a web browser` → copy the one-time code → paste in browser → authorize.

Verify:
```
gh auth status
```
Should show your handle and the scopes (you need `repo` and `admin:org` for branch protection PUTs).

### 3b. Branch protection — `zemo-g/rail`, default branch `next`

**Sequencing**: If Swarm Agent 4 has not yet executed the H10a/b history scrub force-push, **do that first**. Branch protection blocks force-pushes by default. If protection is on, the force-push will fail; you'd have to disable protection, force-push, re-enable. Cleaner to do force-push first, protection second.

Paste-ready:
```
gh api -X PUT /repos/zemo-g/rail/branches/next/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true
}
JSON
```

### 3c. Branch protection — `Ledatic-Empire/ledatic-site`, default branch `main`

```
gh api -X PUT /repos/Ledatic-Empire/ledatic-site/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true
}
JSON
```

Verify each:
```
gh api /repos/zemo-g/rail/branches/next/protection | jq '.enforce_admins.enabled, .required_pull_request_reviews.dismiss_stale_reviews, .allow_force_pushes.enabled'
gh api /repos/Ledatic-Empire/ledatic-site/branches/main/protection | jq '.enforce_admins.enabled, .required_pull_request_reviews.dismiss_stale_reviews, .allow_force_pushes.enabled'
```
Expect: `true`, `true`, `false`.

**Risk**:
- You can no longer push directly to `next` / `main`. Every change goes through a PR + 1 approval. With a 1-person org, that means you'll PR-and-self-approve from a second account, or temporarily lift protection. Decide which workflow you want.
- Bare-relay `post-receive` → GitHub push from Mini will fail if it pushes to a protected branch without a PR. **Check Mini's `~/git/rail.git/hooks/post-receive` and `~/git/ledatic-site.git/hooks/post-receive` before enabling** — they may push directly to `next`/`main`, which will start failing.

**When**: After Agent 4's H10 force-push has landed. If H10 is deferred indefinitely, do this whenever you're ready to switch to PR-flow.

---

## 4. Colima virtfs scope-down

**Current state**: Active profile `default` (running, x86_64, vz). `~/.colima/default/colima.yaml` has `mounts: []` — meaning **Colima is using its default behavior, which mounts `$HOME` (`~`) as writable** into the VM. This is what the audit flagged as `virtfs path=~,security_model=none`.

**Proposed tighter mounts**: explicit list, drop `$HOME`, scope to what actually needs to be visible inside the VM.

**Workflow dependencies** (grepped `~/projects/rail/tools` and `~/projects/ledatic-site` for non-`projects` paths under `~/`): **none found**. No build script or deploy script references `~/<anything-but-projects>`. The x86 conformance cache at `~/.cache/rail-x86-conformance/` is populated (`asm/`, `import_aux/`), so if the x86 conformance harness runs **inside** the Colima VM (not on host), that path needs to be mounted too. If it only runs on host and reads/writes the cache from host, it does **not** need to be in the VM.

**Action steps**:

1. Confirm whether the x86 conformance harness runs inside Colima or on host:
   ```
   grep -rE 'colima|docker run|docker exec' ~/projects/rail/tools/conformance/ 2>/dev/null | head
   ```
   - If empty → host-only → you do not need `.cache/rail-x86-conformance` mounted.
   - If hits → keep it in the mount list.

2. Stop Colima (this kills containers):
   ```
   colima stop
   ```

3. Edit `~/.colima/default/colima.yaml`. Replace `mounts: []` with:
   ```yaml
   mounts:
     - location: ~/projects
       writable: true
     - location: ~/.cache/rail-x86-conformance
       writable: true     # drop this line if step 1 returned empty
   ```

4. Restart with the same flags it currently uses:
   ```
   colima start --arch x86_64 --vm-type=vz --vz-rosetta
   ```
   (Confirm flags first: `colima list` already shows arch=x86_64; if you've added other flags previously, `cat ~/.colima/default/colima.yaml` shows the full effective config — re-pass any non-default flags here.)

5. Verify the mount inside the VM:
   ```
   colima ssh -- ls ~/
   ```
   Should now show only `projects` (and `.cache/rail-x86-conformance` if you kept it), **not** the whole home dir.

**Risk**:
- Any container that reads `~/<something-outside-projects>` (e.g., `~/.ssh`, `~/.aws`, `~/.config`) will start failing with ENOENT. **This is the security win — those exact paths should not have been in the VM in the first place.**
- Restart kills running containers. If you have any active `docker run`, they die.
- If a future workflow needs another host path inside the VM, you now have to extend `mounts:` and `colima restart` rather than it Just Working.

**When**: Quiet window. Don't do this mid-bench, mid-deploy, or mid-anything that touches Docker.

### Status as of 2026-05-12 21:30

- **Container inventory** (`docker ps`): 0 running containers. Killing the dockerd via `colima stop` will not interrupt any active workload.
- **Colima profiles** (`colima list`): only `default` (Running, x86_64, 4 CPU / 4 GiB RAM / 20 GiB disk, runtime=docker). No stale profile to also fix.
- **In-VM cache verdict**: **YES, keep cache mounts.** `tools/test/x86_conformance.sh:328` runs `docker run --rm --platform=linux/amd64 -v "$STAGE":/stage gcc:latest /stage/runner.sh` with `STAGE="$HOME/.cache/rail-x86-conformance"` (line 17). `tools/test/x86_bitops_smoke.sh:60` does the same with `STAGE="$HOME/.cache/rail-x86-bitops-smoke"` (line 55). Both `-v` mounts require those host paths to be visible inside the Colima VM. Without them, the x86 conformance harness (the 128/128 backend gate) breaks.
  - Note: the original action-step grep hint pointed at `tools/conformance/` and `tools/x86/`, neither of which exist in the tree. The actual scripts live in `tools/test/`. The bitops smoke cache (`rail-x86-bitops-smoke`) was missed by the original §4 template; the prep yaml below adds it.
- **Other host paths grepped** (`~/<not-projects>` references in `tools/` + `ledatic-site/`): none. No additional mounts needed.
- **Prep file**: `~/projects/rail/notes/colima_scoped_mounts.yaml` (proposed replacement; live config untouched).
- **Replay sequence** (run during a quiet window — 60 seconds end-to-end):
  ```
  colima stop
  cp ~/.colima/default/colima.yaml ~/.colima/default/colima.yaml.bak.$(date +%Y%m%d)
  cp ~/projects/rail/notes/colima_scoped_mounts.yaml ~/.colima/default/colima.yaml
  colima start --arch x86_64 --vm-type=vz --vz-rosetta
  colima ssh -- ls ~/
  ```
- **Post-restart verification**:
  1. `colima ssh -- ls ~/` should print **only** `projects` and `.cache` (and `.cache/` should contain only `rail-x86-conformance` and `rail-x86-bitops-smoke`). It should NOT show `.ssh`, `.aws`, `.config`, `Library`, `Documents`, etc. If it does, the new YAML didn't take.
  2. `colima ssh -- cat ~/.ssh/id_ed25519` should fail with "No such file or directory". If it succeeds, the mount scope-down failed.
  3. Smoke the x86 backend cache mount: `bash ~/projects/rail/tools/test/x86_bitops_smoke.sh` should still PASS (proves the cache mount path still works inside the VM).
  4. Full conformance: `bash ~/projects/rail/tools/test/x86_conformance.sh` should still report 128/128 (the backend gate; expected runtime ~minutes).
- **Rollback** (if step 3 or 4 fails): `cp ~/.colima/default/colima.yaml.bak.<DATE> ~/.colima/default/colima.yaml && colima stop && colima start --arch x86_64 --vm-type=vz --vz-rosetta`.

---

## 5. Token rotation pointer

After items 1-4 land, work through Swarm Agent 3's runbook at `~/projects/rail/notes/token_rotation_runbook_2026-05-12.md` (or wherever Agent 3 dropped it). That covers CF_TOKEN, GitHub PATs, and any other secrets flagged by Fixer-4's audit. Don't duplicate that work here.
