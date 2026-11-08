// A loop with a run-time trip count and a branch in its body, for the
// BBInterval plugin (tests/test_bb_interval.sh). Exit status 0 if the kernel
// completed, 3 if synchronization reported an error.

#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>

__global__ void bb_interval_loop(float* out, const float* in, int iters) {
    int i = blockIdx.x * 64 + threadIdx.x;
    float acc = in[i];
    for (int k = 0; k < iters; ++k) {
        if (acc > 0.5f) acc = acc * 0.999f + 0.0001f;
        else acc = acc * 1.001f + 0.0002f;
    }
    out[i] = acc;
}

int main(int argc, char** argv) {
    const int iters = argc > 1 ? std::atoi(argv[1]) : 1000;
    float *in, *out;
    if (hipMalloc(&in, 64 * sizeof(float)) != hipSuccess || hipMalloc(&out, 64 * sizeof(float)) != hipSuccess)
        return 2;
    (void)hipMemset(in, 0, 64 * sizeof(float));
    hipLaunchKernelGGL(bb_interval_loop, dim3(1), dim3(64), 0, 0, out, in, iters);
    hipError_t e = hipDeviceSynchronize();
    fprintf(stderr, "bb_interval_loop_test: iters=%d sync=%s\n", iters, hipGetErrorString(e));
    return e == hipSuccess ? 0 : 3;
}
