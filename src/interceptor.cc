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

///////////////////////////////////////////////////////////////////////////////
//                                                                           //
// Test tool used to experiment with interactive profiling.                  //
//                                                                           //
///////////////////////////////////////////////////////////////////////////////
#undef NDEBUG
#include <assert.h>
#include <cxxabi.h>
#include <dirent.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>   /* For SYS_xxx definitions */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/inotify.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>

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


#include "inc/interceptor.h"


using namespace std;
namespace fs = std::filesystem;

int PID = getpid();

ofstream LOG(string("/tmp") + "/rocscope.log." + to_string(PID));

template<typename T>
void PR(const T& arg) { LOG << arg << '\n' << flush; }

template<typename T, typename ...TS>
void PR(const T& arg, const TS&... args) { LOG << arg << " "; PR(args...); }

const char *DBG = ">>>>>>>>";
const char *INTERCEPTOR_MSG = "[hsaInterceptor] ";

std::mutex hsaInterceptor::singleton_mutex_;

hsaInterceptor * hsaInterceptor::getInstance(HsaApiTable *table, uint64_t runtime_version, uint64_t failed_tool_count, const char* const* failed_tool_names)
{
    const lock_guard<mutex> lock(singleton_mutex_);
    if (!singleton_)
    {
        if (table != NULL)
        {
            singleton_ = new hsaInterceptor(table, runtime_version, failed_tool_count, failed_tool_names);
            singleton_->saveHsaApi();
            singleton_->hookApi();
        }
        else
            cerr << "hsaInterceptor Initialization failed - API table is NULL" << endl;
    }
    return singleton_;
}


void hsaInterceptor::OnSubmitPackets(const void* in_packets, uint64_t count,
    uint64_t user_que_idx, void* data, hsa_amd_queue_intercept_packet_writer writer)
{
    hsaInterceptor *hook = hsaInterceptor::getInstance();
    if (hook)
    {
        hsa_queue_t *queue = reinterpret_cast<hsa_queue_t *>(data);
        hook->doPackets(queue, static_cast<const packet_t *>(in_packets), count, writer);
    }
    else
        writer(in_packets, count);
}

bool hsaInterceptor::shuttingdown()
{
    return shutting_down_.load();
}

void hsaInterceptor::shutdown()
{
    shutting_down_.store(true);
}




void hsaInterceptor::cleanup()
{
    if(singleton_)
    {
        delete singleton_;
        singleton_ = NULL;
    }
}


hsaInterceptor::hsaInterceptor(HsaApiTable* table, uint64_t runtime_version, uint64_t failed_tool_count, const char* const* failed_tool_names) :
    signal_runner_(signal_runner), cache_watcher_(cache_watcher), kernel_cache_(table), allocator_(table, std::cerr),
        comms_mgr_(table), comms_runner_(comms_runner, std::ref(comms_mgr_))
{
    apiTable_ = table;
    getLogDurConfig(config_);
    comms_mgr_.setConfig(config_);
    log_.setLocation(config_["LOGDUR_LOG_LOCATION"]);
    if (config_["LOGDUR_INSTRUMENTED"] == "true")
    {
        run_instrumented_ = true;
    }
    else
        run_instrumented_ = false;
    if (!run_instrumented_)
        log_.logHeaders();
    //kernel_cache_.setLocation(config_["LOGDUR_KERNEL_CACHE"]);
    for (int i = 0; i < SIGPOOL_INCREMENT; i++)
    {
        hsa_signal_t curr_sig;
        CHECK_STATUS("Signal creation error at startup",apiTable_->core_->hsa_signal_create_fn(1,0,NULL,&curr_sig));
        sig_pool_.emplace_back(curr_sig);
    }
    if (run_instrumented_)
    {
        std::vector<hsa_agent_t> gpus;
        if (hsa_iterate_agents ([](hsa_agent_t agent, void *data){
                        std::vector<hsa_agent_t> *agents  = reinterpret_cast<std::vector<hsa_agent_t> *>(data);
                        hsa_device_type_t type;
                        hsa_status_t status = hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, static_cast<void *>(&type));
                        if (status == HSA_STATUS_SUCCESS && type == HSA_DEVICE_TYPE_GPU)
                            agents->emplace_back(agent);
                        return HSA_STATUS_SUCCESS;
                    }, reinterpret_cast<void *>(&gpus))== HSA_STATUS_SUCCESS)
                {
                    std::string cacheLocation = config_["LOGDUR_KERNEL_CACHE"];
                    std::string strFilter = config_["LOGDUR_FILTER"];
                    for (auto agent : gpus)
                    {
                        /* If we're running Triton, the user needs to specify the location of the Triton
                         * code object cache directory - usually in $HOME/.triton/cache */
                        if (cacheLocation.length())
                            kernel_cache_.setLocation(agent, cacheLocation, config_["LOGDUR_FILTER"]);
                        else
                        {
                            /* If a KERNEL_CACHE directory is not supplied, we look for all the kernels in fat binaries
                             * (this will be the normal case for, say, HIP applications. */
                            std::vector<std::string>files;
                            files.push_back(getExecutablePath());
                            KernelArgHelper::getSharedLibraries(files);
                            for (auto file : files)
                            {
                                //std::cerr << "File with a possible .fatbin section: " << file << std::endl;
                                try
                                {
                                    kernel_cache_.addFile(file, agent, strFilter);
                                }
                                catch (const std::runtime_error e)
                                {
                                    /* I catch this exception because the shared libraries returned by getSharedLibraries
                                     * can include system libs that do not have the full path to the .so file
                                     * these files will cause addFile() to throw a runtime exception.
                                     * these exceptions are benign for our purposes because any shared lib
                                     * we might be interested in (i.e. the ones that contain .hip_fatbin sections)
                                     * will enumerate from getSharedLibraries with a full path to the file.
                                     * so we catch this exception and continue */
                                    continue;
                                }
                            }

                            kdbs_[agent] = std::make_unique<kernelDB::kernelDB>(agent, "");
                        }
                        comms_mgr_.addAgent(agent);
                    }
                }
    }
}
hsaInterceptor::~hsaInterceptor() {
    shutting_down_.store(true);
    //cerr << "Joining the signal runner\n";
    signal_runner_.join();
    cache_watcher_.join();
    comms_runner_.join();
    // Join signal processing thread here
    lock_guard<std::mutex> lock(mutex_);
    for (auto sig : sig_pool_)
        CHECK_STATUS("Signal cleanup error at shutdown", apiTable_->core_->hsa_signal_destroy_fn(sig));
    restoreHsaApi();
}

bool hsaInterceptor::growBufferPool(hsa_agent_t agent, size_t count)
{
    return false;
}

hsa_mem_mgr * hsaInterceptor::checkoutBuffer(hsa_agent_t agent)
{
    return NULL;
}

bool hsaInterceptor::checkinBuffer(hsa_agent_t agent)
{
    return false;
}

bool hsaInterceptor::addCodeObject(const std::string& name)
{
    std::vector<hsa_agent_t> gpus;
    if (hsa_iterate_agents ([](hsa_agent_t agent, void *data){
                    std::vector<hsa_agent_t> *agents  = reinterpret_cast<std::vector<hsa_agent_t> *>(data);
                    hsa_device_type_t type;
                    hsa_status_t status = hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, static_cast<void *>(&type));
                    if (status == HSA_STATUS_SUCCESS && type == HSA_DEVICE_TYPE_GPU)
                        agents->emplace_back(agent);
                    return HSA_STATUS_SUCCESS;
                }, reinterpret_cast<void *>(&gpus))== HSA_STATUS_SUCCESS)
    {
        if (name.length())
        {
            for (auto agent : gpus)
            {
                kernel_cache_.addFile(name, agent, config_["LOGDUR_FILTER"]);
                lock_guard<std::mutex> lock(mutex_);
                auto it = kdbs_.find(agent);
                if (it != kdbs_.end())
                    it->second.get()->addFile(name, agent, config_["LOGDUR_FILTER"]);
                else
                    kdbs_[agent] = std::make_unique<kernelDB::kernelDB>(agent, name);
            }
        }
    }
    return true;
}

decltype(hsa_queue_create)* hsa_queue_create_fn;
decltype(hsa_queue_destroy)* hsa_queue_destroy_fn;
decltype(hsa_amd_queue_intercept_create)* hsa_amd_queue_intercept_create_fn;
decltype(hsa_amd_queue_intercept_register)* hsa_amd_queue_intercept_register_fn;
decltype(hsa_executable_symbol_get_info)* hsa_executable_symbol_get_info_fn;

void hsaInterceptor::saveHsaApi() {


  hsa_queue_create_fn = apiTable_->core_->hsa_queue_create_fn;
  hsa_queue_destroy_fn = apiTable_->core_->hsa_queue_destroy_fn;
  hsa_amd_queue_intercept_create_fn = apiTable_->amd_ext_->hsa_amd_queue_intercept_create_fn;
  hsa_amd_queue_intercept_register_fn = apiTable_->amd_ext_->hsa_amd_queue_intercept_register_fn;
  hsa_executable_symbol_get_info_fn = apiTable_->core_->hsa_executable_symbol_get_info_fn;;
}

void hsaInterceptor::restoreHsaApi() {

  apiTable_->core_->hsa_queue_create_fn = hsa_queue_create_fn;
  apiTable_->core_->hsa_queue_destroy_fn = hsa_queue_destroy_fn;
  apiTable_->amd_ext_->hsa_amd_queue_intercept_create_fn = hsa_amd_queue_intercept_create_fn;
  apiTable_->amd_ext_->hsa_amd_queue_intercept_register_fn = hsa_amd_queue_intercept_register_fn;
  apiTable_->core_->hsa_executable_symbol_get_info_fn = hsa_executable_symbol_get_info_fn;

}

void hsaInterceptor::signalCompleted(const hsa_signal_t sig)
{
    lock_guard<std::mutex> lock(mutex_);
    auto it = pending_signals_.find(sig);
    if (it != pending_signals_.end())
    {
        kernel_info_t ki = it->second;
        pending_signals_.erase(sig);
        // If the application originally provided a completion_signal
        // We need to decrement it to ensure application behavior isn't affected.
        if (ki.signal_.handle)
        {
            // need to subtract here because that would have been done if we hadn't swapped signals
            hsa_signal_subtract_scacq_screl(ki.signal_, 1);
        }
        // Need to extract start and stop here
        hsa_amd_profiling_dispatch_time_t this_time;
        apiTable_->amd_ext_->hsa_amd_profiling_get_dispatch_time_fn(ki.agent_, sig, &this_time);
        auto startNs = this_time.start;
        auto endNs = this_time.end;
        auto dispatchNs = ki.th_.getStartTime();
        if (!run_instrumented_)
            log_.log(ki.name_, dispatchNs, startNs, endNs);
        //cerr << "Elapsed micro seconds with all the host overhead: " << std::dec << ki.th_.getElapsedMicros() << " us\n";
        //cerr << "\tMeasured kernel duration: " << endNs - startNs << " ns\n";
        // Reinitialize signal value to 1 for use in next dispatch.
        (apiTable_->core_->hsa_signal_store_screlease_fn)(sig, 1);
        // Look to see if we allocated an alternative kernarg  buffer  for this dispatch
        auto ka_it = pending_kernargs_.find(sig);
        if (ka_it != pending_kernargs_.end())
        {
            // Free any alternative kernarg buffer we allocated.
            allocator_.free(ka_it->second);
            pending_kernargs_.erase(sig);
        }
        //Put this completion signal back in the pool for subsequent dispatches
        sig_pool_.push_back(sig);
        if (ki.comms_obj_)
            comms_mgr_.checkinCommsObject(ki.agent_, ki.comms_obj_);
    }
    else
    {
        cerr << "Some big problem occurred, a pending signal is missing\n";
    }
}

void comms_runner(comms_mgr& mgr)
{
    //cerr << "Comms Runner\n";
    hsaInterceptor *me = hsaInterceptor::getInstance();
    while (!me->shuttingdown())
    {
        usleep(500);
    }
    cerr << "Comms Runner shutting down\n";
}

void cache_watcher()
{
    //cerr << "Cache Watcher\n";;
    hsaInterceptor *me = hsaInterceptor::getInstance();
    std::string dir = me->getCacheLocation();
    if (dir.length())
    {
        std::map<int, std::string> watch_map;
        int fd = inotify_init();
        if (fd < 0)
        {
            perror("inotify_init");
            exit(EXIT_FAILURE);
        }
        auto files = util_get_directory_files(dir, true);
        for (const auto& entry : files)
        {
            if (util_is_directory(entry))
            {
                int wd = inotify_add_watch(fd, entry.c_str(), IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO);
                if (wd != -1)
                {
                    watch_map[wd] = entry;
                    cerr << "Added " << entry << " to watch list\n";
                }
                else
                {
                    cerr << "Could not add " << entry << " to watch list\n";
                }
            }
        }


        int wd = inotify_add_watch(fd, dir.c_str(), IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO);
        if (wd == -1)
        {
            fprintf(stderr, "Cannot use '%s' as a kernel cache: %s\n", dir.c_str(), strerror(errno));
            close(fd);
            while (!me->shuttingdown())
                usleep(1000);
        }
        else
        {
            watch_map[wd] = dir.c_str();
            //printf("Watching directory '%s' for changes.\n", dir.c_str());
        }
        while (!me->shuttingdown())
        {
            const size_t event_size = sizeof(struct inotify_event);
            const size_t buf_len = 1024 * (event_size + 16);
            char buffer[buf_len];
            fd_set rfds;
            struct timeval tv;
            int retval;
            tv.tv_sec = 0;
            tv.tv_usec = 10000;
            FD_ZERO(&rfds);
            FD_SET(fd, &rfds);
            retval = select(fd+1, &rfds, NULL, NULL, &tv);
            if (retval != -1)
            {
                if (retval)
                {
                    if (FD_ISSET(fd, &rfds))
                    {
                        int length = read(fd, buffer, buf_len);
                        if (length < 0)
                        {
                            perror("read");
                            exit(EXIT_FAILURE);
                        }

                        int i = 0;
                        while (i < length)
                        {
                            struct inotify_event* event = (struct inotify_event*)&buffer[i];

                            if (event->len)
                            {
                                if (event->mask & IN_CREATE)
                                {
                                    struct stat path_stat;
                                    std::string strNewDirectory = watch_map[event->wd];
                                    strNewDirectory += "/";
                                    strNewDirectory += event->name;
                                    stat(strNewDirectory.c_str(), &path_stat);
                                    cerr << "Creating: " << strNewDirectory << std::endl;
                                    if (S_ISDIR(path_stat.st_mode)) {
                                        int wd = inotify_add_watch(fd, strNewDirectory.c_str(), IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO);
                                        if (wd != -1)
                                            watch_map[wd] = strNewDirectory;
                                      //  else
                                        //    cerr << "ERROR: Trying to watch " << strNewDirectory << std::endl;
                                    }
                                    else if (strNewDirectory.ends_with(".hsaco"))
                                    {
                                        //cerr << "New code object to process";
                                    }
                                    //cerr << "The file/directory " << event->name << "was created in directory " << watch_map[event->wd] << std::endl;
                                }
                                else if (event->mask & IN_DELETE)
                                {
                                    //printf("The file %s was deleted from directory %s.\n", event->name, dir);
                                }
                                else if (event->mask & IN_MODIFY)
                                {
                                    //cerr << "The file/directory " << event->name << "was modified in directory " << watch_map[event->wd] << std::endl;
                                }
                                else if (event->mask & IN_MOVED_FROM)
                                {
                                    //printf("The file %s was moved out of directory %s.\n", event->name, dir.c_str());
                                }
                                else if (event->mask & IN_MOVED_TO)
                                {
                                    std::string strFileName = watch_map[event->wd];
                                    strFileName += "/";
                                    strFileName += event->name;
                                    if (strFileName.ends_with(".hsaco"))
                                    {
                                      //  cerr << "I CAN SEE JITTED CODE OBJECT " << strFileName << std::endl;
                                        me->addCodeObject(strFileName);
                                    }
                                    //else
                                    //    cerr << "The file/directory " << event->name << " was moved to directory " << watch_map[event->wd] << std::endl;
                                }
                            }

                            i += event_size + event->len;
                        }
                    }
                }
            }
            else
                cerr << "Bug in monitoring kernel cache\n";
        }
        inotify_rm_watch(fd, wd);
        close(fd);
    }
    else
    {
        while (!me->shuttingdown())
            usleep(1000);
    }
    cerr << "Cache Watcher shutting down\n";
}

void signal_runner()
{
    hsaInterceptor *me = hsaInterceptor::getInstance();
    //uint64_t count = 0;
    while (!me->shuttingdown())
    {
        std::vector<hsa_signal_t> curr_sigs;
        if (me->getPendingSignals(curr_sigs))
        {
            do{
                auto size = curr_sigs.size();
                for (unsigned long int i = 0; i < size; i++)
                {
                    assert(curr_sigs[i].handle);
                    if (!me->signalWait(curr_sigs[i], 1))
                    {
                        me->signalCompleted(curr_sigs[i]);
      //                  count++;
                    }

                }
                curr_sigs.clear();
            }while (me->getPendingSignals(curr_sigs));
        }
        usleep(1);
    }
    cerr << "signal_runner is shutting down\n";
}

bool hsaInterceptor::signalWait(hsa_signal_t sig, uint64_t timeout)
{
    return (apiTable_->core_->hsa_signal_wait_scacquire_fn)(
                sig, HSA_SIGNAL_CONDITION_EQ, 0,
                timeout, HSA_WAIT_STATE_ACTIVE);
}

bool hsaInterceptor::getPendingSignals(std::vector<hsa_signal_t>& outSigs)
{
    lock_guard<std::mutex> lock(mutex);
    for (const auto& pair : pending_signals_)
    {
        outSigs.push_back(pair.first);
    }
    return outSigs.size() != 0;
}

string hsaInterceptor::packetToText(const packet_t *packet)
{
    assert(packet && "packet null!");
    ostringstream buff;
    uint32_t type = getHeaderType(packet);
    if (type == HSA_PACKET_TYPE_KERNEL_DISPATCH)
    {
        const hsa_kernel_dispatch_packet_t *disp = reinterpret_cast<const hsa_kernel_dispatch_packet_t *>(packet);
        uint32_t scope = getHeaderReleaseScope(disp);
        buff << "Dispatch Packet\n";
        buff << "\tRelease Scope: ";
        if (scope & HSA_FENCE_SCOPE_AGENT)
            buff << "HSA_FENCE_SCOPE_AGENT";
        else if (scope & HSA_FENCE_SCOPE_SYSTEM)
            buff << "HSA_FENCE_SCOPE_SYSTEM";
        else
            buff << hex << scope;
        buff << "\n";
        buff << "\tAcquire Scope: ";
        scope = getHeaderAcquireScope(disp);
        if (scope & HSA_FENCE_SCOPE_AGENT)
            buff << "HSA_FENCE_SCOPE_AGENT";
        else if (scope & HSA_FENCE_SCOPE_SYSTEM)
            buff << "HSA_FENCE_SCOPE_SYSTEM";
        else
            buff << "UNKNOWN";
        buff << "\n";
        buff << "\tsetup: 0x" << hex << disp->setup << "\n";
        buff << "\tworkgroup_size_x: 0x" << hex << disp->workgroup_size_x << "\n";
        buff << "\tworkgroup_size_y: 0x" << hex << disp->workgroup_size_y << "\n";
        buff << "\tworkgroup_size_z: 0x" << hex << disp->workgroup_size_z << "\n";
        buff << "\tgrid_size_x: 0x" << hex << disp->grid_size_x << "\n";
        buff << "\tgrid_size_y: 0x" << hex << disp->grid_size_y << "\n";
        buff << "\tgrid_size_z: 0x" << hex << disp->grid_size_z << "\n";
        buff << "\tprivate_segment_size: 0x" << hex << disp->private_segment_size << "\n";
        buff << "\tgroup_segment_size: 0x" << hex << disp->group_segment_size << "\n";
        buff << "\tkernel_object: 0x" << hex << disp->kernel_object << "\n";
        buff << "\tkernarg_address: 0x" << hex << disp->kernarg_address << "\n";
        buff << "\tcompletion_signal 0x" << hex << disp->completion_signal.handle << "\n";
    }
    else
    {
        buff << "Unsupported packet type\n";
    }
    return buff.str();
}


void test_pointers(char *dst, char *src, arg_descriptor_t desc)
{
    std::cerr << "src length for explicit args: " << std::dec << desc.explicit_args_length - sizeof(char *) << std::endl;
    std::cerr << "Dst offset for hidden args: " << (dst + desc.explicit_args_length) - dst << std::endl;
    std::cerr << "Src offset for hidden args: " << (src + desc.explicit_args_length - sizeof(void *)) - src << std::endl;
}

void dumpKernArgs(void *dst, void *src, arg_descriptor_t desc)
{
    uint32_t wordcount = desc.kernarg_length / 4;
    std::cout << "dumpKernelArgs: Compare 2 segments with largest segment size " << std::dec << desc.kernarg_length << std::endl;
    for(uint32_t i = 0; i < wordcount - 2; i++)
        std::cout << std::hex << std::setw(8) << std::setfill('0') << ((uint32_t *)src)[i] << "\t" << std::setw(8) << std::setfill('0') << ((uint32_t *)dst)[i] <<std::endl;
    std::cout << "\t\t" << std::hex << std::setw(8) << std::setfill('0') << ((uint32_t*)dst)[wordcount - 2] << std::endl;
    std::cout << "\t\t" << std::hex << std::setw(8) << std::setfill('0') << ((uint32_t*)dst)[wordcount - 1] << std::endl;
}


void dumpKernArgs(void *args, uint32_t size)
{
    uint32_t wordcount = size / 4;
    std::cout << "dumpKernelArgs: Single kernarg segment of size " << std::dec << size << std::endl;
    for(uint32_t i = 0; i < wordcount; i++)
        std::cout << std::hex << std::setw(8) << std::setfill('0') << ((uint32_t *)args)[i] << std::endl;
}

void hsaInterceptor::fixupKernArgs(void *dst, void *src, void *comms, arg_descriptor_t desc)
{
    assert(dst);
    assert(src);
    memset(dst, 0, desc.kernarg_length);
    // The descriptor here is a descriptor of the instrumented kernel, so
    // the parameter list of the non-instrumented original is always short one void*
    // relative to the desriptor supplied to this method
    // We want to copy all of the source kernargs except for it's original explicit arguments
    memcpy(dst, src, desc.explicit_args_length - sizeof(void *));
    // Compute where we want to copy hidden args. Right after the last explicit argument.
    void *hidden_args_dst = &(((char *)dst)[desc.explicit_args_length]);
    // We copy from the non-instrumented clone from the location after the last explicit arg in the src.
    // It has 1 fewer arguments than the instrumented clone (i.e. no dh_comms *)
    //void *hidden_args_src = &(((void **)src)[desc.explicit_args_count - 1]);
    void *hidden_args_src = &(((char *)src)[desc.explicit_args_length - sizeof(void *)]);
    // In Triton, for some reason we sometimes get non-instrumented kernsl with no hidden arguments
    // So we only want to copy hidden arguments if there ARE some. If there are, the length to
    // copy is the original size of the kernarg data - the size of explicit arguments. But since its
    // a kernarg segment from a non-instrumented clone, we subtract one from the arg count
    if (desc.clone_hidden_args_length)
    {
        // assert that we aren't going to copy a larger kernarg segment into a smaller one
        assert(desc.clone_hidden_args_length <= desc.kernarg_length - desc.explicit_args_length);
        memcpy(hidden_args_dst, hidden_args_src, desc.clone_hidden_args_length);
    }
    /* The weird thing here is that, apparently, kernel arguments are 4-byteb aligned
     * regardless of the actual argument size. This really bit me working on this code
     * because the metadata on kernel objects that is retrievable from comgr shows argument lengths
     * and at first I was using the argument length to repack the kernel arguments with the
     * newly inserted void * created by the instrumentation code. But after staring
     * at hex dumps, I realized that all of the kernel arguments (at least the explicit arguments,
     * I'm not sure about the hidden arguments) are 4-byte aligned regardless of the inherent argument
     * size. I don't know how portable this is between code object versions. I'm assuming it is some
     * aspect of code object first combined with the expecations of the GPU firmware.
     * */
    //void **comms_loc = &(((void **)dst)[desc.explicit_args_count  - 1]);
    // This computation using explicit_args_length is more adaptable to changes in the way the compiler
    // and runtime pack kernel arguments. For example 2 four-byte args might be packed into a single
    // 64 bit slot and the individual parms might not be 64-bit aligned. For any kernel where that
    // turns out to be the case, this address calculation with be resilient whether the args
    // are packed or not.
    void **comms_loc = (void **)&(((char *)dst)[desc.explicit_args_length  - sizeof(void *)]);
    *comms_loc = comms;
    // dumpKernArgs(dst, src, desc);
}

/*
    This function is the core of functionality for logDuration. It's where completion signals are set up for tracking so that
    at kernel completion we can extract start/stop times from the signal. It's also where "alternative" kernels - those found
    in the kernel cache pointed to by LOGDUR_KERNEL_CACHE - are used to replace the kernel_object in the dispatch packet with
    the kernel cache alternative. Also, whenever replacing the original kernel_object with an alternative, this function
    allocates a new kernarg structure, initializes it to zeros, and copies the original kernarg buffer into the new one.
    Pending signals and the alternative kernarg buffers are stored and processed later when the kernel completes and
    hsaIntereceptor::signalComplete is called.
*/
hsa_kernel_dispatch_packet_t * hsaInterceptor::fixupPacket(const hsa_kernel_dispatch_packet_t *packet, hsa_queue_t *queue, uint64_t dispatch_id)
{
    hsa_kernel_dispatch_packet_t *dispatch = new hsa_kernel_dispatch_packet_t;
    *dispatch = *packet;
    {
        lock_guard<std::mutex> lock(mutex_);
        hsa_signal_t sig;
        // If we're out of signals to use grow the pool.
        if (!sig_pool_.size())
        {
            for (int i = 0; i < SIGPOOL_INCREMENT; i++)
            {
                hsa_signal_t curr_sig = {};
                CHECK_STATUS("Signal creation error replenishing",apiTable_->core_->hsa_signal_create_fn(1,0,NULL,&curr_sig));
                sig_pool_.push_back(curr_sig);
            }
        }
        sig = sig_pool_.back();
        sig_pool_.pop_back();
        dh_comms::dh_comms *comms = NULL;
        uint64_t alt_kernel_object = 0;
        // Are there any kernels in the cache?
        if (kernel_cache_.hasKernels(queues_[queue]))
        {
            auto it = kernel_objects_.find(packet->kernel_object);
            if (it != kernel_objects_.end())
            {
                uint64_t alt_kernel_object = 0;
                arg_descriptor_t args = {};
                // If we're running in instrumented mode, we're looking for a certain kernel naming convention along with
                // an argument list expanded by a single void *
                if (run_instrumented_)
                {
                    alt_kernel_object = kernel_cache_.findInstrumentedAlternative(it->second.symbol_, it->second.name_, queues_[queue]);
                    if(alt_kernel_object){
                        std::cerr << "Found instrumented alternative for " << it->second.name_ << std::endl;
                    } else {
                        std::cerr << "No instrumented alternative found for " << it->second.name_ << std::endl;
                    }
                }
                else
                    alt_kernel_object = kernel_cache_.findAlternative(it->second.symbol_, it->second.name_);
                if (alt_kernel_object)
                {
                    // What's the kernarg buffer size for this new kernel?
                    uint32_t size = kernel_cache_.getArgSize(alt_kernel_object);
                    //uint8_t test_align = kernel_cache_.getArgumentAlignment(packet->kernel_object);
                    if (run_instrumented_ && dispatcher_.canDispatch(alt_kernel_object))
                    {
                        // Found an instrumented  kernel Vobject to use as an alternative
                        dispatch->kernel_object = alt_kernel_object;
                        uint8_t align = kernel_cache_.getArgumentAlignment(alt_kernel_object);
                        assert(size);
                        if (kernel_cache_.getArgDescriptor(queues_[queue], it->second.name_, args, run_instrumented_))
                        {
                            void *new_kernargs = allocator_.allocate(args.kernarg_length,queues_[queue]);

                            kernelDB::kernelDB *kdb = kdbs_[queues_[queue]].get();

                            comms = comms_mgr_.checkoutCommsObject(queues_[queue], it->second.name_, dispatch_id, kdb);

                            fixupKernArgs(new_kernargs, packet->kernarg_address, comms->get_dev_rsrc_ptr(), args);
                            dispatch->kernarg_address = new_kernargs;
                            dispatch->private_segment_size = args.private_segment_size;
                            dispatch->group_segment_size = args.group_segment_size;
                            // Store the new kernarg address so we can free it up at kernel completion
                            pending_kernargs_[sig] = new_kernargs;
                        }
                        else
                        {
                            std::cerr << "Missing arg descriptor for " << it->second.name_ << " aborting in line " << __LINE__ << " of file " << __FILE__ << std::endl;
                            abort();
                        }
                    }
                    else
                    {
                        dispatch->kernel_object = packet->kernel_object; // Restore the original kernel object because we're not rewriting the kernargs
                        //dumpKernArgs(packet->kernarg_address, size);
                    }
                }
            }
        }
        // Store the signal for processing at kernel completion
        pending_signals_[sig] = {dispatch->completion_signal, kernel_objects_[packet->kernel_object].name_, queues_[queue], comms};
        //replace any pre-existing completion_signal in the dispatch. FWIW, normal HIP/ROCm codes don't use dispatch packet
        //completion signals. The typically enqueue a barrier packet immediately following a kernel dispatch packet.
        dispatch->completion_signal = sig;

    }
    return dispatch;
}

/*
    This is the packet handler registered with the intercept queue created by hsa_queue_create(...)
    In this method we inspect every packet, writing every non-dispatch packet to the destination queue.
    But for dispatch packets, we delegate decision making to either runKernel, timeKernel, or traceKernel.  runKernel
    gathers hardware counters while traceKernel gathers SQTT data. timeKernel merely collects timing
    data on the kernel but doesn't otherwise interfere with concurrent execution.  Both runKernel and traceKernel
    take a unique_lock to guarantee serialized kernel execution (required because hardware can't differentiate
    counter values between concurrently running kernels.)
*/
void hsaInterceptor::doPackets(hsa_queue_t *queue, const packet_t *packet, uint64_t count, hsa_amd_queue_intercept_packet_writer writer) {
    try {
        for(uint64_t i = 0; i < count; i++)
        {
            if (getHeaderType(&packet[i]) == HSA_PACKET_TYPE_KERNEL_DISPATCH)
            {
                uint64_t id = ++dispatch_count_;
                hsa_kernel_dispatch_packet_t *dispatch = fixupPacket(reinterpret_cast<const hsa_kernel_dispatch_packet_t *>(&packet[i]), queue, id);
                if (dispatch)
                {
                    writer(dispatch, 1);
                    delete dispatch;
                }
                else
                    writer(&packet[i],1);
            }
            else
                writer(&packet[i],1);
        }
    } catch(const exception& e) {
        debug_out(cerr, INTERCEPTOR_MSG, e.what());
    }
}



void hsaInterceptor::addQueue(hsa_queue_t *queue, hsa_agent_t agent)
{
    // This call results in completion signals having start and stop timestamps on dispatches
    auto result = (*(apiTable_->amd_ext_->hsa_amd_profiling_set_profiler_enabled_fn))(queue, true);
    assert(result == HSA_STATUS_SUCCESS && "Couldn't enable queue for profiling");

    lock_guard<mutex> lock(mutex_);

    queues_[queue] = agent;
    auto it = isas_.find(agent);
    if (it == isas_.end())
    {
        // Query isa info and store in isas_
    }
}


/*
    This is really the key to wiring ourselves into the HSA queuing pipeline.  This static method is written into
    the HsaApiTable at OnLoad time so that application calls to hsa_queue_create (e.g. by the HIP runtime) get resolved
    to this method.  The key here is to not merely forward the call to the original hsa_queue_create API but to create
    an alternative TYPE of queue - an "intercept" queue.  This is a functionality implemented by the HSA runtime
    for the purpose of giving callers control over the AQL packet pipeline.  So we create an intercept queue via
    hsa_amd_queue_intercept_create, and then register a handler for packets enqueued to that particular queue - see the
    call to hsa_amd_queue_intercept_register. By doing this we get invoked on every AQL packet dispatch.  This gives
    us the ability to wrap, as needed, dispatch packets in the PM4 packets needed to start and stop counter and trace collection.
*/
hsa_status_t hsaInterceptor::hsa_queue_create(hsa_agent_t agent, uint32_t size, hsa_queue_type32_t type,
    void(*callback)(hsa_status_t status, hsa_queue_t *source, void *data),
    void *data, uint32_t private_segment_size, uint32_t group_segment_size, hsa_queue_t **queue) {
    hsa_status_t result = HSA_STATUS_SUCCESS;
    try {
        result = (*hsa_amd_queue_intercept_create_fn)(agent, size, type, callback, data, private_segment_size, group_segment_size, queue);
        if (result == HSA_STATUS_SUCCESS) {
            hsaInterceptor *instance = getInstance();
            instance->addQueue(*queue, agent);
            auto hookResult = (*hsa_amd_queue_intercept_register_fn)(*queue, hsaInterceptor::OnSubmitPackets, reinterpret_cast<void *>(*queue));
            if (hookResult != HSA_STATUS_SUCCESS) {
                debug_out(cerr, "hsaInterceptor: Failed to register intercept callback with result of ", hookResult);
            } else {
                cerr << DBG << " HSA intercept registered.\n";
            }
        }
    } catch(const exception& e) {
        cerr << e.what();
    }
    return result;
}

hsa_status_t hsaInterceptor::hsa_queue_destroy(hsa_queue_t *queue)
{
    hsa_status_t result = HSA_STATUS_SUCCESS;
    try
    {
        result = (*hsa_queue_destroy_fn)(queue);
    }
    catch(const exception& e)
    {
        cerr << e.what();
    }
    return result;
}


void hsaInterceptor::addKernel(uint64_t kernelObject, std::string& name, hsa_executable_symbol_t symbol, hsa_agent_t agent, uint32_t kernarg_size)
{
   lock_guard<std::mutex> lock(mutex_);
   auto it = kernel_objects_.find(kernelObject);
   if (it == kernel_objects_.end())
   {
        std::string thisName = demangleName(name.c_str());
        kernel_objects_[kernelObject] = {thisName.length() ? thisName : name, symbol, agent, kernarg_size};
   }
}

hsa_status_t hsaInterceptor::hsa_executable_symbol_get_info(hsa_executable_symbol_t symbol, hsa_executable_symbol_info_t attribute, void *data)
{
    hsa_status_t result = HSA_STATUS_SUCCESS;
    try
    {
        result = (*hsa_executable_symbol_get_info_fn)(symbol, attribute, data);
        if (attribute == HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT)
        {
            uint32_t length;
            if ((*hsa_executable_symbol_get_info_fn)(symbol, HSA_EXECUTABLE_SYMBOL_INFO_NAME_LENGTH,&length) == HSA_STATUS_SUCCESS)
            {
                char *name = reinterpret_cast<char *>(malloc(length + 1));
                if (name)
                {
                    name[length] = '\0';
                    if ((*hsa_executable_symbol_get_info_fn)(symbol, HSA_EXECUTABLE_SYMBOL_INFO_NAME, name) == HSA_STATUS_SUCCESS)
                    {
                       uint32_t kernarg_size;
                       CHECK_STATUS("Unable to get kernarg size", (*hsa_executable_symbol_get_info_fn)(symbol, HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE, reinterpret_cast<void *>(&kernarg_size)));
                       uint64_t kernelObject = *reinterpret_cast<uint64_t *>(data);
                       string strName = name;
                       hsa_agent_t agent;
                       CHECK_STATUS("Unable to identify agent for symbol", (*hsa_executable_symbol_get_info_fn)(symbol, HSA_EXECUTABLE_SYMBOL_INFO_AGENT, reinterpret_cast<void *>(&agent)));
                       getInstance()->addKernel(kernelObject, strName, symbol, agent, kernarg_size);
                    }
                    else
                    {
                        std::cerr << "KERNEL HAS NO NAME!!!\n";
                    }
                }
                free(reinterpret_cast<void *>(name));
            }
        }
    }
    catch(const exception& e)
    {
        cerr << e.what();
    }
    return result;
}

void hsaInterceptor::hookApi(){
    apiTable_->core_->hsa_queue_create_fn = hsaInterceptor::hsa_queue_create;
    apiTable_->core_->hsa_queue_destroy_fn = hsaInterceptor::hsa_queue_destroy;
    apiTable_->core_->hsa_executable_symbol_get_info_fn = hsaInterceptor::hsa_executable_symbol_get_info;

}

hsaInterceptor * hsaInterceptor::singleton_ = NULL;
//mutex hsaInterceptor::mutex_;
shared_mutex hsaInterceptor::stop_mutex_;

timeHelper globalTime;

extern "C" {

    /*
        The HSA runtime has a feature for which you can write extension libraries to hook out the HSA runtime
        API to do clever things like profilers.  The environment variable HSA_TOOLS_LIB points to a shared
        lib that contains an "OnLoad" method which will be invoked by the HSA runtime.  One of the method
        parameters is what amounts to a vtable of the entire HSA api.  Overwriting the vtable entries
        allows the HSA_TOOL to masquerade as the runtime to gain visibility on the application itself.
        Typically an HSA_TOOL will forward calls on to the original APIs once it has processed the call beforehand.

        rocmhook constructs a view of the application (memory allocations, kernels loaded, etc) and uses that
        to support the ability to capture traces and hardware counters during kernel execution. rocmhook also has
        the ability to take snapshots of device memory and restore the contents of memory during runtime.  This was
        implemented to support kernel replay, which does not occur by default but must be explicitly invoked.

    */

    PUBLIC_API bool OnLoad(HsaApiTable* table, uint64_t runtime_version, uint64_t failed_tool_count,
                           const char* const* failed_tool_names) {
        //cerr << "Trying to init hsaInterceptor" << endl;
        hsaInterceptor *hook = hsaInterceptor::getInstance(table, runtime_version, failed_tool_count, failed_tool_names);
        //cerr << "hsaInterceptor: Initializing: 0x" << hex << hook << endl;

        return true;
    }

    PUBLIC_API void OnUnload() {
        // cout << "ROCMHOOK: Unloading" << endl;
        hsaInterceptor::cleanup();
        cerr << "hsaInterceptor: Application elapsed usecs: " << std::dec << globalTime.getElapsedNanos() / 1000 << "us\n";
    }

   /* static void unload_me() __attribute__((destructor));
    void unload_me()
    {
        // cout << "ROCMHOOK: Unloading" << endl;
        hsaInterceptor::cleanup();
        cerr << "hsaInterceptor: Application elapsed usecs: " << globalTime.getElapsedNanos() / 1000 << "us\n";
    }*/
}
