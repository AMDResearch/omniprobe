/******************************************************************************
Copyright (c) 2024 Advanced Micro Devices, Inc. All rights reserved.

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

#include <shared_mutex>
#include <memory>
#include <dlfcn.h>
#include <cxxabi.h>

#include <hsa.h>
#include <hsa_ven_amd_aqlprofile.h>
#include <hsa_ven_amd_loader.h>
#include "rocprofiler/rocprofiler.h"
#define AMD_INTERNAL_BUILD
#include <hsa_api_trace.h>
#include <set>
#include <tuple>
#include <atomic>

#include "timehelper.h"
#include "utils.h"
#include "dh_comms.h"
#include "memory_heatmap.h"
#include "kernelDB.h"


typedef struct pool_specs
{
    hsa_agent_t agent_;
    hsa_amd_memory_pool_t pool_;
    size_t min_alloc_size_;
}pool_specs_t;

class comms_mgr 
{
public: 
    comms_mgr(HsaApiTable *pTable);
    ~comms_mgr();
    dh_comms::dh_comms * checkoutCommsObject(hsa_agent_t agent, std::string& strKernelName, uint64_t dispatch_id, kernelDB::kernelDB *kdb);
    bool checkinCommsObject(hsa_agent_t agent, dh_comms::dh_comms *object);
    bool addAgent(hsa_agent_t agent);
    void setConfig(const std::map<std::string, std::string>& config);
private:
    KernArgAllocator kern_arg_allocator_;
    std::mutex mutex_;
    bool growBufferPool(hsa_agent_t agent, size_t count);
    std::map<hsa_agent_t, pool_specs_t, hsa_cmp<hsa_agent_t>> mem_pools_;
    std::map<hsa_agent_t, dh_comms::dh_comms_mem_mgr *, hsa_cmp<hsa_agent_t>> mem_mgrs_;
    std::map<hsa_agent_t, std::vector<dh_comms::dh_comms *>, hsa_cmp<hsa_agent_t>> comms_pool_;
    std::map<hsa_agent_t, std::vector<dh_comms::dh_comms *>, hsa_cmp<hsa_agent_t>> pending_comms_;
    HsaApiTable *pTable_;
    handlerManager handler_mgr_;
};


#define DH_SUB_BUFFER_COUNT 256
#define DH_THREAD_COUNT 1
#define DH_SUB_BUFFER_CAPACITY (256 * 1024) 


class default_message_handler : public dh_comms::message_handler_base
{
public:
    default_message_handler(std::string& strName, uint32_t dispatch_id);
    ~default_message_handler();
    bool virtual handle(const dh_comms::message_t& message);
private:
    std::string strKernelName_;
    uint64_t dispatch_id_;
};
