#pragma once
#include "dh_comms.h"
#include "message_handlers.h"
#include "time_interval_handler.h"


class time_interval_handler_wrapper : public dh_comms::message_handler_base
{
public:
    time_interval_handler_wrapper(const std::string& strKernel, uint64_t dispatch_id, bool verbose = false);
    time_interval_handler_wrapper(const time_interval_handler_wrapper &) = default;
    virtual ~time_interval_handler_wrapper();
    virtual bool handle(const dh_comms::message_t &message) override;
    virtual bool handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb) override;
    virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
    virtual void report() override;
    virtual void clear() override;

private:
    uint64_t first_start_;
    uint64_t last_stop_;
    uint64_t total_time_;
    size_t no_intervals_;
    bool verbose_;
    std::string strKernel_;
    uint64_t dispatch_id_;
    dh_comms::time_interval_handler_t wrapped_;

};
