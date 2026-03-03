// Simple test kernel for memory heatmap handler
// Emits address messages that should be tracked by memory_heatmap_t

#include <hip/hip_runtime.h>
#include <iostream>

__global__ void simple_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = idx;
    }
}

int main() {
    std::cerr << "Starting simple_heatmap_test" << std::endl;

    constexpr size_t blocksize = 64;
    constexpr size_t no_blocks = 4;
    constexpr size_t size = blocksize * no_blocks;

    int *data;
    hipMalloc(&data, size * sizeof(int));

    simple_kernel<<<no_blocks, blocksize>>>(data, size);
    hipDeviceSynchronize();

    hipFree(data);
    std::cerr << "simple_heatmap_test done" << std::endl;
    return 0;
}
