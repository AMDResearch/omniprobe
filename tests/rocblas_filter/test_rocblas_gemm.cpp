// Test program that calls rocblas_sgemm (BLAS Level 3)
// This should dispatch a Tensile kernel (dynamically loaded from hsaco)

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

    // Small matrices for quick test
    const int m = 64, n = 64, k = 64;
    const int lda = m, ldb = k, ldc = m;
    const size_t size_a = lda * k;
    const size_t size_b = ldb * n;
    const size_t size_c = ldc * n;

    std::vector<float> ha(size_a, 1.0f);
    std::vector<float> hb(size_b, 1.0f);
    std::vector<float> hc(size_c, 0.0f);

    float *da, *db, *dc;
    CHECK_HIP(hipMalloc(&da, size_a * sizeof(float)));
    CHECK_HIP(hipMalloc(&db, size_b * sizeof(float)));
    CHECK_HIP(hipMalloc(&dc, size_c * sizeof(float)));

    CHECK_HIP(hipMemcpy(da, ha.data(), size_a * sizeof(float), hipMemcpyHostToDevice));
    CHECK_HIP(hipMemcpy(db, hb.data(), size_b * sizeof(float), hipMemcpyHostToDevice));
    CHECK_HIP(hipMemcpy(dc, hc.data(), size_c * sizeof(float), hipMemcpyHostToDevice));

    float alpha = 1.0f;
    float beta = 0.0f;

    // rocblas_sgemm: C = alpha * A * B + beta * C
    // This is a BLAS Level 3 operation, uses Tensile kernel
    CHECK_ROCBLAS(rocblas_sgemm(handle,
                                rocblas_operation_none,
                                rocblas_operation_none,
                                m, n, k,
                                &alpha,
                                da, lda,
                                db, ldb,
                                &beta,
                                dc, ldc));

    CHECK_HIP(hipMemcpy(hc.data(), dc, size_c * sizeof(float), hipMemcpyDeviceToHost));

    // Verify result: each element of C should be k (since A[i,j]=1, B[i,j]=1)
    bool ok = true;
    for (size_t i = 0; i < size_c && ok; i++) {
        if (hc[i] != static_cast<float>(k)) ok = false;
    }
    std::cout << "rocblas_sgemm: " << (ok ? "PASS" : "FAIL") << "\n";

    CHECK_HIP(hipFree(da));
    CHECK_HIP(hipFree(db));
    CHECK_HIP(hipFree(dc));
    CHECK_ROCBLAS(rocblas_destroy_handle(handle));

    return 0;
}
