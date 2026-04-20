# Entropy beacon witnesses

Public registry of Ed25519 keys used by fleet nodes to sign
observations of `ledatic.org/entropy/pulse`.

Each witness independently polls the beacon, verifies chain linkage
between consecutive pulses, and appends signed records to a local log.
The daemon that produces these signatures is `witness.sh` in this
directory.

## Verification

Each signed record is a JSONL line of the form:

```json
{
  "pulse_id":       53512,
  "value_hex":      "82b5…ce82",       // beacon SHA-256 for this pulse
  "prev_hex":       "6515…1073",       // beacon's prev_value_hex as fetched
  "beacon_ts":      "2026-04-20T23:00:38Z",
  "beacon_unix":    1776726038,
  "witnessed_at":   1776726041,        // unix seconds (witness-local clock)
  "gap":            1,                 // pulses skipped since last observation
  "chain_verified": true,              // gap==1 && prev_hex==our_prev_value
  "sig":            "…base64…",        // Ed25519 over `${pulse_id}|${value_hex}|${witnessed_at}`
  "pk_fp":          "cac5f21a70564aeb",// sha256(DER public key)[:16]
  "witness":        "fleet0"
}
```

To verify one line, recover the key from this file by `pk_fp`, rebuild
the message `"${pulse_id}|${value_hex}|${witnessed_at}"`, base64-decode
the `sig`, and run Ed25519 verify:

```bash
# Given one log line in $line:
pulse_id=$(jq -r .pulse_id <<<"$line")
value_hex=$(jq -r .value_hex <<<"$line")
witnessed_at=$(jq -r .witnessed_at <<<"$line")
msg="${pulse_id}|${value_hex}|${witnessed_at}"

# Pin the public key for this witness (see fingerprint table below):
cat > /tmp/pk.pem <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEABYCyN+fTbPuRA0BKpSmWhzW+auY1IXiOo99C4cmXBQI=
-----END PUBLIC KEY-----
EOF

# Verify:
jq -r .sig <<<"$line" | base64 -d > /tmp/sig.bin
printf '%s' "$msg" > /tmp/msg.bin
openssl pkeyutl -verify -pubin -inkey /tmp/pk.pem -rawin \
  -in /tmp/msg.bin -sigfile /tmp/sig.bin
# → "Signature Verified Successfully"
```

Cross-reference `value_hex` and `prev_hex` against the live beacon
(`https://ledatic.org/entropy/pulse`) or against other witnesses. A
record is a second-party attestation that the beacon emitted this
pulse at this time as seen from this witness. It doesn't prove the
beacon's plasma source — it proves *independent observation and time
stamping*.

## Witnesses

### fleet0 (Pi Zero 2 W, Tailscale 100.87.231.45)

- **Fingerprint:** `cac5f21a70564aeb`
- **Algorithm:** Ed25519
- **Since:** 2026-04-20
- **Runtime:** `witness.sh` under systemd `witness.service`

```
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEABYCyN+fTbPuRA0BKpSmWhzW+auY1IXiOo99C4cmXBQI=
-----END PUBLIC KEY-----
```

---

New witnesses append a new section. Rotation: generate a new keypair,
publish the new fingerprint with a **Since:** date, keep the old entry
with a **Until:** date so historical log verifications still resolve.
