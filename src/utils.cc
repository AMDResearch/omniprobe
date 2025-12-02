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

#include "inc/utils.h"
#include <algorithm>
#include <regex>


using namespace std;
namespace fs = std::filesystem;


#define ARG_ALIGN 8

size_t roundArgsLength(size_t number) {
    return ((number + (ARG_ALIGN - 1)) / ARG_ALIGN) * ARG_ALIGN;
}

bool util_ends_with_substring(const std::string& str, const std::string& suffix) {
    if (suffix.size() > str.size()) return false;
    return str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::vector<std::string> util_get_directory_files(const std::string& path, bool includeDirectories /*=false*/) {
    std::vector<std::string> files;

    if (!util_is_directory(path)) {
        return files; // Return empty vector if not a directory
    }

    DIR* dir = opendir(path.c_str());
    if (!dir) {
        return files; // Return empty vector if directory can't be opened
    }

    struct dirent* entry;
    while ((entry = readdir(dir))) {
        // Skip "." and ".." entries
        if (std::string(entry->d_name) == "." || std::string(entry->d_name) == "..") {
            continue;
        }

        // Construct full path to check file type
        std::string full_path = path;
        if (!util_ends_with_substring(full_path, "/")) {
            full_path += "/";
        }
        full_path += entry->d_name;

        struct stat info;
        if (stat(full_path.c_str(), &info) == 0)
        {
            if(info.st_mode & S_IFREG) {
                files.push_back(full_path);
            }
            if(info.st_mode & S_IFDIR && includeDirectories)
                files.push_back(full_path);
        }
    }

    closedir(dir);
    return files;
}

bool util_is_directory(const std::string& path) {
    struct stat info;
    if (stat(path.c_str(), &info) != 0) {
        return false; // Path doesn't exist or is inaccessible
    }
    return (info.st_mode & S_IFDIR) != 0;
}

std::string demangleName(const char *name)
{
   int status;
   std::string result;
   char *realname = abi::__cxa_demangle(name, 0, 0, &status);
   if (status == 0)
   {
       if (realname)
       {
           result = realname;
           free(realname);
       }
   }
   else
   {
        if (realname)
            free(realname);
        // We're going through these gyrations here because the OMNIPROBE_PREFIX is being
        // prepended by the LLVM plugin AFTER kernel name mangling has already occurred.
        // So we have to do some special kind of non-standard de-mangling by stripping the
        // OMNIPROBE_PREFIX from the name before demangling, then adding it back in the
        // appropriate place.
        if (!strncmp(name, OMNIPROBE_PREFIX, strlen(OMNIPROBE_PREFIX)))
        {
            realname = abi::__cxa_demangle(&name[strlen(OMNIPROBE_PREFIX)],0,0, &status);
            if (status == 0 && realname)
            {
                result = realname;
                size_t pos = result.find_first_of(" ");
                size_t ret_type = result.find_first_of("(");
                // If pos > ret_type this means that there's no return type in the kernel name
                if (pos > ret_type)
                    pos = -1;
                result.insert(pos+1, OMNIPROBE_PREFIX);
                free(realname);
            }
        }
   }
   return result.length() ? result : std::string(name);
}

bool isFileNewer(const std::chrono::system_clock::time_point& timestamp, const std::string& fileName) {
    try {
        // Get the last write time of the file
        auto fileTime = std::filesystem::last_write_time(fileName);
        // Convert the file time to system_clock::time_point
        auto fileTimePoint = std::chrono::time_point_cast<std::chrono::system_clock::duration>(fileTime - std::filesystem::file_time_type::clock::now() + std::chrono::system_clock::now());

        // Compare the file's modification time with the provided timestamp
        return fileTimePoint > timestamp;
    } catch (std::filesystem::filesystem_error& e) {
        // If the file does not exist or another error occurs, return false
        return false;
    }
}


std::string getExecutablePath() {
    char result[PATH_MAX];
    ssize_t count = readlink("/proc/self/exe", result, PATH_MAX);
    return std::string(result, (count > 0) ? count : 0);
}


std::string getInstrumentedName(const std::string& func_decl) {
    std::string result = func_decl;
    size_t pos = result.find_last_of(')');
    if (pos != std::string::npos) {
        result.replace(pos, 1, ", void*)");
        pos = result.find_first_of(" ");
        size_t ret_type = result.find_first_of("(");
        // If pos > ret_type this means that there's no return type in the kernel name
        if (pos > ret_type)
            pos = -1;
        result.insert(pos+1, OMNIPROBE_PREFIX);
    }
    else
    {
        pos = result.find_last_of(".kd");
        if (pos != std::string::npos)
            result.replace(pos-2, 3, "Pv.kd");
        result = "__amd_crk_" + result;
    }

    //std::cout << "Instrumented name: " << result << std::endl;

    return result;
}

std::vector<std::string> getIsaList(hsa_agent_t agent)
{
    std::vector<std::string> list;
    hsa_agent_iterate_isas(agent,[](hsa_isa_t isa, void *data){
        std::vector<std::string> *pList = reinterpret_cast<std::vector<std::string> *> (data);
           uint32_t length;
           hsa_status_t status = hsa_isa_get_info(isa, HSA_ISA_INFO_NAME_LENGTH, 0, &length);
           if (status == HSA_STATUS_SUCCESS)
           {
                char *pName = static_cast<char *>(malloc(length + 1));
                if (pName)
                {
                    pName[length] = '\0';
                    status = hsa_isa_get_info(isa, HSA_ISA_INFO_NAME, 0, pName);
                    //std::cerr << "Isa name: " << pName << std::endl;
                    if (status == HSA_STATUS_SUCCESS)
                        pList->push_back(std::string(pName));
                    free(pName);
                }
                else
                {
                    std::cout << "The system is somehow out of memory at line " << __LINE__ << " so I'm aborting this run." << std::endl;
                    abort();
                }
           }
           return HSA_STATUS_SUCCESS;
        }, reinterpret_cast<void *>(&list));
    return list;
}


signalPool::signalPool(int initialSize/* = 8 */)
{
}

signalPool::~signalPool()
{
}

hsa_signal_t signalPool::checkout()
{
    lock_guard<mutex> lock(mutex_);
    return {};
}

void signalPool::checkin(hsa_signal_t sig)
{
    lock_guard<mutex> lock(mutex_);
}

coCache::coCache(HsaApiTable *apiTable)
{
    apiTable_ = apiTable;
    auto status = apiTable_->core_->hsa_system_get_major_extension_table_fn(HSA_EXTENSION_AMD_LOADER, 1, sizeof(loader_api_), &loader_api_);
    CHECK_STATUS("Unable to find HSA extension table", status);
}

coCache::~coCache()
{
    lock_guard<std::mutex> lock(mutex);
    for(auto it : cache_objects_)
    {
        CHECK_STATUS("Unable to destroy loaded code objects", apiTable_->core_->hsa_executable_destroy_fn(it.second.executable_));
    }
}

const amd_kernel_code_t* coCache::getKernelCode(uint64_t kernel_object)
{
      const amd_kernel_code_t* kernel_code = NULL;
      hsa_status_t status = loader_api_.hsa_ven_amd_loader_query_host_address(
              reinterpret_cast<const void*>(kernel_object),
              reinterpret_cast<const void**>(&kernel_code));
      if (HSA_STATUS_SUCCESS != status) {
        kernel_code = reinterpret_cast<amd_kernel_code_t*>(kernel_object);
      }
      return kernel_code;
}

uint8_t coCache::getArgumentAlignment(uint64_t kernel_object)
{
      const amd_kernel_code_t* kernel_code = getKernelCode(kernel_object);
      return kernel_code->kernarg_segment_alignment;
}

bool coCache::hasKernels(hsa_agent_t agent)
{
    lock_guard<std::mutex> lock(mutex);
    return lookup_map_.find(agent) != lookup_map_.end();

}

bool coCache::getArgDescriptor(hsa_agent_t agent, std::string& name, arg_descriptor_t& desc, bool instrumented)
{
    // std::cout << "coCache::getArgDescriptor for agent " << agent.handle << " and kernel " << name << " (instrumented=" << instrumented << ")" << std::endl;
    // std::cout << "clone_hidden_args_length before lookup: " << desc.clone_hidden_args_length << std::endl;
    bool bReturn = false;
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = arg_map_.find(agent);
    size_t clone_hidden_args_length = 0;
    if (it != arg_map_.end())
    {
        std::string strName;
        if (instrumented)
        {
            auto itclone = it->second.find(name);
            if (itclone != it->second.end())
            {
                // std::cout << "itclone->second.kernarg_length: " << itclone->second.kernarg_length << std::endl;
                // std::cout << "itclone->second.explicit_args_length: " << itclone->second.explicit_args_length << std::endl;
                // If there are hidden arguments in the clone, compute how many bytes of kernarg data comprises the hidden kernargs.
                if (itclone->second.hidden_args_length)
                    clone_hidden_args_length = itclone->second.kernarg_length - itclone->second.explicit_args_length;
                    //clone_hidden_args_length = itclone->second.kernarg_length - (itclone->second.explicit_args_count * sizeof(void *));
            }

            strName = getInstrumentedName(name);
        }
        else
            strName = name;
        auto dit = it->second.find(strName);
        if (dit != it->second.end())
        {
            desc = dit->second;
            desc.clone_hidden_args_length = clone_hidden_args_length;
            bReturn = true;
        }
    }
    //std::cout << "clone_hidden_args_length after lookup: " << desc.clone_hidden_args_length << std::endl;
    return bReturn;
}

bool coCache::addFile(const std::string& name, hsa_agent_t agent, const std::string& strFilter)
{
    bool bResult = false;
    // Build the code object filename
    //std::clog << "Code object filename: " << name << std::endl;
    hsa_code_object_reader_t code_obj_rdr = {0};
    hsa_file_t file_handle = open(name.c_str(), O_RDONLY);
    hsa_status_t status;
    std::vector<uint8_t> co_bits;

    // Vector to hold executables (one for .hsaco, possibly multiple for fat binaries)
    std::vector<hsa_executable_t> executables;
    KernelArgHelper *p_kh = NULL;

    // Open the file containing code object
    if (name.ends_with(".hsaco"))
    {
        if (file_handle == -1) {
            std::cerr << "Error: failed to load '" << name << "'" << std::endl;
            assert(false);
            return false;
        }

        // Create executable.
        hsa_executable_t executable;
        status = apiTable_->core_->hsa_executable_create_alt_fn(HSA_PROFILE_FULL, HSA_DEFAULT_FLOAT_ROUNDING_MODE_DEFAULT,
                                             NULL, &executable);
        CHECK_STATUS("Error in creating executable object", status);

        // Create code object reader
        status = apiTable_->core_->hsa_code_object_reader_create_from_file_fn(file_handle, &code_obj_rdr);
        if (status != HSA_STATUS_SUCCESS) {
            std::cerr << "Failed to create code object reader '" << name << "'" << std::endl;
            return false;
        }
        // Load code object.
        status = apiTable_->core_->hsa_executable_load_agent_code_object_fn(executable, agent, code_obj_rdr,
                                                         NULL, NULL);
        if (status == HSA_STATUS_ERROR_INCOMPATIBLE_ARGUMENTS)
        {
            cerr << "Looks like " << name << " is not ISA compatible with this GPU\n";
            apiTable_->core_->hsa_executable_destroy_fn(executable);
            return false;
        }
        else
            CHECK_STATUS("Error in loading executable object", status);

        executables.push_back(executable);
        p_kh = new KernelArgHelper(name);
    }
    else
    {
        KernelArgHelper::getElfSectionBits(name,std::string(".hip_fatbin"), co_bits);
        if (co_bits.size())
        {
            std::vector<amd_comgr_code_object_info_t> code_objects = KernelArgHelper::getCodeObjectInfo(agent, co_bits);

            // Create and load an executable for each code object
            for (const auto& info : code_objects)
            {
                if (info.size)
                {
                    hsa_executable_t executable;
                    status = apiTable_->core_->hsa_executable_create_alt_fn(HSA_PROFILE_FULL, HSA_DEFAULT_FLOAT_ROUNDING_MODE_DEFAULT,
                                                         NULL, &executable);
                    CHECK_STATUS("Error in creating executable object", status);

                    status = apiTable_->core_->hsa_code_object_reader_create_from_memory_fn(co_bits.data() + info.offset, info.size, &code_obj_rdr);
                    if (status != HSA_STATUS_SUCCESS)
                        throw std::runtime_error("Could not create code reader from fat binary bits");
                    status = apiTable_->core_->hsa_executable_load_agent_code_object_fn(executable, agent, code_obj_rdr, NULL, NULL);
                    if (status != HSA_STATUS_SUCCESS)
                        throw std::runtime_error("Could not load code object from fat binary bits");

                    executables.push_back(executable);
                }
            }
            // Create KernelArgHelper once - its constructor already handles all code objects
            p_kh = new KernelArgHelper(agent, co_bits);
        }
        else
            return false;
    }

    // Process all executables to extract symbols
    for (auto executable : executables)
    {
        // Freeze executable.
        status = apiTable_->core_->hsa_executable_freeze_fn(executable, "");
        //std::cerr << "Status on freeze: " << std::hex << status << std::endl;
        CHECK_STATUS("Error in freezing executable object", status);

        // Get symbol handle.
        hsa_executable_symbol_t kernelSymbol;
        std::vector<hsa_executable_symbol_t> symbols;
        status = apiTable_->core_->hsa_executable_iterate_symbols_fn(executable, [](hsa_executable_t exec, hsa_executable_symbol_t symbol, void *data){
            std::vector<hsa_executable_symbol_t> *syms = reinterpret_cast<std::vector<hsa_executable_symbol_t> *>(data);
            syms->push_back(symbol);
            return HSA_STATUS_SUCCESS;
        }, reinterpret_cast<void *>(&symbols));

        //KernelArgHelper kh(name);

        //cerr << "coCache found " << symbols.size() << " symbols\n";
        for (auto sym : symbols)
        {
            hsa_symbol_kind_t kind;
            CHECK_STATUS("Unable to get valid symbol info", apiTable_->core_->hsa_executable_symbol_get_info_fn(sym,HSA_EXECUTABLE_SYMBOL_INFO_TYPE,&kind));
            if (kind == HSA_SYMBOL_KIND_KERNEL)
            {
                {
                    lock_guard<std::mutex> lock(mutex_);
                    auto it = kernels_.find(agent);
                    if (it != kernels_.end())
                        it->second.push_back(sym);
                    else
                        kernels_[agent].push_back(sym);
                }

                uint64_t kernel_object;

                CHECK_STATUS("Can't retrieve a kernel object from a valid symbol", apiTable_->core_->hsa_executable_symbol_get_info_fn(sym, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT, reinterpret_cast<void *>(&kernel_object)));
                uint32_t length;
                CHECK_STATUS("Can't retrieve the length of kernel name from a valid symbol",
                    apiTable_->core_->hsa_executable_symbol_get_info_fn(sym, HSA_EXECUTABLE_SYMBOL_INFO_NAME_LENGTH,&length));
                char *name = reinterpret_cast<char *>(malloc(length + 1));
                if (name)
                {
                    name[length] = '\0';
                    CHECK_STATUS("Can't retrieve name from valid symbol", apiTable_->core_->hsa_executable_symbol_get_info_fn(sym, HSA_EXECUTABLE_SYMBOL_INFO_NAME, name));
                    std::string mangledName(name);

                    string strName = demangleName(name);
                    //std::cout << "Kernel Name Found: " << strName << std::endl;
                    // If a kernel filter was supplied, match the demangled name to the filter. If there's no match,
                    // skip this symbol because we don't want to run instrumented for kernels whose names don't
                    // match on the filter
                    if (strFilter.size())
                    {
                        try
                        {
                            std::regex filter_regex(strFilter, std::regex_constants::ECMAScript);
                            if (!std::regex_search(strName, filter_regex))
                                continue;
                        }
                        catch(const std::regex_error& error)
                        {
                            std::cout << "ERROR: There is a problem with your kernel filter (\"" << strFilter << "\"):\n";
                            std::cout << "\t" << error.what() << std::endl;
                            abort();
                        }
                    }
                    arg_descriptor_t desc;
                    if (p_kh->getArgDescriptor(strName, desc))
                    {
                       //std::cerr << "Adding arg descriptor to coCache for " << strName << " of length " << std::dec << strName.size() << std::endl;
                       lock_guard<std::mutex> lock(mutex_);
                       auto itMap = arg_map_.find(agent);
                       if (itMap != arg_map_.end())
                           itMap->second[strName] = desc;
                       else
                            arg_map_[agent] = {{strName, desc}};
                    }
                    else
                        std::cerr << "Unable to find arg descriptor for " << strName << std::endl;
                    free(reinterpret_cast<void *>(name));
                    {
                        lock_guard<std::mutex> lock(mutex_);
                        auto it = lookup_map_.find(agent);
                        if (it != lookup_map_.end())
                            it->second[strName] = sym;
                        else
                            lookup_map_[agent] = {{strName,sym}};
                    }
                }
            }
        }

        // TODO: cache_objects_[agent] currently stores only one executable per agent.
        // With multiple code objects in fat binaries, this will overwrite previous executables.
        // Consider changing cache_objects_ to support multiple executables per agent.
        {
            lock_guard<std::mutex> lock(mutex_);
            cache_objects_[agent] = {executable, name, std::chrono::system_clock::now()};
        }
    }

    close(file_handle);
    delete p_kh;
    return bResult;
}

bool coCache::setLocation(hsa_agent_t agent, const std::string& directory, const std::string& strFilter, bool instrumented)
{
    filelist_.clear();
    if (directory.length())
    {
        location_ = directory;
        if (util_is_directory(directory))
        {
            try {
                auto files = util_get_directory_files(directory);
                for (const auto& file : files) {
                    if (file.ends_with(".hsaco")) {
                        filelist_.push_back(file);
                    }
                }

                for (auto file : filelist_)
                {
                    addFile(file, agent, strFilter);
                }
            }
            catch (const std::exception& e) {
                std::cerr << "General exception: " << e.what() << std::endl;
            }
        }
    }
    return filelist_.size() != 0;
}

uint32_t coCache::getArgSize(uint64_t kernel_object)
{
    uint32_t result = 0;
    lock_guard<std::mutex> lock(mutex_);
    auto it = kernarg_sizes_.find(kernel_object);
    if (it != kernarg_sizes_.end())
        result = it->second;
    return result;
}

extern decltype(hsa_executable_symbol_get_info)* hsa_executable_symbol_get_info_fn;

uint64_t coCache::findAlternative(hsa_executable_symbol_t symbol, const std::string& name, hsa_agent_t queue_agent)
{
    uint64_t object = 0;
    hsa_agent_t agent;
    uint32_t kernarg_size;
    CHECK_STATUS("Unable to identify agent for symbol", hsa_executable_symbol_get_info_fn(symbol, HSA_EXECUTABLE_SYMBOL_INFO_AGENT, reinterpret_cast<void *>(&agent)));
    CHECK_STATUS("Unable to get kernarg size", hsa_executable_symbol_get_info_fn(symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE, reinterpret_cast<void *>(&kernarg_size)));
    if (queue_agent.handle && agent.handle != queue_agent.handle)
        std::cout << "Something is amiss in findAlternative\n";
    lock_guard<std::mutex> lock(mutex_);
    auto it = lookup_map_.find(agent);
    if (it != lookup_map_.end())
    {
        auto kern_it = it->second.find(name);
        if (kern_it != it->second.end())
        {
            uint32_t alt_kernarg_size;
            uint64_t alt_kernel_object;
            CHECK_STATUS("Unable to get kernarg size", hsa_executable_symbol_get_info_fn(kern_it->second, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE, reinterpret_cast<void *>(&alt_kernarg_size)));
            CHECK_STATUS("Unable to get kernel_object", hsa_executable_symbol_get_info_fn(kern_it->second, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT, reinterpret_cast<void *>(&alt_kernel_object)));
            object = alt_kernel_object;
            //cerr << "kernarg_size = " << kernarg_size << "\nalt_kernarg_size = " << alt_kernarg_size << "\nInstrumentation buffer size = " << sizeof(INSTRUMENTATION_BUFFER) << std::endl;
            auto ksit = kernarg_sizes_.find(alt_kernel_object);
            if (ksit == kernarg_sizes_.end())
                kernarg_sizes_[alt_kernel_object] = alt_kernarg_size;
        }
    }
    return object;
}

uint64_t coCache::findInstrumentedAlternative(hsa_executable_symbol_t symbol, const std::string& name, hsa_agent_t queue_agent)
{
    uint64_t result = 0;
    {
        lock_guard<std::mutex> lock(mutex);
        auto it = alternatives_.find(queue_agent);
        if (it != alternatives_.end())
        {
            auto sit = it->second.find(symbol);
            if (sit != it->second.end())
            {
                result = sit->second;
            }
        }
        else
            alternatives_[queue_agent] = {};
    }
    if (!result)
    {
        result = findAlternative(symbol, getInstrumentedName(std::string(name)), queue_agent);
        if (result)
        {
            lock_guard<std::mutex> lock(mutex);
            alternatives_[queue_agent][symbol] = result;
        }
    }
    return result;
}


unsigned int getLogDurConfig(std::map<std::string, std::string>& config) {

    // Read the environment variables
    const char* logDurLogLocation = std::getenv("LOGDUR_LOG_LOCATION");
    const char* logDurKernelCache = std::getenv("LOGDUR_KERNEL_CACHE");
    const char* logDurInstrumented = std::getenv("LOGDUR_INSTRUMENTED");
    const char* logDurHandlers = std::getenv("LOGDUR_HANDLERS");
    const char* logDurKernelFilter = std::getenv("LOGDUR_FILTER");
    const char* logDurDispatches = std::getenv("LOGDUR_DISPATCHES");

    config["LOGDUR_LOG_LOCATION"] = logDurLogLocation ? logDurLogLocation : "console";

    config["LOGDUR_KERNEL_CACHE"] = logDurKernelCache ? logDurKernelCache : "";

    if (logDurInstrumented) {
        std::string tmp = logDurInstrumented;
        std::transform(tmp.begin(), tmp.end(), tmp.begin(),
            [](unsigned char c){ return std::tolower(c); });
        if (tmp != "true" && tmp != "false")
        {
            std::cerr << "Invalid value for LOGDUR_INSTRUMENTED. Must be either \"true\" or \"false\". Running non-instrumented kernels." << std::endl;
            config["LOGDUR_INSTRUMENTED"] = "false";
        }
        else
            config["LOGDUR_INSTRUMENTED"] = tmp;
    }else {
        config["LOGDUR_INSTRUMENTED"] = "false";
    }

    config["LOGDUR_HANDLERS"] = logDurHandlers ? logDurHandlers : "";

    config["LOGDUR_FILTER"] = logDurKernelFilter ? logDurKernelFilter : "";

    config["LOGDUR_DISPATCHES"] = logDurDispatches ? logDurDispatches : "";

    return config.size();
}

logDuration::logDuration()
{
    location_ = "console";
    if (location_ == "console")
        log_file_ = &cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
    //(*log_file_) << "kernel,dispatch,startNs,endNs" << std::endl;
}

logDuration::logDuration(std::string& location)
{
    location_ = location;
    if (location == "console")
        log_file_ = &cout;
    else
        log_file_ = new std::ofstream(location, std::ios::app);
    //*log_file_ << "kernel,dispatch,startNs,endNs" << std::endl;
}

logDuration::~logDuration()
{
    if (location_ != "console")
    {
        delete log_file_;
    }
}

void logDuration::log(std::string& kernelName, uint64_t dispatchTime, uint64_t startNs, uint64_t endNs)
{
    if (log_file_)
        *log_file_ << "\"" << kernelName << "\"," << std::dec << dispatchTime << "," << startNs << "," << endNs << std::endl;
    else
        cerr << "Can't find anyplace to log\n";
}

void logDuration::logHeaders()
{
    if (log_file_)
        *log_file_ << "kernel,dispatch,startNs,endNs" << std::endl;
    else
        std::cerr << "Unable to log headers - not log location set\n";
}

bool logDuration::setLocation(const std::string& strLocation)
{
    if (location_ != "console")
    {
        if (log_file_)
            delete log_file_;
    }
    //cerr << "logDuration::setLocation = " << strLocation << std::endl;
    location_ = strLocation;
    if (!location_.length())
        location_ = "/dev/null";
    if (location_ == "console")
        log_file_ = &cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
    return log_file_ != NULL;
}

void clipKernelName(std::string& str)
{
    // Find the position of the last comma in the string
    size_t lastCommaPos = str.rfind(')');

    // If a comma is found, replace it with a right parenthesis and terminate the string
    if (lastCommaPos != std::string::npos) {
        str.resize(lastCommaPos + 1); // Resize the string to terminate after the parenthesis
    }
}

void clipInstrumentedKernelName(std::string& str) {
    // Find the position of the last comma in the string
    size_t lastCommaPos = str.rfind(',');

    // If a comma is found, replace it with a right parenthesis and terminate the string
    if (lastCommaPos != std::string::npos) {
        str[lastCommaPos] = ')';
        str.resize(lastCommaPos + 1); // Resize the string to terminate after the parenthesis
    }
}


KernArgAllocator::KernArgAllocator(HsaApiTable *apiTable, ostream& out) : out_(out), apiTable_(apiTable)
{
    apiTable_->core_->hsa_iterate_agents_fn([](hsa_agent_t agent, void *data){
        hsa_device_type_t type;
        if (hsa_agent_get_info(agent,HSA_AGENT_INFO_DEVICE, &type) == HSA_STATUS_SUCCESS && type == HSA_DEVICE_TYPE_CPU)
        {
            hsa_amd_agent_iterate_memory_pools(agent, [](hsa_amd_memory_pool_t pool, void *data){
                hsa_amd_segment_t segment;
                uint32_t flags;
                hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SEGMENT, &segment);
                if (HSA_AMD_SEGMENT_GLOBAL != segment)
                    return HSA_STATUS_SUCCESS;
                hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS, &flags);
                if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT)
                    reinterpret_cast<KernArgAllocator *>(data)->setPool(pool);
                return HSA_STATUS_SUCCESS;
            }, data);
        }
        return HSA_STATUS_SUCCESS;
    }, this);
}

void * KernArgAllocator::allocate(size_t size, hsa_agent_t allowed) const
{
  uint8_t* buffer = NULL;
  size = (size + RH_PAGE_MASK) & ~RH_PAGE_MASK;
  auto status = hsa_amd_memory_pool_allocate(pool_, size, 0, reinterpret_cast<void**>(&buffer));
  // Both the CPU and GPU can access the memory
  if (status == HSA_STATUS_SUCCESS) {
    status = hsa_amd_agents_allow_access(1, &allowed, NULL, buffer);
  }
  uint8_t* ptr = (status == HSA_STATUS_SUCCESS) ? buffer : NULL;
  return ptr;
}

void KernArgAllocator::free(void *ptr) const
{
    hsa_amd_memory_pool_free(ptr);
}

KernArgAllocator::~KernArgAllocator()
{
}

#define CHECK_COMGR(call)                                                                          \
  if (amd_comgr_status_s status = call) {                                                          \
    const char* reason = "";                                                                       \
    amd_comgr_status_string(status, &reason);                                                      \
    std::cerr << __LINE__ << " code: " << status << std::endl;                                     \
    std::cerr << __LINE__ << " failed: " << reason << std::endl;                                   \
    exit(1);                                                                                       \
  }

KernelArgHelper::KernelArgHelper(const std::string file_name)
{
    /*
     * Load and pull kernel argument data out of an .hsaco file
     * This code makes no assumptions about what ISA is supported
     * on this system or whether the code will actually run.
     * It is built to assume something akin to the Triton
     * JITed code cache and that if this is called, the code is known
     * to work on some agent on this system.
    */
    amd_comgr_data_t executable;
    std::vector<char> buff;
    std::ifstream file(file_name, std::ios::binary | std::ios::ate);

    if (!file.is_open()) {
        std::cerr << "Failed to open the file: " << file_name << std::endl;
    }

    std::streamsize fileSize = file.tellg();
    file.seekg(0, std::ios::beg);

    // Resize the buffer to fit the file content
    buff.resize(fileSize);

    // Read the file content into the buffer
    if (!file.read(buff.data(), fileSize)) {
        std::cerr << "Failed to read the file content" << std::endl;
    }
    file.close();
    CHECK_COMGR(amd_comgr_create_data(AMD_COMGR_DATA_KIND_EXECUTABLE, &executable));
    CHECK_COMGR(amd_comgr_set_data(executable, buff.size(), buff.data()));

    amd_comgr_metadata_node_t metadata;
    CHECK_COMGR(amd_comgr_get_data_metadata(executable, &metadata));

    amd_comgr_metadata_kind_t md_kind;
    CHECK_COMGR(amd_comgr_get_metadata_kind(metadata, &md_kind));

    if (md_kind == AMD_COMGR_METADATA_KIND_MAP)
    {
        std::string strIndent("");
        std::map<std::string, arg_descriptor_t> parms;
        computeKernargData(metadata);
    }
    CHECK_COMGR(amd_comgr_release_data(executable));
}

KernelArgHelper::~KernelArgHelper()
{
}

std::vector<size_t> findCodeObjectOffsets(hsa_agent_t agent, std::vector<uint8_t>& bits)
{
    std::cout << "=== Analyzing Clang Offload Bundle structure ===" << std::endl;
    // std::cout << "Bundle size: " << bits.size() << " bytes" << std::endl;

    const char* CLANG_OFFLOAD_MAGIC = "__CLANG_OFFLOAD_BUNDLE__";
    const size_t MAGIC_SIZE = 24;
    const size_t ALIGNMENT = 4096; // 4096-byte alignment

    std::vector<size_t> bundle_offsets;
    size_t search_offset = 0;

    // Search for Clang Offload Bundles using calculated positions
    while (search_offset < bits.size()) {
        // Check if there's a valid bundle at this position
        if (search_offset + MAGIC_SIZE > bits.size()) {
            break;
        }

        // Validate that the data starts with "__CLANG_OFFLOAD_BUNDLE__"
        if (memcmp(bits.data() + search_offset, CLANG_OFFLOAD_MAGIC, MAGIC_SIZE) != 0) {
            std::cout << "No bundle found at expected position 0x" << std::hex << search_offset << std::dec << ", stopping search" << std::endl;
            break;
        }

        bundle_offsets.push_back(search_offset);
        // std::cout << "Found Clang Offload Bundle at offset: 0x" << std::hex << search_offset << std::dec << " (" << search_offset << ")" << std::endl;

        // Calculate the next bundle position
        if (search_offset + MAGIC_SIZE + 8 > bits.size()) {
            break;
        }

        uint64_t num_bundles = *reinterpret_cast<const uint64_t*>(bits.data() + search_offset + MAGIC_SIZE);
        // std::cout << "Number of sub-bundles: " << num_bundles << std::endl;

        size_t offset = search_offset + MAGIC_SIZE + 8;
        uint64_t last_bundle_end = 0; // Track the furthest end position relative to bundle start

        // Parse sub-bundles to find their details and the maximum end position
        for (uint64_t i = 0; i < num_bundles && offset + 24 <= bits.size(); i++) {
            uint64_t bundle_offset = *reinterpret_cast<const uint64_t*>(bits.data() + offset);
            uint64_t bundle_size = *reinterpret_cast<const uint64_t*>(bits.data() + offset + 8);
            uint64_t triple_size = *reinterpret_cast<const uint64_t*>(bits.data() + offset + 16);

            offset += 24;
            if (offset + triple_size > bits.size()) break;

            // Read triple string
            std::string triple(reinterpret_cast<const char*>(bits.data() + offset), triple_size);
            if (!triple.empty() && triple.back() == '\0') {
                triple.pop_back(); // Remove null terminator
            }
            offset += triple_size;

            uint64_t bundle_end = bundle_offset + bundle_size;

            // std::cout << "Sub-bundle " << i << ":" << std::endl;
            // std::cout << "  Triple: " << triple << std::endl;
            // std::cout << "  Offset: 0x" << std::hex << bundle_offset << std::dec << " (" << bundle_offset << ")" << std::endl;
            // std::cout << "  Size: " << bundle_size << " bytes" << std::endl;
            // std::cout << "  End: 0x" << std::hex << bundle_end << std::dec << std::endl;
            // std::cout << "  Status: " << (search_offset + bundle_end <= bits.size() ? "Valid" : "Invalid") << std::endl;
            // std::cout << std::endl;

            // Track the last sub-bundle end position (relative to bundle start)
            if (i == num_bundles - 1) {
                last_bundle_end = bundle_end;
            }
        }

        // Calculate absolute end position and round up to next 4096-byte boundary
        uint64_t absolute_end = search_offset + last_bundle_end;
        search_offset = ((absolute_end + ALIGNMENT - 1) / ALIGNMENT) * ALIGNMENT;
        // std::cout << "Next bundle search position: 0x" << std::hex << search_offset << std::dec << std::endl;
        // std::cout << std::endl;
    }

    std::cout << "Total Clang Offload Bundles found: " << bundle_offsets.size() << std::endl;
    std::cout << "=== End analysis ===" << std::endl;
    return bundle_offsets;
}

/*
 * The bits vector passed to this function is created by reading the .fatbin section of an elf binary.
 * These bits take the form of a bundle of code objects, with each code object in the bundle representing
 * A different ISA. This function does the following:
 *   1. Query all the isa's supported by the agent supplied as a parameter. It's theoretically possible
 *      for an agent to support more than one ISA. the call to getIsaList returns a vector of ISA names.
 *   2. Create a FATBIN comgr data object and set the bits into an object of that type.
 *   3. To find a code object that will run on the supplied agent, this function creates an array of
 *      code object info structures, Each of these structures contains a pointer to the isa name,
 *      and the code object offset and length are set to zero.
 *   4. This array of code_object_info structs is passed to a comgr helper function (i.e. lookup_code_object)
 *      to find the offset and length for any code objects in the bundle that match one of the isas supported
 *      by the agent passed in to this method.
 *   5. The first code_object_info struct in the array that has had its offset and length initialized to non-zero
 *      is used to create an executable which can be used to query kernel argument metadata for any kernels in
 *      the code object. */

std::vector<amd_comgr_code_object_info_t> KernelArgHelper::getCodeObjectInfo(hsa_agent_t agent, std::vector<uint8_t>& bits)
{
    std::vector<amd_comgr_code_object_info_t> results;
    auto code_object_offsets = findCodeObjectOffsets(agent, bits);

    for(size_t co_idx = 0; co_idx != code_object_offsets.size(); ++co_idx)
    {
        amd_comgr_data_t bundle;
        std::vector<std::string> isas = getIsaList(agent);
        CHECK_COMGR(amd_comgr_create_data(AMD_COMGR_DATA_KIND_FATBIN, &bundle));
        CHECK_COMGR(amd_comgr_set_data(bundle, bits.size() - code_object_offsets[co_idx],
                                       reinterpret_cast<const char *>(bits.data() + code_object_offsets[co_idx])));
        if (isas.size())
        {
            std::vector<amd_comgr_code_object_info_t> ql;
            for (int i = 0; i < isas.size(); i++)
                ql.push_back({isas[i].c_str(), 0, 0});

            CHECK_COMGR(amd_comgr_lookup_code_object(bundle, static_cast<amd_comgr_code_object_info_t *>(ql.data()), ql.size()));

            for (auto co : ql)
            {
                co.offset += code_object_offsets[co_idx];
                /* Collect all ISA-compatible code objects */
                if (co.size != 0)
                {
                    results.push_back(co);
                    break;  // Only take the first compatible ISA for this bundle offset
                }
            }
        }
        CHECK_COMGR(amd_comgr_release_data(bundle));
    }

    return results;
}

KernelArgHelper::KernelArgHelper(hsa_agent_t agent, std::vector<uint8_t>& bits)
{
    /*
     * This code is given bits from a fat binary and needs to find a code object
     * Since fat binaries can contain code objects for multiple ISAs, we use
     * the supplied agent to find a code object that will run on that agent */
    auto code_object_offsets =  findCodeObjectOffsets(agent, bits);
    for(size_t co_idx = 0; co_idx != code_object_offsets.size(); ++co_idx)
    {
        amd_comgr_data_t bundle;
        std::vector<std::string> isas = getIsaList(agent);
        CHECK_COMGR(amd_comgr_create_data(AMD_COMGR_DATA_KIND_FATBIN, &bundle));
        CHECK_COMGR(amd_comgr_set_data(bundle, bits.size() - code_object_offsets[co_idx],
                                       reinterpret_cast<const char *>(bits.data() + code_object_offsets[co_idx])));
        if (isas.size())
        {
            std::vector<amd_comgr_code_object_info_t> ql;
            for (int i = 0; i < isas.size(); i++)
                ql.push_back({isas[i].c_str(),0,0});
            CHECK_COMGR(amd_comgr_lookup_code_object(bundle,static_cast<amd_comgr_code_object_info_t *>(ql.data()), ql.size()));
            for (auto co : ql)
            {
                co.offset += code_object_offsets[co_idx];
                /* Use the first code object that is ISA-compatible with this agent */
                if (co.size != 0)
                {
                    addCodeObject(reinterpret_cast<const char *>(bits.data() + co.offset), co.size);
                    break;
                }
            }
        }
        CHECK_COMGR(amd_comgr_release_data(bundle));
    }
}


/* Given the bits of a code object, create an instance of a comgr executable
 * and siphon out all of the kernel argument metadata needed later on
 * when we rewrite kernargs to inject a pointer to a dh_comms object. */

void KernelArgHelper::addCodeObject(const char *bits, size_t length)
{
    amd_comgr_data_t executable;
    CHECK_COMGR(amd_comgr_create_data(AMD_COMGR_DATA_KIND_EXECUTABLE, &executable));
    CHECK_COMGR(amd_comgr_set_data(executable, length, bits));
    amd_comgr_metadata_node_t metadata;
    CHECK_COMGR(amd_comgr_get_data_metadata(executable, &metadata));
    amd_comgr_metadata_kind_t md_kind;
    CHECK_COMGR(amd_comgr_get_metadata_kind(metadata, &md_kind));

    if (md_kind == AMD_COMGR_METADATA_KIND_MAP)
    {
        std::string strIndent("");
        std::map<std::string, arg_descriptor_t> parms;
        computeKernargData(metadata);
    }
    CHECK_COMGR(amd_comgr_release_data(executable));

}
/* A helper function to create a list of all the shared libraries in use by the current
 * process. This is needed for HIP-style applications where, rather than utilizing
 * a code object cache of .hsaco files (e.g. the way Triton works), the application
 * is s HIP application where the instrumented clones are bound to the executable in
 * a fat binary */
void KernelArgHelper::getSharedLibraries(std::vector<std::string>& libraries) {
    dl_iterate_phdr([](struct dl_phdr_info *info, size_t size, void *data){
        std::vector<std::string>* p_libraries = static_cast<std::vector<std::string>*>(data);

        if (info->dlpi_name && *info->dlpi_name) {  // Filter out empty names
            p_libraries->push_back(std::string(info->dlpi_name));
        }

        return 0;  // Continue iteration
    }, &libraries);
    return;
}
std::string KernelArgHelper::get_metadata_string(amd_comgr_metadata_node_t node)
{
    std::string strValue;
    amd_comgr_metadata_kind_t kind;
    CHECK_COMGR(amd_comgr_get_metadata_kind(node, &kind));
    if (kind == AMD_COMGR_METADATA_KIND_STRING)
    {
        size_t size;
        CHECK_COMGR(amd_comgr_get_metadata_string(node, &size, NULL));
        strValue.resize(size-1);
        CHECK_COMGR(amd_comgr_get_metadata_string(node, &size, &strValue[0]));
    }
    return strValue;
}

// Function to read the bits of a specific section from an ELF binary. This is a helper function
// used to get the bits of the .hip_fatbin section which contains the code object bundle we
// will use to find a code object with an ISA that is compatible with the agent running
// on this machine.
void KernelArgHelper::getElfSectionBits(const std::string &fileName, const std::string &sectionName, std::vector<uint8_t>& sectionData ) {
    std::ifstream file(fileName, std::ios::binary);
    if (!file) {
        throw std::runtime_error("Could not open file: " + fileName);
    }

    // Read ELF header
    Elf64_Ehdr elfHeader;
    file.read(reinterpret_cast<char*>(&elfHeader), sizeof(elfHeader));

    // Check if it's an ELF file
    if (memcmp(elfHeader.e_ident, ELFMAG, SELFMAG) != 0) {
        throw std::runtime_error("Not a valid ELF file");
    }

    // Seek to the section header table
    file.seekg(elfHeader.e_shoff, std::ios::beg);

    // Read all section headers
    std::vector<Elf64_Shdr> sectionHeaders(elfHeader.e_shnum);
    file.read(reinterpret_cast<char*>(sectionHeaders.data()), elfHeader.e_shnum * sizeof(Elf64_Shdr));

    // Seek to the section header string table
    const Elf64_Shdr &shstrtab = sectionHeaders[elfHeader.e_shstrndx];
    std::vector<char> shstrtabData(shstrtab.sh_size);
    file.seekg(shstrtab.sh_offset, std::ios::beg);
    file.read(shstrtabData.data(), shstrtab.sh_size);

    // Find the section by name
    for (const auto &section : sectionHeaders) {
        std::string currentSectionName(&shstrtabData[section.sh_name]);

        if (currentSectionName == sectionName) {
            // Read the section data
            sectionData.resize(section.sh_size);
            file.seekg(section.sh_offset, std::ios::beg);
            file.read(reinterpret_cast<char*>(sectionData.data()), section.sh_size);
            return;  // Return the section bits
        }
    }

    throw std::runtime_error("Section not found: " + sectionName);
}

/* The way instrumented clones are created, the compiler adds a void * parameter to the end of the parameter list
 * of the instrumented kernel. The void * is actually expected to be a pointer to device memory to a dh_comms::dh_comms_descriptor
 * At runtime, this library silently replaces the application's kernel with an instrumentd equivalent that has the added void *
 * parameter. But that means the kernel args passed to the original kernel are incomplete. So we have to create
 * a new kernarg segement that contains the approprate device memory pointer in its last argument.
 * kernarg segments contain both explicit and implicit (or hidden) parameters. The pointer to the dh_comms_descriptor has
 * to be inserted between the original explicit arguments and the first implicit argument. Therefore, in order
 * to reconstruct a kernarg segment that will work, we need to know the layout, especially where in the kernarg
 * segment we need to insert the dh_comms_descriptor *. This method extracts the relevant metadata
 * from a code object exectuble needed to reconstruct a kernarg segment for an instrumented kernel.*/

void KernelArgHelper::computeKernargData(amd_comgr_metadata_node_t exec_map)
{
    amd_comgr_metadata_node_t kernels;
    amd_comgr_metadata_node_t args;
    amd_comgr_metadata_node_t kernarg_length;
    CHECK_COMGR(amd_comgr_metadata_lookup(exec_map, "amdhsa.kernels", &kernels));
    size_t size;
    CHECK_COMGR(amd_comgr_get_metadata_list_size(kernels, &size));
    for (size_t i = 0; i < size; i++)
    {
        amd_comgr_metadata_node_t value;
        amd_comgr_metadata_kind_t kind;
        CHECK_COMGR(amd_comgr_index_list_metadata(kernels, i, &value));
        CHECK_COMGR(amd_comgr_get_metadata_kind(value, &kind));

        if (kind == AMD_COMGR_METADATA_KIND_MAP)
        {
            amd_comgr_metadata_node_t field;
            CHECK_COMGR(amd_comgr_metadata_lookup(value,".symbol", &field));
            std::string strName = get_metadata_string(field);
            strName = demangleName(strName.c_str());
            arg_descriptor_t desc = {};
            amd_comgr_metadata_node_t args;
            CHECK_COMGR(amd_comgr_metadata_lookup(value, ".args", &args));
            CHECK_COMGR(amd_comgr_get_metadata_kind(args, &kind));
            amd_comgr_metadata_node_t kernarg_length,private_size, group_size;
            CHECK_COMGR(amd_comgr_metadata_lookup(value, ".kernarg_segment_size", &kernarg_length));
            CHECK_COMGR(amd_comgr_metadata_lookup(value, ".private_segment_fixed_size", &private_size));
            CHECK_COMGR(amd_comgr_metadata_lookup(value, ".group_segment_fixed_size", &group_size));
            desc.private_segment_size = std::stoul(get_metadata_string(private_size));
            desc.group_segment_size = std::stoul(get_metadata_string(group_size));
            desc.kernarg_length = std::stoul(get_metadata_string(kernarg_length));
            if (kind == AMD_COMGR_METADATA_KIND_LIST)
            {
                size_t arg_count;
                CHECK_COMGR(amd_comgr_get_metadata_list_size(args, &arg_count));
                for (size_t j = 0; j < arg_count; j++)
                {
                    amd_comgr_metadata_node_t parm_map;
                    amd_comgr_metadata_kind_t parm_kind;
                    CHECK_COMGR(amd_comgr_index_list_metadata(args, j, &parm_map));
                    CHECK_COMGR(amd_comgr_get_metadata_kind(parm_map,&parm_kind));
                    if (parm_kind == AMD_COMGR_METADATA_KIND_MAP)
                    {
                        amd_comgr_metadata_node_t parm_size, parm_type, parm_offset;
                        CHECK_COMGR(amd_comgr_metadata_lookup(parm_map, ".size", &parm_size));
                        CHECK_COMGR(amd_comgr_metadata_lookup(parm_map, ".value_kind", &parm_type));
                        CHECK_COMGR(amd_comgr_metadata_lookup(parm_map, ".offset", &parm_offset));
                        size_t arg_size = std::stoul(get_metadata_string(parm_size));
                        size_t arg_offset = std::stoul(get_metadata_string(parm_offset));
                        std::string parm_name = get_metadata_string(parm_type);
                        //std::cout << "Name, Offset, Size\n";
                        //std::cout << parm_name << "," << arg_offset << "," << arg_size << std::endl;
                        if (parm_name.rfind("hidden_",0) == 0)
                            desc.hidden_args_length = arg_offset + arg_size;
                        else
                        {
                            desc.explicit_args_count++;
                            desc.explicit_args_length = arg_offset + arg_size;
                        }
                    }
                }
            }
            desc.explicit_args_length = std::min(roundArgsLength(desc.explicit_args_length), desc.kernarg_length);
            desc.hidden_args_length = desc.kernarg_length - desc.explicit_args_length;
            kernels_[strName] = desc;
        }
    }
}

bool KernelArgHelper::getArgDescriptor(const std::string& strName, arg_descriptor_t& desc)
{
    bool bSuccess = false;
    auto it = kernels_.find(strName);
    if (it != kernels_.end())
    {
        bSuccess = true;
        desc = it->second;
        //std::cerr << strName << " {" << desc.explicit_args_length << ", " << desc.hidden_args_length << ", " << desc.kernarg_length << "}\n";
    }
    else
    {
        //std::cerr << "getArgDescriptor: Looking for " << strName << " but I only now about -\n";
        for (auto it : kernels_)
        {
          //  std::cerr << "\t" << it.first << std::endl;
        }
    }
    return bSuccess;
}


handlerManager::handlerManager()
{
}

handlerManager::handlerManager(const std::vector<std::string>& handlers)
{
    setHandlers(handlers);
}

handlerManager::~handlerManager()
{
    auto it = plugins_.begin();
    while(it != plugins_.end())
    {
        dlclose(it->first);
        it++;
    }
}

void handlerManager::getMessageHandlers(const std::string& strKernel, uint64_t dispatch_id,std::vector<dh_comms::message_handler_base *>& outHandlers)
{
    for(auto it : plugins_)
        it.second(strKernel, dispatch_id, outHandlers);
}

bool handlerManager::setHandlers(const std::vector<std::string>& handlers)
{
    for (auto lib : handlers)
    {
        void *handle = dlopen(lib.c_str(),RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
        std::cerr << "handlerManager: Opened" << lib.c_str() << std::endl;
        if (!handle)
        {
            std::cerr << "dlopen failed: " <<  dlerror() << std::endl;
            std::cerr << "ERROR: " << errno << " while trying to load " << lib << std::endl;
            exit(1);
        }
        else
        {
            getMessageHandlers_t func = reinterpret_cast<getMessageHandlers_t>(dlsym(handle, "getMessageHandlers"));
            if (func)
            {
                plugins_[handle] = func;
            }
        }
    }
    return true;
}


randomDispatcher::randomDispatcher(int distro): generator_(static_cast<unsigned>(std::time(nullptr))), distribution_(1, distro)
{
}

randomDispatcher::~randomDispatcher()
{
}

bool randomDispatcher::canDispatch()
{
    return distribution_(generator_) == 1;
}

dispatchController::dispatchController() : randomDispatcher_(RANDOM_DISPATCH_DISTRIBUTION)
{
    std::map<std::string, std::string> config;
    getLogDurConfig(config);
    auto it = config.find("LOGDUR_DISPATCHES");
    if (it != config.end())
    {
        if (it->second == "random")
        {
            bRandomDispatch_ = true;
            bAllDispatch_ = false;
            bOneDispatch_ = false;
        }
        else if (it->second == "all")
        {
            bAllDispatch_ = true;
            bRandomDispatch_ = false;
            bOneDispatch_ = false;
        }
        else if (it->second == "1")
        {
            bOneDispatch_ = true;
            bAllDispatch_ = false;
            bRandomDispatch_ = false;
        }
    }
    else
        bAllDispatch_ = true;
}

dispatchController::~dispatchController()
{
}

bool dispatchController::canDispatch(uint64_t kernel_object)
{
    if (bRandomDispatch_)
        return randomDispatcher_.canDispatch();
    else if (bOneDispatch_)
    {
        bool bReturn = false;
        auto it = dispatched_kernels_.find(kernel_object);
        if (it == dispatched_kernels_.end())
        {
            dispatched_kernels_[kernel_object] = true;
            return true;
        }
        else
            return false;
    }
    else
        return true;
}
