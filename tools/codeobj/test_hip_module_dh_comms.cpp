#include <hip/hip_runtime.h>

#include <atomic>
#include <cstddef>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "dh_comms.h"
#include "message.h"
#include "message_handlers.h"

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

enum class LaunchMode {
  kExplicit,
  kHiddenRaw,
};

class CountingHandler : public dh_comms::message_handler_base {
 public:
  CountingHandler(std::atomic<size_t>& total, std::atomic<size_t>& address,
                  std::atomic<size_t>& time_interval)
      : total_(total), address_(address), time_interval_(time_interval) {}

  bool handle(const dh_comms::message_t& message) override {
    total_.fetch_add(1, std::memory_order_relaxed);
    switch (message.wave_header().user_type) {
      case dh_comms::message_type::address:
        address_.fetch_add(1, std::memory_order_relaxed);
        break;
      case dh_comms::message_type::time_interval:
        time_interval_.fetch_add(1, std::memory_order_relaxed);
        break;
      default:
        break;
    }
    return true;
  }

 private:
  std::atomic<size_t>& total_;
  std::atomic<size_t>& address_;
  std::atomic<size_t>& time_interval_;
};

LaunchMode parse_mode(const std::string& mode) {
  if (mode == "explicit") {
    return LaunchMode::kExplicit;
  }
  if (mode == "hidden-raw") {
    return LaunchMode::kHiddenRaw;
  }
  throw std::runtime_error("unsupported mode: " + mode);
}

struct Options {
  const char* hsaco_path = nullptr;
  const char* kernel_name = nullptr;
  LaunchMode mode = LaunchMode::kExplicit;
  size_t raw_kernarg_size = 0;
  size_t hidden_ctx_offset = 0;
  size_t min_address_messages = 1;
};

Options parse_args(int argc, char* argv[]) {
  if (argc < 4) {
    throw std::runtime_error(
        "usage: test_hip_module_dh_comms <hsaco> <kernel-name> "
        "<explicit|hidden-raw> [--raw-kernarg-size <bytes> "
        "--hidden-ctx-offset <bytes>] [--min-address-messages <count>]");
  }

  Options options;
  options.hsaco_path = argv[1];
  options.kernel_name = argv[2];
  options.mode = parse_mode(argv[3]);

  for (int i = 4; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--raw-kernarg-size" && i + 1 < argc) {
      options.raw_kernarg_size = static_cast<size_t>(std::stoull(argv[++i]));
    } else if (arg == "--hidden-ctx-offset" && i + 1 < argc) {
      options.hidden_ctx_offset = static_cast<size_t>(std::stoull(argv[++i]));
    } else if (arg == "--min-address-messages" && i + 1 < argc) {
      options.min_address_messages = static_cast<size_t>(std::stoull(argv[++i]));
    } else {
      throw std::runtime_error("unexpected argument: " + arg);
    }
  }

  if (options.mode == LaunchMode::kHiddenRaw) {
    if (options.raw_kernarg_size == 0) {
      throw std::runtime_error("hidden-raw mode requires --raw-kernarg-size");
    }
    if (options.hidden_ctx_offset + sizeof(void*) > options.raw_kernarg_size) {
      throw std::runtime_error("hidden-ctx-offset falls outside raw kernarg buffer");
    }
  }

  return options;
}

}  // namespace

int main(int argc, char* argv[]) {
  Options options;
  try {
    options = parse_args(argc, argv);
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 2;
  }

  hipModule_t module{};
  CHECK_HIP(hipModuleLoad(&module, options.hsaco_path));

  hipFunction_t kernel{};
  CHECK_HIP(hipModuleGetFunction(&kernel, module, options.kernel_name));

  constexpr size_t blocksize = 64;
  constexpr size_t num_blocks = 4;
  constexpr size_t element_count = blocksize * num_blocks;
  size_t element_count_arg = element_count;

  int* device_data = nullptr;
  CHECK_HIP(hipMalloc(&device_data, element_count * sizeof(int)));
  CHECK_HIP(hipMemset(device_data, 0xff, element_count * sizeof(int)));

  std::atomic<size_t> total_messages{0};
  std::atomic<size_t> address_messages{0};
  std::atomic<size_t> time_interval_messages{0};

  dh_comms::dh_comms comms(64, 32 * 1024, false);
  comms.append_handler(std::make_unique<CountingHandler>(
      total_messages, address_messages, time_interval_messages));
  auto* dev_ctx = comms.get_dev_rsrc_ptr();
  comms.start(options.kernel_name);

  if (options.mode == LaunchMode::kExplicit) {
    void* args[] = {
        &device_data,
        &element_count_arg,
        &dev_ctx,
    };
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        num_blocks, 1, 1,
        blocksize, 1, 1,
        0,
        nullptr,
        args,
        nullptr));
  } else {
    std::vector<std::byte> kernarg(options.raw_kernarg_size, std::byte{0});
    std::memcpy(kernarg.data(), &device_data, sizeof(device_data));
    std::memcpy(kernarg.data() + sizeof(device_data), &element_count_arg,
                sizeof(element_count_arg));
    std::memcpy(kernarg.data() + options.hidden_ctx_offset, &dev_ctx,
                sizeof(dev_ctx));
    size_t kernarg_bytes = kernarg.size();
    void* config[] = {
        HIP_LAUNCH_PARAM_BUFFER_POINTER,
        kernarg.data(),
        HIP_LAUNCH_PARAM_BUFFER_SIZE,
        &kernarg_bytes,
        HIP_LAUNCH_PARAM_END,
    };
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        num_blocks, 1, 1,
        blocksize, 1, 1,
        0,
        nullptr,
        nullptr,
        config));
  }

  CHECK_HIP(hipDeviceSynchronize());
  comms.stop();

  std::vector<int> host_data(element_count);
  CHECK_HIP(hipMemcpy(host_data.data(), device_data, element_count * sizeof(int),
                      hipMemcpyDeviceToHost));

  bool ok = true;
  for (size_t i = 0; i < element_count; ++i) {
    if (host_data[i] != static_cast<int>(i)) {
      std::cerr << "mismatch[" << i << "] expected=" << i
                << " got=" << host_data[i] << std::endl;
      ok = false;
      break;
    }
  }

  const size_t observed_total = total_messages.load(std::memory_order_relaxed);
  const size_t observed_address =
      address_messages.load(std::memory_order_relaxed);
  const size_t observed_time_interval =
      time_interval_messages.load(std::memory_order_relaxed);

  CHECK_HIP(hipFree(device_data));
  comms.delete_handlers();
  CHECK_HIP(hipModuleUnload(module));

  std::cout << "kernel=" << options.kernel_name
            << " mode=" << (options.mode == LaunchMode::kExplicit ? "explicit"
                                                                  : "hidden-raw")
            << " total_messages=" << observed_total
            << " address_messages=" << observed_address
            << " time_interval_messages=" << observed_time_interval
            << std::endl;

  if (!ok) {
    return 1;
  }
  if (observed_address < options.min_address_messages) {
    std::cerr << "expected at least " << options.min_address_messages
              << " address messages, observed " << observed_address
              << std::endl;
    return 1;
  }
  return 0;
}
