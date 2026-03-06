// Test program that calls hipblasLtMatrixTransform
// This dispatches a hipBLASLt matrix transform kernel (compiled from HIP source,
// instrumentable via LLVM IR pass plugin).
//
// The transform computes: C = alpha * op(A) + beta * op(B)
// where op can be transpose or no-op.

#include <hip/hip_runtime.h>
#include <hipblaslt/hipblaslt.h>
#include <iostream>
#include <vector>
#include <cmath>

#define CHECK_HIP(status) \
    if (status != hipSuccess) { \
        std::cerr << "HIP error: " << hipGetErrorString(status) \
                  << " at " << __FILE__ << ":" << __LINE__ << "\n"; \
        exit(EXIT_FAILURE); \
    }

#define CHECK_HIPBLASLT(status) \
    if (status != HIPBLAS_STATUS_SUCCESS) { \
        std::cerr << "hipBLASLt error: " << static_cast<int>(status) \
                  << " at " << __FILE__ << ":" << __LINE__ << "\n"; \
        exit(EXIT_FAILURE); \
    }

int main() {
    const int m = 64, n = 64;
    const size_t size = m * n;

    // Initialize host data
    std::vector<float> ha(size), hb(size), hc(size, 0.0f);
    for (size_t i = 0; i < size; i++) {
        ha[i] = static_cast<float>(i % 7);  // 0,1,2,3,4,5,6,0,1,...
        hb[i] = static_cast<float>(i % 5);  // 0,1,2,3,4,0,1,...
    }

    // Allocate device memory
    float *da, *db, *dc;
    CHECK_HIP(hipMalloc(&da, size * sizeof(float)));
    CHECK_HIP(hipMalloc(&db, size * sizeof(float)));
    CHECK_HIP(hipMalloc(&dc, size * sizeof(float)));
    CHECK_HIP(hipMemcpy(da, ha.data(), size * sizeof(float), hipMemcpyHostToDevice));
    CHECK_HIP(hipMemcpy(db, hb.data(), size * sizeof(float), hipMemcpyHostToDevice));

    // Create hipBLASLt handle
    hipblasLtHandle_t handle;
    CHECK_HIPBLASLT(hipblasLtCreate(&handle));

    // Create matrix transform descriptor
    hipblasLtMatrixTransformDesc_t desc;
    CHECK_HIPBLASLT(hipblasLtMatrixTransformDescCreate(&desc, HIP_R_32F));

    // Set pointer mode to host
    hipblasLtPointerMode_t pMode = HIPBLASLT_POINTER_MODE_HOST;
    CHECK_HIPBLASLT(hipblasLtMatrixTransformDescSetAttribute(
        desc, HIPBLASLT_MATRIX_TRANSFORM_DESC_POINTER_MODE, &pMode, sizeof(pMode)));

    // Set no-transpose for both A and B
    hipblasOperation_t opN = HIPBLAS_OP_N;
    CHECK_HIPBLASLT(hipblasLtMatrixTransformDescSetAttribute(
        desc, HIPBLASLT_MATRIX_TRANSFORM_DESC_TRANSA, &opN, sizeof(opN)));
    CHECK_HIPBLASLT(hipblasLtMatrixTransformDescSetAttribute(
        desc, HIPBLASLT_MATRIX_TRANSFORM_DESC_TRANSB, &opN, sizeof(opN)));

    // Create matrix layouts (column-major)
    hipblasLtMatrixLayout_t layoutA, layoutB, layoutC;
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutCreate(&layoutA, HIP_R_32F, m, n, m));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutCreate(&layoutB, HIP_R_32F, m, n, m));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutCreate(&layoutC, HIP_R_32F, m, n, m));

    hipblasLtOrder_t orderCol = HIPBLASLT_ORDER_COL;
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutSetAttribute(
        layoutA, HIPBLASLT_MATRIX_LAYOUT_ORDER, &orderCol, sizeof(orderCol)));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutSetAttribute(
        layoutB, HIPBLASLT_MATRIX_LAYOUT_ORDER, &orderCol, sizeof(orderCol)));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutSetAttribute(
        layoutC, HIPBLASLT_MATRIX_LAYOUT_ORDER, &orderCol, sizeof(orderCol)));

    // Execute: C = alpha * A + beta * B
    float alpha = 2.0f, beta = 3.0f;
    CHECK_HIPBLASLT(hipblasLtMatrixTransform(
        handle, desc, &alpha, da, layoutA, &beta, db, layoutB, dc, layoutC, nullptr));

    CHECK_HIP(hipDeviceSynchronize());

    // Copy result back and verify
    CHECK_HIP(hipMemcpy(hc.data(), dc, size * sizeof(float), hipMemcpyDeviceToHost));

    bool ok = true;
    for (size_t i = 0; i < size && ok; i++) {
        float expected = alpha * ha[i] + beta * hb[i];
        if (std::fabs(hc[i] - expected) > 1e-5f) {
            std::cerr << "Mismatch at [" << i << "]: got " << hc[i]
                      << ", expected " << expected << "\n";
            ok = false;
        }
    }
    std::cout << "hipblaslt_matrix_transform: " << (ok ? "PASS" : "FAIL") << "\n";

    // Cleanup
    CHECK_HIPBLASLT(hipblasLtMatrixTransformDescDestroy(desc));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutDestroy(layoutA));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutDestroy(layoutB));
    CHECK_HIPBLASLT(hipblasLtMatrixLayoutDestroy(layoutC));
    CHECK_HIP(hipFree(da));
    CHECK_HIP(hipFree(db));
    CHECK_HIP(hipFree(dc));
    CHECK_HIPBLASLT(hipblasLtDestroy(handle));

    return ok ? 0 : 1;
}
