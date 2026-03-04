// Utility macros for HIP error checking in test kernels
// Provides ASSERT_EQ-like functionality without requiring GoogleTest

#pragma once

#include <hip/hip_runtime.h>
#include <iostream>

// Check HIP call and exit with error message if it fails
// Usage: CHECK_HIP(hipMalloc(&ptr, size));
#define CHECK_HIP(call) \
    do { \
        hipError_t err = call; \
        if (err != hipSuccess) { \
            std::cerr << #call << " failed: " << hipGetErrorString(err) << std::endl; \
            return 1; \
        } \
    } while (0)

// Version for void functions (no return value)
#define CHECK_HIP_VOID(call) \
    do { \
        hipError_t err = call; \
        if (err != hipSuccess) { \
            std::cerr << #call << " failed: " << hipGetErrorString(err) << std::endl; \
            exit(1); \
        } \
    } while (0)
