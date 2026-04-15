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
#include "InstrumentationCommon.h"

#include "llvm/ADT/StringRef.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Demangle/Demangle.h"
#include "llvm/IR/CallingConv.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/Linker/Linker.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include <cstdlib>
#include <dlfcn.h>
#include <fstream>
#include <optional>
#include <sstream>
#include <type_traits>

using namespace llvm;

namespace instrumentation {
namespace common {

static constexpr llvm::StringLiteral CloneKernelPrefix("__amd_crk_");
static constexpr llvm::StringLiteral CloneKernelSuffix("Pv");

static std::unique_ptr<llvm::Module> loadBitcodeModuleFromPath(
    const std::string &BitcodePath, llvm::LLVMContext &Ctx) {
  if (!llvm::sys::fs::exists(BitcodePath)) {
    llvm::errs() << "Error: Bitcode file not found at " << BitcodePath << "\n";
    return nullptr;
  }

  auto Buffer = MemoryBuffer::getFile(BitcodePath);
  if (!Buffer) {
    llvm::errs() << "Error loading bitcode file: " << BitcodePath << "\n";
    return nullptr;
  }

  auto DeviceModuleOrErr =
      parseBitcodeFile(Buffer->get()->getMemBufferRef(), Ctx);
  if (!DeviceModuleOrErr) {
    llvm::errs() << "Error parsing bitcode file: " << BitcodePath << "\n";
    return nullptr;
  }

  return std::move(DeviceModuleOrErr.get());
}

static bool linkBitcodeModuleInto(llvm::Module &Dest, const llvm::Module &Src,
                                  llvm::StringRef Label) {
  llvm::errs() << "Linking device module from " << Label << " into GPU module\n";
  if (llvm::Linker::linkModules(Dest, CloneModule(Src))) {
    llvm::errs() << "Error linking device function module into instrumented "
                    "module!\n";
    return false;
  }
  return true;
}

static void linkExtraProbeBitcodeIfRequested(llvm::Module &M) {
  const char *EnvValue = std::getenv("OMNIPROBE_PROBE_BITCODE");
  if (!EnvValue || !*EnvValue)
    return;

  llvm::StringRef RawList(EnvValue);
  llvm::SmallVector<llvm::StringRef, 4> Entries;
  RawList.split(Entries, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/false);

  for (llvm::StringRef Entry : Entries) {
    std::string BitcodePath = Entry.trim().str();
    if (BitcodePath.empty())
      continue;
    auto ExtraModule = loadBitcodeModuleFromPath(BitcodePath, M.getContext());
    if (!ExtraModule)
      continue;
    linkBitcodeModuleInto(M, *ExtraModule, BitcodePath);
  }
}

static std::string normalizeArchName(std::string arch) {
  const size_t feature_pos = arch.find(':');
  if (feature_pos != std::string::npos)
    arch.erase(feature_pos);
  return arch;
}

std::string getBitcodePath(const llvm::Module &M) {
  Dl_info dl_info;
  if (dladdr(reinterpret_cast<void *>(&getBitcodePath), &dl_info) == 0) {
    llvm::errs() << "Error: Could not determine IR pass plugin path!\n";
    return "";
  }

  std::string PluginPath = dl_info.dli_fname;
  size_t LastSlash = PluginPath.find_last_of('/');
  if (LastSlash == std::string::npos) {
    llvm::errs() << "Error: IR pass plugin path invalid!\n";
    return "";
  }

  llvm::errs() << "IR pass plugin path: " << PluginPath << "\n";

  std::string PluginDir = PluginPath.substr(0, LastSlash); // Extract directory
  if (PluginDir.empty()) {
    llvm::errs() << "Error: Could not determine plugin directory!\n";
    return "";
  }

  // Bitcode lives in a sibling "bitcode" directory relative to the plugin.
  // In the build tree:   build/lib/plugins/*.so  → build/lib/bitcode/*.bc
  // In the install tree: <prefix>/lib/plugins/*.so → <prefix>/lib/bitcode/*.bc
  // Fallback: same directory as the plugin (legacy layout).
  std::string BitcodeDir;
  std::string SiblingBitcode = PluginDir + "/../bitcode";
  if (llvm::sys::fs::is_directory(SiblingBitcode)) {
    // Canonicalize by just using the resolved path
    BitcodeDir = PluginDir + "/../bitcode";
  } else {
    BitcodeDir = PluginDir;
  }

  std::string CodeObjectVersion =
      (PluginPath.find("triton") != std::string::npos) ? "_co5" : "_co6";

  // Determine CDNAVersion based on architecture
  std::string CDNAVersion;
  // Try to get the target-cpu from the module flag
  std::string arch;
  if (auto *cpuMD =
          llvm::cast_or_null<llvm::MDString>(M.getModuleFlag("target-cpu"))) {
    arch = cpuMD->getString().str();
  } else {
    // Fallback: try to get from a kernel function attribute
    for (const auto &F : M) {
      if (F.hasFnAttribute("target-cpu")) {
        arch = F.getFnAttribute("target-cpu").getValueAsString().str();
        break;
      }
    }
  }

  if (arch != "") {
    llvm::errs() << "Detected architecture: " << arch << "\n";
  } else {
    llvm::errs() << "Warning: Could not determine target architecture, "
                    "defaulting to cdna2.\n";
    arch = "unknown";
  }

  std::string normalized_arch = normalizeArchName(arch);
  std::string ExactBitcodePath =
      BitcodeDir + "/dh_comms_dev_" + normalized_arch + CodeObjectVersion +
      ".bc";
  if (normalized_arch != "unknown" &&
      llvm::sys::fs::exists(ExactBitcodePath)) {
    llvm::errs() << "Using exact-arch device module " << ExactBitcodePath
                 << "\n";
    return ExactBitcodePath;
  }

  if (normalized_arch == "gfx940" || normalized_arch == "gfx941" ||
      normalized_arch == "gfx942") {
    CDNAVersion = "_cdna3";
  } else {
    CDNAVersion = "_cdna2";
  }

  std::string BitcodePath =
      BitcodeDir + "/dh_comms_dev" + CDNAVersion + CodeObjectVersion + ".bc";

  return BitcodePath;
}

std::string getFullPath(const llvm::DILocation *DIL) {
  if (!DIL)
    return "";

  const llvm::DIFile *File = DIL->getScope()->getFile();
  if (!File)
    return "";

  std::string Directory = File->getDirectory().str();
  std::string FileName = File->getFilename().str();

  if (!Directory.empty())
    return Directory + "/" + FileName; // Concatenate full path
  else
    return FileName; // No directory available, return just the file name
}

bool validateAMDGPUTarget(const llvm::Module &M) {
  auto TargetTriple = M.getTargetTriple();

  // Use std::string comparison if needed, otherwise call str()
  std::string TripleStr = [](const auto &T) -> std::string {
    if constexpr (std::is_same_v<std::decay_t<decltype(T)>, std::string>) {
      return T; // Already a std::string
    } else {
      return T.str(); // Convert llvm::Triple to std::string
    }
  }(TargetTriple);

  if (TripleStr == "amdgcn-amd-amdhsa") {
    llvm::errs() << "device function module found for " << TripleStr << "\n";
    return true;
  } else { // Not an AMDGPU target
    llvm::errs() << TripleStr << ": Not an AMDGPU target, skipping pass.\n";
    return false;
  }
}

std::unique_ptr<llvm::Module> loadAndLinkBitcode(llvm::Module &M) {
  std::string BitcodePath = getBitcodePath(M);
  std::unique_ptr<llvm::Module> DeviceModule =
      loadBitcodeModuleFromPath(BitcodePath, M.getContext());
  if (!DeviceModule)
    return nullptr;

  if (!linkBitcodeModuleInto(M, *DeviceModule, BitcodePath))
    return nullptr;

  linkExtraProbeBitcodeIfRequested(M);

  return DeviceModule;
}

static std::vector<std::string> collectStringArray(const llvm::json::Value *Value,
                                                   llvm::StringRef Context) {
  std::vector<std::string> Result;
  if (!Value)
    return Result;
  auto *Array = Value->getAsArray();
  if (!Array) {
    llvm::errs() << "Ignoring malformed JSON array for " << Context << "\n";
    return Result;
  }
  for (const auto &Entry : *Array) {
    if (auto Str = Entry.getAsString())
      Result.push_back(Str->str());
  }
  return Result;
}

std::vector<ProbeSurrogateSpec> loadProbeSurrogateManifest() {
  std::vector<ProbeSurrogateSpec> Specs;
  const char *ManifestEnv = std::getenv("OMNIPROBE_PROBE_MANIFEST");
  if (!ManifestEnv || !*ManifestEnv)
    return Specs;

  auto Buffer = llvm::MemoryBuffer::getFile(ManifestEnv);
  if (!Buffer) {
    llvm::errs() << "Failed to read probe manifest: " << ManifestEnv << "\n";
    return Specs;
  }

  auto Parsed = llvm::json::parse(Buffer.get()->getBuffer());
  if (!Parsed) {
    llvm::errs() << "Failed to parse probe manifest JSON: " << ManifestEnv
                 << "\n";
    return Specs;
  }

  auto *Root = Parsed->getAsObject();
  if (!Root) {
    llvm::errs() << "Probe manifest root is not an object: " << ManifestEnv
                 << "\n";
    return Specs;
  }

  auto *Surrogates = Root->getArray("surrogates");
  if (!Surrogates)
    return Specs;

  for (const auto &Entry : *Surrogates) {
    auto *Obj = Entry.getAsObject();
    if (!Obj)
      continue;

    auto ProbeId = Obj->getString("probe_id");
    auto Surrogate = Obj->getString("surrogate");
    auto Helper = Obj->getString("helper");
    auto Contract = Obj->getString("contract");
    auto When = Obj->getString("when");
    if (!ProbeId || !Surrogate || !Helper || !Contract || !When)
      continue;

    ProbeSurrogateSpec Spec;
    Spec.probe_id = ProbeId->str();
    Spec.surrogate = Surrogate->str();
    Spec.helper = Helper->str();
    Spec.contract = Contract->str();
    Spec.when = When->str();

    if (auto *Target = Obj->getObject("target"))
      Spec.target_kernels = collectStringArray(Target->get("kernels"),
                                               "surrogates[].target.kernels");
    if (auto *Capture = Obj->getObject("capture")) {
      if (auto *KernelArgs = Capture->getArray("kernel_args")) {
        for (const auto &KernelArgEntry : *KernelArgs) {
          if (auto *KernelArgObj = KernelArgEntry.getAsObject()) {
            if (auto Name = KernelArgObj->getString("name"))
              Spec.kernel_args.push_back(Name->str());
          }
        }
      }
    }

    Specs.push_back(std::move(Spec));
  }

  if (!Specs.empty()) {
    llvm::errs() << "Loaded " << Specs.size()
                 << " generated probe surrogate entries from "
                 << ManifestEnv << "\n";
  }
  return Specs;
}

std::optional<ProbeSurrogateSpec>
findMemoryOpSurrogateForKernel(const std::vector<ProbeSurrogateSpec> &Specs,
                               llvm::StringRef KernelName) {
  std::vector<std::string> CandidateNames{KernelName.str()};
  char *Demangled = llvm::itaniumDemangle(KernelName.str());
  if (Demangled) {
    std::string DemangledName(Demangled);
    CandidateNames.push_back(DemangledName);
    size_t ParamPos = DemangledName.find('(');
    if (ParamPos != std::string::npos)
      CandidateNames.push_back(DemangledName.substr(0, ParamPos));
  }
  std::free(Demangled);

  auto matchesTargetKernel = [&](const ProbeSurrogateSpec &Spec) {
    if (Spec.target_kernels.empty())
      return false;
    for (const auto &Candidate : CandidateNames) {
      auto It = std::find(Spec.target_kernels.begin(), Spec.target_kernels.end(),
                          Candidate);
      if (It != Spec.target_kernels.end())
        return true;
    }
    return false;
  };

  for (const auto &Spec : Specs) {
    if (Spec.contract != "memory_op_v1" || Spec.when != "memory_op")
      continue;
    if (matchesTargetKernel(Spec))
      return Spec;
  }
  return std::nullopt;
}

KernelLifecycleSurrogatePair
findKernelLifecycleSurrogatesForKernel(
    const std::vector<ProbeSurrogateSpec> &Specs, llvm::StringRef KernelName) {
  KernelLifecycleSurrogatePair Result;

  std::vector<std::string> CandidateNames{KernelName.str()};
  char *Demangled = llvm::itaniumDemangle(KernelName.str());
  if (Demangled) {
    std::string DemangledName(Demangled);
    CandidateNames.push_back(DemangledName);
    size_t ParamPos = DemangledName.find('(');
    if (ParamPos != std::string::npos)
      CandidateNames.push_back(DemangledName.substr(0, ParamPos));
  }
  std::free(Demangled);

  auto matchesTargetKernel = [&](const ProbeSurrogateSpec &Spec) {
    if (Spec.target_kernels.empty())
      return false;
    for (const auto &Candidate : CandidateNames) {
      auto It = std::find(Spec.target_kernels.begin(), Spec.target_kernels.end(),
                          Candidate);
      if (It != Spec.target_kernels.end())
        return true;
    }
    return false;
  };

  for (const auto &Spec : Specs) {
    if (Spec.contract != "kernel_lifecycle_v1")
      continue;
    if (!matchesTargetKernel(Spec))
      continue;
    if (Spec.when == "kernel_entry" && !Result.entry) {
      Result.entry = Spec;
    } else if (Spec.when == "kernel_exit" && !Result.exit) {
      Result.exit = Spec;
    }
  }

  return Result;
}

std::vector<llvm::Function *> collectGPUKernels(llvm::Module &M) {
  std::vector<llvm::Function *> GpuKernels;

  for (auto &F : M) {
    if (F.isIntrinsic())
      continue;
    if (F.getCallingConv() == CallingConv::AMDGPU_KERNEL) {
      GpuKernels.push_back(&F);
    }
  }

  return GpuKernels;
}

bool isInstrumentationCloneKernel(const llvm::Function &Kernel) {
  return Kernel.getName().starts_with(CloneKernelPrefix) &&
         Kernel.getName().ends_with(CloneKernelSuffix);
}

static const llvm::Function *
findOriginalKernelForClone(const llvm::Function &Kernel) {
  if (!isInstrumentationCloneKernel(Kernel))
    return nullptr;

  llvm::StringRef Name = Kernel.getName();
  llvm::StringRef OriginalName =
      Name.drop_front(CloneKernelPrefix.size()).drop_back(CloneKernelSuffix.size());
  return Kernel.getParent()->getFunction(OriginalName);
}

size_t getVisibleKernelArgumentCount(const llvm::Function &Kernel) {
  if (const llvm::Function *OriginalKernel = findOriginalKernelForClone(Kernel))
    return OriginalKernel->arg_size();
  return Kernel.arg_size();
}

static std::optional<unsigned>
resolveKernelArgumentOrdinalFromSubprogram(const llvm::DISubprogram *Subprogram,
                                           llvm::StringRef RequestedName) {
  if (!Subprogram)
    return std::nullopt;

  for (llvm::Metadata *Node : Subprogram->getRetainedNodes()) {
    auto *Local = llvm::dyn_cast_or_null<llvm::DILocalVariable>(Node);
    if (!Local || !Local->isParameter() || Local->getName() != RequestedName)
      continue;
    unsigned ArgNo = Local->getArg();
    if (ArgNo == 0)
      return std::nullopt;
    return ArgNo - 1;
  }
  return std::nullopt;
}

std::optional<unsigned>
resolveKernelArgumentOrdinal(const llvm::Function &Kernel,
                             llvm::StringRef RequestedName) {
  if (RequestedName.empty())
    return std::nullopt;

  llvm::SmallVector<const llvm::Function *, 2> Candidates;
  Candidates.push_back(&Kernel);
  if (const llvm::Function *OriginalKernel = findOriginalKernelForClone(Kernel)) {
    if (OriginalKernel != &Kernel)
      Candidates.push_back(OriginalKernel);
  }

  for (const llvm::Function *Candidate : Candidates) {
    if (auto Ordinal = resolveKernelArgumentOrdinalFromSubprogram(
            Candidate->getSubprogram(), RequestedName)) {
      return Ordinal;
    }
  }

  for (const llvm::Function *Candidate : Candidates) {
    for (const llvm::Argument &Arg : Candidate->args()) {
      if (Arg.getName() == RequestedName)
        return Arg.getArgNo();
    }
  }

  return std::nullopt;
}

llvm::Function *cloneKernelWithExtraArg(llvm::Function *OrigKernel,
                                        llvm::Module &M,
                                        llvm::ValueToValueMapTy &VMap) {
  std::string AugmentedName = "__amd_crk_" + OrigKernel->getName().str() + "Pv";

  // Add an extra ptr arg on to the instrumented kernels
  std::vector<Type *> ArgTypes;
  for (auto arg = OrigKernel->arg_begin(); arg != OrigKernel->arg_end();
       ++arg) {
    ArgTypes.push_back(arg->getType());
  }
  ArgTypes.push_back(PointerType::get(M.getContext(), /*AddrSpace=*/0));

  FunctionType *FTy =
      FunctionType::get(OrigKernel->getFunctionType()->getReturnType(),
                        ArgTypes, OrigKernel->getFunctionType()->isVarArg());

  Function *NF =
      Function::Create(FTy, OrigKernel->getLinkage(),
                       OrigKernel->getAddressSpace(), AugmentedName, &M);
  NF->copyAttributesFrom(OrigKernel);
  VMap[OrigKernel] = NF;

  Function *F = cast<Function>(VMap[OrigKernel]);

  Function::arg_iterator DestI = F->arg_begin();
  for (const Argument &J : OrigKernel->args()) {
    DestI->setName(J.getName());
    VMap[&J] = &*DestI++;
  }

  SmallVector<ReturnInst *, 8> Returns; // Ignore returns cloned.
  CloneFunctionInto(F, OrigKernel, VMap, CloneFunctionChangeType::GlobalChanges,
                    Returns);

  return F;
}

llvm::Argument *getInstrumentationBufferArg(llvm::Function *Kernel) {
  if (!Kernel || Kernel->arg_empty())
    return nullptr;

  return Kernel->getArg(Kernel->arg_size() - 1);
}

// --- InstrumentationScope implementation ---

// Helper: trim leading and trailing whitespace from a string.
static std::string trimWhitespace(const std::string &s) {
  size_t start = s.find_first_not_of(" \t\r\n");
  if (start == std::string::npos)
    return "";
  size_t end = s.find_last_not_of(" \t\r\n");
  return s.substr(start, end - start + 1);
}

bool InstrumentationScope::parseDefinitions(const std::string &input) {
  // Split on ';' to get individual scope definitions.
  std::istringstream stream(input);
  std::string definition;

  while (std::getline(stream, definition, ';')) {
    definition = trimWhitespace(definition);
    if (definition.empty())
      continue;

    ScopeEntry entry;

    // Find where the file path ends and line specs begin.
    // The file path is everything before the first ':' that starts a line spec.
    // A line spec starts with a digit after ':'.
    //
    // Cases:
    //   /path/to/file.cpp           → file only, no line specs
    //   /path/to/file.cpp:42        → file + line spec
    //   /path/to/file.cpp:42:50     → file + range
    //   :42,50                      → no file, line specs only
    //   file.cpp:42,50              → tail match + line specs
    //
    // Strategy: find first ':' followed by a digit. Everything before that ':'
    // is the file path. Everything after is line spec text.

    std::string file_part;
    std::string line_part;

    // Handle the ":N" case (starts with colon)
    if (definition[0] == ':') {
      file_part = "";
      line_part = definition.substr(1);
    } else {
      // Scan for first ':' followed by a digit
      size_t colon_pos = std::string::npos;
      for (size_t i = 0; i < definition.size(); ++i) {
        if (definition[i] == ':' && i + 1 < definition.size() &&
            std::isdigit(static_cast<unsigned char>(definition[i + 1]))) {
          colon_pos = i;
          break;
        }
      }

      if (colon_pos == std::string::npos) {
        // No line specs — file path only
        file_part = definition;
        line_part = "";
      } else {
        file_part = definition.substr(0, colon_pos);
        line_part = definition.substr(colon_pos + 1);
      }
    }

    entry.file_pattern = file_part;
    entry.is_full_path = !file_part.empty() && file_part[0] == '/';

    // Parse line specs if present
    if (!line_part.empty()) {
      // Line specs are comma-separated. Each is either N or N:M.
      std::istringstream line_stream(line_part);
      std::string spec;

      while (std::getline(line_stream, spec, ',')) {
        spec = trimWhitespace(spec);
        if (spec.empty())
          continue;

        // Check for range N:M
        size_t range_colon = spec.find(':');
        if (range_colon != std::string::npos) {
          std::string start_str = spec.substr(0, range_colon);
          std::string end_str = spec.substr(range_colon + 1);

          // Validate: no more colons allowed
          if (end_str.find(':') != std::string::npos) {
            llvm::errs()
                << "InstrumentationScope: syntax error in line spec '" << spec
                << "' — too many colons. Disabling scope filtering.\n";
            return false;
          }

          char *endptr = nullptr;
          unsigned long start_val = std::strtoul(start_str.c_str(), &endptr, 10);
          if (*endptr != '\0') {
            llvm::errs()
                << "InstrumentationScope: syntax error in line spec '" << spec
                << "' — invalid start number. Disabling scope filtering.\n";
            return false;
          }

          endptr = nullptr;
          unsigned long end_val = std::strtoul(end_str.c_str(), &endptr, 10);
          if (*endptr != '\0') {
            llvm::errs()
                << "InstrumentationScope: syntax error in line spec '" << spec
                << "' — invalid end number. Disabling scope filtering.\n";
            return false;
          }

          if (end_val <= start_val) {
            llvm::errs()
                << "InstrumentationScope: syntax error in line spec '" << spec
                << "' — end (" << end_val << ") must be greater than start ("
                << start_val << "). Disabling scope filtering.\n";
            return false;
          }

          entry.ranges.emplace_back(static_cast<uint32_t>(start_val),
                                    static_cast<uint32_t>(end_val));
        } else {
          // Single line number N → range [N, N+1)
          char *endptr = nullptr;
          unsigned long line_val = std::strtoul(spec.c_str(), &endptr, 10);
          if (*endptr != '\0') {
            llvm::errs()
                << "InstrumentationScope: syntax error in line spec '" << spec
                << "' — invalid line number. Disabling scope filtering.\n";
            return false;
          }

          entry.ranges.emplace_back(static_cast<uint32_t>(line_val),
                                    static_cast<uint32_t>(line_val + 1));
        }
      }
    }

    entries_.push_back(std::move(entry));
  }

  return true;
}

InstrumentationScope::InstrumentationScope() {
  const char *scope_env = std::getenv("INSTRUMENTATION_SCOPE");
  const char *scope_file_env = std::getenv("INSTRUMENTATION_SCOPE_FILE");

  if (!scope_env && !scope_file_env) {
    active_ = false;
    return;
  }

  bool ok = true;

  if (scope_env) {
    std::string scope_str(scope_env);
    if (!scope_str.empty()) {
      ok = parseDefinitions(scope_str);
    }
  }

  if (ok && scope_file_env) {
    std::string scope_file_str(scope_file_env);
    if (!scope_file_str.empty()) {
      ok = parseFile(scope_file_str);
    }
  }

  if (!ok) {
    // Parse error — disable filtering (instrument everything)
    entries_.clear();
    active_ = false;
    return;
  }

  active_ = !entries_.empty();

  if (active_) {
    llvm::errs() << "InstrumentationScope: " << entries_.size()
                 << " scope definition(s) active\n";
  }
}

bool InstrumentationScope::matches(const std::string &file,
                                   uint32_t line) const {
  if (!active_)
    return true;

  for (const auto &entry : entries_) {
    // Check file match
    bool file_matches = false;

    if (entry.file_pattern.empty()) {
      // Empty pattern matches any file
      file_matches = true;
    } else if (entry.is_full_path) {
      // Full path: exact match
      file_matches = (file == entry.file_pattern);
    } else {
      // Tail match: file must end with the pattern
      if (file.size() >= entry.file_pattern.size()) {
        file_matches =
            (file.compare(file.size() - entry.file_pattern.size(),
                          entry.file_pattern.size(), entry.file_pattern) == 0);
      }
    }

    if (!file_matches)
      continue;

    // If no ranges specified, file match alone is sufficient
    if (entry.ranges.empty())
      return true;

    // Check if line falls in any range
    for (const auto &range : entry.ranges) {
      if (line >= range.first && line < range.second)
        return true;
    }
  }

  return false;
}

bool InstrumentationScope::parseFile(const std::string &path) {
  std::ifstream file(path);
  if (!file.is_open()) {
    llvm::errs() << "InstrumentationScope: cannot open scope file '" << path
                 << "'. Disabling scope filtering.\n";
    return false;
  }

  // Read non-comment, non-blank lines and join them with ';'.
  std::string combined;
  std::string line;
  while (std::getline(file, line)) {
    line = trimWhitespace(line);
    if (line.empty() || line[0] == '#')
      continue;
    if (!combined.empty())
      combined += ';';
    combined += line;
  }

  if (combined.empty())
    return true; // Empty file is valid (no definitions)

  return parseDefinitions(combined);
}

} // namespace common
} // namespace instrumentation
