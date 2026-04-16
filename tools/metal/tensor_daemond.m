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

// Pool stats — see tensor_gpu_lib.m for the struct layout.
typedef struct {
    int       tier;
    const char *storage;
    int       capacity;
    int       count;
    int       in_use;
    int       peak_in_use;
    long long hits;
    long long misses;
    long long drops;
    long long shrinks;
    long long bytes_in_pool;
} tgl_pool_stat_t;
extern int tgl_pool_stats(tgl_pool_stat_t *out, int max);

// Build a JSON document describing every pool tier.  Returns malloc'd
// NUL-terminated string; caller frees.  *len_out gets the byte length
// excluding the terminator.
static char* build_stats_json(size_t *len_out) {
    tgl_pool_stat_t stats[64];
    int n = tgl_pool_stats(stats, 64);

    // ~256 bytes per tier line, plus framing.  Allocate generously.
    size_t cap = 512 + (size_t)n * 256;
    char *buf = malloc(cap);
    if (!buf) { *len_out = 0; return NULL; }
    size_t off = 0;
    off += snprintf(buf + off, cap - off, "{\"tiers\":[");
    long long total_hits = 0, total_misses = 0, total_drops = 0, total_bytes = 0;
    for (int i = 0; i < n; i++) {
        total_hits   += stats[i].hits;
        total_misses += stats[i].misses;
        total_drops  += stats[i].drops;
        total_bytes  += stats[i].bytes_in_pool;
        off += snprintf(buf + off, cap - off,
            "%s{\"tier\":%d,\"storage\":\"%s\",\"capacity\":%d,\"count\":%d,"
            "\"in_use\":%d,\"peak_in_use\":%d,\"hits\":%lld,\"misses\":%lld,"
            "\"drops\":%lld,\"shrinks\":%lld,\"bytes_in_pool\":%lld}",
            i == 0 ? "" : ",",
            stats[i].tier, stats[i].storage,
            stats[i].capacity, stats[i].count,
            stats[i].in_use, stats[i].peak_in_use,
            stats[i].hits, stats[i].misses, stats[i].drops,
            stats[i].shrinks, stats[i].bytes_in_pool);
    }
    long long total_acquires = total_hits + total_misses;
    double miss_rate = total_acquires > 0 ?
        ((double)total_misses / (double)total_acquires) : 0.0;
    off += snprintf(buf + off, cap - off,
        "],\"totals\":{\"hits\":%lld,\"misses\":%lld,\"drops\":%lld,"
        "\"acquires\":%lld,\"miss_rate\":%.6f,\"bytes_in_pool\":%lld}}\n",
        total_hits, total_misses, total_drops, total_acquires,
        miss_rate, total_bytes);
    *len_out = off;
    return buf;
}

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

// Read exactly one line (up to \n, max 1024 bytes). Returns length incl \n,
// or -1 on EOF / error. Writes null terminator.
static int read_line_into(int fd, char *buf, size_t max, char first) {
    buf[0] = first;
    size_t off = 1;
    while (off < max - 1) {
        char c;
        if (read_exact(fd, &c, 1) < 0) return -1;
        buf[off++] = c;
        if (c == '\n') { buf[off] = 0; return (int)off; }
    }
    buf[off] = 0;
    return -1;
}

// Read whole f32 file into a newly malloced f64 buffer with +1 header pad.
// Returns NULL on error. *n_out = element count (doubles).
static double* read_f32_file_padded(const char *path, uint32_t n_elem) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    float *tmp = malloc((size_t)n_elem * 4);
    if (!tmp) { fclose(f); return NULL; }
    size_t got = fread(tmp, 4, n_elem, f);
    fclose(f);
    if (got != n_elem) { free(tmp); return NULL; }
    double *buf = calloc((size_t)n_elem + 1, 8);
    if (!buf) { free(tmp); return NULL; }
    for (uint32_t i = 0; i < n_elem; i++) buf[1 + i] = (double)tmp[i];
    free(tmp);
    return buf;
}

// Write f64 data buffer (with +1 header pad) to f32 file at path.
static int write_f32_file_padded(const char *path, const double *buf, uint32_t n_elem) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    float *tmp = malloc((size_t)n_elem * 4);
    if (!tmp) { fclose(f); return -1; }
    for (uint32_t i = 0; i < n_elem; i++) tmp[i] = (float)buf[1 + i];
    size_t wrote = fwrite(tmp, 4, n_elem, f);
    fclose(f);
    free(tmp);
    return (wrote == n_elem) ? 0 : -1;
}

// Text-mode dispatcher. Called after we've read the first byte and it's ASCII.
// Protocol: "CMD arg1 arg2 ...\n". Reply: "OK\n" or "ERR <msg>\n".
// Supported commands:
//   PING                                             -> OK 1
//   MATMUL_F32FILE M K N path_a path_b path_c        -> OK
//   SHUTDOWN                                         -> OK (closes daemon)
static int handle_text(int fd, char first) {
    char line[1024];
    int len = read_line_into(fd, line, sizeof(line), first);
    if (len < 0) return -1;
    if (len > 0 && line[len-1] == '\n') line[len-1] = 0;
    if (len > 1 && line[len-2] == '\r') line[len-2] = 0;

    char *cmd = strtok(line, " ");
    if (!cmd) { write_exact(fd, "ERR empty\n", 10); return 0; }

    if (strcmp(cmd, "PING") == 0) {
        write_exact(fd, "OK 1\n", 5);
        return 0;
    }
    if (strcmp(cmd, "SHUTDOWN") == 0) {
        write_exact(fd, "OK\n", 3);
        return 1;
    }
    // Plain text stats — `STATS\n` or `GPU_STATS\n` returns just the JSON body.
    if (strcmp(cmd, "STATS") == 0 || strcmp(cmd, "GPU_STATS") == 0) {
        size_t jlen = 0;
        char *json = build_stats_json(&jlen);
        if (!json) { write_exact(fd, "ERR stats\n", 10); return 0; }
        write_exact(fd, json, jlen);
        free(json);
        return 0;
    }
    // Minimal HTTP — `GET /gpu/stats ...` (and any other GET path returns
    // the same payload; we only have one route).  Drains the rest of the
    // request headers, then writes a single HTTP/1.0 response and closes.
    if (strcmp(cmd, "GET") == 0) {
        // strtok consumed the path already if present; we only need to drain.
        // Read until empty line ("\r\n\r\n" or "\n\n").
        char drain[256];
        int blank = 0;
        while (blank < 2) {
            char c;
            if (read_exact(fd, &c, 1) < 0) break;
            if (c == '\n') { blank++; continue; }
            if (c != '\r') blank = 0;
            (void)drain;
        }
        size_t jlen = 0;
        char *json = build_stats_json(&jlen);
        if (!json) {
            const char *err = "HTTP/1.0 500 Internal Server Error\r\n"
                              "Content-Length: 0\r\n\r\n";
            write_exact(fd, err, strlen(err));
            return -1;  // close this connection (NOT daemon shutdown)
        }
        char hdr[160];
        int hlen = snprintf(hdr, sizeof(hdr),
            "HTTP/1.0 200 OK\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %zu\r\n"
            "Connection: close\r\n\r\n", jlen);
        write_exact(fd, hdr, (size_t)hlen);
        write_exact(fd, json, jlen);
        free(json);
        return -1;  // HTTP/1.0 — close connection after responding (not daemon)
    }
    if (strcmp(cmd, "MATMUL_F32FILE") == 0) {
        char *sM = strtok(NULL, " ");
        char *sK = strtok(NULL, " ");
        char *sN = strtok(NULL, " ");
        char *pa = strtok(NULL, " ");
        char *pb = strtok(NULL, " ");
        char *pc = strtok(NULL, " ");
        if (!sM || !sK || !sN || !pa || !pb || !pc) {
            write_exact(fd, "ERR parse\n", 10); return 0;
        }
        int M = atoi(sM), K = atoi(sK), N = atoi(sN);
        double *A = read_f32_file_padded(pa, (uint32_t)(M*K));
        double *B = read_f32_file_padded(pb, (uint32_t)(K*N));
        if (!A || !B) {
            free(A); free(B);
            write_exact(fd, "ERR readfile\n", 13); return 0;
        }
        double *C = calloc((size_t)(M*N) + 1, 8);
        int rc = tgl_matmul_f64(A, B, C, M, K, N);
        if (rc != 1) {
            free(A); free(B); free(C);
            write_exact(fd, "ERR kernel\n", 11); return 0;
        }
        int wrc = write_f32_file_padded(pc, C, (uint32_t)(M*N));
        free(A); free(B); free(C);
        if (wrc != 0) { write_exact(fd, "ERR writefile\n", 14); return 0; }
        write_exact(fd, "OK\n", 3);
        return 0;
    }

    write_exact(fd, "ERR unknown\n", 12);
    return 0;
}

// Handle one request. Returns 0 to continue, 1 to shutdown, -1 on error.
static int handle_request(int fd) {
    uint8_t op;
    if (read_exact(fd, &op, 1) < 0) return -1;

    // Text-mode prefix detection: ASCII uppercase letter → text protocol.
    if (op >= 'A' && op <= 'Z') {
        return handle_text(fd, (char)op);
    }

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
