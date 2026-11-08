
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
#include "AMDGCNSubmitBBInterval.h"
#include "InstrumentationCommon.h"
#include "utils.h"

#include "llvm/ADT/StringRef.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/IntrinsicsAMDGPU.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#if __has_include("llvm/Plugins/PassPlugin.h")
#include "llvm/Plugins/PassPlugin.h"
#else
#include "llvm/Passes/PassPlugin.h"
#endif
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include <cstdlib>
#include <dlfcn.h>
#include <iostream>
#include <limits.h>
#include <type_traits>
#include <unistd.h>
#include <vector>

using namespace llvm;
using namespace std;
using namespace instrumentation::common;


// Codegen is free to move a block's work across the two s_clock64() calls:
// computation whose only use is in a later block sinks past the stop clock,
// and loads are hoisted above the start clock, so the interval measures
// nothing. A scheduling barrier after the start clock and before the stop
// clock, plus an empty side-effecting asm use of every value the block
// defines for later blocks, pins the block's work between them.
static void pinValue(IRBuilder<> &B, Value *V) {
  const DataLayout &DL = B.GetInsertBlock()->getModule()->getDataLayout();
  Type *T = V->getType();
  if (auto *VT = dyn_cast<FixedVectorType>(T)) {
    for (unsigned i = 0; i != VT->getNumElements(); ++i)
      pinValue(B, B.CreateExtractElement(V, B.getInt32(i)));
    return;
  }
  if (T->isPointerTy())
    V = B.CreatePtrToInt(V, B.getIntNTy(DL.getPointerSizeInBits(T->getPointerAddressSpace())));
  else if (!T->isIntegerTy())
    V = B.CreateBitCast(V, B.getIntNTy(DL.getTypeSizeInBits(T)));
  unsigned Bits = V->getType()->getIntegerBitWidth();
  if (Bits < 32)
    V = B.CreateZExt(V, B.getInt32Ty());
  else if (Bits != 32 && Bits != 64) {
    for (unsigned lo = 0; lo < Bits; lo += 32)
      pinValue(B, B.CreateTrunc(B.CreateLShr(V, lo), B.getInt32Ty()));
    return;
  }
  FunctionType *FT = FunctionType::get(B.getVoidTy(), {V->getType()}, false);
  B.CreateCall(FT, InlineAsm::get(FT, "; bbinterval pin $0", "v", /*hasSideEffects=*/true), {V});
}

static bool pinnable(Type *T) {
  if (auto *VT = dyn_cast<FixedVectorType>(T))
    return pinnable(VT->getElementType());
  return T->isIntegerTy() || T->isFloatingPointTy() || T->isPointerTy();
}

static void pinBlockLiveOuts(IRBuilder<> &B, BasicBlock &BB, Instruction *Skip) {
  for (auto &Inst : BB) {
    if (&Inst == Skip || Inst.isTerminator() || Inst.getType()->isVoidTy() ||
        isa<AllocaInst>(Inst) || !pinnable(Inst.getType()))
      continue;
    bool LiveOut = false;
    for (User *U : Inst.users())
      if (auto *UI = dyn_cast<Instruction>(U))
        if (UI->getParent() != &BB || isa<PHINode>(UI))
          LiveOut = true;
    if (LiveOut)
      pinValue(B, &Inst);
  }
}

bool AMDGCNSubmitBBInterval::runOnModule(Module &M) {
  if (!validateAMDGPUTarget(M)) {
    return false;
  }

  errs() << "Running AMDGCNSubmitBBInterval on amdgcn-amd-amdhsa device module "
            "for "
         << M.getName() << "\n";

  if (!loadAndLinkBitcode(M)) {
    return false;
  }

  std::vector<Function *> GpuKernels = collectGPUKernels(M);

  bool ModifiedCodeGen = false;
  for (auto &I : GpuKernels) {
    ValueToValueMapTy VMap;
    Function *NF = cloneKernelWithExtraArg(I, M, VMap);

    // Get the ptr we just added to the kernel arguments
    Value *bufferPtr = &*NF->arg_end() - 1;
    // Instrument each basic block in the cloned kernel NF:
    unsigned bbIndex = 0;
    // One static alloca in the entry block, reused by every block.
    // An alloca in a non-entry block is a *dynamic* alloca: it bumps the
    // stack pointer each time the block executes (never restored), and
    // AMDGPU codegen addresses it inconsistently (wave-scaled soffset for
    // the stores, unscaled VGPR offset for the loads).
    IRBuilder<> EntryBuilder(&*NF->getEntryBlock().getFirstInsertionPt());
    AllocaInst *timeIntervalAlloca = EntryBuilder.CreateAlloca(
        ArrayType::get(EntryBuilder.getInt64Ty(), 2), nullptr, "timeInterval");
    for (auto BB = NF->begin(); BB != NF->end(); ++BB) {
      Instruction *firstInst = nullptr;
      if (!BB->empty()) {
        for (auto &Inst : *BB) {
          if (!isa<PHINode>(Inst) && &Inst != timeIntervalAlloca) {
            firstInst = &Inst;
            break;
          }
        }
      }
      IRBuilder<> BuilderStart(firstInst ? firstInst : &*BB->begin());
      // Obtain (or declare) the s_clock64() function from dh_comms_dev.h
      Function *sClock64Func = cast<Function>(
          M.getOrInsertFunction(
               "s_clock64",
               FunctionType::get(BuilderStart.getInt64Ty(), {}, false))
              .getCallee());
      // Insert call to s_clock64() at BB entry (replacing __clock64())
      CallInst *startCall = BuilderStart.CreateCall(sClock64Func, {});
      BuilderStart.CreateIntrinsic(Intrinsic::amdgcn_sched_barrier, {},
                                   {BuilderStart.getInt32(0)});
      // Allocate a 2-element array for timestamps and get pointer with proper
      // GEP
      Value *zero32 = BuilderStart.getInt32(0);
      Value *startPtr = BuilderStart.CreateInBoundsGEP(
          timeIntervalAlloca->getAllocatedType(), timeIntervalAlloca,
          {BuilderStart.getInt32(0), zero32});
      BuilderStart.CreateStore(startCall, startPtr);

      // Compute debug info constants based on the first instruction (or
      // defaults)
      uint64_t fileHashConst;
      uint32_t lineConst;
      uint32_t columnConst;
      if (firstInst) {
        DILocation *DL = firstInst->getDebugLoc();
        if (DL) {
          std::string dbgFile = getFullPath(DL);
          fileHashConst = std::hash<std::string>{}(dbgFile);
          lineConst = DL->getLine();
          columnConst = DL->getColumn();
        } else {
          fileHashConst = 0;
          lineConst = 0xffffff;
          columnConst = 0xffffff;
        }
      } else {
        fileHashConst = 0;
        lineConst = 0xffffff;
        columnConst = 0xffffff;
      }

      // Insert s_clock64() call at BB end (before terminator)
      Instruction *insertPt = BB->getTerminator();
      IRBuilder<> BuilderEnd(insertPt);
      pinBlockLiveOuts(BuilderEnd, *BB, startCall);
      BuilderEnd.CreateIntrinsic(Intrinsic::amdgcn_sched_barrier, {},
                                 {BuilderEnd.getInt32(0)});
      CallInst *endCall = BuilderEnd.CreateCall(sClock64Func, {});
      Value *one32 = BuilderEnd.getInt32(1);
      Value *endPtr = BuilderEnd.CreateInBoundsGEP(
          timeIntervalAlloca->getAllocatedType(), timeIntervalAlloca,
          {BuilderEnd.getInt32(0), one32});
      BuilderEnd.CreateStore(endCall, endPtr);

      // Prepare constant values for debug metadata
      Value *dbgFileHashVal = BuilderEnd.getInt64(fileHashConst);
      Value *dbgLineVal = BuilderEnd.getInt32(lineConst);
      Value *dbgColumnVal = BuilderEnd.getInt32(columnConst);

      // Get (or insert) the declaration for s_submit_time_interval
      Type *VoidPtrTy = PointerType::get(M.getContext(), 0);
      Function *sSubmitTimeInterval = cast<Function>(
          M.getOrInsertFunction(
               "s_submit_time_interval",
               FunctionType::get(Type::getVoidTy(M.getContext()),
                                 {bufferPtr->getType(), VoidPtrTy,
                                  Type::getInt64Ty(M.getContext()),
                                  Type::getInt32Ty(M.getContext()),
                                  Type::getInt32Ty(M.getContext()),
                                  Type::getInt32Ty(M.getContext())},
                                 false))
              .getCallee());
      // Cast the time interval allocation to a void Ptr
      Value *timeIntervalPtr =
          BuilderEnd.CreatePointerCast(timeIntervalAlloca, VoidPtrTy);

      // Insert call to s_submit_time_interval with debug info and the timing
      // struct
      BuilderEnd.CreateCall(sSubmitTimeInterval,
                            {bufferPtr, timeIntervalPtr, dbgFileHashVal,
                             dbgLineVal, dbgColumnVal,
                             BuilderEnd.getInt32(bbIndex)});

      bbIndex++;
      ModifiedCodeGen = true;
    }
    errs() << "AMDGCNSubmitBBInterval: instrumented " << bbIndex
           << " basic blocks for kernel " << I->getName() << "\n";
  }
  errs() << "Done running AMDGCNSubmitBBInterval on " << M.getName() << "\n";
  return ModifiedCodeGen;
}

PassPluginLibraryInfo getPassPluginInfo() {
  const auto callback = [](PassBuilder &PB) {
    PB.registerOptimizerLastEPCallback(
        [&](ModulePassManager &MPM, auto &&...args) {
          MPM.addPass(AMDGCNSubmitBBInterval());
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
