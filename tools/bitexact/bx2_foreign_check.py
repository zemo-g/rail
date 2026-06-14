#!/usr/bin/env python3
# BX2 D3 leg: an INDEPENDENT Python re-implementation of the SAME fixed-point exact
# matmul. It must reproduce, BIT-FOR-BIT, both (a) Rail's quantized integer inputs and
# (b) the per-output two-limb integer accumulator [hi, lo]. We compare INTEGERS, which
# sidesteps any decimal round-trip ambiguity in show_float -- if the integer
# accumulators match, the deterministic IEEE convert-back yields the identical float.
#
# This is the thesis at the matmul level: where BX1's float path was NOT foreign-
# reproducible (a 5.55e-17 FMA gap between Rail-f64 and Python-f64), the exact-integer
# path IS -- because integer addition is associative and quantize/accumulate are fixed
# algorithms with no platform-dependent rounding inside the reduction.
import sys

LIMB = 2 ** 31

def loadf(p):
    with open(p) as f:
        return [float(x) for x in f.read().split()]

def loadi(p):
    with open(p) as f:
        return [int(x) for x in f.read().split()]

def quantf(x):
    # must match Rail quantf exactly: round-half-away-from-zero, then truncate toward zero
    s = x * 16777216.0
    r = s + 0.5 if s >= 0.0 else s - 0.5
    return int(r)            # Python int(float) truncates toward zero == fcvtzs

def main():
    d = int(sys.argv[1]) if len(sys.argv) > 1 else 32
    P = loadf("/tmp/bx2_P.txt")
    Q = loadf("/tmp/bx2_Q.txt")
    Aq = loadi("/tmp/bx2_Aq.txt")
    Bq = loadi("/tmp/bx2_Bq.txt")
    Hi = loadi("/tmp/bx2_Hi.txt")
    Lo = loadi("/tmp/bx2_Lo.txt")

    # (a) quantization reproduces bit-for-bit
    qbad = 0
    for idx in range(d * d):
        if quantf(P[idx]) != Aq[idx] or quantf(Q[idx]) != Bq[idx]:
            qbad += 1

    # (b) integer accumulator [hi, lo] reproduces bit-for-bit
    abad = 0
    first = None
    for i in range(d):
        for j in range(d):
            S = 0
            for p in range(d):
                S += Aq[i * d + p] * Bq[p * d + j]   # exact Python big-int sum
            lo = S % LIMB                            # Euclidean, in [0, 2^31)
            hi = S // LIMB                           # floor division
            if hi != Hi[i * d + j] or lo != Lo[i * d + j]:
                abad += 1
                if first is None:
                    first = (i, j, hi, lo, Hi[i * d + j], Lo[i * d + j])

    if qbad == 0 and abad == 0:
        print("FOREIGN-EXACT PASS: Python re-impl reproduced all %d quantized inputs and "
              "all %d accumulator limbs bit-for-bit" % (2 * d * d, d * d))
    else:
        print("FOREIGN-EXACT FAIL: quant_mismatch=%d acc_mismatch=%d first=%s"
              % (qbad, abad, first))

if __name__ == "__main__":
    main()
