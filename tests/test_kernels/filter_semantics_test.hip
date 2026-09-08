// Two-kernel program for bf_hip-duplicate-code-object-load's filter-semantics tests.
//
// kernel_strided writes with a stride wide enough to touch one cache line per lane, so
// MemoryAnalysis reports it with a source-line attribution — which is what lets AC-8
// assert that DWARF correlation survives a filtered run.
//
// kernel_linear is coalesced and is reported by nothing. Its job is to be the kernel a
// -k regex does NOT match, so AC-7 can check that the filter restricts dispatch per
// kernel within a single run.
#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void kernel_strided(int *data, size_t n, size_t stride) {
  size_t idx = (blockIdx.x * blockDim.x + threadIdx.x) * stride;
  if (idx < n)
    data[idx] = static_cast<int>(idx);
}

__global__ void kernel_linear(int *data, size_t n) {
  size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n)
    data[idx] = static_cast<int>(idx) * 2;
}

int main() {
  const size_t N = 1024;
  int *d_data = nullptr;
  if (hipMalloc(&d_data, N * sizeof(int)) != hipSuccess) {
    printf("FILTER_SEMANTICS: hipMalloc failed\n");
    return 1;
  }

  hipLaunchKernelGGL(kernel_strided, dim3(1), dim3(64), 0, 0, d_data, N, 16);
  hipLaunchKernelGGL(kernel_linear, dim3(1), dim3(64), 0, 0, d_data, N);
  (void)hipDeviceSynchronize();
  (void)hipFree(d_data);

  printf("FILTER_SEMANTICS: both kernels dispatched\n");
  return 0;
}
