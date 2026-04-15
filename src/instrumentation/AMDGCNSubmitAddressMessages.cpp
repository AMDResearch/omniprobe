
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
#include "AMDGCNSubmitAddressMessage.h"
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
#include <optional>
#include <type_traits>
#include <unistd.h>

using namespace llvm;
using namespace std;
using namespace instrumentation::common;

std::map<int, std::string> AddrSpaceMap = {
    {0, "FLAT"}, {1, "GLOBAL"}, {3, "SHARED"}, {4, "CONSTANT"}};

std::string LoadOrStoreMap(const BasicBlock::iterator &I) {
  if (dyn_cast<LoadInst>(I) != nullptr)
    return "LOAD";
  else if (dyn_cast<StoreInst>(I) != nullptr)
    return "STORE";
  else
    throw std::runtime_error("Error: unknown operation type");
}

static AllocaInst *createEntryAlloca(Function &F, Type *Ty, StringRef Name) {
  IRBuilder<> Builder(&*F.getEntryBlock().getFirstInsertionPt());
  return Builder.CreateAlloca(Ty, nullptr, Name);
}

static Value *createRuntimeCtxStorage(Function &F, Module &M, Value *DhPtr) {
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
  Builder.CreateStore(ConstantInt::get(Builder.getInt64Ty(), 0), DispatchField);
  return RuntimeCtx;
}

static Value *populateCaptureStorage(IRBuilder<> &Builder,
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
    if (!Matched) {
      if (SpecArgIndex < VisibleArgCount && SpecArgIndex < F.arg_size()) {
        Matched = F.getArg(SpecArgIndex);
        llvm::errs() << "Probe surrogate " << Spec.surrogate
                     << " falling back to kernel-arg ordinal "
                     << SpecArgIndex << " for requested arg '"
                     << KernelArgName << "' in kernel " << F.getName()
                     << "\n";
      }
    }
    if (!Matched) {
      llvm::errs() << "Probe surrogate " << Spec.surrogate
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
    } else if (StoredType->isIntegerTy() && StoredType->getIntegerBitWidth() < 64) {
      StoredValue = Builder.CreateZExt(StoredValue, Builder.getInt64Ty());
      StoredType = Builder.getInt64Ty();
    } else if (StoredType->isIntegerTy() && StoredType->getIntegerBitWidth() > 64) {
      StoredValue = Builder.CreateTrunc(StoredValue, Builder.getInt64Ty());
      StoredType = Builder.getInt64Ty();
    } else if (!StoredType->isIntegerTy()) {
      llvm::errs() << "Probe surrogate " << Spec.surrogate
                   << " requested unsupported kernel arg type for '" << KernelArgName
                   << "' in kernel " << F.getName() << "\n";
      continue;
    }

    FieldTypes.push_back(StoredType);
    FieldValues.push_back(StoredValue);
  }

  if (FieldTypes.empty()) {
    AllocaInst *Storage = createEntryAlloca(const_cast<Function &>(F), Builder.getInt8Ty(),
                                            "omniprobe.empty_captures");
    Builder.CreateStore(ConstantInt::get(Builder.getInt8Ty(), 0), Storage);
    return Storage;
  }

  StructType *CaptureTy = StructType::get(M.getContext(), FieldTypes);
  AllocaInst *CaptureStorage =
      createEntryAlloca(const_cast<Function &>(F), CaptureTy,
                        "omniprobe.captures");
  for (unsigned Index = 0; Index < FieldValues.size(); ++Index) {
    Value *FieldPtr = Builder.CreateStructGEP(CaptureTy, CaptureStorage, Index);
    Builder.CreateStore(FieldValues[Index], FieldPtr);
  }
  return CaptureStorage;
}

static bool injectSurrogateAddressCall(const BasicBlock::iterator &I,
                                       const Function &F, Module &M,
                                       llvm::Value *DhPtr,
                                       const ProbeSurrogateSpec &Spec,
                                       bool IsLoad, llvm::Value *Addr,
                                       Value *AddrSpaceVal,
                                       Value *PointeeTypeSizeVal) {
  auto &CTX = M.getContext();
  IRBuilder<> Builder(dyn_cast<Instruction>(I));

  Value *RuntimeCtx = createRuntimeCtxStorage(const_cast<Function &>(F), M, DhPtr);
  Value *CaptureStorage = populateCaptureStorage(Builder, Spec, F, M);

  Type *VoidPtrTy = PointerType::get(CTX, 0);
  Value *AddressAsInt = Builder.CreatePtrToInt(Addr, Builder.getInt64Ty());
  Value *BytesVal = Builder.CreateZExtOrTrunc(PointeeTypeSizeVal, Builder.getInt32Ty());
  Value *AccessTypeVal = Builder.getInt8(IsLoad ? 0b01 : 0b10);
  Value *AddressSpaceAsI8 = Builder.CreateZExtOrTrunc(AddrSpaceVal, Builder.getInt8Ty());

  FunctionType *FT = FunctionType::get(
      Type::getVoidTy(CTX),
      {VoidPtrTy, VoidPtrTy, Builder.getInt64Ty(), Builder.getInt32Ty(),
       Builder.getInt8Ty(), Builder.getInt8Ty()},
      false);
  FunctionCallee Surrogate =
      M.getOrInsertFunction(Spec.surrogate, FT);
  Builder.CreateCall(
      FT, cast<Function>(Surrogate.getCallee()),
      {Builder.CreatePointerCast(RuntimeCtx, VoidPtrTy),
       Builder.CreatePointerCast(CaptureStorage, VoidPtrTy), AddressAsInt,
       BytesVal, AccessTypeVal, AddressSpaceAsI8});
  return true;
}

// Helper functions to detect AMDGPU buffer intrinsics
bool isAMDGCNBufferLoad(const CallInst *CI) {
  if (!CI)
    return false;
  Function *Callee = CI->getCalledFunction();
  if (!Callee)
    return false;
  StringRef Name = Callee->getName();
  return Name.starts_with("llvm.amdgcn.raw.ptr.buffer.load") ||
         Name.starts_with("llvm.amdgcn.struct.ptr.buffer.load");
}

bool isAMDGCNBufferStore(const CallInst *CI) {
  if (!CI)
    return false;
  Function *Callee = CI->getCalledFunction();
  if (!Callee)
    return false;
  StringRef Name = Callee->getName();
  return Name.starts_with("llvm.amdgcn.raw.ptr.buffer.store") ||
         Name.starts_with("llvm.amdgcn.struct.ptr.buffer.store");
}

// Instrumentation function for buffer intrinsics
void InjectBufferInstrumentationFunction(const BasicBlock::iterator &I,
                                         const Function &F, llvm::Module &M,
                                         uint32_t &LocationCounter,
                                         llvm::Value *Ptr, bool IsLoad,
                                         bool PrintLocationInfo,
                                         const ProbeSurrogateSpec *SurrogateSpec) {
  auto &CTX = M.getContext();
  auto CI = dyn_cast<CallInst>(I);
  if (!CI)
    return;

  IRBuilder<> Builder(CI);

  // For buffer intrinsics:
  // - Load:  buffer_load(buffer_desc, offset, ...)
  // - Store: buffer_store(data, buffer_desc, offset, ...)
  // So buffer descriptor is at index 0 for loads, index 1 for stores
  Value *BufferDesc = IsLoad ? CI->getArgOperand(0) : CI->getArgOperand(1);
  Value *Offset = IsLoad ? CI->getArgOperand(1) : CI->getArgOperand(2);

  // Get the original pointer from llvm.amdgcn.make.buffer.rsrc
  // We need to trace back to find the original pointer
  Value *OrigPtr = nullptr;
  if (auto *MakeBufferCall = dyn_cast<CallInst>(BufferDesc)) {
    if (MakeBufferCall->getCalledFunction() &&
        MakeBufferCall->getCalledFunction()->getName().starts_with(
            "llvm.amdgcn.make.buffer.rsrc")) {
      OrigPtr =
          MakeBufferCall->getArgOperand(0); // First arg is the original pointer
    }
  }

  if (!OrigPtr) {
    // Fallback if we can't trace the original pointer - use null pointer
    OrigPtr = ConstantPointerNull::get(PointerType::get(CTX, 1));
  }

  // Calculate the actual address by adding the byte offset to the base pointer
  // Convert pointer to i64, add offset, then we'll use the integer
  // representation
  Value *PtrAsInt = Builder.CreatePtrToInt(OrigPtr, Builder.getInt64Ty());
  Value *OffsetExt = Builder.CreateSExt(Offset, Builder.getInt64Ty());
  Value *ActualAddrInt = Builder.CreateAdd(PtrAsInt, OffsetExt);

  // Create a pointer in address space 0 (flat) for instrumentation
  // We use IntToPtr with the flat address space since that's compatible with
  // Ptr
  Value *ActualAddr =
      Builder.CreateIntToPtr(ActualAddrInt, PointerType::get(CTX, 0));

  Value *AccessTypeVal = Builder.getInt8(IsLoad ? 0b01 : 0b10);

  DILocation *DL = CI->getDebugLoc();
  std::string dbgFile =
      DL != nullptr ? getFullPath(DL) : "<unknown source file>";
  size_t dbgFileHash = std::hash<std::string>{}(dbgFile);

  Value *DbgFileHashVal = Builder.getInt64(dbgFileHash);
  Value *DbgLineVal = Builder.getInt32(DL != nullptr ? DL->getLine() : 0);
  Value *DbgColumnVal = Builder.getInt32(DL != nullptr ? DL->getColumn() : 0);

  // Address space for buffer intrinsics is typically global (1)
  Value *AddrSpaceVal = Builder.getInt8(1);

  // Get size from the vector type (e.g., <4 x float> = 16 bytes)
  Type *DataType = IsLoad ? CI->getType() : CI->getArgOperand(0)->getType();
  uint16_t DataSize = M.getDataLayout().getTypeStoreSize(DataType);
  Value *PointeeTypeSizeVal = Builder.getInt16(DataSize);

  // Ensure Addr64 has exactly the same type as Ptr using bitcast if needed
  Value *Addr64 = ActualAddr;
  if (Addr64->getType() != Ptr->getType()) {
    Addr64 = Builder.CreateBitCast(ActualAddr, Ptr->getType());
  }

  std::string SourceInfo = (F.getName() + "     " + dbgFile + ":" +
                            Twine(DL != nullptr ? DL->getLine() : 0) + ":" +
                            Twine(DL != nullptr ? DL->getColumn() : 0))
                               .str();

  if (SurrogateSpec) {
    injectSurrogateAddressCall(I, F, M, Ptr, *SurrogateSpec, IsLoad, Addr64,
                               AddrSpaceVal, PointeeTypeSizeVal);
  } else {
    FunctionType *FT = FunctionType::get(
        Type::getVoidTy(CTX),
        {Ptr->getType(), Ptr->getType(), Type::getInt64Ty(CTX),
         Type::getInt32Ty(CTX), Type::getInt32Ty(CTX), Type::getInt8Ty(CTX),
         Type::getInt8Ty(CTX), Type::getInt16Ty(CTX)},
        false);
    FunctionCallee InstrumentationFunction =
        M.getOrInsertFunction("v_submit_address", FT);
    Builder.CreateCall(FT, cast<Function>(InstrumentationFunction.getCallee()),
                       {Ptr, Addr64, DbgFileHashVal, DbgLineVal, DbgColumnVal,
                        AccessTypeVal, AddrSpaceVal, PointeeTypeSizeVal});
  }

  if (PrintLocationInfo) {
    errs() << "Injecting Buffer Intrinsic Trace Into AMDGPU Kernel: "
           << SourceInfo << "\n";
    errs() << LocationCounter << "     " << SourceInfo << "     GLOBAL     "
           << (IsLoad ? "LOAD" : "STORE") << "     (buffer intrinsic)\n";
  }
  LocationCounter++;
}

template <typename LoadOrStoreInst>
void InjectInstrumentationFunction(const BasicBlock::iterator &I,
                                   const Function &F, llvm::Module &M,
                                   uint32_t &LocationCounter, llvm::Value *Ptr,
                                   bool PrintLocationInfo,
                                   const ProbeSurrogateSpec *SurrogateSpec) {
  auto &CTX = M.getContext();
  auto LSI = dyn_cast<LoadOrStoreInst>(I);
  Value *AccessTypeVal;
  Type *PointeeType;
  IRBuilder<> Builder(dyn_cast<Instruction>(I));
  auto LI = dyn_cast<LoadInst>(I);
  auto SI = dyn_cast<StoreInst>(I);
  if (LI) {
    AccessTypeVal = Builder.getInt8(0b01);
    PointeeType = LI->getType();
  } else if (SI) {
    AccessTypeVal = Builder.getInt8(0b10);
    PointeeType = SI->getValueOperand()->getType();
  } else {
    return;
  }
  if (not LSI)
    return;

  DILocation *DL = dyn_cast<Instruction>(I)->getDebugLoc();

  std::string dbgFile =
      DL != nullptr ? getFullPath(DL) : "<unknown source file>";
  size_t dbgFileHash = std::hash<std::string>{}(dbgFile);

  Value *Addr = LSI->getPointerOperand();
  Value *DbgFileHashVal = Builder.getInt64(dbgFileHash);
  Value *DbgLineVal = Builder.getInt32(DL != nullptr ? DL->getLine() : 0);
  Value *DbgColumnVal = Builder.getInt32(DL != nullptr ? DL->getColumn() : 0);
  Value *Op = LSI->getPointerOperand()->stripPointerCasts();
  uint32_t AddrSpace = cast<PointerType>(Op->getType())->getAddressSpace();
  Value *AddrSpaceVal = Builder.getInt8(AddrSpace);
  uint16_t PointeeTypeSize = M.getDataLayout().getTypeStoreSize(PointeeType);
  Value *PointeeTypeSizeVal = Builder.getInt16(PointeeTypeSize);

  std::string SourceInfo = (F.getName() + "     " + dbgFile + ":" +
                            Twine(DL != nullptr ? DL->getLine() : 0) + ":" +
                            Twine(DL != nullptr ? DL->getColumn() : 0))
                               .str();

  // v_submit_message expects addresses (passed in Addr) to be 64-bits. However,
  // LDS pointers are 32 bits, so we have to cast those. Ptr (the pointer to the
  // dh_comms resources in global device memory) is 64-bits, so we use its type
  // to do the cast.

  Value *Addr64 = Builder.CreatePointerCast(Addr, Ptr->getType());

  if (SurrogateSpec) {
    injectSurrogateAddressCall(I, F, M, Ptr, *SurrogateSpec, LI != nullptr,
                               Addr64, AddrSpaceVal, PointeeTypeSizeVal);
  } else {
    FunctionType *FT = FunctionType::get(
        Type::getVoidTy(CTX),
        {Ptr->getType(), Addr64->getType(), Type::getInt64Ty(CTX),
         Type::getInt32Ty(CTX), Type::getInt32Ty(CTX), Type::getInt8Ty(CTX),
         Type::getInt8Ty(CTX), Type::getInt16Ty(CTX)},
        false);
    FunctionCallee InstrumentationFunction =
        M.getOrInsertFunction("v_submit_address", FT);
    Builder.CreateCall(FT, cast<Function>(InstrumentationFunction.getCallee()),
                       {Ptr, Addr64, DbgFileHashVal, DbgLineVal, DbgColumnVal,
                        AccessTypeVal, AddrSpaceVal, PointeeTypeSizeVal});
  }
  if (PrintLocationInfo) {
    errs() << "Injecting Mem Trace Function Into AMDGPU Kernel: " << SourceInfo
           << "\n";
    errs() << LocationCounter << "     " << SourceInfo << "     "
           << AddrSpaceMap[AddrSpace] << "     " << LoadOrStoreMap(I) << "\n";
  }
  LocationCounter++;
}

bool AMDGCNSubmitAddressMessage::runOnModule(Module &M) {
  errs() << "Running AMDGCNSubmitAddressMessage on module: " << M.getName()
         << "\n";

  if (!validateAMDGPUTarget(M)) {
    return false;
  }

  if (!loadAndLinkBitcode(M)) {
    return false;
  }

  // Now v_submit_address should be available inside M

  InstrumentationScope scope;
  if (scope.isActive()) {
    errs() << "Instrumentation scope active: " << scope.size()
           << " definition(s)\n";
  }

  std::vector<ProbeSurrogateSpec> ProbeSpecs = loadProbeSurrogateManifest();
  std::vector<Function *> GpuKernels = collectGPUKernels(M);

  bool ModifiedCodeGen = false;
  for (auto &I : GpuKernels) {
    std::optional<ProbeSurrogateSpec> SurrogateSpec =
        findMemoryOpSurrogateForKernel(ProbeSpecs, I->getName());
    if (SurrogateSpec) {
      errs() << "Using generated memory-op surrogate "
             << SurrogateSpec->surrogate << " for kernel " << I->getName()
             << "\n";
    }
    ValueToValueMapTy VMap;
    Function *NF = cloneKernelWithExtraArg(I, M, VMap);

    // Get the ptr we just added to the kernel arguments
    Value *bufferPtr = getInstrumentationBufferArg(NF);
    if (!bufferPtr) {
      errs() << "Failed to locate instrumentation buffer argument for "
             << NF->getName() << "\n";
      continue;
    }
    uint32_t LocationCounter = 0;
    for (Function::iterator BB = NF->begin(); BB != NF->end(); BB++) {
      for (BasicBlock::iterator I = BB->begin(); I != BB->end(); I++) {
        // Scope filtering: skip instructions outside the scope
        if (scope.isActive()) {
          DILocation *DL = dyn_cast<Instruction>(I)->getDebugLoc();
          if (!DL || !scope.matches(getFullPath(DL), DL->getLine()))
            continue;
        }

        if (dyn_cast<LoadInst>(I) != nullptr) {
          InjectInstrumentationFunction<LoadInst>(I, *NF, M, LocationCounter,
                                                  bufferPtr, true,
                                                  SurrogateSpec ? &*SurrogateSpec
                                                                : nullptr);
          ModifiedCodeGen = true;
        } else if (dyn_cast<StoreInst>(I) != nullptr) {
          InjectInstrumentationFunction<StoreInst>(I, *NF, M, LocationCounter,
                                                   bufferPtr, true,
                                                   SurrogateSpec ? &*SurrogateSpec
                                                                 : nullptr);
          ModifiedCodeGen = true;
        } else if (auto CI = dyn_cast<CallInst>(I)) {
          // Handle AMDGPU buffer intrinsics
          if (isAMDGCNBufferLoad(CI)) {
            InjectBufferInstrumentationFunction(I, *NF, M, LocationCounter,
                                                bufferPtr, true, true,
                                                SurrogateSpec ? &*SurrogateSpec
                                                              : nullptr);
            ModifiedCodeGen = true;
          } else if (isAMDGCNBufferStore(CI)) {
            InjectBufferInstrumentationFunction(I, *NF, M, LocationCounter,
                                                bufferPtr, false, true,
                                                SurrogateSpec ? &*SurrogateSpec
                                                              : nullptr);
            ModifiedCodeGen = true;
          }
        }
      }
    }
  }
  errs() << "Done running AMDGCNSubmitAddressMessage on module: " << M.getName()
         << "\n";
  return ModifiedCodeGen;
}

PassPluginLibraryInfo getPassPluginInfo() {
  const auto callback = [](PassBuilder &PB) {
    PB.registerOptimizerLastEPCallback(
        [&](ModulePassManager &MPM, auto &&...args) {
          MPM.addPass(AMDGCNSubmitAddressMessage());
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
