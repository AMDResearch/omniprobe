// lib_dynamic_head: Head of dynamic library chain
#pragma once

#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

// Launch the dynamic_head kernel
void launch_dynamic_head_kernel(int* data, size_t size);

// Launch all dynamic library kernels (head, mid, tail)
void launch_all_dynamic_kernels(int* data, size_t size);

#ifdef __cplusplus
}
#endif
