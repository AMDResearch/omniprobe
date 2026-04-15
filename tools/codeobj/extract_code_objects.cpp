#include <hsa/hsa.h>

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

#include "kernelDB.h"

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

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: " << argv[0] << " <binary-or-hsaco>" << std::endl;
    return 2;
  }

  const std::string input = argv[1];
  check(hsa_init(), "hsa_init");

  AgentSearch search{};
  check(hsa_iterate_agents(find_gpu_agent, &search), "hsa_iterate_agents");
  if (!search.found) {
    std::cerr << "no GPU agent found" << std::endl;
    hsa_shut_down();
    return 1;
  }

  const std::vector<std::string> outputs = extractCodeObjects(search.agent, input);
  for (const auto& path : outputs) {
    std::cout << std::filesystem::absolute(path).string() << "\n";
  }

  check(hsa_shut_down(), "hsa_shut_down");
  return outputs.empty() ? 1 : 0;
}
