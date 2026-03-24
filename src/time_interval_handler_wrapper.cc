
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
#include "inc/time_interval_handler_wrapper.h"
#include <iostream>
#include <cassert>
#include "inc/time_interval_handler.h"

time_interval_handler_wrapper::time_interval_handler_wrapper(const std::string& strKernel, uint64_t dispatch_id, bool verbose)
    : first_start_(0xffffffffffffffff),
      last_stop_(0),
      total_time_(0),
      no_intervals_(0),
      verbose_(verbose),
      strKernel_(strKernel),
      dispatch_id_(dispatch_id),
      current_block_(nullptr),
      start_time_(0),
      wrapped_(verbose)
{
}

time_interval_handler_wrapper::~time_interval_handler_wrapper()
{
}

bool time_interval_handler_wrapper::handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb)
{
    auto hdr = message.wave_header();
    try
    {
        if (hdr.user_type == dh_comms::message_type::time_interval)
        {
            auto& instructions = kdb.getInstructionsForLine(kernel, hdr.dwarf_line);
            if (instructions.size())
            {
                if (current_block_)
                {
                    auto it = block_timings_.find(current_block_);
                    if (it != block_timings_.end())
                        it->second += hdr.timestamp - start_time_;
                    else
                        block_timings_[current_block_] = hdr.timestamp - start_time_;
                }
                current_block_ = instructions[0].block_;
                start_time_ = hdr.timestamp;
            }
        }
    }
    catch (std::runtime_error e)
    {
    }
    return handle(message);
}

bool time_interval_handler_wrapper::handle(const dh_comms::message_t &message)
{
    return wrapped_.handle(message);
}

void time_interval_handler_wrapper::report(const std::string& kernel_name, kernelDB::kernelDB& kdb)
{
    if (kernel_name.length() == 0)
    {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
    }
    report();
}

void time_interval_handler_wrapper::report()
{
    std::cerr << "omniprobe time_interval report for kernel " << strKernel_ << " dispatch[" << std::dec << dispatch_id_ << "]\n";
    wrapped_.report();
}

void time_interval_handler_wrapper::clear()
{
    wrapped_.clear();
    strKernel_ = "";
    dispatch_id_ = 0;
}
