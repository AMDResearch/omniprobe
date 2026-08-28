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
#include "inc/numa_mem_mgr.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <numa.h>
#include <numaif.h>
#include <hip/hip_runtime.h>

numa_mem_mgr::numa_mem_mgr(int numa_node,
                           hsa_agent_t agent,
                           const pool_specs_t& pool,
                           const KernArgAllocator& allocator)
    : hsa_mem_mgr(agent, pool, allocator),
      numa_node_(numa_node),
      verbose_(std::getenv("OMNIPROBE_NUMA_VERBOSE") != nullptr)
{
    if (numa_available() < 0) {
        std::cerr << "numa_mem_mgr: libnuma not available on this system"
                  << std::endl;
        throw std::runtime_error("libnuma not available");
    }

    if (numa_node_ < 0 || numa_node_ > numa_max_node()) {
        std::cerr << "numa_mem_mgr: invalid NUMA node " << numa_node_
                  << " (max=" << numa_max_node() << ")" << std::endl;
        throw std::runtime_error("invalid NUMA node");
    }

    long long node_size = numa_node_size64(numa_node_, nullptr);
    std::cerr << "numa_mem_mgr: targeting NUMA node " << numa_node_
              << " (" << (node_size >> 20) << " MB)" << std::endl;
}

numa_mem_mgr::~numa_mem_mgr()
{
    for (auto& [ptr, size] : alloc_sizes_) {
        hipHostUnregister(ptr);
        numa_free(ptr, size);
    }
    alloc_sizes_.clear();
}

void* numa_mem_mgr::calloc(std::size_t size)
{
    void* ptr = numa_alloc_onnode(size, numa_node_);
    if (!ptr) {
        std::cerr << "numa_mem_mgr: numa_alloc_onnode(" << size << ", "
                  << numa_node_ << ") failed" << std::endl;
        throw std::bad_alloc();
    }

    memset(ptr, 0, size);

    unsigned long nodemask = 1UL << numa_node_;
    long ret = mbind(ptr, size, MPOL_BIND, &nodemask,
                     sizeof(nodemask) * 8 + 1,
                     MPOL_MF_STRICT | MPOL_MF_MOVE);
    if (ret != 0) {
        std::cerr << "numa_mem_mgr: mbind failed (errno=" << errno << ")"
                  << std::endl;
        numa_free(ptr, size);
        throw std::runtime_error("mbind failed");
    }

    // Self-verification: query the actual node the first page landed on.
    // The preceding memset faulted in the buffer and mbind with
    // MPOL_MF_STRICT | MPOL_MF_MOVE forced placement, so move_pages should
    // return a valid node id rather than -ENOENT.  Gated behind
    // OMNIPROBE_NUMA_VERBOSE because allocations can be frequent and we
    // do not want unconditional per-buffer log noise on production paths.
    if (verbose_) {
        void* pages[1] = {ptr};
        int actual_node = -1;
        if (move_pages(0, 1, pages, nullptr, &actual_node, 0) == 0) {
            std::cerr << "numa_mem_mgr: allocated " << ptr
                      << " size=" << size << " on node " << actual_node
                      << " (requested " << numa_node_ << ")" << std::endl;
        }
    }

    hipError_t err = hipHostRegister(ptr, size, hipHostRegisterMapped);
    if (err != hipSuccess) {
        std::cerr << "numa_mem_mgr: hipHostRegister failed ("
                  << hipGetErrorString(err) << ")" << std::endl;
        numa_free(ptr, size);
        throw std::runtime_error("hipHostRegister failed");
    }

    void* gpu_ptr = nullptr;
    err = hipHostGetDevicePointer(&gpu_ptr, ptr, 0);
    if (err != hipSuccess || gpu_ptr != ptr) {
        std::cerr << "numa_mem_mgr: GPU pointer mismatch "
                  << "(host=" << ptr << " gpu=" << gpu_ptr << ")"
                  << std::endl;
        hipHostUnregister(ptr);
        numa_free(ptr, size);
        throw std::runtime_error("GPU pointer != host pointer");
    }

    alloc_sizes_[ptr] = size;
    return ptr;
}

void numa_mem_mgr::free(void* ptr)
{
    auto it = alloc_sizes_.find(ptr);
    if (it == alloc_sizes_.end()) {
        hsa_mem_mgr::free_device_memory(ptr);
        return;
    }
    // NUMA allocations are deferred to the destructor. hipHostUnregister()
    // requires GPU idle, but free() can be called from the signal callback
    // before ensure_shutdown() drains pending HSA completion signals.
}

void numa_mem_mgr::free_device_memory(void* ptr)
{
    auto it = alloc_sizes_.find(ptr);
    if (it != alloc_sizes_.end()) {
        // A NUMA-owned host buffer can reach free_device_memory() as well as
        // free() depending on how dh_comms classifies the allocation it is
        // releasing.  Treat both paths identically: defer cleanup to the
        // destructor for the reason documented in free() above (HIP host
        // unregister requires GPU idle, which is not guaranteed when this
        // is invoked from a completion-signal callback).
        return;
    }

    hsa_mem_mgr::free_device_memory(ptr);
}
