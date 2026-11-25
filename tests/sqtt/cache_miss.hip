// Test kernel for counter_fit.py with cache counters (e.g. TCC_MISS, TCC_REQ).
//
// It has two global load sites with known L2 (TCC) behaviour:
//   site A: the block's lanes read consecutive dwords of a 64 KiB buffer that
//           stays in L2 -> about 0 L2 misses per instruction.
//   site B: every lane reads its own 128-byte line of a 1 GiB buffer, and no
//           line is read twice until the walk wraps around 1 GiB, far more
//           than L2 holds -> about one L2 miss per lane (64 per wave64
//           instruction, 32 per wave32 instruction).
// Each block runs the two sites a different number of times, sweeping from
// "all A" in block 0 to "all B" in the last block, so the mix of A and B
// changes over the run, which lets the least-squares fit separate them.
//
// Markers can be added at load time (no rebuild):
//   omniprobe --sqtt-sites --sites memory --per-block -k cache_miss \
//     --spm TCC_MISS TCC_REQ SQ_INSTS_VMEM_RD -- ./cache_miss 16384 64 64
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
constexpr int kSmallWords = 16384;             // 64 KiB
constexpr size_t kBigWords = size_t(1) << 28;  // 1 GiB
constexpr int kLineWords = 32;                 // 128-byte lines

extern "C" __global__ void cache_miss(float *out, const float *small, const float *big,
                                      int iters_a, int iters_b) {
  const int t = threadIdx.x;

  // Block 0 runs only site A, the last block only site B, and blocks in
  // between run a linear mix of both.
  const int n = gridDim.x > 1 ? gridDim.x - 1 : 1;
  const int a = iters_a * (n - blockIdx.x) / n;
  const int b = iters_b * blockIdx.x / n;

  float acc = 0.f;
  // Site A: coalesced reads of a small buffer -> L2 hits.
#pragma unroll 1
  for (int i = 0; i < a; ++i)
    acc += small[(t + i * kThreads) % kSmallWords];
  // Site B: one fresh 128-byte line per lane -> L2 misses.
  const size_t first = size_t(blockIdx.x) * iters_b;
#pragma unroll 1
  for (int i = 0; i < b; ++i)
    acc += big[((first + i) * kThreads + t) * kLineWords % kBigWords];

  // Keep the loads live so the compiler cannot drop them.
  out[blockIdx.x * kThreads + t] = acc;
}

int main(int argc, char **argv) {
  // Arguments: number of blocks, site A iterations, site B iterations.
  const int blocks = argc > 1 ? std::atoi(argv[1]) : 16384;
  const int iters_a = argc > 2 ? std::atoi(argv[2]) : 64;
  const int iters_b = argc > 3 ? std::atoi(argv[3]) : 64;

  std::vector<float> h_small(kSmallWords);
  for (int i = 0; i < kSmallWords; ++i) h_small[i] = static_cast<float>(i % 7);
  float *out = nullptr, *small = nullptr, *big = nullptr;
  CHECK(hipMalloc(&out, sizeof(float) * blocks * kThreads));
  CHECK(hipMalloc(&small, sizeof(float) * kSmallWords));
  CHECK(hipMalloc(&big, sizeof(float) * kBigWords));
  CHECK(hipMemcpy(small, h_small.data(), sizeof(float) * kSmallWords, hipMemcpyHostToDevice));
  CHECK(hipMemsetD32(reinterpret_cast<hipDeviceptr_t>(big), 0x3f800000, kBigWords));  // 1.0f
  hipLaunchKernelGGL(cache_miss, dim3(blocks), dim3(kThreads), 0, 0, out, small, big,
                     iters_a, iters_b);
  CHECK(hipGetLastError());
  CHECK(hipDeviceSynchronize());

  // Copy back and print a couple of values as a basic sanity check.
  std::vector<float> h(blocks * kThreads);
  CHECK(hipMemcpy(h.data(), out, sizeof(float) * h.size(), hipMemcpyDeviceToHost));
  double sum = 0;
  for (float v : h) sum += v;
  std::printf("blocks=%d iters_a=%d iters_b=%d out[0]=%f out[last]=%f sum=%.1f\n", blocks,
              iters_a, iters_b, h.front(), h.back(), sum);
  CHECK(hipFree(big));
  CHECK(hipFree(small));
  CHECK(hipFree(out));
  return 0;
}
