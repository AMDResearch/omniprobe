// Host program that loads an instrumented .hsaco via hipModuleLoad and
// launches the kernel.  This exercises the code path where both the original
// and the __amd_crk_ instrumented kernel live in the same dynamically-loaded
// code object — a scenario where the interceptor currently cannot discover
// the instrumented alternative without an explicit --library-filter include.

#include <hip/hip_runtime.h>
#include <iostream>
#include <cstdlib>
#include <vector>

#define CHECK_HIP(call)                                                       \
    do {                                                                      \
        hipError_t err = call;                                                \
        if (err != hipSuccess) {                                              \
            std::cerr << #call << " failed: " << hipGetErrorString(err)       \
                      << std::endl;                                           \
            return 1;                                                         \
        }                                                                     \
    } while (0)

int main(int argc, char* argv[]) {
    // The .hsaco path is passed as the first argument (set by CMake / test script).
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <path-to-hsaco>" << std::endl;
        return 1;
    }
    const char* hsaco_path = argv[1];

    std::cerr << "Starting module_load_test" << std::endl;
    std::cerr << "  Loading code object: " << hsaco_path << std::endl;

    // Load the code object.
    hipModule_t module;
    CHECK_HIP(hipModuleLoad(&module, hsaco_path));

    // Look up the kernel function.
    hipFunction_t kernel;
    CHECK_HIP(hipModuleGetFunction(&kernel, module, "module_load_kernel"));

    // Allocate device memory.
    constexpr size_t blocksize = 64;
    constexpr size_t num_blocks = 4;
    constexpr size_t size = blocksize * num_blocks;

    int* d_data = nullptr;
    CHECK_HIP(hipMalloc(&d_data, size * sizeof(int)));
    CHECK_HIP(hipMemset(d_data, 0, size * sizeof(int)));

    // Launch the kernel.
    void* args[] = {&d_data, const_cast<size_t*>(&size)};
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        num_blocks, 1, 1,   // grid
        blocksize, 1, 1,    // block
        0,                  // shared mem
        nullptr,            // stream
        args,               // kernel args
        nullptr));          // extra
    CHECK_HIP(hipDeviceSynchronize());

    // Verify results on host.
    std::vector<int> h_data(size);
    CHECK_HIP(hipMemcpy(h_data.data(), d_data, size * sizeof(int),
                        hipMemcpyDeviceToHost));

    bool ok = true;
    for (size_t i = 0; i < size; ++i) {
        if (h_data[i] != static_cast<int>(i)) {
            std::cerr << "  MISMATCH at index " << i
                      << ": expected " << i << ", got " << h_data[i]
                      << std::endl;
            ok = false;
            break;
        }
    }

    CHECK_HIP(hipFree(d_data));
    CHECK_HIP(hipModuleUnload(module));

    if (ok) {
        std::cerr << "module_load_test: PASS" << std::endl;
    } else {
        std::cerr << "module_load_test: FAIL" << std::endl;
        return 1;
    }
    return 0;
}
