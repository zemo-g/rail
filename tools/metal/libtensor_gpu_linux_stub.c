/* Linux ELF stub for libtensor_gpu.
 *
 * Why this exists: stdlib/tensor.rail declares ~25 `foreign tgl_*` symbols
 * for the Metal-backed dylib that ships on macOS. On Linux, programs that
 * `import "stdlib/tensor.rail"` need those symbols resolved at link time —
 * even though the runtime path always falls through to CPU because
 * `gpu_available` shells out to test for the Mac-only binary and returns 0.
 *
 * Each function is a no-op returning 0. The variadic-ish `(void)` signature
 * lets the linker satisfy the call regardless of caller ABI; since the
 * dynamic path never actually invokes these, the argument list is moot.
 *
 * Built once per conformance run inside the gcc:latest container; the result
 * is linked into every test binary via `gcc -L/stage -ltensor_gpu`.
 */

#define TGL_STUB(name) long name() { return 0; }

TGL_STUB(tgl_init)
TGL_STUB(tgl_matmul_f64)
TGL_STUB(tgl_matmul_f32x_halfw_host)
TGL_STUB(tgl_matmul_relu_f64)
TGL_STUB(tgl_add_f64)
TGL_STUB(tgl_mul_f64)
TGL_STUB(tgl_scale_f64)
TGL_STUB(tgl_relu_f64)
TGL_STUB(tgl_relu_backward_f64)
TGL_STUB(tgl_sigmoid_f64)
TGL_STUB(tgl_exp_f64)
TGL_STUB(tgl_tanh_f64)
TGL_STUB(tgl_softmax_rows_f64)
TGL_STUB(tgl_transpose_f64)
TGL_STUB(tgl_sgd_update_f64)
TGL_STUB(tgl_adam_update_f64)
TGL_STUB(tgl_cross_entropy_f64)
TGL_STUB(tgl_matmul_gelu_f64)
TGL_STUB(tgl_matmul_batched_f64)
TGL_STUB(tgl_softmax_backward_f64)
TGL_STUB(tgl_ce_softmax_backward_f64)
TGL_STUB(tgl_layernorm_backward_f64)
TGL_STUB(tgl_matmul_f16)
TGL_STUB(tgl_matmul_blocked_f16)
TGL_STUB(tgl_matmul_bias_relu_f16)
TGL_STUB(tgl_matmul_bias_gelu_f16)
TGL_STUB(tgl_f64_to_half)
TGL_STUB(tgl_half_to_f64)
TGL_STUB(tgl_matmul_half_host)
TGL_STUB(tgl_add_half_host)
TGL_STUB(tgl_scale_half_host)
TGL_STUB(tgl_transpose_half_host)
TGL_STUB(tgl_softmax_half_host)
