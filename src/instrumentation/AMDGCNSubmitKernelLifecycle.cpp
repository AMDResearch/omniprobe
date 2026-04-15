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
#include "AMDGCNSubmitKernelLifecycle.h"
#include "InstrumentationCommon.h"

#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"

using namespace llvm;
using namespace instrumentation::common;

namespace {

struct StorageInitInfo {
  Value *storage = nullptr;
  Instruction *last_init = nullptr;
};

static AllocaInst *createEntryAlloca(Function &F, Type *Ty, StringRef Name) {
  IRBuilder<> Builder(&*F.getEntryBlock().getFirstInsertionPt());
  return Builder.CreateAlloca(Ty, nullptr, Name);
}

static StorageInitInfo createRuntimeCtxStorage(Function &F, Module &M,
                                               Value *DhPtr) {
  auto &Ctx = M.getContext();
  IRBuilder<> Builder(&*F.getEntryBlock().getFirstInsertionPt());
  Type *PtrTy = PointerType::get(Ctx, 0);
  StructType *RuntimeCtxTy =
      StructType::get(PtrTy, PtrTy, PtrTy, Builder.getInt64Ty());
  AllocaInst *RuntimeCtx = Builder.CreateAlloca(RuntimeCtxTy, nullptr,
                                                "omniprobe.runtime_ctx");

  Value *DhField = Builder.CreateStructGEP(RuntimeCtxTy, RuntimeCtx, 0);
  Value *ConfigField = Builder.CreateStructGEP(RuntimeCtxTy, RuntimeCtx, 1);
  Value *StateField = Builder.CreateStructGEP(RuntimeCtxTy, RuntimeCtx, 2);
  Value *DispatchField = Builder.CreateStructGEP(RuntimeCtxTy, RuntimeCtx, 3);

  Value *DhAsVoidPtr = Builder.CreatePointerCast(DhPtr, PtrTy);
  Builder.CreateStore(DhAsVoidPtr, DhField);
  Builder.CreateStore(ConstantPointerNull::get(cast<PointerType>(PtrTy)),
                      ConfigField);
  Builder.CreateStore(ConstantPointerNull::get(cast<PointerType>(PtrTy)),
                      StateField);
  Instruction *LastInit = Builder.CreateStore(
      ConstantInt::get(Builder.getInt64Ty(), 0), DispatchField);
  return {RuntimeCtx, LastInit};
}

static StorageInitInfo populateCaptureStorage(IRBuilder<> &Builder,
                                              const ProbeSurrogateSpec &Spec,
                                              const Function &F, Module &M) {
  std::vector<Type *> FieldTypes;
  std::vector<Value *> FieldValues;
  const size_t VisibleArgCount = getVisibleKernelArgumentCount(F);
  for (size_t SpecArgIndex = 0; SpecArgIndex < Spec.kernel_args.size();
       ++SpecArgIndex) {
    const std::string &KernelArgName = Spec.kernel_args[SpecArgIndex];
    const Argument *Matched = nullptr;
    if (auto Ordinal = resolveKernelArgumentOrdinal(F, KernelArgName)) {
      if (*Ordinal < VisibleArgCount && *Ordinal < F.arg_size())
        Matched = F.getArg(*Ordinal);
    }
    if (!Matched && SpecArgIndex < VisibleArgCount && SpecArgIndex < F.arg_size()) {
      Matched = F.getArg(SpecArgIndex);
      errs() << "Probe surrogate " << Spec.surrogate
             << " falling back to kernel-arg ordinal " << SpecArgIndex
             << " for requested arg '" << KernelArgName << "' in kernel "
             << F.getName() << "\n";
    }
    if (!Matched) {
      errs() << "Probe surrogate " << Spec.surrogate
             << " requested unknown kernel arg '" << KernelArgName
             << "' for kernel " << F.getName() << "\n";
      continue;
    }

    Value *StoredValue = const_cast<Argument *>(Matched);
    Type *StoredType = StoredValue->getType();
    if (StoredType->isPointerTy()) {
      StoredValue = Builder.CreatePtrToInt(StoredValue, Builder.getInt64Ty());
      StoredType = Builder.getInt64Ty();
    } else if (StoredType->isIntegerTy(1)) {
      StoredValue = Builder.CreateZExt(StoredValue, Builder.getInt8Ty());
      StoredType = Builder.getInt8Ty();
    } else if (StoredType->isIntegerTy() &&
               StoredType->getIntegerBitWidth() < 64) {
      StoredValue = Builder.CreateZExt(StoredValue, Builder.getInt64Ty());
      StoredType = Builder.getInt64Ty();
    } else if (StoredType->isIntegerTy() &&
               StoredType->getIntegerBitWidth() > 64) {
      StoredValue = Builder.CreateTrunc(StoredValue, Builder.getInt64Ty());
      StoredType = Builder.getInt64Ty();
    } else if (!StoredType->isIntegerTy()) {
      errs() << "Probe surrogate " << Spec.surrogate
             << " requested unsupported kernel arg type for '" << KernelArgName
             << "' in kernel " << F.getName() << "\n";
      continue;
    }

    FieldTypes.push_back(StoredType);
    FieldValues.push_back(StoredValue);
  }

  if (FieldTypes.empty()) {
    AllocaInst *Storage = createEntryAlloca(const_cast<Function &>(F),
                                            Builder.getInt8Ty(),
                                            "omniprobe.empty_captures");
    Instruction *LastInit =
        Builder.CreateStore(ConstantInt::get(Builder.getInt8Ty(), 0), Storage);
    return {Storage, LastInit};
  }

  StructType *CaptureTy = StructType::get(M.getContext(), FieldTypes);
  AllocaInst *CaptureStorage =
      createEntryAlloca(const_cast<Function &>(F), CaptureTy,
                        "omniprobe.lifecycle_captures");
  Instruction *LastInit = nullptr;
  for (unsigned Index = 0; Index < FieldValues.size(); ++Index) {
    Value *FieldPtr = Builder.CreateStructGEP(CaptureTy, CaptureStorage, Index);
    LastInit = Builder.CreateStore(FieldValues[Index], FieldPtr);
  }
  return {CaptureStorage, LastInit};
}

static Function *getClock64Function(Module &M, IRBuilder<> &Builder) {
  return cast<Function>(
      M.getOrInsertFunction("s_clock64",
                            FunctionType::get(Builder.getInt64Ty(), {}, false))
          .getCallee());
}

static void injectLifecycleSurrogateCall(Instruction *InsertBefore, Module &M,
                                         Value *RuntimeCtx,
                                         Value *CaptureStorage,
                                         const ProbeSurrogateSpec &Spec) {
  IRBuilder<> Builder(InsertBefore);
  Function *Clock64 = getClock64Function(M, Builder);
  Value *Timestamp = Builder.CreateCall(Clock64, {});
  Type *VoidPtrTy = PointerType::get(M.getContext(), 0);
  FunctionType *FT =
      FunctionType::get(Type::getVoidTy(M.getContext()),
                        {VoidPtrTy, VoidPtrTy, Builder.getInt64Ty()}, false);
  FunctionCallee Surrogate = M.getOrInsertFunction(Spec.surrogate, FT);
  Builder.CreateCall(
      FT, cast<Function>(Surrogate.getCallee()),
      {Builder.CreatePointerCast(RuntimeCtx, VoidPtrTy),
       Builder.CreatePointerCast(CaptureStorage, VoidPtrTy), Timestamp});
}

static Instruction *findInsertionAfter(Instruction *After) {
  if (!After)
    return nullptr;
  if (Instruction *Next = After->getNextNode())
    return Next;
  return After;
}

} // namespace

bool AMDGCNSubmitKernelLifecycle::runOnModule(Module &M) {
  errs() << "Running AMDGCNSubmitKernelLifecycle on module: " << M.getName()
         << "\n";

  if (!validateAMDGPUTarget(M))
    return false;

  if (!loadAndLinkBitcode(M))
    return false;

  std::vector<ProbeSurrogateSpec> ProbeSpecs = loadProbeSurrogateManifest();
  std::vector<Function *> GpuKernels = collectGPUKernels(M);

  bool ModifiedCodeGen = false;
  for (Function *OrigKernel : GpuKernels) {
    KernelLifecycleSurrogatePair Surrogates =
        findKernelLifecycleSurrogatesForKernel(ProbeSpecs, OrigKernel->getName());
    if (!Surrogates.entry && !Surrogates.exit)
      continue;

    if (Surrogates.entry) {
      errs() << "Using generated kernel-entry surrogate "
             << Surrogates.entry->surrogate << " for kernel "
             << OrigKernel->getName() << "\n";
    }
    if (Surrogates.exit) {
      errs() << "Using generated kernel-exit surrogate "
             << Surrogates.exit->surrogate << " for kernel "
             << OrigKernel->getName() << "\n";
    }

    ValueToValueMapTy VMap;
    Function *NF = cloneKernelWithExtraArg(OrigKernel, M, VMap);
    Value *BufferPtr = getInstrumentationBufferArg(NF);
    if (!BufferPtr) {
      errs() << "Failed to locate instrumentation buffer argument for "
             << NF->getName() << "\n";
      continue;
    }

    IRBuilder<> EntryBuilder(&*NF->getEntryBlock().getFirstInsertionPt());
    StorageInitInfo RuntimeCtx = createRuntimeCtxStorage(*NF, M, BufferPtr);
    const ProbeSurrogateSpec *CaptureSpec =
        Surrogates.entry ? &*Surrogates.entry : &*Surrogates.exit;
    StorageInitInfo CaptureStorage =
        populateCaptureStorage(EntryBuilder, *CaptureSpec, *NF, M);

    if (Surrogates.entry) {
      Instruction *EntryInst = findInsertionAfter(
          CaptureStorage.last_init ? CaptureStorage.last_init
                                   : RuntimeCtx.last_init);
      if (EntryInst) {
        injectLifecycleSurrogateCall(EntryInst, M, RuntimeCtx.storage,
                                     CaptureStorage.storage,
                                     *Surrogates.entry);
        ModifiedCodeGen = true;
      }
    }

    if (Surrogates.exit) {
      for (BasicBlock &BB : *NF) {
        if (auto *Ret = dyn_cast<ReturnInst>(BB.getTerminator())) {
          injectLifecycleSurrogateCall(Ret, M, RuntimeCtx.storage,
                                       CaptureStorage.storage,
                                       *Surrogates.exit);
          ModifiedCodeGen = true;
        }
      }
    }
  }

  errs() << "Done running AMDGCNSubmitKernelLifecycle on module: "
         << M.getName() << "\n";
  return ModifiedCodeGen;
}

PassPluginLibraryInfo getPassPluginInfo() {
  const auto callback = [](PassBuilder &PB) {
    PB.registerOptimizerLastEPCallback(
        [&](ModulePassManager &MPM, auto &&...args) {
          MPM.addPass(AMDGCNSubmitKernelLifecycle());
          return true;
        });
  };

  return {LLVM_PLUGIN_API_VERSION, "amdgcn-submit-kernel-lifecycle",
          LLVM_VERSION_STRING, callback};
}

extern "C" LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
  return getPassPluginInfo();
}
