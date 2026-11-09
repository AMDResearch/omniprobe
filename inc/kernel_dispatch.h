/******************************************************************************
Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*******************************************************************************/
#pragma once
// The per-kernel dispatch ordinal ("kernel_dispatch": the n-th dispatch of this
// kernel in this process, from 1) of an instrumented dispatch, looked up by its
// global dispatch id. The interceptor records it before it creates the
// dispatch's message handlers and forgets it right after, so handlers read it
// in their constructors. 0 when unknown.
//
// The symbol lives in liblogDuration64.so. Handlers built into plugins reach it
// through the preloaded library at run time; the weak reference keeps a plugin
// loadable without it (it then reports 0).
#include <cstdint>

extern "C" uint64_t omniprobe_kernel_dispatch(uint64_t dispatch_id) __attribute__((weak));

inline uint64_t kernelDispatchOrdinal(uint64_t dispatch_id)
{
    return omniprobe_kernel_dispatch ? omniprobe_kernel_dispatch(dispatch_id) : 0;
}
