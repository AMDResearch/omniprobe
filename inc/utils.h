/******************************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

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
#pragma once
#undef NDEBUG
#include <assert.h>
#include <cxxabi.h>
#include <dirent.h>
#include <pthread.h>
#include <random>
#include <ctime>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <filesystem>
#include <sys/syscall.h>   /* For SYS_xxx definitions */
#include <sys/types.h>
#include <sys/mman.h>
#include <unistd.h>
#include <limits.h>
#include <dlfcn.h>

#include <atomic>
#include <chrono>
#include <iostream>
#include <fstream>
#include <list>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <thread>
#include <mutex>
#include <utility>
#include <shared_mutex>
#include <filesystem>
#include <ios>
#include <ctime>
#include <algorithm>
#include <regex>
#include <fcntl.h>
#include <sys/stat.h>
#include <link.h>
#include <elf.h>
#include <dirent.h>

#include <hsa.h>
#include <hsa_ven_amd_aqlprofile.h>
#include <hsa_ven_amd_loader.h>
#include <amd_comgr/amd_comgr.h>
#include "rocprofiler/rocprofiler.h"
#define AMD_INTERNAL_BUILD
#include <hsa_api_trace.h>
#include "plugins/plugin.h"


#define INSTRUMENTATION_BUFFER void *
#define OMNIPROBE_PREFIX "__amd_crk_"


#define RH_PAGE_SIZE 0x1000
#define RH_PAGE_MASK 0x0FFF


#define RANDOM_DISPATCH_DISTRIBUTION 100

using namespace std;

bool util_is_directory(const std::string& path);
std::vector<std::string> util_get_directory_files(const std::string& path, bool includeDirectories = false);
bool util_ends_with_substring(const std::string& str, const std::string& suffix);

#define CHECK_STATUS(msg, status) do {                                                             \
  if ((status) != HSA_STATUS_SUCCESS) {                                                            \
    const char* emsg = 0;                                                                          \
    hsa_status_string(status, &emsg);                                                              \
    printf("%s: %s\n", msg, emsg ? emsg : "<unknown error>");                                      \
    abort();                                                                                       \
  }                                                                                                \
} while (0)

template<typename T>
struct hsa_cmp
{
    bool operator() (const T& first, const T& second) const
    {
        return first.handle < second.handle;
    }
};

class KernArgAllocator
{
public:
    KernArgAllocator(HsaApiTable *pTable, std::ostream& out);
    ~KernArgAllocator();
    void *allocate(size_t size, hsa_agent_t allowed)const;
    void *allocate(size_t size)const;
    void free(void *ptr) const;
    void setPool(hsa_amd_memory_pool_t pool) {pool_ = pool;}
    std::ostream& out_;
private:
    hsa_amd_memory_pool_t pool_;
    HsaApiTable *apiTable_;
    hsa_agent_t agent;
};

class signalPool{
public:
    signalPool(int initialSize = 8);
    ~signalPool();
    hsa_signal_t checkout();
    void checkin(hsa_signal_t sig);
private:
    std::vector<hsa_signal_t> available_;
    std::vector<hsa_signal_t> in_use_;
    std::mutex mutex_;
};

typedef struct arg_descriptor {
    size_t explicit_args_length;
    size_t explicit_args_count;
    size_t hidden_args_length;
    size_t kernarg_length;
    uint32_t private_segment_size;
    uint32_t group_segment_size;
    size_t clone_hidden_args_length;
}arg_descriptor_t;


typedef struct cache_object{
    hsa_executable_t executable_;
    std::string filename_;
    std::chrono::time_point<std::chrono::system_clock> timestamp_;
}cache_object_t;

class coCache{
public:
    coCache(HsaApiTable *apiTable);
    ~coCache();
    bool setLocation(hsa_agent_t agent, const std::string& directory, const std::string& strFilter, bool instrumented = true);
    uint64_t findAlternative(hsa_executable_symbol_t symbol, const std::string& name, hsa_agent_t queue_agent = {0});
    uint64_t findInstrumentedAlternative(hsa_executable_symbol_t, const std::string& name, hsa_agent_t queue_agent = {0});
    bool hasKernels(hsa_agent_t agent);
    uint32_t getArgSize(uint64_t kernel_object);
    bool addFile(const std::string& name, hsa_agent_t agent, const std::string& strFilter);
    bool getArgDescriptor(hsa_agent_t agent, std::string& name, arg_descriptor_t& desc, bool instrumented);
    uint8_t getArgumentAlignment(uint64_t kernel_object);
    const amd_kernel_code_t* getKernelCode(uint64_t kernel_object);
private:
    HsaApiTable *apiTable_;
    hsa_ven_amd_loader_1_00_pfn_t loader_api_;
    std::map<hsa_agent_t, std::vector<hsa_executable_symbol_t>, hsa_cmp<hsa_agent_t>> kernels_;
    std::vector<std::string> filelist_;
    std::map<hsa_agent_t, std::map<std::string, hsa_executable_symbol_t>, hsa_cmp<hsa_agent_t>> lookup_map_;
    std::map<hsa_agent_t, std::map<std::string, arg_descriptor_t>, hsa_cmp<hsa_agent_t>> arg_map_;
    std::mutex mutex_;
    std::string location_;
    std::map<hsa_agent_t, cache_object_t, hsa_cmp<hsa_agent_t>> cache_objects_;
    std::map<hsa_agent_t, std::map<hsa_executable_symbol_t, uint64_t, hsa_cmp<hsa_executable_symbol_t>>, hsa_cmp<hsa_agent_t>> alternatives_;
    std::map<uint64_t, uint32_t> kernarg_sizes_;
};

class KernelArgHelper {
public:
    KernelArgHelper(const std::string file_name);
    KernelArgHelper(hsa_agent_t agent, std::vector<uint8_t>& bits);
    ~KernelArgHelper();
    void addCodeObject(const char *bits, size_t length);
    bool getArgDescriptor(const std::string& strName, arg_descriptor_t& desc);
    static void getElfSectionBits(const std::string &fileName, const std::string &sectionName, std::vector<uint8_t>& sectionData);
    static amd_comgr_code_object_info_t getCodeObjectInfo(hsa_agent_t agent, std::vector<uint8_t>& bits);
    static void getSharedLibraries(std::vector<std::string>& libraries);
private:
    std::string get_metadata_string(amd_comgr_metadata_node_t node);
    void computeKernargData(amd_comgr_metadata_node_t exec_map);
    std::map<std::string, arg_descriptor_t> kernels_;

};

class logDuration{
public:
    logDuration();
    logDuration(std::string& location);
    ~logDuration();
    void log(std::string& kernelName, uint64_t dispatchTime, uint64_t startNs, uint64_t endNs);
    bool setLocation(const std::string& strLocation);
    void logHeaders();
private:
    std::ostream *log_file_;
    std::string location_;
};

class handlerManager{
public:
    handlerManager();
    handlerManager(const std::vector<std::string>& handlers);
    ~handlerManager();
    void getMessageHandlers(const std::string& strKernel, uint64_t dispatch_id, std::vector<dh_comms::message_handler_base *>& outHandlers);
    bool setHandlers(const std::vector<std::string>& handlers);
private:
    std::map<void *, getMessageHandlers_t> plugins_;
};

class randomDispatcher{
public:
    randomDispatcher(int distro);
    ~randomDispatcher();
    bool canDispatch();
private:
    std::mt19937 generator_;
    std::uniform_int_distribution<int> distribution_;
};

class dispatchController{
public:
    dispatchController();
    ~dispatchController();
    bool canDispatch(uint64_t kernel_object);
private:
    bool bAllDispatch_;
    bool bRandomDispatch_;
    bool bOneDispatch_;
    std::map<uint64_t, bool> dispatched_kernels_;
    randomDispatcher randomDispatcher_;
};


std::vector<std::string> getIsaList(hsa_agent_t agent);
unsigned int getLogDurConfig(std::map<std::string, std::string>& config);
void clipInstrumentedKernelName(std::string& str);
void clipKernelName(std::string& str);
bool isFileNewer(const std::chrono::system_clock::time_point& timestamp, const std::string& fileName);
std::string demangleName(const char *name);
std::string getExecutablePath();


static inline void ltrim(std::string &s) {
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), [](unsigned char ch) {
        return !std::isspace(ch);
    }));
}

// trim from end (in place)
static inline void rtrim(std::string &s) {
    s.erase(std::find_if(s.rbegin(), s.rend(), [](unsigned char ch) {
        return !std::isspace(ch);
    }).base(), s.end());
}

// trim from both ends (in place)
static inline void trim(std::string &s) {
    ltrim(s);
    rtrim(s);
}

static inline size_t split(std::string const& s,
             std::vector<std::string> &container,
             const char * delimiter,
             bool keepBlankFields)
{
    size_t n = 0;
    std::string::const_iterator it = s.begin(), end = s.end(), first;
    for (first = it; it != end; ++it)
    {
        // Examine each character and if it matches the delimiter
        if (*delimiter == *it)
        {
            if (keepBlankFields || first != it)
            {
                // extract the current field from the string and
                // append the current field to the given container
                container.push_back(std::string(first, it));
                ++n;

                // skip the delimiter
                first = it + 1;
            }
            else
            {
                ++first;
            }
        }
    }
    if (keepBlankFields || first != it)
    {
        // extract the last field from the string and
        // append the last field to the given container
        container.push_back(std::string(first, it));
        ++n;
    }
    return n;
}
