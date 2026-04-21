#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kQueueSize = 64;
constexpr uint32_t kDefaultWorkgroupSize = 64;
constexpr size_t kDefaultElementCount = 256;
constexpr size_t kHiddenBlockCountXOffset = 16;
constexpr size_t kHiddenBlockCountYOffset = 20;
constexpr size_t kHiddenBlockCountZOffset = 24;
constexpr size_t kHiddenGroupSizeXOffset = 28;
constexpr size_t kHiddenGroupSizeYOffset = 30;
constexpr size_t kHiddenGroupSizeZOffset = 32;
constexpr size_t kHiddenRemainderXOffset = 34;
constexpr size_t kHiddenRemainderYOffset = 36;
constexpr size_t kHiddenRemainderZOffset = 38;
constexpr size_t kHiddenGlobalOffsetXOffset = 56;
constexpr size_t kHiddenGlobalOffsetYOffset = 64;
constexpr size_t kHiddenGlobalOffsetZOffset = 72;
constexpr size_t kHiddenGridDimsOffset = 80;

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

void check(hsa_status_t status, const char* what) {
  if (status != HSA_STATUS_SUCCESS) {
    const char* message = nullptr;
    hsa_status_string(status, &message);
    std::cerr << what << ": "
              << (message ? message : "unknown HSA error") << std::endl;
    std::exit(1);
  }
}

struct AgentSelection {
  hsa_agent_t cpu{};
  hsa_agent_t gpu{};
  bool have_cpu = false;
  bool have_gpu = false;
};

hsa_status_t find_agents(hsa_agent_t agent, void* data) {
  auto* selection = static_cast<AgentSelection*>(data);
  hsa_device_type_t type{};
  if (hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type) !=
      HSA_STATUS_SUCCESS) {
    return HSA_STATUS_SUCCESS;
  }
  if (type == HSA_DEVICE_TYPE_CPU && !selection->have_cpu) {
    selection->cpu = agent;
    selection->have_cpu = true;
  } else if (type == HSA_DEVICE_TYPE_GPU && !selection->have_gpu) {
    selection->gpu = agent;
    selection->have_gpu = true;
  }
  return HSA_STATUS_SUCCESS;
}

std::string agent_name(hsa_agent_t agent) {
  std::array<char, 64> name{};
  check(hsa_agent_get_info(agent, HSA_AGENT_INFO_NAME, name.data()),
        "HSA_AGENT_INFO_NAME");
  return std::string(name.data());
}

struct PoolSelection {
  hsa_amd_memory_pool_t pool{};
  size_t granule = 1;
  bool found = false;
};

hsa_status_t find_kernarg_pool(hsa_amd_memory_pool_t pool, void* data) {
  auto* selection = static_cast<PoolSelection*>(data);
  if (selection->found) {
    return HSA_STATUS_SUCCESS;
  }
  hsa_amd_segment_t segment{};
  bool alloc_allowed = false;
  uint32_t flags = 0;
  size_t granule = 1;
  check(hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SEGMENT,
                                     &segment),
        "HSA_AMD_MEMORY_POOL_INFO_SEGMENT");
  check(hsa_amd_memory_pool_get_info(
            pool, HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_ALLOWED,
            &alloc_allowed),
        "HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_ALLOWED");
  check(hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS,
                                     &flags),
        "HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS");
  check(hsa_amd_memory_pool_get_info(
            pool, HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_GRANULE, &granule),
        "HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_GRANULE");
  if (segment == HSA_AMD_SEGMENT_GLOBAL && alloc_allowed &&
      (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT)) {
    selection->pool = pool;
    selection->granule = granule;
    selection->found = true;
  }
  return HSA_STATUS_SUCCESS;
}

hsa_status_t find_device_pool(hsa_amd_memory_pool_t pool, void* data) {
  auto* selection = static_cast<PoolSelection*>(data);
  if (selection->found) {
    return HSA_STATUS_SUCCESS;
  }
  hsa_amd_segment_t segment{};
  bool alloc_allowed = false;
  uint32_t flags = 0;
  size_t granule = 1;
  check(hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SEGMENT,
                                     &segment),
        "HSA_AMD_MEMORY_POOL_INFO_SEGMENT");
  check(hsa_amd_memory_pool_get_info(
            pool, HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_ALLOWED,
            &alloc_allowed),
        "HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_ALLOWED");
  check(hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS,
                                     &flags),
        "HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS");
  check(hsa_amd_memory_pool_get_info(
            pool, HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_GRANULE, &granule),
        "HSA_AMD_MEMORY_POOL_INFO_RUNTIME_ALLOC_GRANULE");
  if (segment == HSA_AMD_SEGMENT_GLOBAL && alloc_allowed &&
      (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_COARSE_GRAINED)) {
    selection->pool = pool;
    selection->granule = granule;
    selection->found = true;
  }
  return HSA_STATUS_SUCCESS;
}

size_t round_up(size_t value, size_t granule) {
  const size_t mask = granule - 1;
  return (value + mask) & ~mask;
}

void* allocate_pool(hsa_amd_memory_pool_t pool, size_t granule, size_t size) {
  void* ptr = nullptr;
  check(hsa_amd_memory_pool_allocate(pool, round_up(size, granule), 0, &ptr),
        "hsa_amd_memory_pool_allocate");
  return ptr;
}

void allow_access(const std::vector<hsa_agent_t>& agents, const void* ptr) {
  check(hsa_amd_agents_allow_access(static_cast<uint32_t>(agents.size()),
                                    agents.data(), nullptr, ptr),
        "hsa_amd_agents_allow_access");
}

template <typename T>
void write_scalar(std::vector<std::byte>& buffer, size_t offset, T value) {
  if (offset + sizeof(T) <= buffer.size()) {
    std::memcpy(buffer.data() + offset, &value, sizeof(T));
  }
}

struct SymbolInfo {
  hsa_executable_symbol_t symbol{};
  uint64_t kernel_object = 0;
  uint32_t kernarg_size = 0;
  uint32_t group_segment_size = 0;
  uint32_t private_segment_size = 0;
};

bool try_load_symbol(hsa_executable_t executable, hsa_agent_t gpu,
                     const std::string& symbol_name, SymbolInfo* info) {
  hsa_executable_symbol_t symbol{};
  const hsa_status_t status =
      hsa_executable_get_symbol_by_name(executable, symbol_name.c_str(), &gpu,
                                        &symbol);
  if (status != HSA_STATUS_SUCCESS) {
    return false;
  }
  info->symbol = symbol;
  check(hsa_executable_symbol_get_info(
            info->symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT,
            &info->kernel_object),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT");
  check(hsa_executable_symbol_get_info(
            info->symbol,
            HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE,
            &info->kernarg_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE");
  check(hsa_executable_symbol_get_info(
            info->symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE,
            &info->group_segment_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE");
  check(hsa_executable_symbol_get_info(
            info->symbol,
            HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE,
            &info->private_segment_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE");
  return true;
}

SymbolInfo load_symbol(hsa_executable_t executable, hsa_agent_t gpu,
                       const std::string& symbol_name) {
  SymbolInfo info{};
  if (try_load_symbol(executable, gpu, symbol_name, &info)) {
    return info;
  }
  if (!symbol_name.ends_with(".kd") &&
      try_load_symbol(executable, gpu, symbol_name + ".kd", &info)) {
    return info;
  }
  std::cerr << "failed to locate HSA kernel symbol " << symbol_name << std::endl;
  std::exit(1);
}

void wait_for_queue_slot(const hsa_queue_t* queue, uint64_t write_index) {
  while (write_index - hsa_queue_load_read_index_scacquire(queue) >=
         queue->size) {
  }
}

void dispatch_kernel(hsa_queue_t* queue, const SymbolInfo& symbol,
                     const void* kernarg, uint32_t grid_size_x,
                     uint32_t grid_size_y, uint32_t grid_size_z,
                     uint16_t workgroup_size_x, uint16_t workgroup_size_y,
                     uint16_t workgroup_size_z) {
  hsa_signal_t completion{};
  check(hsa_signal_create(1, 0, nullptr, &completion), "hsa_signal_create");

  const uint64_t write_index = hsa_queue_add_write_index_scacq_screl(queue, 1);
  wait_for_queue_slot(queue, write_index);
  const uint64_t packet_id = write_index & (queue->size - 1);
  auto* packet = reinterpret_cast<hsa_kernel_dispatch_packet_t*>(
      queue->base_address) +
                 packet_id;
  std::memset(packet, 0, sizeof(*packet));

  const uint16_t dimensions =
      grid_size_z > 1 ? 3 : (grid_size_y > 1 ? 2 : 1);
  packet->setup = 1u << HSA_KERNEL_DISPATCH_PACKET_SETUP_DIMENSIONS;
  packet->setup = dimensions << HSA_KERNEL_DISPATCH_PACKET_SETUP_DIMENSIONS;
  packet->workgroup_size_x = workgroup_size_x;
  packet->workgroup_size_y = workgroup_size_y;
  packet->workgroup_size_z = workgroup_size_z;
  packet->grid_size_x = grid_size_x;
  packet->grid_size_y = grid_size_y;
  packet->grid_size_z = grid_size_z;
  packet->private_segment_size = symbol.private_segment_size;
  packet->group_segment_size = symbol.group_segment_size;
  packet->kernel_object = symbol.kernel_object;
  packet->kernarg_address = const_cast<void*>(kernarg);
  packet->completion_signal = completion;

  const uint16_t header =
      (HSA_PACKET_TYPE_KERNEL_DISPATCH << HSA_PACKET_HEADER_TYPE) |
      (HSA_FENCE_SCOPE_SYSTEM << HSA_PACKET_HEADER_SCACQUIRE_FENCE_SCOPE) |
      (HSA_FENCE_SCOPE_SYSTEM << HSA_PACKET_HEADER_SCRELEASE_FENCE_SCOPE);
  __atomic_store_n(&packet->header, header, __ATOMIC_RELEASE);

  hsa_signal_store_screlease(queue->doorbell_signal, write_index);
  const hsa_signal_value_t observed =
      hsa_signal_wait_scacquire(completion, HSA_SIGNAL_CONDITION_LT, 1,
                                std::numeric_limits<uint64_t>::max(),
                                HSA_WAIT_STATE_BLOCKED);
  if (observed >= 1) {
    std::cerr << "hsa_signal_wait_scacquire: timed out with signal="
              << observed << std::endl;
    std::exit(1);
  }
  check(hsa_signal_destroy(completion), "hsa_signal_destroy");
}

uint16_t derive_grid_dims(uint32_t grid_size_y, uint32_t grid_size_z) {
  if (grid_size_z > 1) {
    return 3;
  }
  if (grid_size_y > 1) {
    return 2;
  }
  return 1;
}

void populate_opencl_hidden_args(std::vector<std::byte>& kernarg, uint32_t grid_size_x,
                                 uint32_t grid_size_y, uint32_t grid_size_z,
                                 uint16_t workgroup_size_x,
                                 uint16_t workgroup_size_y,
                                 uint16_t workgroup_size_z) {
  const uint32_t block_count_x =
      workgroup_size_x ? (grid_size_x / workgroup_size_x) : 0;
  const uint16_t remainder_x =
      workgroup_size_x ? static_cast<uint16_t>(grid_size_x % workgroup_size_x) : 0;
  const uint32_t block_count_y =
      workgroup_size_y ? (grid_size_y / workgroup_size_y) : 0;
  const uint32_t block_count_z =
      workgroup_size_z ? (grid_size_z / workgroup_size_z) : 0;
  const uint16_t group_size_x = workgroup_size_x;
  const uint16_t group_size_y = workgroup_size_y;
  const uint16_t group_size_z = workgroup_size_z;
  const uint16_t remainder_y =
      workgroup_size_y ? static_cast<uint16_t>(grid_size_y % workgroup_size_y) : 0;
  const uint16_t remainder_z =
      workgroup_size_z ? static_cast<uint16_t>(grid_size_z % workgroup_size_z) : 0;
  const uint64_t global_offset = 0;
  const uint16_t grid_dims = derive_grid_dims(grid_size_y, grid_size_z);

  write_scalar(kernarg, kHiddenBlockCountXOffset, block_count_x);
  write_scalar(kernarg, kHiddenBlockCountYOffset, block_count_y);
  write_scalar(kernarg, kHiddenBlockCountZOffset, block_count_z);
  write_scalar(kernarg, kHiddenGroupSizeXOffset, group_size_x);
  write_scalar(kernarg, kHiddenGroupSizeYOffset, group_size_y);
  write_scalar(kernarg, kHiddenGroupSizeZOffset, group_size_z);
  write_scalar(kernarg, kHiddenRemainderXOffset, remainder_x);
  write_scalar(kernarg, kHiddenRemainderYOffset, remainder_y);
  write_scalar(kernarg, kHiddenRemainderZOffset, remainder_z);
  write_scalar(kernarg, kHiddenGlobalOffsetXOffset, global_offset);
  write_scalar(kernarg, kHiddenGlobalOffsetYOffset, global_offset);
  write_scalar(kernarg, kHiddenGlobalOffsetZOffset, global_offset);
  write_scalar(kernarg, kHiddenGridDimsOffset, grid_dims);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::cerr << "usage: " << argv[0]
              << " <hsaco> <kernel-symbol> <index|zero|first-block-only|untouched>"
              << " [--hidden-ctx-offset <bytes> [--populate-original-kernarg-pointer]"
              << " [--populate-workgroup-id-x <value>] [--single-workgroup]"
              << " [--single-wave]"
              << " [--workgroup-size-x <n>] [--workgroup-size-y <n>] [--workgroup-size-z <n>]]"
              << std::endl;
    return 2;
  }

  const std::string hsaco_path = argv[1];
  const std::string symbol_name = argv[2];
  const Expectation expectation = parse_expectation(argv[3]);

  bool use_hidden_ctx = false;
  bool populate_original_kernarg_pointer = false;
  bool single_workgroup = false;
  bool single_wave = false;
  bool populate_workgroup_id_x = false;
  size_t hidden_ctx_offset = 0;
  uint32_t workgroup_id_x_value = 0;
  std::vector<std::pair<size_t, uint32_t>> verify_hidden_u32_checks;
  std::vector<size_t> verify_hidden_u32_nonzero_checks;
  uint16_t workgroup_size_x = static_cast<uint16_t>(kDefaultWorkgroupSize);
  uint16_t workgroup_size_y = 1;
  uint16_t workgroup_size_z = 1;
  for (int index = 4; index < argc; ++index) {
    const std::string arg = argv[index];
    if (arg == "--hidden-ctx-offset") {
      if (index + 1 >= argc) {
        std::cerr << "missing value for --hidden-ctx-offset" << std::endl;
        return 2;
      }
      hidden_ctx_offset = static_cast<size_t>(std::stoull(argv[++index]));
      use_hidden_ctx = true;
      continue;
    }
    if (arg == "--populate-original-kernarg-pointer") {
      populate_original_kernarg_pointer = true;
      continue;
    }
    if (arg == "--populate-workgroup-id-x") {
      if (index + 1 >= argc) {
        std::cerr << "missing value for --populate-workgroup-id-x" << std::endl;
        return 2;
      }
      workgroup_id_x_value = static_cast<uint32_t>(std::stoul(argv[++index]));
      populate_workgroup_id_x = true;
      continue;
    }
    if (arg == "--single-workgroup") {
      single_workgroup = true;
      continue;
    }
    if (arg == "--single-wave") {
      single_wave = true;
      continue;
    }
    if (arg == "--workgroup-size-x") {
      if (index + 1 >= argc) {
        std::cerr << "missing value for --workgroup-size-x" << std::endl;
        return 2;
      }
      workgroup_size_x = static_cast<uint16_t>(std::stoul(argv[++index]));
      continue;
    }
    if (arg == "--workgroup-size-y") {
      if (index + 1 >= argc) {
        std::cerr << "missing value for --workgroup-size-y" << std::endl;
        return 2;
      }
      workgroup_size_y = static_cast<uint16_t>(std::stoul(argv[++index]));
      continue;
    }
    if (arg == "--workgroup-size-z") {
      if (index + 1 >= argc) {
        std::cerr << "missing value for --workgroup-size-z" << std::endl;
        return 2;
      }
      workgroup_size_z = static_cast<uint16_t>(std::stoul(argv[++index]));
      continue;
    }
    if (arg == "--verify-hidden-u32") {
      if (index + 2 >= argc) {
        std::cerr << "missing values for --verify-hidden-u32" << std::endl;
        return 2;
      }
      const size_t verify_hidden_u32_offset =
          static_cast<size_t>(std::stoull(argv[++index]));
      const uint32_t verify_hidden_u32_value =
          static_cast<uint32_t>(std::stoul(argv[++index]));
      verify_hidden_u32_checks.emplace_back(verify_hidden_u32_offset,
                                            verify_hidden_u32_value);
      continue;
    }
    if (arg == "--verify-hidden-u32-nonzero") {
      if (index + 1 >= argc) {
        std::cerr << "missing value for --verify-hidden-u32-nonzero" << std::endl;
        return 2;
      }
      const size_t verify_hidden_u32_offset =
          static_cast<size_t>(std::stoull(argv[++index]));
      verify_hidden_u32_nonzero_checks.push_back(verify_hidden_u32_offset);
      continue;
    }
    std::cerr << "unknown argument: " << arg << std::endl;
    return 2;
  }
  if ((populate_original_kernarg_pointer || populate_workgroup_id_x ||
       !verify_hidden_u32_checks.empty() ||
       !verify_hidden_u32_nonzero_checks.empty()) &&
      !use_hidden_ctx) {
    std::cerr << "hidden handoff population requires --hidden-ctx-offset"
              << std::endl;
    return 2;
  }
  if (single_wave) {
    single_workgroup = true;
    workgroup_size_x = 32;
    workgroup_size_y = 1;
    workgroup_size_z = 1;
  }
  const uint32_t grid_size_x = single_workgroup ? workgroup_size_x : static_cast<uint32_t>(kDefaultElementCount);
  const uint32_t grid_size_y = single_workgroup ? workgroup_size_y : 1;
  const uint32_t grid_size_z = single_workgroup ? workgroup_size_z : 1;
  const size_t element_count =
      static_cast<size_t>(grid_size_x) * static_cast<size_t>(grid_size_y) * static_cast<size_t>(grid_size_z);

  check(hsa_init(), "hsa_init");

  AgentSelection agents{};
  check(hsa_iterate_agents(find_agents, &agents), "hsa_iterate_agents");
  if (!agents.have_cpu || !agents.have_gpu) {
    std::cerr << "failed to find both CPU and GPU agents" << std::endl;
    check(hsa_shut_down(), "hsa_shut_down");
    return 1;
  }

  PoolSelection kernarg_pool{};
  PoolSelection device_pool{};
  check(hsa_amd_agent_iterate_memory_pools(agents.cpu, find_kernarg_pool,
                                           &kernarg_pool),
        "hsa_amd_agent_iterate_memory_pools(cpu)");
  check(hsa_amd_agent_iterate_memory_pools(agents.gpu, find_device_pool,
                                           &device_pool),
        "hsa_amd_agent_iterate_memory_pools(gpu)");
  if (!kernarg_pool.found || !device_pool.found) {
    std::cerr << "failed to find required memory pools" << std::endl;
    check(hsa_shut_down(), "hsa_shut_down");
    return 1;
  }

  const int fd = open(hsaco_path.c_str(), O_RDONLY);
  if (fd < 0) {
    std::perror("open");
    check(hsa_shut_down(), "hsa_shut_down");
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
  check(hsa_executable_load_agent_code_object(executable, agents.gpu, reader,
                                              nullptr, nullptr),
        "hsa_executable_load_agent_code_object");
  check(hsa_executable_freeze(executable, ""), "hsa_executable_freeze");

  const SymbolInfo symbol = load_symbol(executable, agents.gpu, symbol_name);
  std::cout << "CPU agent: " << agent_name(agents.cpu) << "\n";
  std::cout << "GPU agent: " << agent_name(agents.gpu) << "\n";
  std::cout << symbol_name << " kernel_object=0x" << std::hex
            << symbol.kernel_object << std::dec
            << " kernarg=" << symbol.kernarg_size
            << " group=" << symbol.group_segment_size
            << " private=" << symbol.private_segment_size << "\n";

  std::vector<int> host_data(element_count, -1);
  void* device_data =
      allocate_pool(device_pool.pool, device_pool.granule,
                    host_data.size() * sizeof(host_data[0]));
  allow_access({agents.cpu, agents.gpu}, device_data);
  std::vector<int> initial_data(element_count, -1);
  check(hsa_memory_copy(device_data, initial_data.data(),
                        initial_data.size() * sizeof(initial_data[0])),
        "hsa_memory_copy(host->dst)");

  void* hidden_ctx = nullptr;
  if (use_hidden_ctx) {
    hidden_ctx = allocate_pool(device_pool.pool, device_pool.granule, 64);
    allow_access({agents.cpu, agents.gpu}, hidden_ctx);
    std::memset(hidden_ctx, 0, 64);
  }

  std::vector<std::byte> kernarg(symbol.kernarg_size, std::byte{0});
  if (symbol.kernarg_size < sizeof(void*) + sizeof(size_t)) {
    std::cerr << "kernarg segment too small for module-load kernel contract"
              << std::endl;
    return 1;
  }
  const size_t size_value = host_data.size();
  std::memcpy(kernarg.data(), &device_data, sizeof(device_data));
  std::memcpy(kernarg.data() + sizeof(device_data), &size_value, sizeof(size_value));
  populate_opencl_hidden_args(
      kernarg, grid_size_x, grid_size_y, grid_size_z,
      workgroup_size_x, workgroup_size_y, workgroup_size_z);
  if (use_hidden_ctx) {
    if (hidden_ctx_offset + sizeof(void*) > kernarg.size()) {
      std::cerr << "hidden ctx offset exceeds kernarg size" << std::endl;
      return 2;
    }
    std::memcpy(kernarg.data() + hidden_ctx_offset, &hidden_ctx, sizeof(hidden_ctx));
  }

  void* kernarg_buffer =
      allocate_pool(kernarg_pool.pool, kernarg_pool.granule, kernarg.size());
  allow_access({agents.gpu}, kernarg_buffer);
  if (populate_original_kernarg_pointer) {
    std::memcpy(hidden_ctx, &kernarg_buffer, sizeof(kernarg_buffer));
    std::cout << "hidden ctx offset=" << hidden_ctx_offset
              << " original_kernarg_pointer=0x" << std::hex
              << reinterpret_cast<uintptr_t>(kernarg_buffer) << std::dec << "\n";
  }
  if (populate_workgroup_id_x) {
    std::memcpy(static_cast<std::byte*>(hidden_ctx) + 8, &workgroup_id_x_value,
                sizeof(workgroup_id_x_value));
    std::cout << "hidden ctx workgroup_id_x=" << workgroup_id_x_value << "\n";
  }
  std::memcpy(kernarg_buffer, kernarg.data(), kernarg.size());

  hsa_queue_t* queue = nullptr;
  check(hsa_queue_create(agents.gpu, kQueueSize, HSA_QUEUE_TYPE_SINGLE, nullptr,
                         nullptr, UINT32_MAX, UINT32_MAX, &queue),
        "hsa_queue_create");
  dispatch_kernel(queue, symbol, kernarg_buffer,
                  grid_size_x, grid_size_y, grid_size_z,
                  workgroup_size_x, workgroup_size_y, workgroup_size_z);

  check(hsa_memory_copy(host_data.data(), device_data,
                        host_data.size() * sizeof(host_data[0])),
        "hsa_memory_copy(dst->host)");

  bool ok = true;
  for (const auto& [verify_hidden_u32_offset, verify_hidden_u32_value] :
       verify_hidden_u32_checks) {
    uint32_t observed = 0;
    check(hsa_memory_copy(&observed,
                          static_cast<std::byte*>(hidden_ctx) + verify_hidden_u32_offset,
                          sizeof(observed)),
          "hsa_memory_copy(hidden_ctx->host)");
    std::cout << "hidden ctx u32[" << verify_hidden_u32_offset
              << "]=" << observed << "\n";
    if (observed != verify_hidden_u32_value) {
      std::cerr << "hidden ctx mismatch offset=" << verify_hidden_u32_offset
                << " expected=" << verify_hidden_u32_value
                << " got=" << observed << std::endl;
      ok = false;
    }
  }
  for (const size_t verify_hidden_u32_offset : verify_hidden_u32_nonzero_checks) {
    uint32_t observed = 0;
    check(hsa_memory_copy(&observed,
                          static_cast<std::byte*>(hidden_ctx) + verify_hidden_u32_offset,
                          sizeof(observed)),
          "hsa_memory_copy(hidden_ctx->host)");
    std::cout << "hidden ctx u32[" << verify_hidden_u32_offset
              << "]=" << observed << "\n";
    if (observed == 0) {
      std::cerr << "hidden ctx mismatch offset=" << verify_hidden_u32_offset
                << " expected=nonzero got=0" << std::endl;
      ok = false;
    }
  }
  for (size_t i = 0; i < host_data.size(); ++i) {
    const int expected = expected_value(expectation, i);
    if (host_data[i] != expected) {
      std::cerr << "mismatch[" << i << "] expected=" << expected
                << " got=" << host_data[i] << std::endl;
      ok = false;
      break;
    }
  }

  check(hsa_queue_destroy(queue), "hsa_queue_destroy");
  check(hsa_amd_memory_pool_free(kernarg_buffer),
        "hsa_amd_memory_pool_free(kernarg)");
  if (hidden_ctx != nullptr) {
    check(hsa_amd_memory_pool_free(hidden_ctx),
          "hsa_amd_memory_pool_free(hidden_ctx)");
  }
  check(hsa_amd_memory_pool_free(device_data),
        "hsa_amd_memory_pool_free(device_data)");
  check(hsa_executable_destroy(executable), "hsa_executable_destroy");
  close(fd);
  check(hsa_shut_down(), "hsa_shut_down");

  if (!ok) {
    return 1;
  }
  std::cout << "PASS kernel=" << symbol_name
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
