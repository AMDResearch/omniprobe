// lib_dynamic_mid: Middle of dynamic library chain
#pragma once

#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

// Launch the dynamic_mid kernel
void launch_dynamic_mid_kernel(int* data, size_t size);

// Launch both dynamic_mid and dynamic_tail kernels
void launch_dynamic_mid_and_tail(int* data, size_t size);

#ifdef __cplusplus
}
#endif
