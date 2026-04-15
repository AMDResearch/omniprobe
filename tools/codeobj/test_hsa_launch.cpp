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
#include <string>
#include <vector>

namespace {

constexpr uint32_t kQueueSize = 64;
constexpr uint32_t kWorkgroupSize = 64;
constexpr size_t kElementCount = 256;
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

SymbolInfo load_symbol(hsa_executable_t executable, hsa_agent_t gpu,
                       const std::string& symbol_name) {
  SymbolInfo info{};
  check(hsa_executable_get_symbol_by_name(executable, symbol_name.c_str(), &gpu,
                                          &info.symbol),
        "hsa_executable_get_symbol_by_name");
  check(hsa_executable_symbol_get_info(
            info.symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT,
            &info.kernel_object),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT");
  check(hsa_executable_symbol_get_info(
            info.symbol,
            HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE,
            &info.kernarg_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE");
  check(hsa_executable_symbol_get_info(
            info.symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE,
            &info.group_segment_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE");
  check(hsa_executable_symbol_get_info(
            info.symbol,
            HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE,
            &info.private_segment_size),
        "HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE");
  return info;
}

void wait_for_queue_slot(const hsa_queue_t* queue, uint64_t write_index) {
  while (write_index - hsa_queue_load_read_index_scacquire(queue) >=
         queue->size) {
  }
}

void dispatch_kernel(hsa_queue_t* queue, const SymbolInfo& symbol,
                     const void* kernarg) {
  hsa_signal_t completion{};
  check(hsa_signal_create(1, 0, nullptr, &completion), "hsa_signal_create");

  const uint64_t write_index = hsa_queue_add_write_index_scacq_screl(queue, 1);
  wait_for_queue_slot(queue, write_index);
  const uint64_t packet_id = write_index & (queue->size - 1);
  auto* packet = reinterpret_cast<hsa_kernel_dispatch_packet_t*>(
      queue->base_address) +
                 packet_id;
  std::memset(packet, 0, sizeof(*packet));

  packet->setup = 1u << HSA_KERNEL_DISPATCH_PACKET_SETUP_DIMENSIONS;
  packet->workgroup_size_x = kWorkgroupSize;
  packet->workgroup_size_y = 1;
  packet->workgroup_size_z = 1;
  packet->grid_size_x = static_cast<uint32_t>(kElementCount);
  packet->grid_size_y = 1;
  packet->grid_size_z = 1;
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

bool is_instrumented_symbol(const std::string& symbol_name) {
  return symbol_name.rfind("__amd_crk_", 0) == 0;
}

void populate_opencl_hidden_args(std::vector<std::byte>& kernarg) {
  const uint32_t block_count_x =
      static_cast<uint32_t>(kElementCount / kWorkgroupSize);
  const uint16_t remainder_x =
      static_cast<uint16_t>(kElementCount % kWorkgroupSize);
  const uint32_t block_count_y = 1;
  const uint32_t block_count_z = 1;
  const uint16_t group_size_x = static_cast<uint16_t>(kWorkgroupSize);
  const uint16_t group_size_y = 1;
  const uint16_t group_size_z = 1;
  const uint16_t remainder_y = 1;
  const uint16_t remainder_z = 1;
  const uint64_t global_offset = 0;
  const uint16_t grid_dims = 1;

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
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " <hsaco> <kernel-symbol>"
              << std::endl;
    return 2;
  }

  const std::string hsaco_path = argv[1];
  const std::string symbol_name = argv[2];

  check(hsa_init(), "hsa_init");

  AgentSelection agents{};
  check(hsa_iterate_agents(find_agents, &agents), "hsa_iterate_agents");
  if (!agents.have_cpu || !agents.have_gpu) {
    std::cerr << "failed to find both CPU and GPU agents" << std::endl;
    check(hsa_shut_down(), "hsa_shut_down");
    return 1;
  }

  std::cout << "CPU agent: " << agent_name(agents.cpu) << "\n";
  std::cout << "GPU agent: " << agent_name(agents.gpu) << "\n";

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
  std::cout << symbol_name << " kernel_object=0x" << std::hex
            << symbol.kernel_object << std::dec
            << " kernarg=" << symbol.kernarg_size
            << " group=" << symbol.group_segment_size
            << " private=" << symbol.private_segment_size << "\n";

  std::vector<uint32_t> host_src(kElementCount);
  std::vector<uint32_t> host_dst(kElementCount, 0xdeadbeefU);
  for (size_t i = 0; i < host_src.size(); ++i) {
    host_src[i] = static_cast<uint32_t>(0x1000 + i);
  }

  void* device_src =
      allocate_pool(device_pool.pool, device_pool.granule,
                    host_src.size() * sizeof(host_src[0]));
  void* device_dst =
      allocate_pool(device_pool.pool, device_pool.granule,
                    host_dst.size() * sizeof(host_dst[0]));
  void* hidden_ctx =
      allocate_pool(device_pool.pool, device_pool.granule, sizeof(uint64_t));
  allow_access({agents.cpu, agents.gpu}, device_src);
  allow_access({agents.cpu, agents.gpu}, device_dst);
  allow_access({agents.cpu, agents.gpu}, hidden_ctx);

  check(hsa_memory_copy(device_src, host_src.data(),
                        host_src.size() * sizeof(host_src[0])),
        "hsa_memory_copy(host->src)");
  check(hsa_memory_copy(device_dst, host_dst.data(),
                        host_dst.size() * sizeof(host_dst[0])),
        "hsa_memory_copy(host->dst)");

  std::vector<std::byte> kernarg(symbol.kernarg_size, std::byte{0});
  std::memcpy(kernarg.data(), &device_dst, sizeof(device_dst));
  std::memcpy(kernarg.data() + sizeof(device_dst), &device_src,
              sizeof(device_src));
  populate_opencl_hidden_args(kernarg);
  if (is_instrumented_symbol(symbol_name) &&
      symbol.kernarg_size >= sizeof(void*) * 3) {
    const size_t hidden_offset = symbol.kernarg_size - sizeof(void*);
    std::memcpy(kernarg.data() + hidden_offset, &hidden_ctx,
                sizeof(hidden_ctx));
    std::cout << "hidden ctx offset=" << hidden_offset << "\n";
  }

  void* kernarg_buffer =
      allocate_pool(kernarg_pool.pool, kernarg_pool.granule, kernarg.size());
  allow_access({agents.gpu}, kernarg_buffer);
  std::memcpy(kernarg_buffer, kernarg.data(), kernarg.size());

  hsa_queue_t* queue = nullptr;
  check(hsa_queue_create(agents.gpu, kQueueSize, HSA_QUEUE_TYPE_SINGLE, nullptr,
                         nullptr, UINT32_MAX, UINT32_MAX, &queue),
        "hsa_queue_create");
  dispatch_kernel(queue, symbol, kernarg_buffer);

  check(hsa_memory_copy(host_dst.data(), device_dst,
                        host_dst.size() * sizeof(host_dst[0])),
        "hsa_memory_copy(dst->host)");

  const bool passed = std::equal(host_src.begin(), host_src.end(),
                                 host_dst.begin(), host_dst.end());
  if (!passed) {
    size_t mismatches = 0;
    for (size_t i = 0; i < host_src.size(); ++i) {
      if (host_src[i] != host_dst[i]) {
        if (mismatches < 8) {
          std::cout << "mismatch[" << i << "] src=0x" << std::hex
                    << host_src[i] << " dst=0x" << host_dst[i] << std::dec
                    << "\n";
        }
        ++mismatches;
      }
    }
    std::cout << "mismatches=" << mismatches << "\n";
  }
  std::cout << (passed ? "PASS" : "FAIL") << "\n";

  check(hsa_queue_destroy(queue), "hsa_queue_destroy");
  check(hsa_amd_memory_pool_free(kernarg_buffer),
        "hsa_amd_memory_pool_free(kernarg)");
  check(hsa_amd_memory_pool_free(hidden_ctx),
        "hsa_amd_memory_pool_free(hidden_ctx)");
  check(hsa_amd_memory_pool_free(device_dst),
        "hsa_amd_memory_pool_free(device_dst)");
  check(hsa_amd_memory_pool_free(device_src),
        "hsa_amd_memory_pool_free(device_src)");
  check(hsa_executable_destroy(executable), "hsa_executable_destroy");
  close(fd);
  check(hsa_shut_down(), "hsa_shut_down");
  return passed ? 0 : 1;
}
