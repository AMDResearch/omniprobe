#include <hip/hip_runtime.h>

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#define CHECK_HIP(call)                                                        \
  do {                                                                         \
    hipError_t err__ = (call);                                                 \
    if (err__ != hipSuccess) {                                                 \
      std::cerr << #call << " failed: " << hipGetErrorString(err__)            \
                << std::endl;                                                  \
      return 1;                                                                \
    }                                                                          \
  } while (0)

namespace {

enum class Expectation {
  kIndex,
  kZero,
  kFirstBlockOnly,
  kUntouched,
};

Expectation parse_expectation(const std::string& value) {
  if (value == "index") {
    return Expectation::kIndex;
  }
  if (value == "zero") {
    return Expectation::kZero;
  }
  if (value == "first-block-only") {
    return Expectation::kFirstBlockOnly;
  }
  if (value == "untouched") {
    return Expectation::kUntouched;
  }
  throw std::runtime_error("unsupported expectation: " + value);
}

int expected_value(Expectation expectation, size_t index) {
  switch (expectation) {
    case Expectation::kIndex:
      return static_cast<int>(index);
    case Expectation::kZero:
      return 0;
    case Expectation::kFirstBlockOnly:
      return index < 64 ? static_cast<int>(index) : -1;
    case Expectation::kUntouched:
      return -1;
  }
  return 0;
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc != 3 && argc != 4 && argc != 8) {
    std::cerr << "usage: " << argv[0]
              << " <hsaco> <kernel-name> [index|zero|first-block-only|untouched]"
              << "\n   or: " << argv[0]
              << " <hsaco> <kernel-name> <expectation> --raw-kernarg-size <bytes> --hidden-ctx-offset <bytes>"
              << std::endl;
    return 2;
  }

  const char* hsaco_path = argv[1];
  const char* kernel_name = argv[2];
  const Expectation expectation =
      argc == 4 ? parse_expectation(argv[3]) : Expectation::kIndex;
  bool use_raw_kernarg = false;
  size_t raw_kernarg_size = 0;
  size_t hidden_ctx_offset = 0;
  if (argc == 8) {
    if (std::string(argv[4]) != "--raw-kernarg-size" ||
        std::string(argv[6]) != "--hidden-ctx-offset") {
      std::cerr << "unexpected raw-kernarg arguments" << std::endl;
      return 2;
    }
    use_raw_kernarg = true;
    raw_kernarg_size = static_cast<size_t>(std::stoull(argv[5]));
    hidden_ctx_offset = static_cast<size_t>(std::stoull(argv[7]));
    if (raw_kernarg_size < sizeof(void*) * 2 ||
        hidden_ctx_offset + sizeof(void*) > raw_kernarg_size) {
      std::cerr << "invalid raw kernarg layout" << std::endl;
      return 2;
    }
  }

  hipModule_t module{};
  CHECK_HIP(hipModuleLoad(&module, hsaco_path));

  hipFunction_t kernel{};
  CHECK_HIP(hipModuleGetFunction(&kernel, module, kernel_name));

  constexpr size_t blocksize = 64;
  constexpr size_t num_blocks = 4;
  constexpr size_t size = blocksize * num_blocks;

  int* device_data = nullptr;
  CHECK_HIP(hipMalloc(&device_data, size * sizeof(int)));
  CHECK_HIP(hipMemset(device_data, 0xff, size * sizeof(int)));
  void* hidden_ctx = nullptr;
  if (use_raw_kernarg) {
    CHECK_HIP(hipMalloc(&hidden_ctx, sizeof(uint64_t)));
    CHECK_HIP(hipMemset(hidden_ctx, 0, sizeof(uint64_t)));
  }

  if (use_raw_kernarg) {
    std::vector<std::byte> kernarg(raw_kernarg_size, std::byte{0});
    std::memcpy(kernarg.data(), &device_data, sizeof(device_data));
    std::memcpy(kernarg.data() + sizeof(device_data), &size, sizeof(size));
    std::memcpy(kernarg.data() + hidden_ctx_offset, &hidden_ctx, sizeof(hidden_ctx));
    size_t kernarg_bytes = kernarg.size();
    void* config[] = {
        HIP_LAUNCH_PARAM_BUFFER_POINTER,
        kernarg.data(),
        HIP_LAUNCH_PARAM_BUFFER_SIZE,
        &kernarg_bytes,
        HIP_LAUNCH_PARAM_END};
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        num_blocks, 1, 1,
        blocksize, 1, 1,
        0,
        nullptr,
        nullptr,
        config));
  } else {
    void* args[] = {&device_data, const_cast<size_t*>(&size)};
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        num_blocks, 1, 1,
        blocksize, 1, 1,
        0,
        nullptr,
        args,
        nullptr));
  }
  CHECK_HIP(hipDeviceSynchronize());

  std::vector<int> host_data(size);
  CHECK_HIP(hipMemcpy(host_data.data(), device_data, size * sizeof(int),
                      hipMemcpyDeviceToHost));

  bool ok = true;
  for (size_t i = 0; i < size; ++i) {
    const int expected = expected_value(expectation, i);
    if (host_data[i] != expected) {
      std::cerr << "mismatch[" << i << "] expected=" << expected
                << " got=" << host_data[i] << std::endl;
      ok = false;
      break;
    }
  }

  CHECK_HIP(hipFree(device_data));
  if (hidden_ctx != nullptr) {
    CHECK_HIP(hipFree(hidden_ctx));
  }
  CHECK_HIP(hipModuleUnload(module));

  if (!ok) {
    return 1;
  }
  std::cout << "PASS kernel=" << kernel_name
            << " expectation="
            << (expectation == Expectation::kIndex
                    ? "index"
                    : (expectation == Expectation::kZero
                           ? "zero"
                           : (expectation == Expectation::kFirstBlockOnly ? "first-block-only"
                                                                          : "untouched")))
            << std::endl;
  return 0;
}
