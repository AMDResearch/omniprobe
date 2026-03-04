// lib_dynamic_tail: Base of dynamic library chain (no dependencies)
// Loaded transitively via dlopen of lib_dynamic_head

#include <hip/hip_runtime.h>
#include "lib_dynamic_tail.h"

// Simple kernel - writes thread index to output
__global__ void dynamic_tail_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx + 6000);  // 6000 series = dynamic_tail
    }
}

extern "C" void launch_dynamic_tail_kernel(int* data, size_t size) {
    constexpr size_t blocksize = 64;
    size_t num_blocks = (size + blocksize - 1) / blocksize;
    dynamic_tail_kernel<<<num_blocks, blocksize>>>(data, size);
}
