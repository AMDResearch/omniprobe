// lib_static_tail: Base of static library chain (no dependencies)
// Provides a simple kernel that can be called from app

#include <hip/hip_runtime.h>
#include "lib_static_tail.h"

// Simple kernel - writes thread index to output
__global__ void static_tail_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx + 3000);  // 3000 series = static_tail
    }
}

void launch_static_tail_kernel(int* data, size_t size) {
    constexpr size_t blocksize = 64;
    size_t num_blocks = (size + blocksize - 1) / blocksize;
    static_tail_kernel<<<num_blocks, blocksize>>>(data, size);
}
