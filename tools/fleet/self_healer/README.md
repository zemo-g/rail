# Mini self-healer

90-second reflex loop that watches the local Mini for the failure modes that have actually bitten the fleet. Auto-fixes the safe stuff (bridge0 alias, TB peer membership, token perms), alerts on the rest. Companion to `tools/attest/drift_audit.sh` (deeper, weekly) and `tools/attest/daily.sh` (production attest, 06:00 daily).

## Where it runs

| | |
|---|---|
| Script | `~/.fleet/self_healer/heal.sh` (this file is the canonical copy) |
| Wiring | `~/Library/LaunchAgents/com.ledatic.self_healer.plist` |
| Cadence | every 90 s (StartInterval) |
| State | `~/.fleet/self_healer/{state.json, heal.log, events.jsonl, heartbeat, breaker, rate.log}` |

## Checks

| Check | Auto-fix? | Pattern |
|---|---|---|
| `bridge_alias` | ✅ `sudo ifconfig bridge0 alias 10.42.0.1 …` | re-add when missing |
| `bridge_members` | ✅ `sudo ifconfig bridge0 addm enN` | new TB peers |
| `token_health` | ✅ `chmod 600 ~/.fleet/token` | perms drift |
| `wan` | alert | 3-consecutive-down before scream |
| `fleet_reach` | alert | ≥2 nodes down |
| `fleet_agent` | alert | LaunchAgent missing |
| `attest_surfaces` | alert | beacon stale 5 min / witness silent 5 min / `/builds/latest` > 36 h |

The `attest_surfaces` check (added 2026-05-04) catches the failure mode where a service is "active" per systemd / launchd but is producing no output — the bash glob crashloop that silenced fleet0 for 80 h is the canonical example.

## Safety guarantees

- Narrow `sudo` (only `ifconfig alias|addm|up`) via `/etc/sudoers.d/fleet-healer`
- Rate limit: same fix ≤ 3 in 10 min
- Circuit breaker: 10 failures/hr → pause + Slack scream
- Never touches: plists, binaries, LaunchDaemon state, fleet token *content*
- Only mutates: `bridge0` aliases/members, token *perms*

## Running ad-hoc

```bash
~/.fleet/self_healer/heal.sh              # single pass (default; what LaunchAgent invokes)
~/.fleet/self_healer/heal.sh test         # dry-run all checks, no fixes
~/.fleet/self_healer/heal.sh status       # human-readable recent events
~/.fleet/self_healer/heal.sh events 50    # last 50 raw event JSON lines
~/.fleet/self_healer/heal.sh reset        # clear circuit breaker + rate limit counters
```

`SELF_HEALER_DRYRUN=1 ~/.fleet/self_healer/heal.sh` does a real pass with all auto-fixes turned off.

## Slack delivery

Direct to `slack.com/api/chat.postMessage` with TLS 1.3 (was previously routed via a socat proxy on `:8444` — that proxy had a TLS version mismatch and was eating every alert silently for weeks; fixed 2026-05-04). All alerts go to `brockbro2` DM (`D0ATHQ1BQD7`).

## Recovery scenario

Fresh Mini setup or bare-metal recovery:

```bash
# 1. Drop heal.sh into place + make executable
mkdir -p ~/.fleet/self_healer
cp tools/fleet/self_healer/heal.sh ~/.fleet/self_healer/heal.sh
chmod +x ~/.fleet/self_healer/heal.sh

# 2. Drop LaunchAgent plist (template — adjust paths if HOME is non-default)
cat > ~/Library/LaunchAgents/com.ledatic.self_healer.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.ledatic.self_healer</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>$HOME/.fleet/self_healer/heal.sh</string>
    </array>
    <key>StartInterval</key><integer>90</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/.fleet/self_healer/launchd.log</string>
    <key>StandardErrorPath</key><string>$HOME/.fleet/self_healer/launchd.err</string>
</dict>
</plist>
PLIST

# 3. Narrow sudoers entry
sudo tee /etc/sudoers.d/fleet-healer <<SUDOERS >/dev/null
$USER ALL=(root) NOPASSWD: /sbin/ifconfig bridge0 alias *, /sbin/ifconfig bridge0 addm en*, /sbin/ifconfig en* up
SUDOERS
sudo chmod 0440 /etc/sudoers.d/fleet-healer

# 4. Bootstrap
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ledatic.self_healer.plist
launchctl list | grep self_healer
```
