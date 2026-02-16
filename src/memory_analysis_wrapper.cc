
/******************************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

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
#include "inc/memory_analysis_wrapper.h"

#include "hip_utils.h"
#include "utils.h"

#include <cassert>
#include <hip/hip_runtime.h>
#include <set>
#include <string>
#include <iostream>

__attribute__((constructor)) void on_library_load() { std::cerr << "Memory Analysis Wrapper loaded (constructor)." << std::endl; }
__attribute__((destructor)) void on_library_unload() { std::cerr << "Memory Analysis Wrapper unloaded (destructor)." << std::endl; }

memory_analysis_wrapper_t::memory_analysis_wrapper_t(const std::string& kernel, uint64_t dispatch_id, const std::string& location,  bool verbose) :
    kernel_(kernel), dispatch_id_(dispatch_id), location_(location), wrapped_(verbose)
{
}

bool memory_analysis_wrapper_t::handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb)
{
    return wrapped_.handle(message, kernel, kdb);
}


bool memory_analysis_wrapper_t::handle(const dh_comms::message_t &message) {
  return wrapped_.handle(message);
}

void memory_analysis_wrapper_t::report(const std::string& kernel_name, kernelDB::kernelDB& kdb)
{
    if (kernel_name.length() == 0)
    {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
    }
    wrapped_.report();
}

void memory_analysis_wrapper_t::report() {
  std::cout << "Memory analysis for " << kernel_ << " dispatch_id[" << std::dec << dispatch_id_ << "]" << std::endl;
  wrapped_.report();
}

void memory_analysis_wrapper_t::clear() {
  wrapped_.clear();
}
