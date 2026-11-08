// LDS accesses before any global access (test_json_output.sh): each wave
// fills a shared tile, then reads it and stores to global memory. MemoryAnalysis
// used to learn LDS source file names only from global accesses seen earlier,
// so the first wave's LDS accesses were filed under "<unknown source file>"
// and one source location became two entries.
#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

__global__ void lds_fill_then_read(float* out) {
    __shared__ float tile[64 * 65];
    int l = threadIdx.x;
    for (int k = l; k < 64 * 65; k += 64) tile[k] = static_cast<float>(k);
    __syncthreads();
    out[blockIdx.x * 64 + l] = tile[l * 2];
}

int main() {
    constexpr int blocks = 16, threads = 64;
    float* out;
    CHECK_HIP(hipMalloc(&out, sizeof(float) * blocks * threads));
    lds_fill_then_read<<<blocks, threads>>>(out);
    CHECK_HIP(hipDeviceSynchronize());
    CHECK_HIP(hipFree(out));
    std::cerr << "lds_split_test done" << std::endl;
    return 0;
}
