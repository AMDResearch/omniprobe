/******************************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

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
#include "inc/comms_mgr.h"
#include "inc/hsa_mem_mgr.h"
#include "inc/memory_heatmap_wrapper.h"
#include "inc/time_interval_handler_wrapper.h"

comms_mgr::comms_mgr(HsaApiTable *pTable) : kern_arg_allocator_(pTable, std::cerr), pTable_(pTable)
{
}
comms_mgr::~comms_mgr()
{
    std::cerr << "comms_mgr destructor START" << std::endl;
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto item : mem_mgrs_)
    {
        std::cerr << "comms_mgr deleting mem_mgr" << std::endl;
        delete item.second;
    }
    mem_mgrs_.clear();
    std::cerr << "comms_mgr destructor END" << std::endl;
}


void comms_mgr::setConfig(const std::map<std::string, std::string>& config)
{
    auto it = config.find("LOGDUR_HANDLERS");
    if (it != config.end() && it->second.size())
    {
        std::vector<string> libs;
        split(it->second, libs, ",", false);
        for (auto h : libs)
            std::cerr << "HANDLER: " << h << std::endl;
        handler_mgr_.setHandlers(libs) ;
    }
}

dh_comms::dh_comms * comms_mgr::checkoutCommsObject(hsa_agent_t agent, std::string& strKernelName, uint64_t dispatch_id, kernelDB::kernelDB *kdb)
{
    std::cerr << "comms_mgr::checkoutCommsObject START for kernel " << strKernelName << std::endl;
    std::lock_guard<std::mutex> lock(mutex_);
    dh_comms::dh_comms_mem_mgr *mem_mgr = NULL;
    auto it = mem_mgrs_.find(agent);
    if (it != mem_mgrs_.end())
    {
        mem_mgr = it->second;
        dh_comms::dh_comms *obj = new dh_comms::dh_comms(DH_SUB_BUFFER_COUNT, DH_SUB_BUFFER_CAPACITY, kdb, false, false, mem_mgr);
        std::cerr << "comms_mgr::checkoutCommsObject created dh_comms at " << static_cast<void*>(obj) << std::endl;
        std::vector<dh_comms::message_handler_base *> handlers;
        handler_mgr_.getMessageHandlers(strKernelName, dispatch_id, handlers);
        if (handlers.size())
        {
            for(auto it : handlers)
            {
                auto tmp = std::unique_ptr<dh_comms::message_handler_base>(it);
                obj->append_handler(std::move(tmp));
            }
        }
        else
        {
            obj->append_handler(std::make_unique<memory_heatmap_wrapper>(strKernelName, dispatch_id));
            obj->append_handler(std::make_unique<time_interval_handler_wrapper>(strKernelName, dispatch_id));
        }
        obj->start(strKernelName);
        std::cerr << "comms_mgr::checkoutCommsObject END - returning " << static_cast<void*>(obj) << std::endl;
        return obj;

    }
    std::cerr << "comms_mgr::checkoutCommsObject END - no mem_mgr found, returning NULL" << std::endl;
    return NULL;
}

bool comms_mgr::checkinCommsObject(hsa_agent_t agent, dh_comms::dh_comms *object)
{
    std::cerr << "comms_mgr::checkinCommsObject START for object at " << static_cast<void*>(object) << std::endl;
    std::lock_guard<std::mutex> lock(mutex_);
    try
    {
        std::cerr << "comms_mgr::checkinCommsObject calling object->stop()" << std::endl;
        object->stop();
        std::cerr << "comms_mgr::checkinCommsObject calling object->report()" << std::endl;
        object->report();
        std::cerr << "comms_mgr::checkinCommsObject calling object->delete_handlers()" << std::endl;
        object->delete_handlers();
        std::cerr << "comms_mgr::checkinCommsObject deleting object" << std::endl;
        delete object;
        std::cerr << "comms_mgr::checkinCommsObject delete completed" << std::endl;
    }
    catch (const exception& e)
    {
        printf("%s: %s\n ", "comms_mgr", e.what());
    }
    return true;
}


bool comms_mgr::addAgent(hsa_agent_t agent)
{
    std::lock_guard<std::mutex> lock(mutex_);
    //std::cerr << "comms_mgr::addAgent: " << std::hex << agent.handle << std::dec << std::endl;
    std::vector<pool_specs_t> pools;
    struct parms {
        std::vector<pool_specs_t> *pools;
        hsa_agent_t agent;
    };
    struct parms data = {&pools, agent};
    hsa_amd_agent_iterate_memory_pools(agent, [](hsa_amd_memory_pool_t pool, void *data){
        hsa_status_t status;
        struct parms *parms = reinterpret_cast<struct parms *>(data);
        size_t granularity = 0;
        hsa_amd_segment_t segment;
        uint32_t flags;
        bool runtime_allocatable;
        hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SEGMENT, &segment);
        if (HSA_AMD_SEGMENT_GLOBAL != segment)
            return HSA_STATUS_SUCCESS;
        status = hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_ALLOWED, &runtime_allocatable);
        if (status == HSA_STATUS_SUCCESS && runtime_allocatable)
        {
            status = hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_GRANULE,&granularity);
            if (status != HSA_STATUS_SUCCESS)
                throw std::bad_alloc();
            size_t size;
            status = hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SIZE, &size);
            if (status != HSA_STATUS_SUCCESS)
                throw std::bad_alloc();
            hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS, &flags);
            if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_COARSE_GRAINED)
            {
                parms->pools->push_back({parms->agent, pool, granularity});
            }
        }
        return HSA_STATUS_SUCCESS;
    }, &data);

    if (pools.size())
    {
        for (auto item : pools)
        {
            hsa_mem_mgr * mgr = new hsa_mem_mgr(item.agent_, item, kern_arg_allocator_);
            mem_mgrs_[item.agent_] = mgr;
        }
    }
    return false;
}


bool comms_mgr::growBufferPool(hsa_agent_t agent, size_t count)
{
    return false;
}


default_message_handler::default_message_handler(std::string& strName, uint32_t dispatch_id)
{
    strKernelName_ = strName;
    dispatch_id_ = dispatch_id;
}

default_message_handler::~default_message_handler()
{
    std::cerr << "Message Handler is cleaned up";
}

bool default_message_handler::handle(const dh_comms::message_t& message)
{
    std::cerr << "Message from " << strKernelName_ << " for dispatch id " << std::dec << dispatch_id_ << std::endl;
    return true;
}
