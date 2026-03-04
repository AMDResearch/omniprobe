// lib_static_mid: Middle of static library chain
#pragma once

#include <cstddef>

// Launch the static_mid kernel
void launch_static_mid_kernel(int* data, size_t size);

// Launch both static_mid and static_tail kernels
void launch_static_mid_and_tail(int* data, size_t size);
