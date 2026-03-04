// lib_dynamic_tail: Base of dynamic library chain
#pragma once

#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

// Launch the dynamic_tail kernel
void launch_dynamic_tail_kernel(int* data, size_t size);

#ifdef __cplusplus
}
#endif
