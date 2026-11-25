// Host harness for the rewriter with global-memory sites: loads cache_miss
// from a code object file with hipModuleLoad, runs it, and writes the output
// buffer to a file so a rewritten code object can be checked bit-for-bit
// against the original.
//
// Usage: cache_module <code_object> <out.bin> [blocks iters_a iters_b]
#include <hip/hip_runtime.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(x)                                                              \
  do {                                                                        \
    hipError_t e = (x);                                                       \
    if (e != hipSuccess) {                                                    \
      std::printf("%s failed: %s\n", #x, hipGetErrorString(e));               \
      return 1;                                                               \
    }                                                                         \
  } while (0)

constexpr int kThreads = 256;
constexpr int kSmallWords = 16384;
constexpr size_t kBigWords = size_t(1) << 28;

int main(int argc, char **argv) {
  if (argc < 3) {
    std::printf("usage: %s <code_object> <out.bin> [blocks iters_a iters_b]\n", argv[0]);
    return 2;
  }
  const int blocks = argc > 3 ? std::atoi(argv[3]) : 1024;
  const int iters_a = argc > 4 ? std::atoi(argv[4]) : 64;
  const int iters_b = argc > 5 ? std::atoi(argv[5]) : 64;

  hipModule_t module;
  hipFunction_t kernel;
  CHECK(hipModuleLoad(&module, argv[1]));
  CHECK(hipModuleGetFunction(&kernel, module, "cache_miss"));

  // Small buffer: distinct values; big buffer: a value per line, so a load
  // from the wrong address changes the output.
  std::vector<float> h_small(kSmallWords);
  for (int i = 0; i < kSmallWords; ++i) h_small[i] = static_cast<float>(i % 7);
  std::vector<float> h_big(kBigWords);
  for (size_t i = 0; i < kBigWords; ++i) h_big[i] = static_cast<float>((i / 32) % 1021);
  float *out = nullptr, *small = nullptr, *big = nullptr;
  CHECK(hipMalloc(&out, sizeof(float) * blocks * kThreads));
  CHECK(hipMalloc(&small, sizeof(float) * kSmallWords));
  CHECK(hipMalloc(&big, sizeof(float) * kBigWords));
  CHECK(hipMemcpy(small, h_small.data(), sizeof(float) * kSmallWords, hipMemcpyHostToDevice));
  CHECK(hipMemcpy(big, h_big.data(), sizeof(float) * kBigWords, hipMemcpyHostToDevice));

  struct {
    float *out;
    const float *small;
    const float *big;
    int iters_a;
    int iters_b;
  } args{out, small, big, iters_a, iters_b};
  size_t size = sizeof(args);
  void *config[] = {HIP_LAUNCH_PARAM_BUFFER_POINTER, &args, HIP_LAUNCH_PARAM_BUFFER_SIZE,
                    &size, HIP_LAUNCH_PARAM_END};
  CHECK(hipModuleLaunchKernel(kernel, blocks, 1, 1, kThreads, 1, 1, 0, nullptr, nullptr,
                              config));
  CHECK(hipDeviceSynchronize());

  std::vector<float> h(blocks * kThreads);
  CHECK(hipMemcpy(h.data(), out, sizeof(float) * h.size(), hipMemcpyDeviceToHost));
  FILE *f = std::fopen(argv[2], "wb");
  std::fwrite(h.data(), sizeof(float), h.size(), f);
  std::fclose(f);
  std::printf("blocks=%d out[0]=%f out[last]=%f\n", blocks, h.front(), h.back());
  CHECK(hipFree(big));
  CHECK(hipFree(small));
  CHECK(hipFree(out));
  CHECK(hipModuleUnload(module));
  return 0;
}
