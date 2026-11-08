// Known control flow for BasicBlockAnalysis: every count per block has an
// analytic answer (see tests/test_bba_counts.sh). Keep the marked lines in
// sync with that script.
#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

constexpr int kThreads = 1024;
constexpr int kBlockSize = 256;

__global__ void bb_counts_kernel(float* out, float* side, int trips) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;    // BB_LINE_ENTRY
    float acc = out[idx];
    if ((threadIdx.x & 3) == 0) {
        side[idx] = acc * 3.0f;                          // BB_LINE_QUARTER
    }
#pragma unroll 1
    for (int i = 0; i < trips; ++i) {
        acc = acc * 0.5f + static_cast<float>(i);        // BB_LINE_LOOP
    }
    out[idx] = acc;
}

int main(int argc, char** argv) {
    int trips = argc > 1 ? std::atoi(argv[1]) : 5;
    float *out, *side;
    CHECK_HIP(hipMalloc(&out, kThreads * sizeof(float)));
    CHECK_HIP(hipMalloc(&side, kThreads * sizeof(float)));
    CHECK_HIP(hipMemset(out, 0, kThreads * sizeof(float)));
    bb_counts_kernel<<<kThreads / kBlockSize, kBlockSize>>>(out, side, trips);
    CHECK_HIP(hipDeviceSynchronize());
    CHECK_HIP(hipFree(out));
    CHECK_HIP(hipFree(side));
    std::cerr << "bb_counts_test done" << std::endl;
    return 0;
}
