#pragma once

#include <map>
#include "message.h"
#include "message_handlers.h"
#include "memory_heatmap.h"

class memory_heatmap_wrapper : public dh_comms::message_handler_base
{
public:
    memory_heatmap_wrapper(const std::string& strKernel, uint64_t dispatch_id, size_t page_size = 1024 * 1024, bool verbose = false);
    memory_heatmap_wrapper(const memory_heatmap_wrapper&) = default;
    virtual ~memory_heatmap_wrapper();
    virtual bool handle(const dh_comms::message_t &message) override;
    virtual bool handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb) override;
    virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
    virtual void report() override;
    virtual void clear() override;

private:
    std::string strKernel_;
    uint64_t dispatch_id_;
    bool verbose_;
    size_t page_size_;
    std::map<uint64_t, size_t> page_counts_;
    dh_comms::memory_heatmap_t wrapped_;
};

