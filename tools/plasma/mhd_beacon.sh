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

mkdir -p /tmp/mhd_beacon

# Emit the small shim the Rail beacon shells out to.  Absolute paths
# in here so we don't have to reason about Rail's runtime CWD.
cat > /tmp/mhd_beacon/run_packer <<EOF
#!/bin/sh
python3 "${PACKER_PY}"
EOF
chmod +x /tmp/mhd_beacon/run_packer

cd "${RAIL_DIR}"

while true; do
    "${RAIL_BIN}" run "${BEACON_RAIL}"
    rc=$?
    echo "mhd_beacon: rail exited (rc=${rc}); restarting in 2s" >&2
    sleep 2
done
