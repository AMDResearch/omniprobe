// Kernels whose demangled names exercise -k (tests/test_kernel_filter_names.sh):
// a plain kernel, a template (demangled with a leading "void "), a static kernel
// (its clone gets an .intern suffix under -fgpu-rdc), a kernel without
// parameters, and one in an anonymous namespace.

#include <hip/hip_runtime.h>
#include <cstdio>

__device__ int filter_sink[8];

__global__ void filterAlpha(int* d) { d[threadIdx.x] = 1; }

template <int N>
__global__ void filterTemplate(int* d) { d[threadIdx.x] = N; }

static __global__ void filterStatic(int* d) { d[threadIdx.x] = 3; }

__global__ void filterNoParams() { filter_sink[threadIdx.x % 8] = 4; }

namespace {
__global__ void filterAnon(int* d) { d[threadIdx.x] = 5; }
}

int main() {
    int* d;
    if (hipMalloc(&d, 64 * sizeof(int)) != hipSuccess)
        return 2;
    filterAlpha<<<1, 64>>>(d);
    filterTemplate<4><<<1, 64>>>(d);
    filterStatic<<<1, 64>>>(d);
    filterNoParams<<<1, 64>>>();
    filterAnon<<<1, 64>>>(d);
    hipError_t e = hipDeviceSynchronize();
    fprintf(stderr, "kernel_filter_names_test: %s\n", hipGetErrorString(e));
    return e == hipSuccess ? 0 : 3;
}
