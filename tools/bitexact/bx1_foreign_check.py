#!/usr/bin/env python3
# BX1 D3 leg: an INDEPENDENT, pure-Python re-implementation of the same matmul.
# No numpy / no BLAS -- plain IEEE-754 doubles, left-to-right accumulation -- so it
# is a genuine foreign witness, not a wrapper around the same library. It reads the
# inputs the Rail harness dumped and the Rail outputs, recomputes, and prints the
# cross-implementation gaps. The thesis (reached at BX2/BX3) is that with exact-integer
# accumulation g1 and g2 both become EXACTLY 0.0 on any implementation.
import sys, struct

def load(path):
    with open(path) as f:
        return [float(x) for x in f.read().split()]

def matmul_f64(A, B, m, k, n):
    C = [0.0] * (m * n)
    for i in range(m):
        for j in range(n):
            acc = 0.0
            for p in range(k):              # left-to-right, same order as Rail cpu_mm
                acc += A[i * k + p] * B[p * n + j]
            C[i * n + j] = acc
    return C

def f32(x):                                  # round a double through single precision
    return struct.unpack('<f', struct.pack('<f', x))[0]

def matmul_f32(A, B, m, k, n):
    C = [0.0] * (m * n)
    for i in range(m):
        for j in range(n):
            acc = 0.0
            for p in range(k):
                acc = f32(acc + f32(A[i * k + p] * B[p * n + j]))
            C[i * n + j] = acc
    return C

def maxdiff(X, Y):
    return max(abs(a - b) for a, b in zip(X, Y))

def main():
    d = int(sys.argv[1]) if len(sys.argv) > 1 else 32
    P = load("/tmp/bx1_P.txt")
    Q = load("/tmp/bx1_Q.txt")
    rail_f64 = load("/tmp/bx1_railf64.txt")
    rail_gpu = load("/tmp/bx1_railgpu.txt")
    py64 = matmul_f64(P, Q, d, d, d)
    py32 = matmul_f32(P, Q, d, d, d)
    g1 = maxdiff(rail_f64, py64)             # Rail f64 vs Python f64 (two indep f64 impls)
    g2 = maxdiff(rail_gpu, py64)             # Rail GPU f32 vs Python f64 (precision gap)
    g3 = maxdiff(py32, py64)                 # Python f32 vs f64 (size of the f32 penalty)
    same = "YES" if g1 == 0.0 else "NO"
    print("railf64==pyf64 bit-identical: %s (g1=%.3e)  railGPU-vs-pyf64 g2=%.3e  pyf32-vs-pyf64 g3=%.3e"
          % (same, g1, g2, g3))

if __name__ == "__main__":
    main()
