// Standalone kernel compiled to .hsaco for hipModuleLoad testing.
// This kernel lives in a separate translation unit from the host program;
// it is compiled to a code object (.hsaco) and loaded at runtime via
// hipModuleLoad().

#include <hip/hip_runtime.h>

extern "C" __global__ void module_load_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx);
    }
}
