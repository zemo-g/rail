#!/bin/sh
# R5b fixture generator: a REAL packed multi-tensor .safetensors file, written
# with interior NUL bytes that read_file (strlen-terminated) cannot read but
# read_file_bytes can. Layout per the safetensors spec:
#   [8-byte little-endian header length N][N-byte JSON header][raw tensor data]
#
# Two tensors, chosen to exercise both decode paths and force leading-0x00 bytes:
#   a : F32  shape [2] = [1.0f, 0.5f]   bytes 00 00 80 3F  00 00 00 3F   (8 bytes)
#   b : BF16 shape [2] = [1.0,  -0.375] bytes 80 3F  C0 BE              (4 bytes)
# Expected fixed-point (S=2^24): a=[16777216, 8388608], b=[16777216, -6291456].
#
# N (the JSON length) is < 256 here, so the LE prefix is  N 00 00 00 00 00 00 00
# -> byte 1 is 0x00: read_file truncates the whole file to 1 byte; read_file_bytes
# reads all of it. The F32 data also starts 00 00 ... so even the payload has
# leading nulls. Pure POSIX printf -- no python dependency.
set -e
OUT="${1:-/tmp/r5b_fix.safetensors}"
H='{"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},"b":{"dtype":"BF16","shape":[2],"data_offsets":[8,12]}}'
N=${#H}
{
  # 8-byte little-endian header length (N < 256 -> one octal byte then 7 nulls)
  printf "$(printf '\\%03o' "$N")\000\000\000\000\000\000\000"
  # the JSON header (pure ASCII, no nulls)
  printf '%s' "$H"
  # raw tensor data: 1.0f, 0.5f (F32 LE) then bf16 1.0, bf16 -0.375
  printf '\000\000\200\077\000\000\000\077\200\077\300\276'
} > "$OUT"
