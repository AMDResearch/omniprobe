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

#include <map>
namespace dh_comms {

//! The memory_heatmap_t class keeps track of how many accesses to each memory
//! page are done. Page size is configurable.
class __attribute__((visibility("default"))) memory_heatmap_t : public message_handler_base {
public:
  memory_heatmap_t(const std::string& strKernel, uint64_t dispatch_id, const std::string& location, size_t page_size = 1024 * 1024, bool verbose = false);
  memory_heatmap_t(size_t page_size = 1024 * 1024, bool verbose = false);
  memory_heatmap_t(const memory_heatmap_t &) = default;
  void setupLogger();
  virtual ~memory_heatmap_t();
  virtual bool handle(const message_t &message) override;
  virtual bool handle(const message_t &message, const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
  virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
  virtual void report() override;
  virtual void clear() override;

private:
  bool verbose_;
  size_t page_size_;
  std::string kernel_;
  uint64_t dispatch_id_;
  std::string location_;
  std::ostream *log_file_;
  //! Maps the lowest address on each page to the number of accesses to the page.
  std::map<uint64_t, size_t> page_counts_;
  std::string format_;
};

} // namespace dh_comms
