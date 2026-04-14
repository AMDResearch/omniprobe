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

#include "message_handlers.h"
#include "kernelDB.h"
#include <string>

/// Base class for Omniprobe message handlers that need access to KernelDB.
///
/// After construction, call set_context() before processing begins to provide
/// the KernelDB instance and kernel name. Handlers use the stored kdb_p_ and
/// kernel_name_ in their handle(msg) and report() implementations.
class kdb_message_handler_base : public dh_comms::message_handler_base {
public:
  kdb_message_handler_base() = default;
  kdb_message_handler_base(const kdb_message_handler_base &) = default;
  virtual ~kdb_message_handler_base() = default;

  void set_context(kernelDB::kernelDB *kdb, const std::string &kernel_name) {
    kdb_p_ = kdb;
    kernel_name_ = kernel_name;
  }

protected:
  kernelDB::kernelDB *kdb_p_ = nullptr;
  std::string kernel_name_;
};
