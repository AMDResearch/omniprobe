// Test program that calls rocblas_sscal (BLAS Level 1)
// This should dispatch a non-Tensile kernel (built into librocblas.so)

#include <hip/hip_runtime.h>
#include <rocblas/rocblas.h>
#include <iostream>
#include <vector>

#define CHECK_HIP(status) \
    if (status != hipSuccess) { \
        std::cerr << "HIP error: " << hipGetErrorString(status) << "\n"; \
        exit(EXIT_FAILURE); \
    }

#define CHECK_ROCBLAS(status) \
    if (status != rocblas_status_success) { \
        std::cerr << "rocBLAS error: " << status << "\n"; \
        exit(EXIT_FAILURE); \
    }

int main() {
    rocblas_handle handle;
    CHECK_ROCBLAS(rocblas_create_handle(&handle));

    const int n = 1024;
    std::vector<float> hx(n, 1.0f);

    float* dx;
    CHECK_HIP(hipMalloc(&dx, n * sizeof(float)));
    CHECK_HIP(hipMemcpy(dx, hx.data(), n * sizeof(float), hipMemcpyHostToDevice));

    float alpha = 2.0f;

    // rocblas_sscal: x = alpha * x
    // This is a BLAS Level 1 operation, uses non-Tensile kernel
    CHECK_ROCBLAS(rocblas_sscal(handle, n, &alpha, dx, 1));

    CHECK_HIP(hipMemcpy(hx.data(), dx, n * sizeof(float), hipMemcpyDeviceToHost));

    // Verify result (optional, just for sanity)
    bool ok = true;
    for (int i = 0; i < n && ok; i++) {
        if (hx[i] != 2.0f) ok = false;
    }
    std::cout << "rocblas_sscal: " << (ok ? "PASS" : "FAIL") << "\n";

    CHECK_HIP(hipFree(dx));
    CHECK_ROCBLAS(rocblas_destroy_handle(handle));

    return 0;
}
