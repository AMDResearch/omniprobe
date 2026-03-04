// lib_dynamic_head: Head of dynamic library chain (depends on lib_dynamic_mid)
// This is what app loads via dlopen

#include <hip/hip_runtime.h>
#include "lib_dynamic_head.h"
#include "lib_dynamic_mid.h"

// Simple kernel - writes thread index to output
__global__ void dynamic_head_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx + 4000);  // 4000 series = dynamic_head
    }
}

extern "C" void launch_dynamic_head_kernel(int* data, size_t size) {
    constexpr size_t blocksize = 64;
    size_t num_blocks = (size + blocksize - 1) / blocksize;
    dynamic_head_kernel<<<num_blocks, blocksize>>>(data, size);
}

extern "C" void launch_all_dynamic_kernels(int* data, size_t size) {
    launch_dynamic_head_kernel(data, size);
    launch_dynamic_mid_and_tail(data, size);
}
