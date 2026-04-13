
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
#include "dh_comms.h"
#include "message_handlers.h"
#include "time_interval_handler.h"
#include "kernelDB.h"


class time_interval_handler_wrapper : public dh_comms::kdb_message_handler_base
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
    kernelDB::basicBlock *current_block_;
    uint64_t start_time_;
    dh_comms::time_interval_handler_t wrapped_;
    std::map<kernelDB::basicBlock *, uint64_t> block_timings_;

};
