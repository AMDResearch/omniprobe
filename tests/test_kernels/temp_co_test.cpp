// An instrumented kernel for tests/test_temp_code_objects.sh: omniprobe
// extracts this binary's code object to a temporary file, whose debug info
// names this source file, so the test can tell it from other processes' files.

#include <hip/hip_runtime.h>
#include <cstdio>
#include "hip_test_utils.h"

__global__ void strided_kernel(int* data, size_t size, size_t stride) {
    size_t idx = (blockIdx.x * blockDim.x + threadIdx.x) * stride;
    if (idx < size) {
        data[idx] = idx;
    }
}

int main() {
    constexpr size_t blocksize = 64, no_blocks = 2, stride = 16;
    constexpr size_t size = blocksize * no_blocks * stride;
    int* data;
    CHECK_HIP(hipMalloc(&data, size * sizeof(int)));
    strided_kernel<<<no_blocks, blocksize>>>(data, size, stride);
    CHECK_HIP(hipDeviceSynchronize());
    CHECK_HIP(hipFree(data));
    printf("temp_co_test done\n");
    return 0;
}
