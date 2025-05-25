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

// Manual cleanup when we're truly done
void on_library_unload() { 
    std::cout << "Memory Analysis Wrapper manual unload requested." << std::endl;
    // Only cleanup JsonOutputManager after we're done with all analysis
    dh_comms::JsonOutputManager::cleanup();
}

memory_analysis_wrapper_t::memory_analysis_wrapper_t(const std::string& kernel, uint64_t dispatch_id, const std::string& location,  bool verbose) :
    kernel_(kernel), dispatch_id_(dispatch_id), location_(location), wrapped_(verbose)
{
    std::cout << "[MemoryAnalysisWrapper] Initializing wrapper for kernel: " << kernel << std::endl;
    dh_comms::JsonOutputManager::getInstance().initializeKernelAnalysis(kernel, dispatch_id);
    
    // Get GPU architecture and cache line size
    hipDeviceProp_t props;
    hipGetDeviceProperties(&props, 0);
    std::string gpu_arch = props.gcnArchName;
    
    // Initialize metadata with default kernels_found (will be updated in report)
    dh_comms::JsonOutputManager::getInstance().setMetadata(gpu_arch, 128, 0); // Using default cache line size of 128
    std::cout << "[MemoryAnalysisWrapper] Initialization complete" << std::endl;
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
    // Get all kernels and update the count
    std::vector<std::string> kernels;
    kdb.getKernels(kernels);
    dh_comms::JsonOutputManager::getInstance().updateKernelsFound(kernels.size());
    
    // Only get lines if kernel_name is provided
    if (!kernel_name.empty()) {
        std::vector<uint32_t> lines;
        kdb.getKernelLines(kernel_name, lines);
    }
    
    report();
}

void memory_analysis_wrapper_t::report() {
  if (verbose_) {
    std::cout << "Memory analysis for " << kernel_ << " dispatch_id[" << std::dec << dispatch_id_ << "]" << std::endl;
  }
  
  std::cout << "[MemoryAnalysisWrapper] Starting wrapped_.report()..." << std::endl;
  try {
    wrapped_.report();
    std::cout << "[MemoryAnalysisWrapper] Completed wrapped_.report() successfully" << std::endl;
    std::cout << "[MemoryAnalysisWrapper] Current analysis size after report: " 
              << dh_comms::JsonOutputManager::getInstance().getCurrentAnalysisSize() << std::endl;
  } catch (const std::exception& e) {
    std::cerr << "[MemoryAnalysisWrapper] ERROR: Exception in wrapped_.report(): " << e.what() << std::endl;
  } catch (...) {
    std::cerr << "[MemoryAnalysisWrapper] ERROR: Unknown exception in wrapped_.report()" << std::endl;
  }
  
  // Set up output directory path
  std::filesystem::path output_dir = std::filesystem::current_path() / "memory_analysis_output";
  std::cout << "[MemoryAnalysisWrapper] Output directory: " << output_dir << std::endl;
  
  // Create output directory if it doesn't exist
  std::cout << "[MemoryAnalysisWrapper] Creating output directory..." << std::endl;
  try {
    if (!std::filesystem::exists(output_dir)) {
      std::filesystem::create_directories(output_dir);
      std::cout << "[MemoryAnalysisWrapper] Created directory: " << output_dir << std::endl;
    }
    
    // Generate output filename
    std::string filename = (output_dir / ("memory_analysis_" + std::to_string(dispatch_id_) + ".json")).string();
    std::cout << "[MemoryAnalysisWrapper] Writing memory analysis to " << filename << std::endl;
    
    // Dump current state before writing
    std::cout << "[MemoryAnalysisWrapper] Dumping current JsonOutputManager state..." << std::endl;
    auto& manager = dh_comms::JsonOutputManager::getInstance();
    std::cout << "[MemoryAnalysisWrapper] Current analysis size before dump: " << manager.getCurrentAnalysisSize() << std::endl;
    manager.dumpCurrentState();
    
    // Attempt to write the file
    std::cout << "[MemoryAnalysisWrapper] Writing to file..." << std::endl;
    try {
      manager.writeToFile(filename);
      std::cout << "[MemoryAnalysisWrapper] Report completed successfully" << std::endl;
    } catch (const std::exception& e) {
      std::cerr << "[MemoryAnalysisWrapper] ERROR: Failed to write file: " << e.what() << std::endl;
      // Try writing to current directory as fallback
      filename = (std::filesystem::current_path() / ("memory_analysis_" + std::to_string(dispatch_id_) + ".json")).string();
      std::cout << "[MemoryAnalysisWrapper] Attempting to write to current directory: " << filename << std::endl;
      manager.writeToFile(filename);
    }
  } catch (const std::filesystem::filesystem_error& e) {
    std::cerr << "[MemoryAnalysisWrapper] ERROR: Filesystem error: " << e.what() << std::endl;
    // Fall back to current directory
    std::string filename = (std::filesystem::current_path() / ("memory_analysis_" + std::to_string(dispatch_id_) + ".json")).string();
    std::cout << "[MemoryAnalysisWrapper] Falling back to current directory: " << filename << std::endl;
    dh_comms::JsonOutputManager::getInstance().writeToFile(filename);
  } catch (const std::exception& e) {
    std::cerr << "[MemoryAnalysisWrapper] ERROR: Unexpected error: " << e.what() << std::endl;
  }
}

void memory_analysis_wrapper_t::clear() {
  wrapped_.clear();
  dh_comms::JsonOutputManager::getInstance().clear();
}
