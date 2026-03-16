// Test kernel for sub-8B (e.g. int) kernel arguments.
// This reproduces the bug reported in issue "Error with sub-8B kernel arguments":
// when a kernel has pointer arguments followed by 32-bit integer arguments, the
// kernarg layout places the last explicit argument at a non-8-byte-aligned offset.
// The old roundArgsLength() logic incorrectly rounded that offset up, overshooting
// the hidden-args boundary and triggering an assertion failure in fixupKernArgs().

#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

// Kernel with pointer args followed by 32-bit int args (sub-8B).
// This layout mirrors the hgemm_kernel from the bug report:
//   ptr(0,8), ptr(8,8), ptr(16,8), int(24,4), int(28,4), int(32,4)
// The last explicit arg ends at byte 36, which is not 8-byte aligned.
__global__ void sub8b_args_kernel(const int* __restrict__ A,
                                  const int* __restrict__ B,
                                  int* __restrict__ C,
                                  int M, int N, int K)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < M * N)
    {
        // Simple element-wise add using M, N, K to ensure they are live.
        int row = idx / N;
        int col = idx % N;
        if (row < M && col < N && col < K)
            C[row * N + col] = A[row * K + col] + B[row * N + col];
    }
}

int main()
{
    std::cerr << "Starting sub8b_args_test" << std::endl;

    constexpr int M = 4;
    constexpr int N = 4;
    constexpr int K = 4;

    int *dA, *dB, *dC;
    CHECK_HIP(hipMalloc(&dA, M * K * sizeof(int)));
    CHECK_HIP(hipMalloc(&dB, M * N * sizeof(int)));
    CHECK_HIP(hipMalloc(&dC, M * N * sizeof(int)));

    constexpr int blocksize = 64;
    constexpr int no_blocks = 1;

    sub8b_args_kernel<<<no_blocks, blocksize>>>(dA, dB, dC, M, N, K);
    CHECK_HIP(hipDeviceSynchronize());

    CHECK_HIP(hipFree(dA));
    CHECK_HIP(hipFree(dB));
    CHECK_HIP(hipFree(dC));

    std::cerr << "sub8b_args_test done" << std::endl;
    return 0;
}
