#include <hip/hip_runtime.h>

// Five loads from one source line; the compiler merges some of them, so not
// every load has an ISA instruction at its own column.
__global__ void stencil5(const float* in, float* out, int nx, int ny) {
    int x = blockIdx.x * blockDim.x + threadIdx.x + 1;
    int y = blockIdx.y + 1;
    if (x < nx - 1 && y < ny - 1)
        out[y * nx + x] = in[y * nx + x - 1] + in[y * nx + x] + in[y * nx + x + 1] + in[(y - 1) * nx + x] + in[(y + 1) * nx + x];
}

void launch_stencil(const float* in, float* out, int nx, int ny) {
    stencil5<<<dim3((nx + 255) / 256, ny), 256>>>(in, out, nx, ny);
}
