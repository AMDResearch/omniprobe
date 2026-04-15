#include <fcntl.h>
#include <hsa/hsa.h>

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

void check(hsa_status_t status, const char* what) {
  if (status != HSA_STATUS_SUCCESS) {
    const char* message = nullptr;
    hsa_status_string(status, &message);
    std::cerr << what << ": "
              << (message ? message : "unknown HSA error") << std::endl;
    std::exit(1);
  }
}

struct AgentSearch {
  hsa_agent_t agent{};
  bool found = false;
};

hsa_status_t find_gpu_agent(hsa_agent_t agent, void* data) {
  auto* search = static_cast<AgentSearch*>(data);
  hsa_device_type_t device_type{};
  if (hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type) !=
      HSA_STATUS_SUCCESS) {
    return HSA_STATUS_SUCCESS;
  }
  if (device_type == HSA_DEVICE_TYPE_GPU && !search->found) {
    search->agent = agent;
    search->found = true;
  }
  return HSA_STATUS_SUCCESS;
}

std::string symbol_name(hsa_executable_symbol_t symbol) {
  uint32_t length = 0;
  check(hsa_executable_symbol_get_info(
            symbol, HSA_EXECUTABLE_SYMBOL_INFO_NAME_LENGTH, &length),
        "HSA_EXECUTABLE_SYMBOL_INFO_NAME_LENGTH");
  std::string result(length, '\0');
  check(hsa_executable_symbol_get_info(symbol, HSA_EXECUTABLE_SYMBOL_INFO_NAME,
                                       result.data()),
        "HSA_EXECUTABLE_SYMBOL_INFO_NAME");
  return result;
}

void print_kernel_symbol(hsa_executable_symbol_t symbol) {
  const std::string name = symbol_name(symbol);
  uint64_t kernel_object = 0;
  uint32_t kernarg_size = 0;
  uint32_t group_segment_size = 0;
  uint32_t private_segment_size = 0;
  check(hsa_executable_symbol_get_info(
            symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT, &kernel_object),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT");
  check(hsa_executable_symbol_get_info(
            symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE,
            &kernarg_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE");
  check(hsa_executable_symbol_get_info(
            symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE,
            &group_segment_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE");
  check(hsa_executable_symbol_get_info(
            symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE,
            &private_segment_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE");

  std::cout << name << " kernel_object=0x" << std::hex << kernel_object
            << std::dec << " kernarg=" << kernarg_size
            << " group=" << group_segment_size
            << " private=" << private_segment_size << "\n";
}

struct SymbolSearch {
  std::string wanted;
  bool matched = false;
};

hsa_status_t collect_symbols(hsa_executable_t, hsa_executable_symbol_t symbol,
                             void* data) {
  auto* search = static_cast<SymbolSearch*>(data);
  hsa_symbol_kind_t kind{};
  check(hsa_executable_symbol_get_info(symbol, HSA_EXECUTABLE_SYMBOL_INFO_TYPE,
                                       &kind),
        "HSA_EXECUTABLE_SYMBOL_INFO_TYPE");
  if (kind != HSA_SYMBOL_KIND_KERNEL) {
    return HSA_STATUS_SUCCESS;
  }

  const std::string name = symbol_name(symbol);
  print_kernel_symbol(symbol);
  if (!search->wanted.empty() && name == search->wanted) {
    search->matched = true;
  }
  return HSA_STATUS_SUCCESS;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2 && argc != 3) {
    std::cerr << "usage: " << argv[0] << " <hsaco> [kernel-symbol]" << std::endl;
    return 2;
  }

  const std::string hsaco_path = argv[1];
  const std::string wanted_symbol = argc == 3 ? argv[2] : "";

  check(hsa_init(), "hsa_init");

  AgentSearch search{};
  check(hsa_iterate_agents(find_gpu_agent, &search), "hsa_iterate_agents");
  if (!search.found) {
    std::cerr << "no GPU agent found" << std::endl;
    hsa_shut_down();
    return 1;
  }

  const int fd = open(hsaco_path.c_str(), O_RDONLY);
  if (fd < 0) {
    std::perror("open");
    hsa_shut_down();
    return 1;
  }

  hsa_code_object_reader_t reader{};
  check(hsa_code_object_reader_create_from_file(fd, &reader),
        "hsa_code_object_reader_create_from_file");

  hsa_executable_t executable{};
  check(hsa_executable_create_alt(HSA_PROFILE_FULL,
                                  HSA_DEFAULT_FLOAT_ROUNDING_MODE_DEFAULT,
                                  nullptr, &executable),
        "hsa_executable_create_alt");
  check(hsa_executable_load_agent_code_object(executable, search.agent, reader,
                                              nullptr, nullptr),
        "hsa_executable_load_agent_code_object");
  check(hsa_executable_freeze(executable, ""), "hsa_executable_freeze");

  SymbolSearch symbol_search{wanted_symbol, false};
  check(hsa_executable_iterate_symbols(executable, collect_symbols,
                                       &symbol_search),
        "hsa_executable_iterate_symbols");

  if (!wanted_symbol.empty()) {
    std::cout << (symbol_search.matched ? "matched " : "missing ")
              << wanted_symbol << "\n";
  }

  check(hsa_executable_destroy(executable), "hsa_executable_destroy");
  close(fd);
  check(hsa_shut_down(), "hsa_shut_down");
  return symbol_search.matched || wanted_symbol.empty() ? 0 : 1;
}
