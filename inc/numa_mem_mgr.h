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

#include <unordered_map>
#include "inc/hsa_mem_mgr.h"

/**
 * Memory manager that places dh_comms shared buffers on a specific NUMA
 * node (e.g., CXL-attached memory).  Inherits from hsa_mem_mgr so that
 * GPU device-memory operations (calloc_device_memory, copy_to_device,
 * free_device_memory) are unchanged.
 *
 * Only calloc() and free() are overridden: host-visible shared buffers
 * are allocated via libnuma and registered with HIP for GPU access.
 *
 * Activate by setting env var OMNIPROBE_NUMA_NODE=<node_id>.
 * Set OMNIPROBE_NUMA_VERBOSE=1 to log per-allocation placement
 * (actual vs. requested NUMA node) for diagnostics.
 */
class numa_mem_mgr : public hsa_mem_mgr
{
public:
    numa_mem_mgr(int numa_node,
                 hsa_agent_t agent,
                 const pool_specs_t& pool,
                 const KernArgAllocator& allocator);
    virtual ~numa_mem_mgr();

    virtual void* calloc(std::size_t size) override;
    virtual void  free(void* ptr) override;
    virtual void  free_device_memory(void* ptr) override;

private:
    int  numa_node_;
    bool verbose_;
    std::unordered_map<void*, std::size_t> alloc_sizes_;
};
