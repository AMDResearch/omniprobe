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

#include "inc/memory_heatmap.h"
#include "inc/json_helpers.h"

#include "data_headers.h"
#include "message.h"

#include <cassert>
#include <cstdio>
#include <vector>

namespace dh_comms {
  
memory_heatmap_t::memory_heatmap_t(const std::string& strKernel, uint64_t dispatch_id, const std::string& location, size_t page_size /*= 1024 * 1024*/, bool verbose /*= false*/) : verbose_(verbose), page_size_(page_size), kernel_(strKernel), dispatch_id_(dispatch_id), location_(location)
{
    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat)
        format_ = logDurLogFormat;
    else
        format_= "csv";
}
memory_heatmap_t::memory_heatmap_t(size_t page_size, bool verbose)
    : verbose_(verbose),
      page_size_(page_size) {}

memory_heatmap_t::~memory_heatmap_t()
{
    if(location_ != "console")
        delete log_file_;
}

bool memory_heatmap_t::handle(const message_t &message, const std::string& kernel_name, kernelDB::kernelDB& kdb) {
    // This if block is just to get the compiler to quick throwing errors for unused parameters
    if (kernel_name.length() == 0)
    {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
    }
    return handle(message);
}
bool memory_heatmap_t::handle(const message_t &message) {
  if (message.wave_header().user_type != message_type::address) {
    if (verbose_) {
      printf("memory_heatmap: skipping message with user type 0x%x\n", message.wave_header().user_type);
    }
    return false;
  }
  assert(message.data_item_size() == sizeof(uint64_t));
  for (size_t i = 0; i != message.no_data_items(); ++i) {
    uint64_t address = *(const uint64_t *)message.data_item(i);
    // map address to lowest address in page and update page count
    address /= page_size_;
    address *= page_size_;
    ++page_counts_[address];
    if (verbose_) {
      printf("memory_heatmap: added address 0x%lx to map\n", address);
    }
  }
  return true;
}

void memory_heatmap_t::report(const std::string& kernel_name, kernelDB::kernelDB& kdb)
{
    setupLogger();
    if (kernel_name.length() == 0)
    {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
    }
    report();
    if (location_ != "console")
    {
        delete log_file_;
        log_file_ = nullptr;
    }
}

void memory_heatmap_t::setupLogger()
{
    if (location_ == "console")
        log_file_ = &std::cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
}

void memory_heatmap_t::report() {
  if (format_ != "json")
  {
      if (page_counts_.size() != 0) {
        *log_file_ << "memory heatmap report(" << kernel_ << "[" << dispatch_id_ << "])\n\tpage size = " << page_size_ << "\n";
      }
      for (const auto &[first_page_address, count] : page_counts_) {
        auto last_page_address = first_page_address + page_size_ - 1;
        *log_file_ << "\tpage[0x" << std::hex << std::setfill('0') << first_page_address << ":" << last_page_address << "] " << std::dec << count << " accesses\n";
        //printf("\tpage [%016lx:%016lx] %12lu accesses\n", first_page_address, last_page_address, count);
      }
  }
  else if (page_counts_.size() != 0)
  {
    JSONHelper json;
    json.addField("kernel", kernel_, true, false);
    json.addField("dispatch_id", dispatch_id_);
    std::vector<std::string> pages;
    for (const auto &[first_page_address, count] : page_counts_) {
        JSONHelper thisRange;
        thisRange.addField("start_address", first_page_address);
        thisRange.addField("end_address", first_page_address + page_size_ - 1);
        thisRange.addField("accesses", count);
        pages.push_back(thisRange.getJSON());
    }
    json.addVector("pages", pages);
    *log_file_ << json.getJSON() << std::endl;
  }
}

void memory_heatmap_t::clear() { page_counts_.clear(); }

} // namespace dh_comms
