// test_dylib.c — Verify libtensor_gpu.dylib works before wiring into Rail.
// Build: clang test_dylib.c -L. -ltensor_gpu -o test_dylib
// Run:   DYLD_LIBRARY_PATH=. ./test_dylib

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

extern int tgl_init(void);
extern int tgl_matmul_f64(const double *A, const double *B, double *C, int M, int K, int N);
extern int tgl_relu_f64(const double *X, double *Y, int N);

int main(void) {
    if (tgl_init() != 0) { fprintf(stderr, "init failed\n"); return 1; }
    printf("init OK\n");

    // Matmul test: 2×3 × 3×2
    double A[6] = {1,2,3,4,5,6};
    double B[6] = {7,8,9,10,11,12};
    double C[4];
    tgl_matmul_f64(A, B, C, 2, 3, 2);
    printf("matmul: [%.0f %.0f %.0f %.0f] expect [58 64 139 154]\n",
           C[0], C[1], C[2], C[3]);

    int ok_mm = (fabs(C[0]-58) < 0.01 && fabs(C[1]-64) < 0.01 &&
                 fabs(C[2]-139) < 0.01 && fabs(C[3]-154) < 0.01);
    printf("matmul: %s\n", ok_mm ? "PASS" : "FAIL");

    // ReLU test
    double X[4] = {-2.0, -0.5, 1.5, 3.0};
    double Y[4];
    tgl_relu_f64(X, Y, 4);
    printf("relu:   [%.2f %.2f %.2f %.2f] expect [0 0 1.5 3]\n",
           Y[0], Y[1], Y[2], Y[3]);

    int ok_relu = (Y[0] == 0 && Y[1] == 0 && fabs(Y[2]-1.5) < 0.01 && fabs(Y[3]-3.0) < 0.01);
    printf("relu:   %s\n", ok_relu ? "PASS" : "FAIL");

    // Benchmark: 100 matmul 128×128 calls
    int N = 128;
    double *bA = (double*)malloc(N*N*sizeof(double));
    double *bB = (double*)malloc(N*N*sizeof(double));
    double *bC = (double*)malloc(N*N*sizeof(double));
    for (int i = 0; i < N*N; i++) { bA[i] = (double)(i % 100) / 100.0; bB[i] = (double)((i*7) % 100) / 100.0; }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < 100; i++) tgl_matmul_f64(bA, bB, bC, N, N, N);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    double per_call = elapsed / 100 * 1000; // ms
    double gflops = 2.0 * N * N * N * 100 / (elapsed * 1e9);
    printf("bench:  100x matmul 128x128 = %.2fs total, %.2fms/call, %.1f GFLOPS\n",
           elapsed, per_call, gflops);

    free(bA); free(bB); free(bC);

    return (ok_mm && ok_relu) ? 0 : 1;
}
