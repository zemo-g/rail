#!/usr/bin/env bash
# tools/garmin/gcd_extract.sh - Extract firmware streams from a Garmin GCD.
#
# The Rail parser at stdlib/gcd.rail handles small files end-to-end. For
# multi-MB GCDs we hit Rail's chars-list memory ceiling, so this helper
# does the byte-level extraction in shell and produces:
#   <out>/stream_<HEX_ID>.bin     - raw concatenated firmware bytes per stream
#   <out>/manifest.txt            - record-by-record table (id, offset, length)
#
# Usage:
#   tools/garmin/gcd_extract.sh <path-to-GCD> <out-dir>

set -eu
gcd="${1:?missing GCD path}"
out="${2:?missing output dir}"
mkdir -p "$out"

python3 - "$gcd" "$out" <<'PY'
import os, struct, sys
gcd_path, out_dir = sys.argv[1], sys.argv[2]
data = open(gcd_path, "rb").read()
assert data[:6] == b"GARMIN", f"bad signature: {data[:6]!r}"
ver = struct.unpack("<H", data[6:8])[0]

manifest = [f"# {gcd_path}",
            f"# size {len(data)} bytes, GARMIN V{ver//100}.{ver%100}",
            "# idx offset len id_hex name"]
streams = {}
off = 8
i = 0
while off + 4 <= len(data):
    rid, rlen = struct.unpack("<HH", data[off:off+4])
    body = data[off+4:off+4+rlen]
    name = {
        1: "CheckPoint", 2: "Filler", 3: "PartNumber", 5: "Copyright",
        6: "FirmwareDescriptorType", 7: "FirmwareDescriptor", 0xFFFF: "End",
    }.get(rid, f"fw:0x{rid:04X}")
    manifest.append(f"{i:4d} {off+4:8d} {rlen:6d} 0x{rid:04X} {name}")
    if rid >= 8 and rid != 0xFFFF:
        streams.setdefault(rid, bytearray()).extend(body)
    off += 4 + rlen
    i += 1
    if rid == 0xFFFF:
        break

with open(os.path.join(out_dir, "manifest.txt"), "w") as f:
    f.write("\n".join(manifest) + "\n")

for rid, body in streams.items():
    p = os.path.join(out_dir, f"stream_{rid:04X}.bin")
    open(p, "wb").write(bytes(body))
    print(f"  wrote {p}  {len(body)} bytes")

print(f"records: {i}, streams: {len(streams)}")
PY
