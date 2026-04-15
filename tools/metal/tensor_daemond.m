// tensor_daemond.m — Rail-native Metal tensor daemon (Fork B M3).
//
// Long-lived ObjC binary. Listens on /tmp/rail_tensord.sock (Unix). Keeps
// Metal device, command queue, and compiled pipelines warm across calls.
// Links against libtensor_gpu.dylib which already houses all 23 kernels.
//
// Rail talks via stdlib/socket.rail. No Python in the inner loop.
//
// Build:
//   cd ~/projects/rail/tools/metal
//   clang -fobjc-arc -framework Foundation \
//     tensor_daemond.m -L. -ltensor_gpu -o tensor_daemond
//
// Protocol (binary, big-endian where noted):
//   Request:
//     u8  op_id              -- see OP_* below
//     u32 arg_count          -- number of float64 arrays that follow
//     for each arg:
//       u32 n_doubles
//       u8[n_doubles*8] payload
//     u32 int_count          -- scalar int args
//     i32[int_count] ints
//   Response:
//     u8  status              -- 0 ok, non-zero = kernel rc
//     u32 out_n_doubles
//     u8[out_n_doubles*8] payload
//
// All byte order native (arm64 little-endian). Big-endian wasn't worth the
// swap cost — this is localhost-only IPC.
//
// Single-threaded loop. One request at a time. Good enough for a training
// loop that issues kernels sequentially.

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

// Declarations from libtensor_gpu.dylib.
extern int tgl_init(int);
extern int tgl_matmul_f64(const double*, const double*, double*, int, int, int);
extern int tgl_add_f64(const double*, const double*, double*, int);
extern int tgl_mul_f64(const double*, const double*, double*, int);
extern int tgl_scale_f64(const double*, double*, const double*, int);
extern int tgl_relu_f64(const double*, double*, int);
extern int tgl_relu_backward_f64(const double*, const double*, double*, int);
extern int tgl_sigmoid_f64(const double*, double*, int);
extern int tgl_exp_f64(const double*, double*, int);
extern int tgl_tanh_f64(const double*, double*, int);
extern int tgl_softmax_rows_f64(const double*, double*, int, int);
extern int tgl_softmax_backward_f64(const double*, const double*, double*, int, int);
extern int tgl_transpose_f64(const double*, double*, int, int);
extern int tgl_sgd_update_f64(double*, const double*, const double*, int);
extern int tgl_adam_update_f64(double*, const double*, double*, double*, const double*, int);
extern int tgl_cross_entropy_f64(const double*, const double*, double*, int, int);
extern int tgl_matmul_relu_f64(const double*, const double*, const double*, double*, int, int, int);
extern int tgl_matmul_gelu_f64(const double*, const double*, const double*, double*, int, int, int);
extern int tgl_matmul_batched_f64(const double*, const double*, double*, int, int, int, int);
extern int tgl_ce_softmax_backward_f64(const double*, const double*, double*, int, int);
extern int tgl_layernorm_backward_f64(const double*, const double*, const double*, const double*, const double*, double*, int, int);

// Op codes. Must match Rail-side dispatch in stdlib/tensor.rail.
typedef enum {
    OP_INIT               = 0,
    OP_MATMUL             = 1,
    OP_ADD                = 2,
    OP_MUL                = 3,
    OP_SCALE              = 4,
    OP_RELU               = 5,
    OP_RELU_BACK          = 6,
    OP_SIGMOID            = 7,
    OP_EXP                = 8,
    OP_TANH               = 9,
    OP_SOFTMAX_ROWS       = 10,
    OP_SOFTMAX_BACK       = 11,
    OP_TRANSPOSE          = 12,
    OP_SGD                = 13,
    OP_ADAM               = 14,
    OP_CE                 = 15,
    OP_MATMUL_RELU        = 16,
    OP_MATMUL_GELU        = 17,
    OP_MATMUL_BATCHED     = 18,
    OP_CE_SOFTMAX_BACK    = 19,
    OP_LAYERNORM_BACK     = 20,
    OP_PING               = 254,
    OP_SHUTDOWN           = 255,
} op_t;

#define SOCK_PATH "/tmp/rail_tensord.sock"
#define TCP_PORT  9302

static int read_exact(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char*)buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char*)buf + off, n - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

// Read a float64 array. Allocate with a +1 double prefix because
// libtensor_gpu.dylib expects Rail float_arr layout: [count@0, data@8..].
// The dylib skips the first double (A+1) — we just leave it zero.
// Returned pointer is the ALLOCATED base, not the data pointer. Pass it as-is
// to tgl_* functions; they do the +1 offset internally.
// Caller frees returned buffer.
static double* read_darr(int fd, uint32_t *n_out) {
    uint32_t n;
    if (read_exact(fd, &n, 4) < 0) return NULL;
    *n_out = n;
    if (n == 0) return NULL;
    double *buf = calloc((size_t)n + 1, 8);  // +1 for count slot
    if (!buf) return NULL;
    // Skip the header slot; write data starting at index 1.
    if (read_exact(fd, buf + 1, (size_t)n * 8) < 0) { free(buf); return NULL; }
    return buf;
}

// Allocate an output buffer with the same +1 header padding.
static double* alloc_out(uint32_t n) {
    return calloc((size_t)n + 1, 8);
}

// Write the data portion (skipping the +1 header slot).
static int write_darr(int fd, const double *buf, uint32_t n) {
    uint8_t status = 0;
    if (write_exact(fd, &status, 1) < 0) return -1;
    if (write_exact(fd, &n, 4) < 0) return -1;
    if (n > 0 && write_exact(fd, buf + 1, (size_t)n * 8) < 0) return -1;
    return 0;
}

static int write_status(int fd, uint8_t status) {
    if (write_exact(fd, &status, 1) < 0) return -1;
    uint32_t zero = 0;
    return write_exact(fd, &zero, 4);
}

// Handle one request. Returns 0 to continue, 1 to shutdown, -1 on error.
static int handle_request(int fd) {
    uint8_t op;
    if (read_exact(fd, &op, 1) < 0) return -1;

    uint32_t arg_count;
    if (read_exact(fd, &arg_count, 4) < 0) return -1;

    // Read all array args.
    double *args[8] = {0};
    uint32_t arg_ns[8] = {0};
    if (arg_count > 8) { write_status(fd, 1); return 0; }
    for (uint32_t i = 0; i < arg_count; i++) {
        args[i] = read_darr(fd, &arg_ns[i]);
    }

    uint32_t int_count;
    if (read_exact(fd, &int_count, 4) < 0) goto fail;
    int32_t ints[8] = {0};
    if (int_count > 8) { write_status(fd, 1); goto cleanup; }
    for (uint32_t i = 0; i < int_count; i++) {
        if (read_exact(fd, &ints[i], 4) < 0) goto fail;
    }

    int rc = 0;
    double *out = NULL;
    uint32_t out_n = 0;

    switch ((op_t)op) {
        case OP_PING:
            out = alloc_out(1); out[1] = 1.0; out_n = 1; rc = 1;
            break;
        case OP_SHUTDOWN:
            write_status(fd, 0);
            goto cleanup_shutdown;
        case OP_INIT:
            rc = tgl_init(0);
            write_status(fd, rc == 1 ? 0 : 1);
            goto cleanup;
        case OP_MATMUL: {
            // args: A, B. ints: M, K, N.
            int M = ints[0], K = ints[1], N = ints[2];
            out_n = (uint32_t)(M * N);
            out = alloc_out(out_n);
            rc = tgl_matmul_f64(args[0], args[1], out, M, K, N);
            break;
        }
        case OP_ADD:
        case OP_MUL: {
            int N = ints[0];
            out_n = (uint32_t)N;
            out = alloc_out(out_n);
            rc = (op == OP_ADD)
                ? tgl_add_f64(args[0], args[1], out, N)
                : tgl_mul_f64(args[0], args[1], out, N);
            break;
        }
        case OP_RELU:
        case OP_SIGMOID:
        case OP_EXP:
        case OP_TANH: {
            int N = ints[0];
            out_n = (uint32_t)N;
            out = alloc_out(out_n);
            rc = (op == OP_RELU)    ? tgl_relu_f64(args[0], out, N)
               : (op == OP_SIGMOID) ? tgl_sigmoid_f64(args[0], out, N)
               : (op == OP_EXP)     ? tgl_exp_f64(args[0], out, N)
                                    : tgl_tanh_f64(args[0], out, N);
            break;
        }
        case OP_SOFTMAX_ROWS: {
            int rows = ints[0], cols = ints[1];
            out_n = (uint32_t)(rows * cols);
            out = alloc_out(out_n);
            rc = tgl_softmax_rows_f64(args[0], out, rows, cols);
            break;
        }
        case OP_TRANSPOSE: {
            int M = ints[0], N = ints[1];
            out_n = (uint32_t)(M * N);
            out = alloc_out(out_n);
            rc = tgl_transpose_f64(args[0], out, M, N);
            break;
        }
        case OP_MATMUL_RELU:
        case OP_MATMUL_GELU: {
            // args: A, B, bias. ints: M, K, N.
            int M = ints[0], K = ints[1], N = ints[2];
            out_n = (uint32_t)(M * N);
            out = alloc_out(out_n);
            rc = (op == OP_MATMUL_RELU)
                ? tgl_matmul_relu_f64(args[0], args[1], args[2], out, M, K, N)
                : tgl_matmul_gelu_f64(args[0], args[1], args[2], out, M, K, N);
            break;
        }
        case OP_ADAM: {
            // In-place: w, g, m, v, hyp. Size = N. Returns w (which was mutated).
            int N = ints[0];
            rc = tgl_adam_update_f64(args[0], args[1], args[2], args[3], args[4], N);
            out_n = (uint32_t)N;
            out = alloc_out(out_n);
            // args[0] is padded: data lives at args[0]+1. Copy data to out+1.
            memcpy(out + 1, args[0] + 1, (size_t)N * 8);
            break;
        }
        case OP_CE_SOFTMAX_BACK: {
            // args: probs, targets. ints: batch, vocab.
            int batch = ints[0], vocab = ints[1];
            out_n = (uint32_t)(batch * vocab);
            out = alloc_out(out_n);
            rc = tgl_ce_softmax_backward_f64(args[0], args[1], out, batch, vocab);
            break;
        }
        case OP_LAYERNORM_BACK: {
            // args: x, mean, rstd, gamma, dy. ints: rows, dim.
            int rows = ints[0], dim = ints[1];
            out_n = (uint32_t)(rows * dim);
            out = alloc_out(out_n);
            rc = tgl_layernorm_backward_f64(args[0], args[1], args[2], args[3], args[4], out, rows, dim);
            break;
        }
        default:
            rc = 99;
            break;
    }

    if (rc != 1 && op != OP_PING) {
        write_status(fd, 2);
        goto cleanup;
    }
    write_darr(fd, out, out_n);
    free(out);

cleanup:
    for (uint32_t i = 0; i < arg_count; i++) free(args[i]);
    return 0;

cleanup_shutdown:
    for (uint32_t i = 0; i < arg_count; i++) free(args[i]);
    return 1;

fail:
    for (uint32_t i = 0; i < arg_count; i++) free(args[i]);
    return -1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        if (tgl_init(0) != 1) {
            fprintf(stderr, "tensor_daemond: tgl_init failed\n");
            return 1;
        }
        fprintf(stderr, "tensor_daemond: Metal init ok\n");

        int srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) { perror("socket"); return 1; }
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(TCP_PORT);
        addr.sin_addr.s_addr = htonl(0x7F000001);  // 127.0.0.1
        if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            perror("bind"); return 1;
        }
        if (listen(srv, 4) < 0) { perror("listen"); return 1; }
        fprintf(stderr, "tensor_daemond: listening on 127.0.0.1:%d\n", TCP_PORT);

        int shutdown_flag = 0;
        while (!shutdown_flag) {
            int fd = accept(srv, NULL, NULL);
            if (fd < 0) { if (errno == EINTR) continue; perror("accept"); break; }

            // Handle sequential requests on this connection until peer closes.
            while (1) {
                int rc = handle_request(fd);
                if (rc == 1) { shutdown_flag = 1; break; }
                if (rc < 0) break;
            }
            close(fd);
        }

        close(srv);
        fprintf(stderr, "tensor_daemond: shutdown\n");
    }
    return 0;
}
