# tools/fleet

Fleet-wide daemons and orchestration for the Rail compute fleet
(Mini hub + Studio/Air spokes + Pi).

## tb_autojoin — walk-away Thunderbolt bridge reconciler

`tb_autojoin.sh` + `com.ledatic.tb_autojoin.plist`.

Runs as root under launchd every 30 s on each TB-cabled node. Enumerates
`en<N>` interfaces, classifies each as a real TB peer or a stub (USB-C
Ethernet dongle, Apple's shadow adapters), and reconciles `bridge0`:

- Ensures `bridge0` exists with the node's IP from `~/.fleet/tb-ip`
- Adds any real peer not yet in `bridge0`
- Removes any stale member that isn't a real peer
- Toggles the Thunderbolt Bridge service if `bridge0` is `inactive`
  but real peers are present

Plug a cable → fabric self-joins within 30 s. Unplug → stub cleaned
within 30 s. Walk-away.

### Install (per node)

```bash
echo "10.42.0.X" > ~/.fleet/tb-ip           # Mini=.1, Studio=.2, Air=.3 (leak-guard-allow: convention example)
sudo cp tools/fleet/com.ledatic.tb_autojoin.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.ledatic.tb_autojoin.plist
sudo chmod 644        /Library/LaunchDaemons/com.ledatic.tb_autojoin.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ledatic.tb_autojoin.plist
```

Immediate dry-run (before installing the plist) to confirm idempotence:

```bash
sudo bash tools/fleet/tb_autojoin.sh
sudo bash tools/fleet/tb_autojoin.sh    # second pass should be a no-op
tail -20 /var/log/tb_autojoin.log
```

### Opt out

```bash
rm ~/.fleet/tb-ip                       # next pass logs no-ip-configured, exits
```

### Uninstall

```bash
sudo launchctl bootout system/com.ledatic.tb_autojoin
sudo rm /Library/LaunchDaemons/com.ledatic.tb_autojoin.plist
```

### Observe

- `/var/log/tb_autojoin.log` — one line per interface classified +
  summary line per pass (rotated at 1 MiB to `.prev`)
- `/var/log/tb_autojoin.launchd.out|.err` — launchd-captured stdio
  (should stay empty)
- `sudo launchctl print system/com.ledatic.tb_autojoin` — launchd state

## security_bootstrap — one-shot hardening

`security_bootstrap.sh` + `pf_ledatic_fleet.conf`.

Run once per node. Locks down the fleet control plane (`:9101`) and
local TLS proxies (`:8443/:8444/:8445`) to loopback + Tailscale + the
TB mesh only, and forces SSH into key-only mode.

### Install (per node)

```bash
sudo bash tools/fleet/security_bootstrap.sh
```

Idempotent — re-run anytime to re-apply. The sshd step validates the
config with `sshd -t` before restart so a typo can't lock you out.

### Verify

```bash
sudo pfctl -s rules | grep 9101
sudo pfctl -s info   | head -2                    # Status: Enabled
# From a LAN IP that isn't on Tailscale:
curl -m 3 http://<node-lan-ip>:9101/health        # should time out / be dropped
# From the same node:
curl -s http://127.0.0.1:9101/health              # should respond
```

### Rollback

```bash
sudo sed -i '' '/^# Fleet control-plane firewall/,/load anchor "ledatic_fleet"/d' /etc/pf.conf
sudo rm /etc/pf.anchors/ledatic_fleet
sudo pfctl -f /etc/pf.conf
# sshd: revert via System Settings → General → Sharing → Remote Login options,
# or edit /etc/ssh/sshd_config back and kickstart sshd.
```

