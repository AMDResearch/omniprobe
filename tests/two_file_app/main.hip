// Two source files, no -fgpu-rdc (tests/test_two_file_app.sh). The two kernels
// are launched back to back without a synchronization; scale_rows has few
// waves that each loop over a whole row, so its address records keep coming
// while the stencil's are still being written.
#include <hip/hip_runtime.h>
#include <cstdio>

void launch_stencil(const float* in, float* out, int nx, int ny);

__global__ void scale_rows(float* a, int nx, int ny, float s) {
    int row = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= ny) return;
    for (int col = 0; col < nx; col++)
        a[row * nx + col] *= s;
}

int main() {
    const int nx = 2048, ny = 2048;
    float *in, *out;
    if (hipMalloc(&in, nx * ny * sizeof(float)) != hipSuccess || hipMalloc(&out, nx * ny * sizeof(float)) != hipSuccess)
        return 1;
    (void)hipMemset(in, 0, nx * ny * sizeof(float));
    launch_stencil(in, out, nx, ny);
    scale_rows<<<ny / 64, 64>>>(out, nx, ny, 0.5f);
    if (hipDeviceSynchronize() != hipSuccess)
        return 1;
    printf("two_file_app done\n");
    return 0;
}
