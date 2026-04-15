// Smoke-test client for tensor_daemond. Connects, sends PING, sends MATMUL
// [[1,2,3],[4,5,6]] @ [[1,0],[0,1],[1,1]] = [[4,5],[10,11]], verifies, exits.
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define PORT 9302

static int connect_sock(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(PORT);
    a.sin_addr.s_addr = htonl(0x7F000001);
    if (connect(fd, (struct sockaddr*)&a, sizeof(a)) < 0) { perror("connect"); exit(1); }
    return fd;
}
static void wex(int fd, const void *b, size_t n) { write(fd, b, n); }
static void rex(int fd, void *b, size_t n) {
    size_t off = 0;
    while (off < n) { ssize_t r = read(fd, (char*)b+off, n-off); if (r<=0) { perror("read"); exit(1); } off += r; }
}

int main(void) {
    int fd = connect_sock();

    // PING: op=254, arg_count=0, int_count=0
    uint8_t op = 254;
    uint32_t z = 0;
    wex(fd, &op, 1); wex(fd, &z, 4); wex(fd, &z, 4);
    uint8_t status; uint32_t n;
    rex(fd, &status, 1); rex(fd, &n, 4);
    double v; rex(fd, &v, 8);
    printf("PING status=%u n=%u v=%g\n", status, n, v);

    // MATMUL: A(2x3) @ B(3x2) = C(2x2)
    double A[6] = {1,2,3, 4,5,6};
    double B[6] = {1,0, 0,1, 1,1};
    op = 1; // OP_MATMUL
    uint32_t arg_count = 2;
    wex(fd, &op, 1); wex(fd, &arg_count, 4);
    uint32_t na = 6; wex(fd, &na, 4); wex(fd, A, 48);
    uint32_t nb = 6; wex(fd, &nb, 4); wex(fd, B, 48);
    uint32_t int_count = 3;
    wex(fd, &int_count, 4);
    int32_t M=2, K=3, N=2;
    wex(fd, &M, 4); wex(fd, &K, 4); wex(fd, &N, 4);

    rex(fd, &status, 1); rex(fd, &n, 4);
    if (status != 0) { printf("MATMUL status=%u\n", status); return 1; }
    double C[4]; rex(fd, C, 32);
    printf("MATMUL C = [[%g,%g],[%g,%g]]\n", C[0],C[1],C[2],C[3]);
    // Expected: [[4,5],[10,11]]
    int ok = (C[0]==4 && C[1]==5 && C[2]==10 && C[3]==11);
    printf("%s\n", ok ? "PASS" : "FAIL");

    // Benchmark: 100 iterations of 128x128x128 matmul via daemon
    int SZ = 128;
    int NEL = SZ * SZ;
    double *bA = malloc(NEL * 8);
    double *bB = malloc(NEL * 8);
    for (int i = 0; i < NEL; i++) { bA[i] = (i % 100) / 100.0; bB[i] = ((i*7) % 100) / 100.0; }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int it = 0; it < 100; it++) {
        uint8_t o = 1; uint32_t ac = 2;
        wex(fd, &o, 1); wex(fd, &ac, 4);
        uint32_t nel = NEL; wex(fd, &nel, 4); wex(fd, bA, NEL*8);
        wex(fd, &nel, 4); wex(fd, bB, NEL*8);
        uint32_t ic = 3; wex(fd, &ic, 4);
        int32_t m=SZ, k=SZ, nn=SZ;
        wex(fd, &m, 4); wex(fd, &k, 4); wex(fd, &nn, 4);
        uint8_t st; uint32_t rn;
        rex(fd, &st, 1); rex(fd, &rn, 4);
        double *Cr = malloc(rn*8); rex(fd, Cr, rn*8); free(Cr);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec)/1e9;
    double ms = el * 1000.0 / 100.0;
    double gflops = 2.0 * SZ * SZ * SZ * 100 / (el * 1e9);
    printf("BENCH 100x 128x128 matmul via daemon: %.2fs total, %.3fms/call, %.1f GFLOPS\n",
           el, ms, gflops);
    free(bA); free(bB);

    close(fd);
    return ok ? 0 : 1;
}
