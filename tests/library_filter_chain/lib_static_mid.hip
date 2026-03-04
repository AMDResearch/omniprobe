// lib_static_mid: Middle of static library chain (depends on lib_static_tail)
// Provides a kernel and calls into lib_static_tail

#include <hip/hip_runtime.h>
#include "lib_static_mid.h"
#include "lib_static_tail.h"

// Simple kernel - writes thread index to output
__global__ void static_mid_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx + 2000);  // 2000 series = static_mid
    }
}

void launch_static_mid_kernel(int* data, size_t size) {
    constexpr size_t blocksize = 64;
    size_t num_blocks = (size + blocksize - 1) / blocksize;
    static_mid_kernel<<<num_blocks, blocksize>>>(data, size);
}

void launch_static_mid_and_tail(int* data, size_t size) {
    launch_static_mid_kernel(data, size);
    launch_static_tail_kernel(data, size);
}
