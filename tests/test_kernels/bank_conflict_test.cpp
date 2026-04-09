// Test kernel for LDS bank conflict detection
// Matrix transpose using shared memory WITHOUT padding — the classic bank conflict scenario.
// On gfx90a with 4-byte accesses, each column read hits the same bank across 32 lanes.

#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

// Tile dimension chosen so column accesses cause bank conflicts
// (32 threads reading column of 32x32 shared array → all hit same bank)
constexpr int TILE_DIM = 32;

__global__ void transpose_no_pad(float* out, const float* in, int width, int height) {
    __shared__ float tile[TILE_DIM][TILE_DIM];  // No +1 padding → bank conflicts on column read
    int x = blockIdx.x * TILE_DIM + threadIdx.x;
    int y = blockIdx.y * TILE_DIM + threadIdx.y;
    // Row write into LDS (no conflict)
    tile[threadIdx.y][threadIdx.x] = in[y * width + x];
    __syncthreads();
    // Column read from LDS (conflict! all 32 threads hit same bank)
    x = blockIdx.y * TILE_DIM + threadIdx.x;
    y = blockIdx.x * TILE_DIM + threadIdx.y;
    out[y * width + x] = tile[threadIdx.x][threadIdx.y];
}

int main() {
    std::cerr << "Starting bank_conflict_test" << std::endl;

    constexpr int WIDTH = TILE_DIM;
    constexpr int HEIGHT = TILE_DIM;
    constexpr size_t size = WIDTH * HEIGHT * sizeof(float);

    float *d_in, *d_out;
    CHECK_HIP(hipMalloc(&d_in, size));
    CHECK_HIP(hipMalloc(&d_out, size));

    // Initialize input on host and copy to device
    float h_in[WIDTH * HEIGHT];
    for (int i = 0; i < WIDTH * HEIGHT; i++) {
        h_in[i] = static_cast<float>(i);
    }
    CHECK_HIP(hipMemcpy(d_in, h_in, size, hipMemcpyHostToDevice));

    // Single 32x32 block on a 32x32 matrix — exactly one tile dispatch
    dim3 block(TILE_DIM, TILE_DIM);
    dim3 grid(1, 1);
    transpose_no_pad<<<grid, block>>>(d_out, d_in, WIDTH, HEIGHT);
    CHECK_HIP(hipDeviceSynchronize());

    CHECK_HIP(hipFree(d_in));
    CHECK_HIP(hipFree(d_out));

    std::cerr << "bank_conflict_test done" << std::endl;
    return 0;
}
