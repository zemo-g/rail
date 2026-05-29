#!/usr/bin/env bash
# tools/verify_sdk/selftest.sh — health-check gate for the verifiability SDK.
#
# Compiles sdk.rail to a native binary (exit codes are only honest from the
# compiled binary, NOT from `rail_native run`), then drives the full lifecycle
# in a throwaway sandbox: keygen -> pubkey -> sign -> verify, plus the tamper
# cases that MUST fail with distinct exit codes.
#
# Anchored-receipt gates exercise the paid path offline: witness_sign.rail is
# the reference counter-signer and doubles as the oracle that forges a valid
# witness response, so `sign --anchor` and the pinned-key verify (which fails
# closed with exit 10) run without the live metered endpoint.
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
VHEX="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
LOOKDIR="$SANDBOX/lookup"; mkdir -p "$LOOKDIR/empty"
printf 'ledatic verify_sdk selftest artifact\n' > "$ART"
cp "$ART" "$ART_TAMPERED"; printf 'X' >> "$ART_TAMPERED"   # 1 byte different -> digest changes
printf '{"pulse_id": 999, "value_hex": "%s", "timestamp_utc": "2026-05-29T00:00:00Z"}\n' "$VHEX" > "$PULSE"

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

# --- membership gates (hermetic, file:// pulse-by-id lookup) --------------
# receipt cites pulse 999; lookup serves /<id> as a file named by the id.
printf '{"pulse_id": 999, "value_hex": "%s", "timestamp_utc": "x"}\n' "$VHEX" > "$LOOKDIR/999"
expect_exit 0 "membership match -> 0"      env LEDATIC_PULSE_LOOKUP="file://$LOOKDIR/"       "$BIN" verify "$ART" "$RECEIPT" --check-beacon
printf '{"pulse_id": 999, "value_hex": "%s", "timestamp_utc": "x"}\n' "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" > "$LOOKDIR/999"
expect_exit 8 "membership mismatch -> 8"   env LEDATIC_PULSE_LOOKUP="file://$LOOKDIR/"       "$BIN" verify "$ART" "$RECEIPT" --check-beacon
expect_exit 9 "membership unverifiable -> 9" env LEDATIC_PULSE_LOOKUP="file://$LOOKDIR/empty/" "$BIN" verify "$ART" "$RECEIPT" --check-beacon
# endpoint serves the WRONG pulse for the requested id (e.g. latest-for-all misconfig) -> unverifiable, not a false pass
printf '{"pulse_id": 12345, "value_hex": "%s", "timestamp_utc": "x"}\n' "$VHEX" > "$LOOKDIR/999"
expect_exit 9 "membership wrong-id -> 9"   env LEDATIC_PULSE_LOOKUP="file://$LOOKDIR/"       "$BIN" verify "$ART" "$RECEIPT" --check-beacon

# --- anchored-receipt gates (hermetic: file:// anchor + witness oracle) ----
# A credit buys a Ledatic witness counter-signature. The oracle forges a valid
# witness response offline so the paid path runs without the metered endpoint.
( cd "$REPO_ROOT" && "$RAIL" "$REPO_ROOT/tools/verify_sdk/witness_sign.rail" ) >/dev/null 2>&1
if [ -f /tmp/rail_out ]; then
  WITNESS_BIN="$SANDBOX/witness_bin"; cp /tmp/rail_out "$WITNESS_BIN" && chmod +x "$WITNESS_BIN"
  ok "compile witness_sign.rail -> binary"
else
  bad "compile witness_sign.rail (no /tmp/rail_out)"
fi

# ephemeral witness key (NOT fleet0, NOT the caller signing key); pin it via env
WKEY="$SANDBOX/witness_key.hex"
"$BIN" keygen "$WKEY" >/dev/null 2>&1
WPUB=$("$BIN" pubkey "$WKEY" 2>/dev/null | tr -d '\n\r ')
WFP="${WPUB:0:16}"
WHEN=1780000000
# DIGEST must be the SDK's OWN sha256 of ART -> read it back from the bare receipt
DIGEST=$(grep '"sha256"' "$RECEIPT" | sed -E 's/.*"sha256": "([0-9a-f]+)".*/\1/')
# oracle signs the canonical witness msg: attest|v1|<digest>|<pulse_id>|<value_hex>|<witnessed_at>
WSIG=$("$WITNESS_BIN" "$WKEY" "$DIGEST" 999 "$VHEX" "$WHEN" 2>/dev/null | tr -d '\n\r ')
ANCHOR_OK="$SANDBOX/anchor_ok.json"
printf '{"witnessed_at": %s, "pk_fp": "%s", "sig": "%s"}\n' "$WHEN" "$WFP" "$WSIG" > "$ANCHOR_OK"
ANCHOR_402="$SANDBOX/anchor_402.json"
printf '{"error": "payment_required"}\n' > "$ANCHOR_402"
ANCHORED="$SANDBOX/artifact.anchored.json"
ANCHORED_BADW="$SANDBOX/anchored_badwsig.json"

# sign --anchor against the canned-OK anchor -> receipt carries a witness{} block
env LEDATIC_BEACON_URL="file://$PULSE" LEDATIC_ANCHOR_URL="file://$ANCHOR_OK" \
    LEDATIC_SDK_API_KEY="testkey" LEDATIC_WITNESS_PUBKEY="$WPUB" \
    "$BIN" sign "$ART" "$ANCHORED" "$KEY" --anchor >/dev/null 2>&1
anc_rc=$?
if [ "$anc_rc" -eq 0 ] && grep -q '"witness"' "$ANCHORED"; then ok "sign --anchor -> anchored receipt"; else bad "sign --anchor (rc=$anc_rc, witness? $(grep -q '"witness"' "$ANCHORED" 2>/dev/null && echo yes || echo no))"; fi

# verify anchored with the correct pinned witness key -> strongest verdict, 0
expect_exit 0 "verify anchored (pinned ok) -> 0"    env LEDATIC_WITNESS_PUBKEY="$WPUB" "$BIN" verify "$ART" "$ANCHORED"

# wrong pinned key: receipt pk_fp != pinned fp -> fail closed (never a false pass)
expect_exit 10 "verify anchored wrong-pin -> 10"    env LEDATIC_WITNESS_PUBKEY="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "$BIN" verify "$ART" "$ANCHORED"

# tampered witness sig (fp still matches): sig verify fails -> fail closed
wsig=$(grep '"sig"' "$ANCHORED" | tail -1 | sed -E 's/.*"sig": "([0-9a-f]+)".*/\1/')
case "${wsig:0:1}" in 0) wnc=1;; *) wnc=0;; esac
sed "s/\"sig\": \"$wsig\"/\"sig\": \"${wnc}${wsig:1}\"/" "$ANCHORED" > "$ANCHORED_BADW"
expect_exit 10 "verify anchored tampered-wsig -> 10" env LEDATIC_WITNESS_PUBKEY="$WPUB" "$BIN" verify "$ART" "$ANCHORED_BADW"

# out of credits: server returns payment_required -> SDK exits 3
expect_exit 3 "sign --anchor out-of-credits -> 3"  env LEDATIC_BEACON_URL="file://$PULSE" LEDATIC_ANCHOR_URL="file://$ANCHOR_402" LEDATIC_SDK_API_KEY="testkey" "$BIN" sign "$ART" "$SANDBOX/nope.json" "$KEY" --anchor

# no API key configured -> SDK exits 2 (before contacting the endpoint)
expect_exit 2 "sign --anchor no-API-key -> 2"      env -u LEDATIC_SDK_API_KEY LEDATIC_BEACON_URL="file://$PULSE" LEDATIC_ANCHOR_URL="file://$ANCHOR_OK" "$BIN" sign "$ART" "$SANDBOX/nope2.json" "$KEY" --anchor

# --- live beacon (skip with SDK_SELFTEST_OFFLINE=1) -----------------------
if [ "${SDK_SELFTEST_OFFLINE:-0}" = "1" ]; then
  echo "  --   live beacon checks skipped (SDK_SELFTEST_OFFLINE=1)"
else
  raw=$(curl -s --max-time 6 'https://ledatic.org/entropy/pulse' 2>/dev/null)
  if printf '%s' "$raw" | grep -q '"pulse_id"' && \
     printf '%s' "$raw" | grep -Eq '"value_hex"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"'; then
    ok "live beacon reachable"
  else
    bad "live beacon unreachable or malformed"
  fi
  # against prod (no by-id endpoint yet) --check-beacon must honestly say unverifiable, never a false pass
  expect_exit 9 "live --check-beacon honestly unverifiable -> 9" "$BIN" verify "$ART" "$RECEIPT" --check-beacon
fi

echo "== $PASS ok / $FAIL bad =="
if [ "$FAIL" -eq 0 ]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
