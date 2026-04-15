// Standalone manual carrier for validating Omniprobe's runtime context passing.
// The original kernels match module_load_kernel.hip, while the __amd_crk_ clones
// explicitly emit dh_comms address messages through an added context parameter.

#include <hip/hip_runtime.h>

#include "dh_comms_dev.h"

extern "C" __global__ void mlk(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx);
    }
}

extern "C" __global__ void mlk_d(int* data, size_t size) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        data[idx] = static_cast<int>(idx);
    }
}

extern "C" __global__ void __amd_crk_mlkPv(
    int* data,
    size_t size,
    dh_comms::dh_comms_descriptor* rsrc) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        dh_comms::v_submit_address(
            rsrc,
            data + idx,
            0,
            __LINE__,
            0,
            dh_comms::memory_access::write,
            dh_comms::address_space::global,
            sizeof(*data));
        data[idx] = static_cast<int>(idx);
    }
}

extern "C" __global__ void __amd_crk_mlk_dPv(
    int* data,
    size_t size,
    dh_comms::dh_comms_descriptor* rsrc) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        dh_comms::v_submit_address(
            rsrc,
            data + idx,
            0,
            __LINE__,
            0,
            dh_comms::memory_access::write,
            dh_comms::address_space::global,
            sizeof(*data));
        data[idx] = static_cast<int>(idx);
    }
}
