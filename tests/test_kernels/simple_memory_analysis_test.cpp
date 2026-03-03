// Simple test kernel for memory analysis handler
// Creates both coalesced and uncoalesced memory access patterns

#include <hip/hip_runtime.h>
#include <iostream>

// Coalesced access - adjacent threads access adjacent memory
__global__ void coalesced_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = idx;
    }
}

// Strided access - creates uncoalesced pattern
__global__ void strided_kernel(int* data, size_t size, size_t stride) {
    size_t idx = (blockIdx.x * blockDim.x + threadIdx.x) * stride;
    if (idx < size) {
        data[idx] = idx;
    }
}

int main() {
    std::cerr << "Starting simple_memory_analysis_test" << std::endl;

    constexpr size_t blocksize = 64;
    constexpr size_t no_blocks = 2;
    constexpr size_t size = blocksize * no_blocks * 16; // Extra space for strided access

    int *data;
    hipError_t err = hipMalloc(&data, size * sizeof(int));
    if (err != hipSuccess) {
        std::cerr << "hipMalloc failed: " << hipGetErrorString(err) << std::endl;
        return 1;
    }

    // First dispatch: coalesced access
    coalesced_kernel<<<no_blocks, blocksize>>>(data, blocksize * no_blocks);
    err = hipDeviceSynchronize();
    if (err != hipSuccess) {
        std::cerr << "hipDeviceSynchronize failed: " << hipGetErrorString(err) << std::endl;
        (void)hipFree(data);  // Explicitly ignore return on error path
        return 1;
    }

    // Second dispatch: strided access (uncoalesced)
    strided_kernel<<<no_blocks, blocksize>>>(data, size, 16);
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

    std::cerr << "simple_memory_analysis_test done" << std::endl;
    return 0;
}
