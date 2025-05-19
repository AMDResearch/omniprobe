#include "inc/memory_analysis_wrapper.h"

#include "hip_utils.h"
#include "utils.h"

#include <cassert>
#include <hip/hip_runtime.h>
#include <set>
#include <string>
#include <iostream>
#include <filesystem>

__attribute__((constructor)) void on_library_load() { std::cout << "Memory Analysis Wrapper loaded." << std::endl; }
__attribute__((destructor)) void on_library_unload() { std::cout << "Memory Analysis Wrapper unloaded." << std::endl; }

memory_analysis_wrapper_t::memory_analysis_wrapper_t(const std::string& kernel, uint64_t dispatch_id, const std::string& location,  bool verbose) :
    kernel_(kernel), dispatch_id_(dispatch_id), location_(location), wrapped_(verbose)
{
    JsonOutputManager::getInstance().initializeKernelAnalysis(kernel, dispatch_id);
    
    // Get GPU architecture and cache line size
    hipDeviceProp_t props;
    hipGetDeviceProperties(&props, 0);
    std::string gpu_arch = props.gcnArchName;
    
    // Initialize metadata with default kernels_found (will be updated in report)
    JsonOutputManager::getInstance().setMetadata(gpu_arch, 128, 0); // Using default cache line size of 128
}

bool memory_analysis_wrapper_t::handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb)
{
    return wrapped_.handle(message, kernel, kdb);
}


bool memory_analysis_wrapper_t::handle(const dh_comms::message_t &message) {
  return wrapped_.handle(message);
}

void memory_analysis_wrapper_t::report(const std::string& kernel_name, kernelDB::kernelDB& kdb)
{
    if (kernel_name.length() == 0)
    {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
        
        // Update kernels found count
        std::vector<std::string> kernels;
        kdb.getKernels(kernels);
        JsonOutputManager::getInstance().updateKernelsFound(kernels.size());
    }
    report();
}

void memory_analysis_wrapper_t::report() {
  if (verbose_) {
    std::cout << "Memory analysis for " << kernel_ << " dispatch_id[" << std::dec << dispatch_id_ << "]" << std::endl;
  }
  wrapped_.report();
  
  // Create output directory if it doesn't exist
  std::filesystem::path output_dir = location_;
  if (!std::filesystem::exists(output_dir)) {
    std::filesystem::create_directories(output_dir);
  }
  
  // Generate output filename
  std::string filename = (output_dir / ("memory_analysis_" + std::to_string(dispatch_id_) + ".json")).string();
  JsonOutputManager::getInstance().writeToFile(filename);
}

void memory_analysis_wrapper_t::clear() {
  wrapped_.clear();
  JsonOutputManager::getInstance().clear();
}
