#!/usr/bin/env bash
# tools/verify_sdk/selftest.sh — health-check gate for the verifiability SDK.
#
# Compiles sdk.rail to a native binary (exit codes are only honest from the
# compiled binary, NOT from `rail_native run`), then drives the full lifecycle
# in a throwaway sandbox: keygen -> pubkey -> sign -> verify, plus the two
# tamper cases that MUST fail with distinct exit codes.
#
# Crypto gates are hermetic: a local file:// pulse stands in for the live
# beacon so the gate runs offline and deterministically. One extra gate pings
# the real beacon to confirm the supply side is up (skip with
# SDK_SELFTEST_OFFLINE=1).
#
# Exit 0 + last line "PASS" on success; non-zero + "FAIL" otherwise. This is
# the repo gate convention (cf. tools/test/rail_test.rail).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAIL="$REPO_ROOT/rail_native"
SDK_SRC="$REPO_ROOT/tools/verify_sdk/sdk.rail"

PASS=0
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  BAD  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# run <expected_exit> <label> -- <command...>
expect_exit() {
  local want="$1"; shift
  local label="$1"; shift
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then ok "$label (exit $got)"; else bad "$label (want $want, got $got)"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdk_selftest.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

BIN="$SANDBOX/sdk_bin"
KEY="$SANDBOX/key.hex"
ART="$SANDBOX/artifact.txt"
ART_TAMPERED="$SANDBOX/artifact_tampered.txt"
RECEIPT="$SANDBOX/artifact.receipt.json"
RECEIPT_BADSIG="$SANDBOX/receipt_badsig.json"
PULSE="$SANDBOX/pulse.json"

echo "== verify_sdk selftest =="

# --- compile sdk.rail -> native binary (honest exit codes) ----------------
( cd "$REPO_ROOT" && "$RAIL" "$SDK_SRC" ) >/dev/null 2>&1
if [ ! -f /tmp/rail_out ]; then
  bad "compile sdk.rail (no /tmp/rail_out)"
  echo "FAIL ($PASS ok / $FAIL bad)"; exit 1
fi
cp /tmp/rail_out "$BIN" && chmod +x "$BIN"
ok "compile sdk.rail -> binary"

# --- fixtures -------------------------------------------------------------
printf 'ledatic verify_sdk selftest artifact\n' > "$ART"
cp "$ART" "$ART_TAMPERED"; printf 'X' >> "$ART_TAMPERED"   # 1 byte different -> digest changes
cat > "$PULSE" <<'JSON'
{"pulse_id": 999, "value_hex": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", "timestamp_utc": "2026-05-29T00:00:00Z"}
JSON

# --- crypto gates (hermetic, file:// beacon) ------------------------------
expect_exit 0 "keygen"            "$BIN" keygen "$KEY"

# key file is 64 hex chars
keylen=$(tr -d '\n\r ' < "$KEY" | wc -c | tr -d ' ')
if [ "$keylen" -eq 64 ]; then ok "key is 64 hex"; else bad "key length ($keylen != 64)"; fi

expect_exit 1 "keygen refuses to clobber" "$BIN" keygen "$KEY"

# pubkey prints 64 hex on stdout
pub=$("$BIN" pubkey "$KEY" 2>/dev/null | tr -d '\n\r ')
if printf '%s' "$pub" | grep -Eq '^[0-9a-f]{64}$'; then ok "pubkey is 64 hex"; else bad "pubkey not 64 hex ('$pub')"; fi

LEDATIC_BEACON_URL="file://$PULSE" "$BIN" sign "$ART" "$RECEIPT" "$KEY" >/dev/null 2>&1
sign_rc=$?
if [ "$sign_rc" -eq 0 ] && [ -f "$RECEIPT" ]; then ok "sign -> receipt"; else bad "sign (rc=$sign_rc, receipt? $( [ -f "$RECEIPT" ] && echo yes || echo no ))"; fi

expect_exit 0 "verify (untouched)"        "$BIN" verify "$ART" "$RECEIPT"
expect_exit 5 "verify content-tamper -> 5" "$BIN" verify "$ART_TAMPERED" "$RECEIPT"

# sig tamper: flip the first hex digit of the signature (stays valid hex, wrong sig)
sig=$(grep '"sig"' "$RECEIPT" | sed -E 's/.*"sig": "([0-9a-f]+)".*/\1/')
case "${sig:0:1}" in 0) newc=1;; *) newc=0;; esac
badsig="${newc}${sig:1}"
sed "s/\"sig\": \"$sig\"/\"sig\": \"$badsig\"/" "$RECEIPT" > "$RECEIPT_BADSIG"
expect_exit 6 "verify sig-tamper -> 6"     "$BIN" verify "$ART" "$RECEIPT_BADSIG"

# --- live beacon reachability (skip with SDK_SELFTEST_OFFLINE=1) ----------
if [ "${SDK_SELFTEST_OFFLINE:-0}" = "1" ]; then
  echo "  --   live beacon check skipped (SDK_SELFTEST_OFFLINE=1)"
else
  raw=$(curl -s --max-time 6 'https://ledatic.org/entropy/pulse' 2>/dev/null)
  if printf '%s' "$raw" | grep -q '"pulse_id"' && \
     printf '%s' "$raw" | grep -Eq '"value_hex"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"'; then
    ok "live beacon reachable"
  else
    bad "live beacon unreachable or malformed"
  fi
fi

echo "== $PASS ok / $FAIL bad =="
if [ "$FAIL" -eq 0 ]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
