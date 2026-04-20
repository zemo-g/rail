# SECURITY_HANDOFF — v2 (Fort Knox punch list)

**Origin:** self-audit 2026-04-20 after the v1 security pass.  Ten holes
identified; each becomes a ticket below.  Execution order is designed
so nothing interrupts the user's SSH, site, or fleet access.

Every ticket has: **scope**, **files touched**, **commands**, **verification**,
**rollback**.  Per-node blocks are ready to paste.  Tickets are independent
— skip any, order preserved.

---

## T1 — IPv6 pf rules

**Scope:** The current pf anchor blocks IPv4 only.  If any service
binds `::` (IPv6 all-interfaces), LAN/WAN peers reach it via IPv6.
`fleet_agent_v3` currently shows `*.9101` (IPv4), but belt-and-suspenders.

**Files:** `tools/fleet/pf_ledatic_fleet.conf` — add `inet6` parallel
rules.  See `tools/fleet/pf_ledatic_fleet.v2.conf` for the ready version.

**Command (per node):**
```bash
sudo bash ~/projects/rail/tools/fleet/security_bootstrap.sh
```
(re-run is idempotent; picks up the new anchor text automatically)

**Verification:**
```bash
sudo pfctl -s rules | grep -E "(9101|inet6)"
# Must show block+pass pairs for both inet and inet6
```

**Rollback:**
```bash
sudo sed -i '' '/^# Fleet control-plane firewall/,/load anchor "ledatic_fleet"/d' /etc/pf.conf
sudo rm /etc/pf.anchors/ledatic_fleet
sudo pfctl -f /etc/pf.conf
```

---

## T2 — authorized_keys preflight in SSH key-only step

**Scope:** `security_bootstrap.sh` currently disables password auth
after validating sshd_config syntax — but doesn't verify that a public
key is actually installed.  On a node without `~/.ssh/authorized_keys`,
the user is locked out.

**Files:** `tools/fleet/security_bootstrap.sh` — already patched in v2.

**Behavior after patch:** script aborts with explicit error
`ERR: no authorized_keys for user <u>, refusing to disable password auth`.

**Verification:**
```bash
ls -la ~/.ssh/authorized_keys        # must exist, chmod 600
```

**Rollback:** the script already validates sshd_config and skips restart
on error; rollback only needed if you want password auth back:
```bash
sudo sed -i '' 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo launchctl kickstart -k system/com.openssh.sshd
```

---

## T3 — pf reboot persistence

**Scope:** `pfctl -e` enables pf for the current boot.  macOS's
`com.apple.pfctl` LaunchDaemon loads `/etc/pf.conf` at boot but doesn't
always toggle enable.  Need to verify pf stays on across reboots.

**Files:** `tools/fleet/com.ledatic.pf_enable.plist` — new LaunchDaemon
that runs `pfctl -e` at boot, idempotent.

**Command (per node):**
```bash
sudo cp ~/projects/rail/tools/fleet/com.ledatic.pf_enable.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.ledatic.pf_enable.plist
sudo chmod 644       /Library/LaunchDaemons/com.ledatic.pf_enable.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ledatic.pf_enable.plist
```

**Verification:**
```bash
sudo launchctl print system/com.ledatic.pf_enable | grep state
# Then reboot and re-run:
sudo pfctl -s info | head -2     # Status: Enabled
```

---

## T4 — Rate limit rule for reports.ledatic.org

**Scope:** Current `general-rate-limit` matches only `http.host eq "ledatic.org"`.
The reports subdomain has auth-gated PDF serves that can be hammered.

**Where:** CF Dashboard → Security → WAF → Rate limiting rules → Create rule.

**Rule:**
- Name: `reports-rate-limit`
- Match expression: `(http.host eq "reports.ledatic.org")`
- Rate: `60 requests / 60 seconds` per IP (reports reads are slow + infrequent; this is tight but not painful)
- Action: Block, Duration 60s

**Verification:** hit `reports.ledatic.org/api/login` 61 times in a minute from one IP — should block.

---

## T5 — Report portal password hash upgrade (PBKDF2 + salt)

**Scope:** `worker.js:158-162` uses raw SHA-256 of password.  No salt,
no iterations.  A KV dump = rainbow-table-able passwords.

**Files:**
- `tools/deploy/worker.js` — replace `hashPassword` with PBKDF2-SHA256 (100k iterations) using a per-client random salt.
- `tools/deploy/worker_migrate_passwords.md` — migration plan: on next successful login with the old hash, re-hash to new format and update KV.  Backwards-compatible during the transition window.

**Commands:** deploy via `bash tools/deploy/deploy_worker.sh` once the change + migration path land.  No user-visible change; existing sessions stay valid; re-logins silently upgrade.

**Rollback:** `git revert` the worker commit, redeploy.  Users on upgraded hashes need to reset passwords (no automated downgrade).

---

## T6 — Fleet token rotation utility

**Scope:** Fleet token at `~/.fleet/token` — 64 hex, rotated once
(2026-04-18).  Stays forever.  Should rotate quarterly minimum, or
on-demand if compromised.

**Files:** `tools/fleet/rotate_fleet_token.sh` — new; generates a new
token, stamps all four nodes atomically (via ssh), validates fleet
endpoint still responds on each.

**Command (Mini-only, run once per rotation):**
```bash
bash ~/projects/rail/tools/fleet/rotate_fleet_token.sh
```
Script prompts for confirmation, new token → Mini → Studio → Air → Pi,
validates `curl -H "X-Fleet-Token: <new>" http://<node>:9101/health`
on each.  On any failure, rolls back.

---

## T7 — Tailscale peer drift alert

**Scope:** pf admits `100.64.0.0/10` — the whole tailnet.  If an
unexpected device joins (old shared account, forgotten laptop), it's
inside the fleet trust boundary.

**Files:**
- `tools/fleet/tailscale_peer_check.sh` — new; compares `tailscale status` peer list against `~/.fleet/allowed_tailnet_peers`.  On mismatch, posts to Slack + logs.
- `tools/fleet/com.ledatic.tailscale_peer_check.plist` — new LaunchAgent, runs hourly on Mini.

**Command (Mini):**
```bash
tailscale status | awk 'NR>1 {print $2}' | sort > ~/.fleet/allowed_tailnet_peers
chmod 600 ~/.fleet/allowed_tailnet_peers
sudo cp ~/projects/rail/tools/fleet/com.ledatic.tailscale_peer_check.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.ledatic.tailscale_peer_check.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ledatic.tailscale_peer_check.plist
```

**Verification:** manually add a test peer → within an hour, Slack DM.
Remove it → DM clears.

---

## T8 — Log permission hardening

**Scope:** `/var/log/tb_autojoin.log` is `chmod 644` (world-readable).
No secrets in the log today, but the principle stands.

**Files:** `tools/fleet/tb_autojoin.sh` — add `chmod 600 "$LOG"` after
first write.  Trivial diff.

**Command (per node):** next `tb_autojoin` tick applies the chmod on its
own.  No manual intervention.

---

## T9 — CF API token scope audit

**Scope:** `~/Desktop/rings` was scoped "KV write" per memory, but
hasn't been verified.  If overly broad (e.g., global zone:edit), it's
one stolen file away from catastrophe.

**Files:** `tools/deploy/audit_cf_token.sh` — new; calls
`/user/tokens/:id` and prints the permission list.  Flags broad scopes.

**Command (Mini):**
```bash
bash ~/projects/rail/tools/deploy/audit_cf_token.sh
```

**Remediation if broad:** create a new scoped token (KV write + cache
purge only), update `~/Desktop/rings`, revoke the old one in CF dash.

---

## T10 — Dashboard tune: rate limit split by content type

**Scope:** Current `general-rate-limit` at 600/10s is loose.  A real
user browsing rarely exceeds 60/10s HTML-only; static assets fan-out
to ~30 per page.  Split the rule for tighter HTML protection without
false-positives on asset bursts.

**Where:** CF Dashboard → Security → WAF → Rate limiting rules.

**Replace `general-rate-limit` with two:**

1. `html-rate-limit`
   - Match: `(http.host eq "ledatic.org" and not http.request.uri.path matches "\\.(css|js|wasm|svg|png|jpg|webp|ico|woff2?|ttf)$")`
   - Rate: `60 / 10s`, Block 10s

2. `asset-rate-limit`
   - Match: `(http.host eq "ledatic.org" and http.request.uri.path matches "\\.(css|js|wasm|svg|png|jpg|webp|ico|woff2?|ttf)$")`
   - Rate: `600 / 10s`, Block 10s

---

## Execution order (recommended)

Safest order; each step is independently revertible:

```
T8  (log chmod)              — auto, next daemon tick, zero risk
T1  (IPv6 pf rules)          — idempotent re-run of security_bootstrap.sh
T2  (authorized_keys check)  — same re-run, aborts if keys missing
T3  (pf reboot persistence)  — install LaunchDaemon, reboot test optional
T6  (token rotation script)  — ship first, rotate on a quiet morning
T7  (tailscale peer drift)   — after T6 so both are observable
T9  (CF token audit)         — read-only probe, decide if rotation needed
T10 (dashboard rate split)   — 5 min clicks
T4  (reports rate rule)      — 2 min clicks
T5  (password hash upgrade)  — last; requires code review + migration window
```

**Nothing in T1–T10 changes your SSH, daily site access, or fleet
control-plane UX.** The only dashboard-facing changes (T4, T10) are
additive WAF rules; your IP is on the allow list, so you bypass both.

---

## Verification script

After any subset, run:

```bash
bash ~/projects/rail/tools/fleet/security_status.sh
```

Prints a one-screen summary: pf status per node, sshd PasswordAuth
value, log perms, token age, tailnet peer diff, CF token scope.
(Lives at `tools/fleet/security_status.sh` alongside the other fleet
tooling.)

---

## Non-goals (explicitly)

- Two-factor on SSH (complex for a 3-node fleet; key-only + Tailscale ACLs are enough).
- Full SIEM / log shipping (Slack alerts on specific events are sufficient at this scale).
- Changing the fleet control-plane auth model beyond token rotation (v3 is stable).
- Touching the Rail compiler, training stack, or anything in `stdlib/` — all out of scope.
