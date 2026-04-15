#include <hip/hip_runtime.h>

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void check(hipError_t status, const char *what) {
  if (status != hipSuccess) {
    std::cerr << what << ": " << hipGetErrorString(status) << std::endl;
    std::exit(1);
  }
}

}  // namespace

int main(int argc, char **argv) {
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " <hsaco> <kernel-symbol>" << std::endl;
    return 2;
  }

  const std::string hsaco_path = argv[1];
  const std::string kernel_symbol = argv[2];

  hipModule_t module{};
  check(hipModuleLoad(&module, hsaco_path.c_str()), "hipModuleLoad");

  hipFunction_t function{};
  check(hipModuleGetFunction(&function, module, kernel_symbol.c_str()),
        "hipModuleGetFunction");

  hipFuncAttributes attributes{};
  check(hipFuncGetAttributes(&attributes, reinterpret_cast<const void *>(function)),
        "hipFuncGetAttributes");

  std::cout << "resolved " << kernel_symbol << " from " << hsaco_path << "\n";
  std::cout << "numRegs=" << attributes.numRegs
            << " sharedSizeBytes=" << attributes.sharedSizeBytes
            << " maxThreadsPerBlock=" << attributes.maxThreadsPerBlock << "\n";

  check(hipModuleUnload(module), "hipModuleUnload");
  return 0;
}
