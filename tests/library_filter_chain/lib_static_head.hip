// lib_static_head: Head of static library chain (depends on lib_static_mid)
// This is what app links against directly

#include <hip/hip_runtime.h>
#include "lib_static_head.h"
#include "lib_static_mid.h"

// Simple kernel - writes thread index to output
__global__ void static_head_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx + 1000);  // 1000 series = static_head
    }
}

void launch_static_head_kernel(int* data, size_t size) {
    constexpr size_t blocksize = 64;
    size_t num_blocks = (size + blocksize - 1) / blocksize;
    static_head_kernel<<<num_blocks, blocksize>>>(data, size);
}

void launch_all_static_kernels(int* data, size_t size) {
    launch_static_head_kernel(data, size);
    launch_static_mid_and_tail(data, size);
}
