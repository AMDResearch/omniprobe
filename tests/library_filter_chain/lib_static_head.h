// lib_static_head: Head of static library chain
#pragma once

#include <cstddef>

// Launch the static_head kernel
void launch_static_head_kernel(int* data, size_t size);

// Launch all static library kernels (head, mid, tail)
void launch_all_static_kernels(int* data, size_t size);
