
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
#include "AMDGCNSubmitBBStart.h"
#include "InstrumentationCommon.h"
#include "utils.h"

#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/IntrinsicsAMDGPU.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include <iostream>
#include <vector>

#include "llvm/ADT/StringRef.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include <cstdlib>
#include <dlfcn.h>
#include <limits.h>
#include <type_traits>
#include <unistd.h>

using namespace llvm;
using namespace std;
using namespace instrumentation::common;

void InjectInstrumentationFunction(const BasicBlock::iterator &I,
                                   const Function &F, llvm::Module &M,
                                   uint32_t &LocationCounter, llvm::Value *Ptr,
                                   bool PrintLocationInfo) {
  DILocation *DL = dyn_cast<Instruction>(I)->getDebugLoc();

  std::string dbgFile =
      DL != nullptr ? getFullPath(DL) : "<unknown source file>";
  size_t dbgFileHash = std::hash<std::string>{}(dbgFile);

  IRBuilder<> Builder(dyn_cast<Instruction>(I));
  Value *DbgFileHashVal = Builder.getInt64(dbgFileHash);
  Value *DbgLineVal = Builder.getInt32(DL != nullptr ? DL->getLine() : 0);
  Value *DbgColumnVal = Builder.getInt32(DL != nullptr ? DL->getColumn() : 0);
  // TODO: replace hard-coded constant below by an enum from dh_comms'
  // message_h, but reorganize dh_comms' files first to avoid creating
  // unnecessary dependencies on dh_comms data types for
  // instrument-amdgpu-kernels
  uint32_t basic_block_start_type = 2;
  Value *UserTypeVal = Builder.getInt32(basic_block_start_type);
  Value *UserDataVal = Builder.getInt32(LocationCounter);

  std::string SourceInfo = (F.getName() + "     " + dbgFile + ":" +
                            Twine(DL != nullptr ? DL->getLine() : 0) + ":" +
                            Twine(DL != nullptr ? DL->getColumn() : 0))
                               .str();

  auto &CTX = M.getContext();
  FunctionType *FT = FunctionType::get(
      Type::getVoidTy(CTX),
      {Ptr->getType(), Type::getInt64Ty(CTX), Type::getInt32Ty(CTX),
       Type::getInt32Ty(CTX), Type::getInt32Ty(CTX), Type::getInt32Ty(CTX)},
      false);
  FunctionCallee InstrumentationFunction =
      M.getOrInsertFunction("s_submit_wave_header", FT);
  Builder.CreateCall(FT, cast<Function>(InstrumentationFunction.getCallee()),
                     {Ptr, DbgFileHashVal, DbgLineVal, DbgColumnVal,
                      UserTypeVal, UserDataVal});
  if (PrintLocationInfo) {
    errs() << "Injecting Basic Block tracker " << LocationCounter
           << " into AMDGPU Kernel: " << SourceInfo << "\n";
  }
  LocationCounter++;
}

bool AMDGCNSubmitBBStart::runOnModule(Module &M) {
  errs() << "Running AMDGCNSubmitBBStart on module: " << M.getName() << "\n";

  if (!validateAMDGPUTarget(M)) {
    return false;
  }

  if (!loadAndLinkBitcode(M)) {
    return false;
  }

  // Now s_submit_wave_header should be available inside M

  std::vector<Function *> GpuKernels = collectGPUKernels(M);

  bool ModifiedCodeGen = false;
  for (auto &I : GpuKernels) {
    ValueToValueMapTy VMap;
    Function *NF = cloneKernelWithExtraArg(I, M, VMap);

    // Get the ptr we just added to the kernel arguments
    Value *bufferPtr = &*NF->arg_end() - 1;
    uint32_t LocationCounter = 0;
    for (Function::iterator BB = NF->begin(); BB != NF->end(); BB++) {
      auto I = BB->begin();
      // Skip PHI nodes
      while (I != BB->end() && isa<PHINode>(&*I)) {
        ++I;
      }
      if (I != BB->end()) {
        InjectInstrumentationFunction(I, *NF, M, LocationCounter, bufferPtr,
                                      true);
        ModifiedCodeGen = true;
      }
    }
  }
  errs() << "Done running AMDGCNSubmitBBStart on module: " << M.getName()
         << "\n";
  return ModifiedCodeGen;
}

PassPluginLibraryInfo getPassPluginInfo() {
  const auto callback = [](PassBuilder &PB) {
    PB.registerOptimizerLastEPCallback(
        [&](ModulePassManager &MPM, auto &&...args) {
          MPM.addPass(AMDGCNSubmitBBStart());
          return true;
        });
  };

  return {LLVM_PLUGIN_API_VERSION, "amdgcn-submit-address-message",
          LLVM_VERSION_STRING, callback};
};

extern "C"
    //    __attribute__((visibility("default"))) PassPluginLibraryInfo extern
    //    "C"
    LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
  return getPassPluginInfo();
}
