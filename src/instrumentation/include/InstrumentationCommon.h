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
#ifndef INSTRUMENTATION_COMMON_H
#define INSTRUMENTATION_COMMON_H

#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Transforms/Utils/ValueMapper.h"
#include <cstdint>
#include <optional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace llvm {
class DILocation;
}

namespace instrumentation {
namespace common {

// Get the path to the bitcode file containing device functions for
// instrumentation based on the module's architecture and code object version
std::string getBitcodePath(const llvm::Module &M);

// Extract full file path from debug location information
std::string getFullPath(const llvm::DILocation *DIL);

// Validate that the module targets AMDGPU (amdgcn-amd-amdhsa)
// Returns true if valid AMDGPU target, false otherwise
bool validateAMDGPUTarget(const llvm::Module &M);

// Load bitcode file and link it into the module
// Automatically determines the bitcode path based on the module's architecture
// Returns the loaded device module on success, nullptr on failure
std::unique_ptr<llvm::Module> loadAndLinkBitcode(llvm::Module &M);

struct ProbeSurrogateSpec {
  std::string probe_id;
  std::string surrogate;
  std::string helper;
  std::string contract;
  std::string when;
  std::vector<std::string> target_kernels;
  std::vector<std::string> kernel_args;
};

struct KernelLifecycleSurrogatePair {
  std::optional<ProbeSurrogateSpec> entry;
  std::optional<ProbeSurrogateSpec> exit;
};

// Load generated probe-surrogate manifest from OMNIPROBE_PROBE_MANIFEST.
std::vector<ProbeSurrogateSpec> loadProbeSurrogateManifest();

// Find a matching memory-op surrogate for the given kernel name.
std::optional<ProbeSurrogateSpec>
findMemoryOpSurrogateForKernel(const std::vector<ProbeSurrogateSpec> &Specs,
                               llvm::StringRef KernelName);

// Find matching kernel-entry and kernel-exit surrogates for the given kernel
// name. Either field may be empty if the manifest only supplies one side.
KernelLifecycleSurrogatePair
findKernelLifecycleSurrogatesForKernel(
    const std::vector<ProbeSurrogateSpec> &Specs, llvm::StringRef KernelName);

// Collect all GPU kernel functions from the module
std::vector<llvm::Function *> collectGPUKernels(llvm::Module &M);

// Clone a kernel function with an additional pointer argument for
// instrumentation buffer. Creates a new function with name
// "__amd_crk_<original_name>Pv"
llvm::Function *cloneKernelWithExtraArg(llvm::Function *OrigKernel,
                                        llvm::Module &M,
                                        llvm::ValueToValueMapTy &VMap);

// Return the trailing instrumentation buffer argument that was appended by
// cloneKernelWithExtraArg().
llvm::Argument *getInstrumentationBufferArg(llvm::Function *Kernel);

// Returns true when Kernel is one of Omniprobe's cloned kernels with a trailing
// instrumentation buffer argument.
bool isInstrumentationCloneKernel(const llvm::Function &Kernel);

// Returns the number of visible user kernel arguments, excluding Omniprobe's
// appended instrumentation buffer argument when Kernel is a cloned kernel.
size_t getVisibleKernelArgumentCount(const llvm::Function &Kernel);

// Resolve a source-level kernel argument name to its visible argument ordinal.
// Uses debug metadata when available, then falls back to preserved IR names.
std::optional<unsigned>
resolveKernelArgumentOrdinal(const llvm::Function &Kernel,
                             llvm::StringRef RequestedName);

// Represents a single scope entry: a file pattern with optional line ranges.
struct ScopeEntry {
  std::string file_pattern;
  bool is_full_path; // true if file_pattern starts with '/'
  std::vector<std::pair<uint32_t, uint32_t>> ranges; // half-open [start, end)
};

// Source-level scope filter for instrumentation.
//
// Reads INSTRUMENTATION_SCOPE and INSTRUMENTATION_SCOPE_FILE environment
// variables to determine which source locations should be instrumented.
// When no scope is set, all instructions are instrumented (default behavior).
class InstrumentationScope {
public:
  // Reads env vars and parses scope definitions.
  // On parse error, prints diagnostic to stderr and disables filtering.
  InstrumentationScope();

  // Returns true if scope filtering is active.
  bool isActive() const { return active_; }

  // Returns true if the given source location matches the scope.
  // When scope is not active, always returns true.
  bool matches(const std::string &file, uint32_t line) const;

  // Returns the number of scope entries (for diagnostic messages).
  size_t size() const { return entries_.size(); }

private:
  bool parseDefinitions(const std::string &input);
  bool parseFile(const std::string &path);

  std::vector<ScopeEntry> entries_;
  bool active_ = false;
};

} // namespace common
} // namespace instrumentation

#endif // INSTRUMENTATION_COMMON_H
