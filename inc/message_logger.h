#pragma once

#include <map>
#include <iostream>
#include <fstream>
#include "message_handlers.h"

class message_logger_t : public dh_comms::message_handler_base
{
public:
    message_logger_t(const std::string& strKernel, uint64_t dispatch_id, std::string& location, bool verbose = false);
    message_logger_t(const message_logger_t&) = default;
    virtual ~message_logger_t();
    virtual bool handle(const dh_comms::message_t &message) override;
    virtual bool handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb) override;
    virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
    virtual void report() override;
    virtual void clear() override;

private:
    std::string strKernel_;
    uint64_t dispatch_id_;
    std::string location_;
    bool verbose_;
    std::ostream *log_file_;
    // out iostream here
};

