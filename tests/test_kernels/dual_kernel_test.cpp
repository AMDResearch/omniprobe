// Test program that dispatches two distinct instrumented kernels
// Used to investigate how many times ISA scanning passes execute
// (once total, or once per kernel dispatch?)

#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

__global__ void kernel_alpha(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = idx * 2;
    }
}

__global__ void kernel_beta(float* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<float>(idx) * 0.5f;
    }
}

int main() {
    std::cerr << "Starting dual_kernel_test" << std::endl;

    constexpr size_t blocksize = 64;
    constexpr size_t no_blocks = 4;
    constexpr size_t size = blocksize * no_blocks;

    // First kernel: integer data
    int *idata;
    CHECK_HIP(hipMalloc(&idata, size * sizeof(int)));
    std::cerr << "Dispatching kernel_alpha..." << std::endl;
    kernel_alpha<<<no_blocks, blocksize>>>(idata, size);
    CHECK_HIP(hipDeviceSynchronize());
    std::cerr << "kernel_alpha done" << std::endl;

    // Second kernel: float data
    float *fdata;
    CHECK_HIP(hipMalloc(&fdata, size * sizeof(float)));
    std::cerr << "Dispatching kernel_beta..." << std::endl;
    kernel_beta<<<no_blocks, blocksize>>>(fdata, size);
    CHECK_HIP(hipDeviceSynchronize());
    std::cerr << "kernel_beta done" << std::endl;

    CHECK_HIP(hipFree(idata));
    CHECK_HIP(hipFree(fdata));

    std::cerr << "dual_kernel_test done" << std::endl;
    return 0;
}
