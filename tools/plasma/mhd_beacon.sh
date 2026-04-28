#!/bin/bash
# tools/plasma/mhd_beacon.sh — Rail-native entropy-beacon daemon wrapper
#
# Replaces invocation of mhd_ot_beacon.py.  This wrapper is what the
# launchd plist (com.ledatic.mhd) runs; it execs the Rail beacon and
# restarts on crash with a brief backoff so a stuck/crashed process
# can't loop the kernel into oblivion.

set -u

RAIL_DIR="${RAIL_DIR:-/Users/ledaticempire/projects/rail}"
RAIL_BIN="${RAIL_DIR}/rail_native"
BEACON_RAIL="${RAIL_DIR}/tools/plasma/mhd_beacon.rail"
PACKER_PY="${RAIL_DIR}/tools/plasma/mhd_beacon_pack.py"
# Output path: canonical /tmp/plasma_live.bin in production, side path
# /tmp/plasma_live_rail.bin by default so dev runs don't clobber a live
# numpy beacon.  We bake this into the run_packer shim because Rail's
# `shell()` does not inherit the parent's environment, so passing it
# via launchd's EnvironmentVariables alone would not reach the packer.
MHD_BEACON_OUT="${MHD_BEACON_OUT:-/tmp/plasma_live_rail.bin}"

mkdir -p /tmp/mhd_beacon

cat > /tmp/mhd_beacon/run_packer <<EOF
#!/bin/sh
MHD_BEACON_OUT="${MHD_BEACON_OUT}" python3 "${PACKER_PY}"
EOF
chmod +x /tmp/mhd_beacon/run_packer

cd "${RAIL_DIR}"

while true; do
    "${RAIL_BIN}" run "${BEACON_RAIL}"
    rc=$?
    echo "mhd_beacon: rail exited (rc=${rc}); restarting in 2s" >&2
    sleep 2
done
