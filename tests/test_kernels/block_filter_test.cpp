// Test kernel for block index filtering
// Launches kernel with known grid dimensions and accesses memory based on block coordinates
// Used to verify that DH_COMMS_GROUP_FILTER_{X,Y,Z} environment variables work correctly

#include <hip/hip_runtime.h>
#include <iostream>
#include "hip_test_utils.h"

// Kernel that uses block indices to determine which array element to access
// This creates a predictable pattern: each workgroup writes to a unique location
// based on its 3D block coordinates
__global__ void block_indexed_kernel(int* data, int grid_dim_x, int grid_dim_y, int grid_dim_z) {
    // Compute linear index from 3D block coordinates
    int block_linear_idx = blockIdx.x +
                          blockIdx.y * grid_dim_x +
                          blockIdx.z * grid_dim_x * grid_dim_y;

    // Each thread in the workgroup accesses offset by threadIdx.x
    size_t idx = block_linear_idx * blockDim.x + threadIdx.x;

    // Read and write to create address messages
    int value = data[idx];  // Read
    data[idx] = value + block_linear_idx;  // Write back with block index added
}

int main() {
    std::cerr << "Starting block_filter_test" << std::endl;

    // Use 3D grid to test all three dimensions
    constexpr int grid_x = 8;
    constexpr int grid_y = 4;
    constexpr int grid_z = 2;
    constexpr int blocksize = 64;
    constexpr size_t total_blocks = grid_x * grid_y * grid_z;
    constexpr size_t size = total_blocks * blocksize;

    std::cerr << "Grid dimensions: " << grid_x << " x " << grid_y << " x " << grid_z << std::endl;
    std::cerr << "Block size: " << blocksize << std::endl;
    std::cerr << "Total blocks: " << total_blocks << std::endl;
    std::cerr << "Array size: " << size << " elements" << std::endl;

    int *data;
    CHECK_HIP(hipMalloc(&data, size * sizeof(int)));

    // Initialize data to zero
    CHECK_HIP(hipMemset(data, 0, size * sizeof(int)));

    // Launch with 3D grid
    dim3 grid(grid_x, grid_y, grid_z);
    dim3 block(blocksize);

    std::cerr << "Launching kernel..." << std::endl;
    block_indexed_kernel<<<grid, block>>>(data, grid_x, grid_y, grid_z);
    CHECK_HIP(hipDeviceSynchronize());

    CHECK_HIP(hipFree(data));

    std::cerr << "block_filter_test done" << std::endl;
    return 0;
}
