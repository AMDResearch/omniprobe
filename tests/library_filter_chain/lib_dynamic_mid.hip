// lib_dynamic_mid: Middle of dynamic library chain (depends on lib_dynamic_tail)

#include <hip/hip_runtime.h>
#include "lib_dynamic_mid.h"
#include "lib_dynamic_tail.h"

// Simple kernel - writes thread index to output
__global__ void dynamic_mid_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx + 5000);  // 5000 series = dynamic_mid
    }
}

extern "C" void launch_dynamic_mid_kernel(int* data, size_t size) {
    constexpr size_t blocksize = 64;
    size_t num_blocks = (size + blocksize - 1) / blocksize;
    dynamic_mid_kernel<<<num_blocks, blocksize>>>(data, size);
}

extern "C" void launch_dynamic_mid_and_tail(int* data, size_t size) {
    launch_dynamic_mid_kernel(data, size);
    launch_dynamic_tail_kernel(data, size);
}
