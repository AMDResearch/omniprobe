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
#include <functional>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

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
  /// Source file name for the std::hash of a path that the instrumentation
  /// plugins put in wave_header_t::dwarf_fname_hash, resolved against the file
  /// names kernelDB holds for this kernel. "<unknown>" for the plugins' own
  /// no-location marker, "<unresolved 0x...>" if no known file matches.
  std::string sourceFileForHash(uint64_t hash) {
    if (!file_names_built_) {
      file_names_built_ = true;
      file_names_[std::hash<std::string>{}("<unknown source file>")] = "<unknown>";
      if (kdb_p_) {
        try {
          // Through the line map, the lookup MemoryAnalysis's attribution uses:
          // the instruction copies held by basic blocks do not carry file ids
          // in every build (measured: non-RDC, two source files).
          std::set<size_t> path_ids;
          std::vector<uint32_t> lines;
          kdb_p_->getKernelLines(kernel_name_, lines);
          for (auto line : lines)
            for (auto &inst : kdb_p_->getInstructionsForLine(kernel_name_, line))
              path_ids.insert(inst.path_id_);
          for (auto id : path_ids) {
            if (id == 0 || id == (size_t)-1)
              continue;
            std::string name = kdb_p_->getFileName(kernel_name_, id);
            if (!name.empty())
              file_names_[std::hash<std::string>{}(name)] = name;
          }
        } catch (const std::exception &) {
          // No kernelDB entry for this kernel: every hash stays unresolved.
        }
      }
    }
    auto it = file_names_.find(hash);
    if (it != file_names_.end())
      return it->second;
    std::stringstream ss;
    ss << "<unresolved 0x" << std::hex << hash << ">";
    return ss.str();
  }

  kernelDB::kernelDB *kdb_p_ = nullptr;
  std::string kernel_name_;

private:
  bool file_names_built_ = false;
  std::map<uint64_t, std::string> file_names_;
};
