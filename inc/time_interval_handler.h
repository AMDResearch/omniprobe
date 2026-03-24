// MIT License
//
// Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#pragma once
#include "message_handlers.h"

namespace dh_comms {
struct time_interval {
  uint64_t start;
  uint64_t stop;
};

//! The time_interval_handler class processes time interval messages. It Keeps
//! track of the sum of the time covered by the messages as well as the total
//! elapsed time between the earliest start time in any message and the latest
//! stop time in any message.
class __attribute__((visibility("default"))) time_interval_handler_t : public message_handler_base {
public:
  time_interval_handler_t(const std::string& strKernel, uint64_t dispatch_id, const std::string& location, bool verbose = false);
  time_interval_handler_t(bool verbose);
  time_interval_handler_t(const time_interval_handler_t &) = default;
  void setupLogger();
  virtual ~time_interval_handler_t();
  virtual bool handle(const message_t &message) override;
  virtual bool handle(const message_t &message, const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
  virtual void report() override;
  virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
  virtual void clear() override;

private:
  std::string kernel_;
  uint64_t dispatch_id_;
  std::string location_;
  uint64_t first_start_;
  uint64_t last_stop_;
  uint64_t total_time_;
  size_t no_intervals_;
  bool verbose_;
  std::ostream *log_file_;
  std::string format_;
};
} // namespace dh_comms
