# Witness rollout — fleet0 (Pi) and beyond

The witness daemon scripts (`tools/fleet/witness.sh`, `witness_push.sh`) and systemd unit files were committed weeks ago (`33ecf46`, `9a2e9a6`); the Worker route at `PUT/GET /witness/<node>/latest` is already in `Ledatic-Empire/ledatic-site`'s worker.js. Per `worker_state_2026-05-02.md`, Mini's worker.js is canonical and includes the route. The remaining work is **getting the daemon running on the Pi** and **registering the fingerprint in WITNESSES.md**.

This doc is the end-to-end recipe.

## Prerequisites

- Pi reachable via Tailscale. From `tools/fleet/WITNESSES.md`: fleet0 = Pi Zero 2 W, Tailscale IP `<witness-tailscale-ip>`. SSH alias `pi` is conventional but verify with `ssh pi hostname` before relying on it.
- The shared `BEACON_TOKEN` lives at `~/.ledatic/entropy/beacon_token` on Studio (used by `tools/attest/frame_attest_ot256_publisher.sh`). Same token authenticates both the entropy publisher (Studio → Worker) and the witness publisher (Pi → Worker).
- Pi has `openssl`, `curl`, `python3`, `systemctl`, `sha256sum`. Stock Raspberry Pi OS includes all of these.

## Rollout (Studio → Pi)

```bash
# 1. From Studio (or wherever the rail repo lives):
PI=pi   # or <witness-tailscale-ip> — whichever resolves on the tailnet
cd ~/projects/rail

ssh "$PI" 'mkdir -p ~/.ledatic/witness'
scp -p tools/fleet/witness.sh                "$PI":~/.ledatic/witness/
scp -p tools/fleet/witness_push.sh           "$PI":~/.ledatic/witness/
scp -p tools/fleet/witness.service           "$PI":~/.ledatic/witness/
scp -p tools/fleet/witness_push.service      "$PI":~/.ledatic/witness/
scp -p tools/fleet/install_witness.sh        "$PI":~/.ledatic/witness/

# 2. Hand the Pi a copy of the upload token.  Two paths:
#    a) Push from Studio (token never leaves Studio's filesystem briefly).
scp -p ~/.ledatic/entropy/beacon_token       "$PI":~/.ledatic/witness/upload_token
ssh "$PI" 'chmod 600 ~/.ledatic/witness/upload_token'

#    b) Or pull from Studio at install time (TOKEN_SRC env var below).

# 3. Run the installer on the Pi.
ssh "$PI" 'cd ~/.ledatic/witness && WITNESS_NAME=fleet0 ./install_witness.sh'
```

The installer is idempotent — re-running it after a tweak doesn't break anything.

It will:
1. Verify all five required files are in place
2. Generate `witness.sk` (Ed25519) on first run, reuse on subsequent
3. Print the `pk_fp` (16-hex sha256 of DER-encoded pubkey) for `WITNESSES.md`
4. Confirm `upload_token` exists (pulls from `$TOKEN_SRC` if not)
5. Install both systemd units in `/etc/systemd/system/` (rewriting `User=` and the path prefix to match the install location, since the bundled service files assume `~/...`)
6. Pin `WITNESS_NAME=fleet0` via a systemd drop-in if hostname differs
7. `daemon-reload`, `enable`, `restart` both services
8. Poll `https://ledatic.org/witness/fleet0/latest` for up to 30 s waiting for the first round-trip, then dump the published record

A successful run ends with the JSON body of the latest signed record.

## Verification (from anywhere)

```bash
curl -s https://ledatic.org/witness/fleet0/latest | python3 -m json.tool
```

Expected fields per `tools/fleet/WITNESSES.md`:
```
pulse_id, value_hex, prev_hex, beacon_ts, beacon_unix,
witnessed_at, gap, chain_verified, sig, pk_fp, witness
```

The dashboard at `https://ledatic.org/witness.html` flips its fleet0 card from amber `fixture` to green `live` automatically (the fixture fallback only fires on 404; once the route returns 200, the live record wins).

End-to-end signature verification (also documented in `tools/fleet/WITNESSES.md`):
```bash
line=$(curl -s https://ledatic.org/witness/fleet0/latest)
pulse_id=$(printf '%s' "$line" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])")
value_hex=$(printf '%s' "$line" | python3 -c "import sys,json;print(json.load(sys.stdin)['value_hex'])")
witnessed_at=$(printf '%s' "$line" | python3 -c "import sys,json;print(json.load(sys.stdin)['witnessed_at'])")
sig=$(printf '%s' "$line" | python3 -c "import sys,json;print(json.load(sys.stdin)['sig'])")
msg="${pulse_id}|${value_hex}|${witnessed_at}"

# Pin the fleet0 pubkey from WITNESSES.md (replace with the actual block):
cat > /tmp/pk.pem <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEABYCyN+fTbPuRA0BKpSmWhzW+auY1IXiOo99C4cmXBQI=
-----END PUBLIC KEY-----
EOF
printf '%s' "$msg" > /tmp/msg.bin
printf '%s' "$sig"  | base64 -d > /tmp/sig.bin
openssl pkeyutl -verify -pubin -inkey /tmp/pk.pem -rawin -in /tmp/msg.bin -sigfile /tmp/sig.bin
# → "Signature Verified Successfully"
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `install_witness.sh: upload_token missing` | Token wasn't scp'd or env var unset | Push token from Studio (step 2a above) |
| `PUT https://ledatic.org/witness/fleet0/latest → 401` | `upload_token` doesn't match the Worker's expected secret | Verify Studio's token is current; rotate if needed |
| `PUT ... → 403` | `node` not in Worker's allow-list | Worker has `{fleet0}` allow-listed by default; new nodes need a Worker-side update |
| `PUT ... → 404` | Worker route not deployed | Verify with `curl -sI https://ledatic.org/witness/fleet0/latest`; if 404, the worker.js patch from `33ecf46`'s sibling commit didn't ship |
| Service starts then exits | Missing `witness.sk` permissions or openssl | `journalctl -u witness.service -n 50` |
| `chain_verified: false` in published records | Beacon's `prev_value_hex` doesn't match the witness's local last-seen | Wipe `$WITNESS_DIR/last_value` to reset chain anchor |

## Adding more witnesses (mini, studio, etc.)

The installer is deliberately node-agnostic. To add Mini as a witness:
```bash
ssh mini 'mkdir -p ~/.ledatic/witness'
scp -p tools/fleet/{witness.sh,witness_push.sh,witness.service,witness_push.service,install_witness.sh} mini:~/.ledatic/witness/
scp -p ~/.ledatic/entropy/beacon_token mini:~/.ledatic/witness/upload_token
ssh mini 'cd ~/.ledatic/witness && WITNESS_NAME=mini ./install_witness.sh'
```

Each new witness needs:
1. Its own `pk_fp` recorded in `tools/fleet/WITNESSES.md`
2. The Worker's allow-list updated to include the new `<node>` name (one-line patch in worker.js, currently allows only `{fleet0}`)
3. The `wasmRender`-style witness registry in `tools/witness/viz.html` extended (one entry append in the `WITNESSES = [...]` array)

All three are a few minutes of work per node.

## What "live" looks like

Once `fleet0` publishes:
- `/witness.html` shows fleet0 card with green `live` pill, real `pulse_id`, recent `witnessed_at`, `chain_verified ✓`
- Dashboard's status header reads "consensus" (only one witness is reporting, but it agrees with itself trivially)
- `/now.html` "Witness" lane's "fleet0 witness daemon" item flips from `awaiting publisher` to `live`

Once mini and studio publish:
- All three cards green, header reads "consensus" non-trivially (three independent observers agreeing)
- Any future tampering with the beacon would show as `divergent` or `chain-break` immediately
