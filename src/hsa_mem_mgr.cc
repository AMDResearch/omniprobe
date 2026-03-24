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
#include "inc/hsa_mem_mgr.h"


hsa_mem_mgr::hsa_mem_mgr(hsa_agent_t agent, const pool_specs_t& pool, const KernArgAllocator& allocator) : dh_comms::dh_comms_mem_mgr(), agent_(agent), pool_(pool), allocator_(allocator)
{
    char name[1024];
    memset(name, 0, sizeof(name));
    uint32_t length = sizeof(name);
    hsa_agent_get_info(pool.agent_, HSA_AGENT_INFO_NAME, name);
    //std::cerr << "AGENT NAME in hsa_mem_mgr: " << name << std::endl;
    //std::cerr << "agent: " << std::hex << pool.agent_.handle << " pool: " << pool.pool_.handle << " min_alloc_size: " << std::dec << pool.min_alloc_size_ << std::endl;
}

hsa_mem_mgr::~hsa_mem_mgr()
{
}

void * hsa_mem_mgr::calloc(std::size_t size)
{
    void *result = allocator_.allocate(size, pool_.agent_);
    zero(result,size);
    return result;
}

void hsa_mem_mgr::free(void *ptr)
{
    allocator_.free(ptr);
}

void hsa_mem_mgr::free_device_memory(void *ptr)
{
    hsa_amd_memory_pool_free(ptr);
}


void * hsa_mem_mgr::copy(void *dst, void *src, std::size_t size)
{
    memcpy(dst, src, size);
    return dst;
}

void * hsa_mem_mgr::copy_to_device(void *dst, const void *src, std::size_t size)
{
    hsa_status_t status = hsa_memory_copy(dst, src, size);
    if (status == HSA_STATUS_SUCCESS)
        return dst;
    else
        throw std::exception();
}

void * hsa_mem_mgr::calloc_device_memory(std::size_t size)
{
    void *buffer = NULL;
    size_t mask = pool_.min_alloc_size_ - 1;
    //std::cerr << "hsa_mem_mgr pool min size == " << pool_.min_alloc_size_ << " mask == " << std::hex << mask << std::endl;
    size_t adjusted_size = (size + mask) & ~mask; // round up allocation to be even numbers of allocation granularity
    //std::cerr << "thus adjusted size == " << adjusted_size << std::endl;
    hsa_status_t status = hsa_amd_memory_pool_allocate(pool_.pool_, adjusted_size, 0, &buffer);
    if (status != HSA_STATUS_SUCCESS)
        throw std::bad_alloc();
    zero_device_memory(buffer, adjusted_size);
    return buffer;
}
