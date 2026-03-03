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
    hipError_t err = hipMalloc(&data, size * sizeof(int));
    if (err != hipSuccess) {
        std::cerr << "hipMalloc failed: " << hipGetErrorString(err) << std::endl;
        return 1;
    }

    simple_kernel<<<no_blocks, blocksize>>>(data, size);
    err = hipDeviceSynchronize();
    if (err != hipSuccess) {
        std::cerr << "hipDeviceSynchronize failed: " << hipGetErrorString(err) << std::endl;
        (void)hipFree(data);  // Explicitly ignore return on error path
        return 1;
    }

    err = hipFree(data);
    if (err != hipSuccess) {
        std::cerr << "hipFree failed: " << hipGetErrorString(err) << std::endl;
        return 1;
    }

    std::cerr << "simple_heatmap_test done" << std::endl;
    return 0;
}
