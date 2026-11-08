// Internal-linkage kernels under -fgpu-rdc get a ".intern.<hash>" symbol
// suffix. Used by tests/test_intern_linkage.sh, which builds this file twice
// with fixed -cuid values so that one build gets a letter-leading hash and the
// other a digit-leading one (the two take different name-lookup paths).
// The kernels without parameters cover a second naming hazard: the clone of
// _Z1kv is _Z1kvPv, which demangles as k(void, void*).
#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

__global__ void kernel_external(int* data, size_t n) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) data[i] = static_cast<int>(i);
}

static __global__ void kernel_static(int* data, size_t n) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) data[i] += 1;
}

namespace {
__global__ void kernel_anon(int* data, size_t n) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) data[i] *= 2;
}
}

__device__ int g_data[256];

__global__ void kernel_noargs() {
    g_data[threadIdx.x] = static_cast<int>(threadIdx.x);
}

static __global__ void kernel_static_noargs() {
    g_data[threadIdx.x] += 1;
}

int main() {
    constexpr size_t n = 256;
    int* data;
    CHECK_HIP(hipMalloc(&data, n * sizeof(int)));
    kernel_external<<<n / 64, 64>>>(data, n);
    kernel_static<<<n / 64, 64>>>(data, n);
    kernel_anon<<<n / 64, 64>>>(data, n);
    kernel_noargs<<<1, 256>>>();
    kernel_static_noargs<<<1, 256>>>();
    CHECK_HIP(hipDeviceSynchronize());
    CHECK_HIP(hipFree(data));
    std::cerr << "intern_linkage_test done" << std::endl;
    return 0;
}
