{
  "name": "fp16_matmul",
  "target": "tools/metal/tensor_gpu.metal",
  "goal": "Add fp16 variant of matmul kernel: operands in `half`, accumulator in `float`, entry point `matmul_f16`. Keep the original fp32 `matmul` unchanged.",
  "reference": "tools/metal/probes/fp16_probe.m (standalone proof that the pattern compiles and runs at 1.70x speedup).",
  "correctness": {
    "bench_bin": "tools/metal/bench_matmul",
    "compare_against": "matmul (fp32)",
    "tol_max_abs": 0.001,
    "N": 1024
  },
  "throughput": {
    "bench_bin": "tools/metal/bench_matmul",
    "min_speedup_vs_fp32": 1.6,
    "N": 1024
  },
  "max_iters": 5,
  "keep_rule": "throughput.min_speedup_vs_fp32 AND correctness.tol_max_abs"
}
