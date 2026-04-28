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
DAEMON_PY="${RAIL_DIR}/tools/plasma/mhd_beacon_daemon.py"
# Canonical /tmp/plasma_live.bin in production; side path
# /tmp/plasma_live_rail.bin by default so dev runs don't clobber a live
# numpy beacon.  Exported so the daemon (spawned below) inherits it.
export MHD_BEACON_OUT="${MHD_BEACON_OUT:-/tmp/plasma_live_rail.bin}"

mkdir -p /tmp/mhd_beacon

# FIFO that Rail writes to after each frame to wake the warm packer.
[ -p /tmp/mhd_beacon/ready ] || mkfifo /tmp/mhd_beacon/ready

# Stop any prior daemon, then start a fresh one.  Without the warm
# daemon, the run_packer shim was forking python3 once per frame (~50 ms
# startup tax) — eliminating that fork tax is the whole point of #3.
pkill -f mhd_beacon_daemon.py 2>/dev/null
sleep 0.3
python3 "${DAEMON_PY}" >> /Users/ledaticempire/.ledatic/logs/mhd_packer.log 2>&1 &
DAEMON_PID=$!
trap "kill ${DAEMON_PID} 2>/dev/null" EXIT

# The Rail beacon shells out to /tmp/mhd_beacon/run_packer once per
# frame.  This shim now just signals the daemon — open + write 2 bytes
# + close, ~1 ms vs the previous 50 ms python startup.
cat > /tmp/mhd_beacon/run_packer <<'EOF'
#!/bin/sh
echo 1 > /tmp/mhd_beacon/ready
EOF
chmod +x /tmp/mhd_beacon/run_packer

cd "${RAIL_DIR}"

while true; do
    "${RAIL_BIN}" run "${BEACON_RAIL}"
    rc=$?
    echo "mhd_beacon: rail exited (rc=${rc}); restarting in 2s" >&2
    sleep 2
done
