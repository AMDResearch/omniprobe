// Launches kernel_a and kernel_b alternately, N times each (default 12), so that
// per-kernel dispatch numbers differ from global ones: kernel_a's n-th dispatch
// is global dispatch 2n-1 (plus any runtime blit kernels). Used by
// tests/test_dispatch_selection.sh.

#include <hip/hip_runtime.h>
#include <cstdlib>
#include <iostream>
#include "hip_test_utils.h"

__global__ void kernel_a(int* data, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    data[idx] = idx + n;
}

__global__ void kernel_b(float* data, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    data[idx] = static_cast<float>(idx) * 0.5f + n;
}

int main(int argc, char** argv) {
    int count = argc > 1 ? std::atoi(argv[1]) : 12;
    constexpr int threads = 64;
    int* idata;
    float* fdata;
    CHECK_HIP(hipMalloc(&idata, threads * sizeof(int)));
    CHECK_HIP(hipMalloc(&fdata, threads * sizeof(float)));
    for (int i = 1; i <= count; i++) {
        kernel_a<<<1, threads>>>(idata, i);
        CHECK_HIP(hipDeviceSynchronize());
        kernel_b<<<1, threads>>>(fdata, i);
        CHECK_HIP(hipDeviceSynchronize());
    }
    CHECK_HIP(hipFree(idata));
    CHECK_HIP(hipFree(fdata));
    std::cerr << "dispatch_select_test done (" << count << " dispatches of each kernel)" << std::endl;
    return 0;
}
