
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

#include <map>
#include <iostream>
#include <fstream>
#include "message_handlers.h"
#include "json_helpers.h"

class message_logger_t : public dh_comms::message_handler_base
{
public:
    message_logger_t(const std::string& strKernel, uint64_t dispatch_id, std::string& location, bool verbose = false);
    message_logger_t(const message_logger_t&) = default;
    virtual ~message_logger_t();
    virtual bool handle(const dh_comms::message_t &message) override;
    virtual void report() override;
    virtual void clear() override;
    bool handle_address_message(const dh_comms::message_t& message, JSONHelper& json);
    bool handle_timeinterval_message(const dh_comms::message_t& message, JSONHelper& json);
    void handle_header(const dh_comms::message_t& message, JSONHelper& json);

private:
    std::string strKernel_;
    uint64_t dispatch_id_;
    std::string location_;
    bool verbose_;
    bool format_csv_;
    std::ostream *log_file_;
    // out iostream here
};

