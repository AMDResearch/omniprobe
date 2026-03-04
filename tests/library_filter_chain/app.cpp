// Test application for library filter testing
// - Has its own kernel
// - Links against lib_static_head (which links lib_static_mid -> lib_static_tail)
// - dlopen's lib_dynamic_head (which links lib_dynamic_mid -> lib_dynamic_tail)

#include <hip/hip_runtime.h>
#include <dlfcn.h>
#include <iostream>
#include <cstdlib>
#include "hip_test_utils.h"
#include "lib_static_head.h"

// App's own kernel
__global__ void app_kernel(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx);  // 0 series = app
    }
}

// Function pointer types for dynamic library functions
using launch_kernel_fn = void (*)(int*, size_t);

int main(int argc, char* argv[]) {
    std::cerr << "=== Library Filter Chain Test ===" << std::endl;

    // Get path to dynamic library from environment or command line
    const char* lib_path = std::getenv("LIB_DYNAMIC_HEAD_PATH");
    if (argc > 1) {
        lib_path = argv[1];
    }
    if (!lib_path) {
        std::cerr << "Error: Set LIB_DYNAMIC_HEAD_PATH or pass path as argument" << std::endl;
        return 1;
    }

    constexpr size_t blocksize = 64;
    constexpr size_t num_blocks = 2;
    constexpr size_t size = blocksize * num_blocks;

    int* data;
    CHECK_HIP(hipMalloc(&data, size * sizeof(int)));

    // 1. Launch app's own kernel
    std::cerr << "Launching app_kernel..." << std::endl;
    app_kernel<<<num_blocks, blocksize>>>(data, size);
    CHECK_HIP(hipDeviceSynchronize());
    std::cerr << "  app_kernel done" << std::endl;

    // 2. Launch all static library kernels (linked at compile time)
    std::cerr << "Launching static library kernels..." << std::endl;
    launch_all_static_kernels(data, size);
    CHECK_HIP(hipDeviceSynchronize());
    std::cerr << "  static kernels done" << std::endl;

    // 3. Load dynamic library via dlopen
    std::cerr << "Loading dynamic library: " << lib_path << std::endl;
    void* handle = dlopen(lib_path, RTLD_NOW);
    if (!handle) {
        std::cerr << "dlopen failed: " << dlerror() << std::endl;
        return 1;
    }
    std::cerr << "  dlopen succeeded" << std::endl;

    // Get function pointer
    auto launch_all_dynamic = reinterpret_cast<launch_kernel_fn>(
        dlsym(handle, "launch_all_dynamic_kernels")
    );
    if (!launch_all_dynamic) {
        std::cerr << "dlsym failed: " << dlerror() << std::endl;
        dlclose(handle);
        return 1;
    }

    // 4. Launch all dynamic library kernels (loaded at runtime)
    std::cerr << "Launching dynamic library kernels..." << std::endl;
    launch_all_dynamic(data, size);
    CHECK_HIP(hipDeviceSynchronize());
    std::cerr << "  dynamic kernels done" << std::endl;

    // Cleanup
    dlclose(handle);
    CHECK_HIP(hipFree(data));

    std::cerr << "=== Test completed successfully ===" << std::endl;
    return 0;
}
