// metal_kernels.metal — RailML GPU kernel library
// Phase 2 of RailML: Metal compute kernels for tensor operations
//
// Compile:
//   xcrun metal -c metal_kernels.metal -o /tmp/railml.air
//   xcrun metallib /tmp/railml.air -o /tmp/railml.metallib
//
// All kernels operate on float (32-bit) buffers.
// Thread dispatch: 1D for elementwise/row ops, 2D for matmul.

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// 1. ELEMENTWISE OPERATIONS
// ============================================================================
// Each thread handles one element. Dispatch with grid size = number of elements.

// C[i] = A[i] + B[i]
kernel void tensor_add_kernel(
    device float       *a  [[buffer(0)]],
    device const float *b  [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = a[id] + b[id];
}

// C[i] = A[i] - B[i]
kernel void tensor_sub_kernel(
    device float       *a  [[buffer(0)]],
    device const float *b  [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = a[id] - b[id];
}

// Hadamard (elementwise) product: C[i] = A[i] * B[i]
kernel void tensor_mul_kernel(
    device float       *a  [[buffer(0)]],
    device const float *b  [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = a[id] * b[id];
}

// Scalar multiply: A[i] = A[i] * scalar
// The scalar is passed as a single-element constant buffer.
kernel void tensor_scale_kernel(
    device float          *a      [[buffer(0)]],
    constant float        &scalar [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = a[id] * scalar;
}

// ReLU: f(x) = max(0, x)
kernel void tensor_relu_kernel(
    device float *a [[buffer(0)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = max(0.0f, a[id]);
}

// GELU (Gaussian Error Linear Unit) — approximate form:
//   GELU(x) ~ 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
// This is the standard approximation used in GPT-2/BERT.
kernel void tensor_gelu_kernel(
    device float *a [[buffer(0)]],
    uint id [[thread_position_in_grid]])
{
    float x = a[id];
    // sqrt(2/pi) = 0.7978845608...
    float inner = 0.7978845608f * (x + 0.044715f * x * x * x);
    a[id] = 0.5f * x * (1.0f + tanh(inner));
}

// Elementwise exp: A[i] = exp(A[i])
kernel void tensor_exp_kernel(
    device float *a [[buffer(0)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = exp(a[id]);
}

// Elementwise log (natural logarithm): A[i] = ln(A[i])
// Adds a tiny epsilon to prevent log(0) = -inf.
kernel void tensor_log_kernel(
    device float *a [[buffer(0)]],
    uint id [[thread_position_in_grid]])
{
    a[id] = log(a[id] + 1e-10f);
}


// ============================================================================
// 2. MATRIX MULTIPLICATION
// ============================================================================
// C = A * B where A is [M x K], B is [K x N], C is [M x N].
// Row-major layout: A[row][col] = A[row * K + col].

// --- Naive matmul ---
// One thread per output element C[row][col].
// Dispatch: grid = (N, M), i.e. gid.x = col, gid.y = row.
kernel void matmul_kernel(
    device const float *A [[buffer(0)]],
    device const float *B [[buffer(1)]],
    device float       *C [[buffer(2)]],
    constant uint      &M [[buffer(3)]],   // rows of A / rows of C
    constant uint      &N [[buffer(4)]],   // cols of B / cols of C
    constant uint      &K [[buffer(5)]],   // cols of A / rows of B
    uint2 gid [[thread_position_in_grid]])
{
    uint col = gid.x;  // column in C
    uint row = gid.y;  // row in C

    if (row >= M || col >= N) return;

    // Dot product of A[row, :] and B[:, col]
    float sum = 0.0f;
    for (uint i = 0; i < K; i++) {
        sum += A[row * K + i] * B[i * N + col];
    }
    C[row * N + col] = sum;
}

// --- Tiled matmul ---
// Uses threadgroup (shared) memory to reduce global memory accesses.
// Each threadgroup loads a TILE_SIZE x TILE_SIZE block of A and B into
// shared memory, computes partial sums, then moves to the next tile.
//
// This reduces global memory reads from O(K) per thread to O(K/TILE_SIZE)
// per thread, since each element is read once into shared memory and
// reused TILE_SIZE times.

#define TILE_SIZE 16

kernel void matmul_tiled_kernel(
    device const float *A [[buffer(0)]],
    device const float *B [[buffer(1)]],
    device float       *C [[buffer(2)]],
    constant uint      &M [[buffer(3)]],
    constant uint      &N [[buffer(4)]],
    constant uint      &K [[buffer(5)]],
    uint2 gid   [[thread_position_in_grid]],
    uint2 tid   [[thread_position_in_threadgroup]],
    uint2 tgid  [[threadgroup_position_in_grid]])
{
    // Threadgroup-local tile buffers
    threadgroup float tileA[TILE_SIZE][TILE_SIZE];
    threadgroup float tileB[TILE_SIZE][TILE_SIZE];

    uint col = gid.x;  // global column
    uint row = gid.y;  // global row

    float sum = 0.0f;

    // Number of tiles needed to cover the K dimension
    uint numTiles = (K + TILE_SIZE - 1) / TILE_SIZE;

    for (uint t = 0; t < numTiles; t++) {
        // Each thread loads one element of A and one element of B into
        // the shared tile. The tile covers:
        //   A rows [tgid.y*TILE_SIZE .. (tgid.y+1)*TILE_SIZE-1],
        //     cols [t*TILE_SIZE .. (t+1)*TILE_SIZE-1]
        //   B rows [t*TILE_SIZE .. (t+1)*TILE_SIZE-1],
        //     cols [tgid.x*TILE_SIZE .. (tgid.x+1)*TILE_SIZE-1]

        uint aCol = t * TILE_SIZE + tid.x;
        uint bRow = t * TILE_SIZE + tid.y;

        // Load A tile element (bounds-check for edge tiles)
        if (row < M && aCol < K) {
            tileA[tid.y][tid.x] = A[row * K + aCol];
        } else {
            tileA[tid.y][tid.x] = 0.0f;
        }

        // Load B tile element
        if (bRow < K && col < N) {
            tileB[tid.y][tid.x] = B[bRow * N + col];
        } else {
            tileB[tid.y][tid.x] = 0.0f;
        }

        // Synchronize: all threads must finish loading before computing
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Accumulate partial dot product from this tile
        for (uint i = 0; i < TILE_SIZE; i++) {
            sum += tileA[tid.y][i] * tileB[i][tid.x];
        }

        // Synchronize: all threads must finish reading before next tile load
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (row < M && col < N) {
        C[row * N + col] = sum;
    }
}


// ============================================================================
// 3. SOFTMAX (Two-pass, numerically stable)
// ============================================================================
// softmax(x_i) = exp(x_i - max(x)) / sum(exp(x_j - max(x)))
//
// This is split into three kernels for a matrix of shape [rows x cols]:
//   Pass 1: Find max per row           → row_max[row]
//   Pass 2: Compute exp(x-max) and sum → row_sum[row], and x[] is overwritten with exp(x-max)
//   Pass 3: Normalize x[i] /= sum     → final softmax output
//
// Each kernel dispatches one thread per row (simple version).
// For large vocab sizes, a parallel reduction per row would be faster,
// but this is correct and clear for initial integration.

// Pass 1: Find the maximum value in each row.
// One thread per row. Writes result to row_max[row].
kernel void softmax_max_kernel(
    device const float *x       [[buffer(0)]],   // [rows x cols] input
    device float       *row_max [[buffer(1)]],   // [rows] output
    constant uint      &cols    [[buffer(2)]],   // number of columns
    uint row [[thread_position_in_grid]])
{
    float mx = x[row * cols];
    for (uint j = 1; j < cols; j++) {
        mx = max(mx, x[row * cols + j]);
    }
    row_max[row] = mx;
}

// Pass 2: Compute exp(x_i - max) for each element in the row,
// store it back into x, and accumulate the sum into row_sum.
kernel void softmax_exp_sum_kernel(
    device float       *x       [[buffer(0)]],   // [rows x cols] in/out
    device const float *row_max [[buffer(1)]],   // [rows] from pass 1
    device float       *row_sum [[buffer(2)]],   // [rows] output
    constant uint      &cols    [[buffer(3)]],
    uint row [[thread_position_in_grid]])
{
    float mx = row_max[row];
    float s = 0.0f;
    for (uint j = 0; j < cols; j++) {
        float val = exp(x[row * cols + j] - mx);
        x[row * cols + j] = val;    // overwrite with exp(x - max)
        s += val;
    }
    row_sum[row] = s;
}

// Pass 3: Divide each element by the row sum to get final probabilities.
kernel void softmax_normalize_kernel(
    device float       *x       [[buffer(0)]],   // [rows x cols] in/out
    device const float *row_sum [[buffer(1)]],   // [rows] from pass 2
    constant uint      &cols    [[buffer(2)]],
    uint row [[thread_position_in_grid]])
{
    float s = row_sum[row];
    // Guard against division by zero (degenerate row of -inf)
    if (s < 1e-10f) s = 1e-10f;
    for (uint j = 0; j < cols; j++) {
        x[row * cols + j] /= s;
    }
}


// ============================================================================
// 4. LAYER NORMALIZATION
// ============================================================================
// LayerNorm(x) = gamma * (x - mean) / sqrt(variance + eps) + beta
//
// For a tensor of shape [rows x d_model]:
//   mean_i    = (1/d) * sum(x[i,j] for j in 0..d-1)
//   var_i     = (1/d) * sum((x[i,j] - mean_i)^2 for j in 0..d-1)
//   out[i,j]  = gamma[j] * (x[i,j] - mean_i) / sqrt(var_i + eps) + beta[j]
//
// One thread per row. For large d_model, a parallel reduction would be
// faster, but this is correct and suitable for d_model up to ~4096.

kernel void layernorm_kernel(
    device const float *x       [[buffer(0)]],   // [rows x d_model] input
    device float       *out     [[buffer(1)]],   // [rows x d_model] output
    device const float *gamma   [[buffer(2)]],   // [d_model] scale
    device const float *beta    [[buffer(3)]],   // [d_model] shift
    constant uint      &d_model [[buffer(4)]],
    constant float     &eps     [[buffer(5)]],
    uint row [[thread_position_in_grid]])
{
    uint base = row * d_model;

    // Compute mean of this row
    float sum = 0.0f;
    for (uint j = 0; j < d_model; j++) {
        sum += x[base + j];
    }
    float mean = sum / float(d_model);

    // Compute variance of this row: E[(x - mean)^2]
    float var_sum = 0.0f;
    for (uint j = 0; j < d_model; j++) {
        float diff = x[base + j] - mean;
        var_sum += diff * diff;
    }
    float inv_std = rsqrt(var_sum / float(d_model) + eps);

    // Normalize, scale by gamma, shift by beta
    for (uint j = 0; j < d_model; j++) {
        out[base + j] = gamma[j] * (x[base + j] - mean) * inv_std + beta[j];
    }
}


// ============================================================================
// 5. CROSS-ENTROPY LOSS
// ============================================================================
// Cross-entropy loss for classification:
//   L = -(1/N) * sum_i( log(probs[i, target[i]]) )
//
// Input: probs [N x C] — softmax output (probabilities)
//        targets [N]   — integer class labels (0..C-1)
// Output: losses [N]   — per-sample loss (host sums and averages)
//
// One thread per sample. The host is responsible for the final mean
// reduction (summing losses[] and dividing by N).

kernel void cross_entropy_kernel(
    device const float *probs   [[buffer(0)]],   // [N x num_classes] softmax probs
    device const int   *targets [[buffer(1)]],   // [N] target class indices
    device float       *losses  [[buffer(2)]],   // [N] per-sample loss output
    constant uint      &num_classes [[buffer(3)]],
    uint i [[thread_position_in_grid]])
{
    // Look up the predicted probability for the correct class
    int target = targets[i];
    float p = probs[i * num_classes + target];

    // Clamp to avoid log(0) = -inf
    if (p < 1e-10f) p = 1e-10f;

    // Negative log-likelihood
    losses[i] = -log(p);
}


// ============================================================================
// 6. BACKWARD KERNELS (for training)
// ============================================================================
// These are the gradient kernels needed for backpropagation.

// ReLU backward: grad_in[i] = (x[i] > 0) ? grad_out[i] : 0
kernel void tensor_relu_backward_kernel(
    device float       *grad_out [[buffer(0)]],  // gradient from upstream (in/out)
    device const float *x        [[buffer(1)]],   // original input to ReLU
    uint id [[thread_position_in_grid]])
{
    grad_out[id] = (x[id] > 0.0f) ? grad_out[id] : 0.0f;
}

// GELU backward (approximate):
//   Let inner = sqrt(2/pi) * (x + 0.044715 * x^3)
//   Let t = tanh(inner)
//   GELU'(x) = 0.5 * (1 + t) + 0.5 * x * (1 - t^2) * sqrt(2/pi) * (1 + 3*0.044715*x^2)
kernel void tensor_gelu_backward_kernel(
    device float       *grad_out [[buffer(0)]],  // upstream gradient (in/out)
    device const float *x        [[buffer(1)]],   // original input
    uint id [[thread_position_in_grid]])
{
    float v = x[id];
    float inner = 0.7978845608f * (v + 0.044715f * v * v * v);
    float t = tanh(inner);
    float dtanh = 1.0f - t * t;  // sech^2(inner)
    float dinner = 0.7978845608f * (1.0f + 3.0f * 0.044715f * v * v);
    float dgelu = 0.5f * (1.0f + t) + 0.5f * v * dtanh * dinner;
    grad_out[id] = grad_out[id] * dgelu;
}

// Cross-entropy backward (softmax + cross-entropy combined gradient):
//   For softmax output p and target y (one-hot):
//     dL/dlogit[i,j] = p[i,j] - (j == target[i] ? 1 : 0)
//   This is the well-known simplification for softmax + NLL.
//   One thread per sample, iterates over classes.
kernel void cross_entropy_backward_kernel(
    device const float *probs      [[buffer(0)]],   // [N x C] softmax probs
    device const int   *targets    [[buffer(1)]],   // [N] target indices
    device float       *grad_logits [[buffer(2)]],  // [N x C] output gradients
    constant uint      &num_classes [[buffer(3)]],
    constant float     &inv_n       [[buffer(4)]],  // 1.0/N for mean reduction
    uint i [[thread_position_in_grid]])
{
    int target = targets[i];
    for (uint j = 0; j < num_classes; j++) {
        float p = probs[i * num_classes + j];
        // Gradient of mean cross-entropy w.r.t. logits
        // = (p - one_hot(target)) / N
        float grad = p;
        if (int(j) == target) grad -= 1.0f;
        grad_logits[i * num_classes + j] = grad * inv_n;
    }
}
