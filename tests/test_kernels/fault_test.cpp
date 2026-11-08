// A kernel that faults on the GPU (stores to an unmapped address), for
// tests/test_faulted_dispatch.sh. With --no-fault it stores to a valid buffer.
// Exit status: 0 if the kernel completed, 3 if synchronization reported an error.

#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstring>

__global__ void fault_kernel(int* p) {
    p[threadIdx.x * 1024 * 1024] = 1;
}

int main(int argc, char** argv) {
    const bool fault = !(argc > 1 && std::strcmp(argv[1], "--no-fault") == 0);
    int* target = reinterpret_cast<int*>(0x10);   // never mapped
    if (!fault && hipMalloc(&target, 64 * 1024 * 1024 * sizeof(int)) != hipSuccess)
        return 2;
    hipLaunchKernelGGL(fault_kernel, dim3(1), dim3(64), 0, 0, target);
    hipError_t e = hipDeviceSynchronize();
    fprintf(stderr, "fault_test: %s\n", hipGetErrorString(e));
    if (!fault)
        (void)hipFree(target);
    return e == hipSuccess ? 0 : 3;
}
