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
#include "message_handlers.h"
#include "memory_analysis_handler.h"
#include "json_output.h"

#include <map>
#include <set>
#include <vector>

class memory_analysis_wrapper_t : public dh_comms::message_handler_base {
public:
  memory_analysis_wrapper_t(const std::string& strKernel, uint64_t dispatch_id, const std::string& strLocation, bool verbose);
  virtual ~memory_analysis_wrapper_t() = default;
  virtual bool handle(const dh_comms::message_t &message) override;
  virtual bool handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb) override;
  virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
  virtual void report() override;
  virtual void clear() override;

private:
  const std::string& kernel_;
  uint64_t dispatch_id_;
  const std::string& location_;
  bool verbose_;
  dh_comms::memory_analysis_handler_t wrapped_;
};
