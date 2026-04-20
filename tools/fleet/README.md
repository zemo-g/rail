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
echo "10.42.0.X" > ~/.fleet/tb-ip           # Mini=.1, Studio=.2, Air=.3
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
