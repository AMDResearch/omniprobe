// Test kernel exercising dynamic shared memory (extern __shared__).
//
// Verifies that omniprobe's instrumented dispatch preserves the dynamic
// portion of group_segment_size requested at launch via the third launch
// argument (dynamicSharedMemoryBytes). Without that preservation the
// instrumented clone allocates only its own fixed LDS, the kernel reads
// past the end of LDS, and the output mismatches.

#include <hip/hip_runtime.h>
#include <iostream>
#include <vector>
#include "hip_test_utils.h"

// Each thread writes its global index into shared memory at threadIdx.x,
// then reads from a permuted slot and writes that to global memory.
// All accesses are within blockDim.x ints of LDS, requested at launch.
__global__ void dynamic_lds_kernel(int* output, size_t n) {
    extern __shared__ int sdata[];

    int tid = threadIdx.x;
    size_t idx = static_cast<size_t>(blockIdx.x) * blockDim.x + tid;

    sdata[tid] = static_cast<int>(idx);
    __syncthreads();

    int permuted_tid = blockDim.x - 1 - tid;
    if (idx < n) {
        output[idx] = sdata[permuted_tid];
    }
}

int main() {
    std::cerr << "Starting dynamic_lds_test" << std::endl;

    constexpr int blocksize = 256;
    constexpr int no_blocks = 4;
    constexpr size_t size = static_cast<size_t>(blocksize) * no_blocks;

    int* d_output = nullptr;
    CHECK_HIP(hipMalloc(&d_output, size * sizeof(int)));
    CHECK_HIP(hipMemset(d_output, -1, size * sizeof(int)));

    // Request enough dynamic LDS for one int per thread in the block.
    // Without the fixupPacket fix, the instrumented dispatch will only
    // allocate the instrumented kernel's fixed LDS (typically much smaller
    // or zero), and the kernel will read past its allocated LDS region.
    const size_t dyn_lds_bytes = blocksize * sizeof(int);

    dynamic_lds_kernel<<<no_blocks, blocksize, dyn_lds_bytes>>>(d_output, size);
    CHECK_HIP(hipGetLastError());
    CHECK_HIP(hipDeviceSynchronize());

    std::vector<int> h_output(size);
    CHECK_HIP(hipMemcpy(h_output.data(), d_output,
                        size * sizeof(int), hipMemcpyDeviceToHost));
    CHECK_HIP(hipFree(d_output));

    int errors = 0;
    constexpr int max_errors_to_report = 5;
    for (int b = 0; b < no_blocks; ++b) {
        for (int t = 0; t < blocksize; ++t) {
            size_t idx = static_cast<size_t>(b) * blocksize + t;
            int permuted_tid = blocksize - 1 - t;
            int expected = b * blocksize + permuted_tid;
            if (h_output[idx] != expected) {
                if (errors < max_errors_to_report) {
                    std::cerr << "  MISMATCH at idx=" << idx
                              << ": expected " << expected
                              << ", got " << h_output[idx] << std::endl;
                }
                ++errors;
            }
        }
    }

    if (errors == 0) {
        std::cout << "dynamic_lds_test: PASS" << std::endl;
        return 0;
    }
    std::cout << "dynamic_lds_test: FAIL (" << errors
              << " mismatches out of " << size << ")" << std::endl;
    return 1;
}
