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

#include "utils.h"
#include "dh_comms.h"
#include "inc/comms_mgr.h"

class hsa_mem_mgr : public dh_comms::dh_comms_mem_mgr
{
public:
    hsa_mem_mgr(hsa_agent_t agent,const pool_specs_t& pool, const KernArgAllocator& allocator);
    virtual ~hsa_mem_mgr();
    virtual void * calloc(std::size_t size) override;
    virtual void free(void *) override;
    virtual void free_device_memory(void *) override;
    virtual void * copy(void *dst, void *src, std::size_t size) override;
    virtual void * calloc_device_memory(std::size_t size) override;
    virtual void * copy_to_device(void *dst, const void *src, std::size_t size) override;
private:
    hsa_agent_t agent_;
    const pool_specs_t pool_;
    const KernArgAllocator& allocator_;

};
