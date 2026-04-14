// smoke_test.c — verify every dylib export before wiring to Rail.
// Uses the Rail float_arr convention: index 0 is count, data starts at index 1.
// Build: clang -o smoke_test smoke_test.c libtensor_gpu.dylib -Wl,-rpath,.
// Run:   ./smoke_test
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

int tgl_init(int);
int tgl_matmul_f64(const double*, const double*, double*, int, int, int);
int tgl_matmul_relu_f64(const double*, const double*, const double*, double*, int, int, int);
int tgl_add_f64(const double*, const double*, double*, int);
int tgl_mul_f64(const double*, const double*, double*, int);
int tgl_scale_f64(const double*, double*, const double*, int);
int tgl_relu_f64(const double*, double*, int);
int tgl_relu_backward_f64(const double*, const double*, double*, int);
int tgl_sigmoid_f64(const double*, double*, int);
int tgl_exp_f64(const double*, double*, int);
int tgl_tanh_f64(const double*, double*, int);
int tgl_softmax_rows_f64(const double*, double*, int, int);
int tgl_transpose_f64(const double*, double*, int, int);
int tgl_sgd_update_f64(double*, const double*, const double*, int);
int tgl_adam_update_f64(double*, const double*, double*, double*, const double*, int);
int tgl_cross_entropy_f64(const double*, const double*, double*, int, int);

// Allocate a Rail-style float_arr: [count, v0, v1, ...]. Count is stored
// as a double for the smoke test (Rail stores it as a tagged int, but the
// library skips 8 bytes regardless).
static double *arr(int n) {
    double *a = calloc(n+1, sizeof(double));
    a[0] = (double)n;
    return a;
}
static void fill(double *a, int n, double base) { for (int i=0;i<n;i++) a[i+1]=base+i; }
static int check(const char *name, double got, double want, double tol) {
    if (fabs(got-want) > tol) { printf("FAIL %s: got %.6g want %.6g\n", name, got, want); return 0; }
    printf("PASS %s: %.6g\n", name, got);
    return 1;
}

int main(void) {
    if (tgl_init(0) != 1) { printf("tgl_init failed\n"); return 1; }
    printf("init ok\n");
    int ok = 1;

    // ── matmul: [[1,2],[3,4]] @ [[5,6],[7,8]] = [[19,22],[43,50]]
    {
        double *A = arr(4), *B = arr(4), *C = arr(4);
        A[1]=1; A[2]=2; A[3]=3; A[4]=4;
        B[1]=5; B[2]=6; B[3]=7; B[4]=8;
        tgl_matmul_f64(A,B,C,2,2,2);
        ok &= check("matmul[0,0]", C[1], 19, 1e-4);
        ok &= check("matmul[1,1]", C[4], 50, 1e-4);
        free(A); free(B); free(C);
    }

    // ── add
    {
        double *A = arr(4), *B = arr(4), *C = arr(4);
        for (int i=0;i<4;i++){A[i+1]=i+1; B[i+1]=10+i;}
        tgl_add_f64(A,B,C,4);
        ok &= check("add[0]", C[1], 11, 1e-4);
        ok &= check("add[3]", C[4], 17, 1e-4);
        free(A); free(B); free(C);
    }

    // ── mul (hadamard)
    {
        double *A = arr(3), *B = arr(3), *C = arr(3);
        A[1]=2; A[2]=3; A[3]=4;
        B[1]=5; B[2]=6; B[3]=7;
        tgl_mul_f64(A,B,C,3);
        ok &= check("mul[0]", C[1], 10, 1e-4);
        ok &= check("mul[2]", C[3], 28, 1e-4);
        free(A); free(B); free(C);
    }

    // ── scale by 3
    {
        double *A = arr(3), *C = arr(3), *s = arr(1);
        A[1]=2; A[2]=5; A[3]=10;
        s[1] = 3.0;
        tgl_scale_f64(A, C, s, 3);
        ok &= check("scale[0]", C[1], 6, 1e-4);
        ok &= check("scale[2]", C[3], 30, 1e-4);
        free(A); free(C); free(s);
    }

    // ── relu: negatives → 0, positives pass
    {
        double *X = arr(4), *Y = arr(4);
        X[1]=-1; X[2]=2; X[3]=-3; X[4]=4;
        tgl_relu_f64(X, Y, 4);
        ok &= check("relu[0]", Y[1], 0, 1e-6);
        ok &= check("relu[1]", Y[2], 2, 1e-6);
        ok &= check("relu[3]", Y[4], 4, 1e-6);
        free(X); free(Y);
    }

    // ── relu_backward
    {
        double *X = arr(4), *G = arr(4), *O = arr(4);
        X[1]=-1; X[2]=2; X[3]=-3; X[4]=4;
        G[1]=G[2]=G[3]=G[4]=5.0;
        tgl_relu_backward_f64(X, G, O, 4);
        ok &= check("relu_bw[0]", O[1], 0, 1e-6);
        ok &= check("relu_bw[1]", O[2], 5, 1e-6);
        free(X); free(G); free(O);
    }

    // ── sigmoid(0) = 0.5
    {
        double *X = arr(1), *Y = arr(1);
        X[1] = 0.0;
        tgl_sigmoid_f64(X, Y, 1);
        ok &= check("sigmoid(0)", Y[1], 0.5, 1e-5);
        free(X); free(Y);
    }

    // ── exp / tanh at 0
    {
        double *X = arr(2), *Y = arr(2);
        X[1] = 0; X[2] = 1;
        tgl_exp_f64(X, Y, 2);
        ok &= check("exp(0)", Y[1], 1.0, 1e-4);
        ok &= check("exp(1)", Y[2], 2.718281828, 1e-3);
        tgl_tanh_f64(X, Y, 2);
        ok &= check("tanh(0)", Y[1], 0.0, 1e-5);
        free(X); free(Y);
    }

    // ── softmax rows: [[1,2,3]] should sum to 1
    {
        double *X = arr(3), *Y = arr(3);
        X[1]=1; X[2]=2; X[3]=3;
        tgl_softmax_rows_f64(X, Y, 1, 3);
        double s = Y[1]+Y[2]+Y[3];
        ok &= check("softmax sum", s, 1.0, 1e-4);
        ok &= check("softmax increasing", (Y[3] > Y[2]) ? 1.0 : 0.0, 1.0, 1e-6);
        free(X); free(Y);
    }

    // ── transpose 2×3 → 3×2
    {
        double *A = arr(6), *B = arr(6);
        // A = [[1,2,3],[4,5,6]], A^T = [[1,4],[2,5],[3,6]]
        A[1]=1; A[2]=2; A[3]=3; A[4]=4; A[5]=5; A[6]=6;
        tgl_transpose_f64(A, B, 2, 3);
        ok &= check("T[0,0]", B[1], 1, 1e-6);
        ok &= check("T[0,1]", B[2], 4, 1e-6);
        ok &= check("T[2,1]", B[6], 6, 1e-6);
        free(A); free(B);
    }

    // ── SGD: w=[1,2,3], g=[0.1,0.2,0.3], lr=0.5 → w-=lr*g → [0.95,1.9,2.85]
    {
        double *W = arr(3), *G = arr(3), *lr = arr(1);
        W[1]=1; W[2]=2; W[3]=3;
        G[1]=0.1; G[2]=0.2; G[3]=0.3;
        lr[1] = 0.5;
        tgl_sgd_update_f64(W, G, lr, 3);
        ok &= check("sgd[0]", W[1], 0.95, 1e-3);
        ok &= check("sgd[2]", W[3], 2.85, 1e-3);
        free(W); free(G); free(lr);
    }

    // ── cross_entropy: probs=[[0.7,0.2,0.1]], target=0 → loss=-log(0.7)≈0.3567
    {
        double *P = arr(3), *T = arr(1), *L = arr(1);
        P[1]=0.7; P[2]=0.2; P[3]=0.1;
        T[1] = 0.0;  // target class index as double
        tgl_cross_entropy_f64(P, T, L, 1, 3);
        ok &= check("cross_entropy", L[1], 0.3567, 1e-3);
        free(P); free(T); free(L);
    }

    // ── fused matmul+bias+relu: A=[[1,2],[3,4]], B=[[1,0],[0,1]], bias=[-5,0]
    //     A@B = [[1,2],[3,4]], +bias → [[-4,2],[-2,4]], relu → [[0,2],[0,4]]
    {
        double *A = arr(4), *B = arr(4), *bias = arr(2), *C = arr(4);
        A[1]=1; A[2]=2; A[3]=3; A[4]=4;
        B[1]=1; B[2]=0; B[3]=0; B[4]=1;
        bias[1] = -5.0; bias[2] = 0.0;
        tgl_matmul_relu_f64(A, B, bias, C, 2, 2, 2);
        ok &= check("fused[0,0]", C[1], 0, 1e-4);
        ok &= check("fused[0,1]", C[2], 2, 1e-4);
        ok &= check("fused[1,0]", C[3], 0, 1e-4);
        ok &= check("fused[1,1]", C[4], 4, 1e-4);
        free(A); free(B); free(bias); free(C);
    }

    // ── adam: single-step sanity
    //   w=[1,2,3], g=[0.1,0.2,0.3], m=v=[0,0,0]
    //   β1=0.9, β2=0.999, ε=1e-8, lr=0.01, t=1 → bc1=0.1, bc2=0.001
    //   m1 = 0.1*g = [0.01,0.02,0.03]   v1 = 0.001*g² = [1e-6,4e-6,9e-6]
    //   m̂ = m/bc1 = g ; v̂ = v/bc2 = g² ; w -= lr*g/(|g|+ε) ≈ w - 0.01
    {
        double *W = arr(3), *G = arr(3), *M = arr(3), *V = arr(3), *H = arr(6);
        W[1]=1.0; W[2]=2.0; W[3]=3.0;
        G[1]=0.1; G[2]=0.2; G[3]=0.3;
        // m,v already zero
        H[1]=0.01;   // lr
        H[2]=0.9;    // β1
        H[3]=0.999;  // β2
        H[4]=1e-8;   // ε
        H[5]=0.1;    // bc1 = 1 - 0.9^1
        H[6]=0.001;  // bc2 = 1 - 0.999^1
        tgl_adam_update_f64(W, G, M, V, H, 3);
        ok &= check("adam w[0]", W[1], 1.0 - 0.01, 1e-4);
        ok &= check("adam w[1]", W[2], 2.0 - 0.01, 1e-4);
        ok &= check("adam w[2]", W[3], 3.0 - 0.01, 1e-4);
        ok &= check("adam m[0]", M[1], 0.01, 1e-4);
        ok &= check("adam v[0]", V[1], 1e-5, 1e-7);
        free(W); free(G); free(M); free(V); free(H);
    }

    // ── stress: 10k relu, 5 times
    {
        int N = 10000;
        double *X = arr(N), *Y = arr(N);
        for (int i = 0; i < N; i++) X[i+1] = (i % 7) - 3.0;
        for (int k = 0; k < 5; k++) {
            tgl_relu_f64(X, Y, N);
        }
        ok &= check("stress relu 10k[0]", Y[1], X[1] > 0 ? X[1] : 0, 1e-6);
        ok &= check("stress relu 10k[last]", Y[N], X[N] > 0 ? X[N] : 0, 1e-6);
        free(X); free(Y);
    }
    // ── stress: 10k add + mul + scale interleaved
    {
        int N = 10000;
        double *A = arr(N), *B = arr(N), *C = arr(N), *s = arr(1);
        for (int i = 0; i < N; i++) { A[i+1]=1.0; B[i+1]=2.0; }
        s[1] = 3.0;
        for (int k = 0; k < 10; k++) {
            tgl_add_f64(A,B,C,N);
            tgl_mul_f64(A,B,C,N);
            tgl_scale_f64(A,C,s,N);
        }
        ok &= check("stress mix 10k", C[1], 3.0, 1e-5);
        free(A); free(B); free(C); free(s);
    }
    printf("\n%s\n", ok ? "ALL PASS" : "FAILURES");
    return ok ? 0 : 1;
}
