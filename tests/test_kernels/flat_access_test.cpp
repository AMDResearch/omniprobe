// Flat-pointer accesses for MemoryAnalysis (tests/test_flat_access.sh).
// Built twice: flat_access_test (-O2) and flat_access_O0_test (-O0). At -O0
// every access goes through a flat pointer; at -O2 the compiler infers global
// and LDS for the first two kernels, but not for a pointer loaded from memory
// (ptr_table) nor for a pointer that is LDS in some lanes and global in others
// (mixed_spaces). Lines carrying a marker comment are the ones the test checks.

#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

constexpr int TILE = 32;
constexpr int STRIDE = 16;   // floats: 64 bytes between lanes, so 2 lanes per 128-byte line

__global__ void strided_read(float* out, const float* in) {
    int i = blockIdx.x * 64 + threadIdx.x;
    out[i] = in[i * STRIDE];   // FLAT_LINE_STRIDED
}

__global__ void transpose_no_pad(float* out, const float* in) {
    __shared__ float tile[TILE][TILE];
    tile[threadIdx.y][threadIdx.x] = in[threadIdx.y * TILE + threadIdx.x];
    __syncthreads();
    out[threadIdx.y * TILE + threadIdx.x] = tile[threadIdx.x][threadIdx.y];   // FLAT_LINE_TRANSPOSE
}

__global__ void ptr_table(float* out, float* const* table) {
    const float* p = table[blockIdx.x];
    int i = blockIdx.x * 64 + threadIdx.x;
    out[i] = p[threadIdx.x * STRIDE];   // FLAT_LINE_TABLE
}

__global__ void mixed_spaces(float* g) {
    __shared__ float s[64];
    float* p = (threadIdx.x & 1) ? &s[threadIdx.x] : &g[threadIdx.x];
    *p = 1.0f;   // FLAT_LINE_MIXED
    __syncthreads();
    if (threadIdx.x & 1) g[threadIdx.x] = s[threadIdx.x];
}

int main() {
    constexpr int N = 1024;
    float *in, *out, *g;
    float** table;
    CHECK_HIP(hipMalloc(&in, N * STRIDE * sizeof(float)));
    CHECK_HIP(hipMalloc(&out, N * sizeof(float)));
    CHECK_HIP(hipMalloc(&g, 64 * sizeof(float)));
    CHECK_HIP(hipMalloc(&table, (N / 64) * sizeof(float*)));
    CHECK_HIP(hipMemset(in, 0, N * STRIDE * sizeof(float)));
    float* host_table[N / 64];
    for (int b = 0; b < N / 64; ++b) host_table[b] = in + b * 64 * STRIDE;
    CHECK_HIP(hipMemcpy(table, host_table, sizeof(host_table), hipMemcpyHostToDevice));

    strided_read<<<N / 64, 64>>>(out, in);
    transpose_no_pad<<<1, dim3(TILE, TILE)>>>(out, in);
    ptr_table<<<N / 64, 64>>>(out, table);
    mixed_spaces<<<1, 64>>>(g);
    CHECK_HIP(hipDeviceSynchronize());

    CHECK_HIP(hipFree(in)); CHECK_HIP(hipFree(out)); CHECK_HIP(hipFree(g)); CHECK_HIP(hipFree(table));
    std::cerr << "flat_access_test: done" << std::endl;
    return 0;
}
