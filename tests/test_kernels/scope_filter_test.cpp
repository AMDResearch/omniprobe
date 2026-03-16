// Test kernel for instrumentation scope filtering
// Has multiple memory operations on distinct lines with SCOPE_MARKER comments.
// The test script greps for SCOPE_MARKER to discover line numbers dynamically.
// This kernel is compiled on-the-fly by the test script (not built by CMake).

#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

__global__ void scope_test_kernel(int* a, int* b, int* c, int* d, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n)
        return;

    int val_a = a[idx];          // SCOPE_MARKER line_a
    int val_b = b[idx];          // SCOPE_MARKER line_b
    c[idx] = val_a + val_b;      // SCOPE_MARKER line_c
    d[idx] = val_a * val_b;      // SCOPE_MARKER line_d
}

int main() {
    std::cerr << "Starting scope_filter_test" << std::endl;

    constexpr int blocksize = 64;
    constexpr int n = blocksize;  // Single block for simplicity

    int *a, *b, *c, *d;
    CHECK_HIP(hipMalloc(&a, n * sizeof(int)));
    CHECK_HIP(hipMalloc(&b, n * sizeof(int)));
    CHECK_HIP(hipMalloc(&c, n * sizeof(int)));
    CHECK_HIP(hipMalloc(&d, n * sizeof(int)));

    CHECK_HIP(hipMemset(a, 1, n * sizeof(int)));
    CHECK_HIP(hipMemset(b, 2, n * sizeof(int)));
    CHECK_HIP(hipMemset(c, 0, n * sizeof(int)));
    CHECK_HIP(hipMemset(d, 0, n * sizeof(int)));

    std::cerr << "Launching kernel..." << std::endl;
    scope_test_kernel<<<1, blocksize>>>(a, b, c, d, n);
    CHECK_HIP(hipDeviceSynchronize());

    CHECK_HIP(hipFree(a));
    CHECK_HIP(hipFree(b));
    CHECK_HIP(hipFree(c));
    CHECK_HIP(hipFree(d));

    std::cerr << "scope_filter_test done" << std::endl;
    return 0;
}
