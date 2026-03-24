
/******************************************************************************
Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.

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
#include <string>
#include <cstring>
#include <getopt.h>
#include <hip/hip_runtime.h>
#include "dh_comms_dev.h"
#include "dh_comms.h"
#include "hip_utils.h"
#include "inc/memory_heatmap.h"
#include "inc/time_interval_handler.h"

__global__ void __amd_crk_test(float *dst, float *src, float alpha, size_t array_size, dh_comms::dh_comms_descriptor *tmp_rsrc, void *ptr)
{
    dh_comms::dh_comms_descriptor *rsrc = (dh_comms::dh_comms_descriptor *)ptr;
    if (tmp_rsrc != NULL)
        tmp_rsrc = NULL;
    dh_comms::time_interval time_interval;
    time_interval.start = __clock64(); // time in cycles
    dh_comms::s_submit_wave_header(rsrc); // scalar message, wave header only

    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= array_size)
    {
        // scalar message without lane headers, single data item
        int meaning_of_life = 42;
        dh_comms::s_submit_message(rsrc, &meaning_of_life, sizeof(int), false, __LINE__);

        return;
    }
    // scalar message with lane headers, without data
    dh_comms::s_submit_message(rsrc, nullptr, 0, true, __LINE__);

    // scalar message with lane headers, single data item
    size_t number_of_the_beast = 666;
    dh_comms::s_submit_message(rsrc, &number_of_the_beast, sizeof(size_t), true, __LINE__);

    dst[idx] = alpha * src[idx];

    // two vector messages with lane headers and a data item for every active lane.
    // source code line is passed as location index
    dh_comms::v_submit_address(rsrc, src + idx, 0, __LINE__, 0, 0b01, 0b01, sizeof(*dst));
    dh_comms::v_submit_address(rsrc, dst + idx, 0, __LINE__, 0, 0b01, 0b01, sizeof(*dst));
    time_interval.stop = __clock64(); // time in cycles
    s_submit_time_interval(rsrc, &time_interval);
}

__global__ void test(float *dst, float *src, float alpha, size_t array_size, dh_comms::dh_comms_descriptor *rsrc)
{
    dh_comms::time_interval time_interval;
    time_interval.start = __clock64(); // time in cycles
    dh_comms::s_submit_wave_header(rsrc); // scalar message, wave header only

    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= array_size)
    {
        // scalar message without lane headers, single data item
        int meaning_of_life = 42;
        dh_comms::s_submit_message(rsrc, &meaning_of_life, sizeof(int), false, __LINE__);

        return;
    }
    // scalar message with lane headers, without data
    dh_comms::s_submit_message(rsrc, nullptr, 0, true, __LINE__);

    // scalar message with lane headers, single data item
    size_t number_of_the_beast = 666;
    dh_comms::s_submit_message(rsrc, &number_of_the_beast, sizeof(size_t), true, __LINE__);

    dst[idx] = alpha * src[idx];

    // two vector messages with lane headers and a data item for every active lane.
    // source code line is passed as location index
    dh_comms::v_submit_address(rsrc, src + idx, 0, __LINE__, 0, 0b01, 0b01, sizeof(*src));
    dh_comms::v_submit_address(rsrc, dst + idx, 0, __LINE__, 0, 0b01, 0b01, sizeof(*src));
    time_interval.stop = __clock64(); // time in cycles
    s_submit_time_interval(rsrc, &time_interval);
}

void help(char **argv)
{
    printf("Usage: %s <options>\n"
           "Options:\n"
           "  -a <n>, --array-size <n>:\n"
           "     Set source and destination array sizes (and implicitly, the number of GPU threads) to n.\n"
           "  -b <n>, --blocksize <n>:\n"
           "     Set workgroup/block size to n.\n"
           "  -s <n>, --no-sub-buffers <n>:\n"
           "     Set the number of sub-buffers used to pass messages from device to host to n.\n"
           "  -c <n>, --sub-buffer-capacity <n>:\n"
           "     Set the capacity of each of the sub-buffers to n bytes.\n"
           "  -p <n>, --page-size <n>:\n"
           "     Assume a page size of n for counting memory accesses for each page.\n"
           "  -v, --verbose:\n"
           "     Print message headers, thread headers and raw data during host-side processing.\n"
           "     It is recommended to use a small array size when using verbose output.\n"
           "  -h, --help:\n"
           "     Print this message and exit.\n",
           argv[0]);
}

void get_options(int argc, char **argv, size_t &array_size, int &threads_per_block,
                 size_t &no_sub_buffers, size_t &sub_buffer_capacity,
                 size_t &page_size, bool &verbose)
{
    static struct option long_options[] =
        {
            {"help", no_argument, 0, 'h'},
            {"array-size", required_argument, 0, 'a'},
            {"blocksize", required_argument, 0, 'b'},
            {"no-sub-buffers", required_argument, 0, 's'},
            {"sub-buffer-capacity", required_argument, 0, 'c'},
            {"page-size", required_argument, 0, 'p'},
            {"verbose", no_argument, 0, 'v'},
            {0, 0, 0, 0}};
    int option_index = 0;
    int c;
    while (true)
    {
        c = getopt_long(argc, argv, "a:b:s:c:p:vh", long_options, &option_index);
        if (c == -1) // end of options
        {
            break;
        }

        switch (c)
        {
        case 'a':
            array_size = std::stoull(optarg);
            break;
        case 'b':
            threads_per_block = std::stoi(optarg);
            break;
        case 's':
            no_sub_buffers = std::stoull(optarg);
            break;
        case 'c':
            sub_buffer_capacity = std::stoull(optarg);
            break;
        case 'p':
            page_size = std::stoull(optarg);
            break;
        case 'v':
            verbose = true;
            break;
        case 'h':
        default:
            help(argv);
            exit(1);
        }
    }
}

int main(int argc, char **argv)
{
    // set default parameter values
    //    kernel launch parameters
    size_t array_size = 5 * 1024 * 128 + 17; // large enough to get full sub-buffers during run, and slightly unbalanced
    int blocksize = 128;
    //    dh_comms configuration parameters
    size_t no_sub_buffers = 256; // gave best performance in several not too thorough tests
    size_t sub_buffer_capacity = 64 * 1024;
    //    memory heatmap configuration parameter
    size_t page_size = 1024 * 1024; // large page size to reduce output
    //    both dh_comms and heatmap configuration parameter
    bool verbose = false; // only be verbose with really small array sizes

    // now see if user specified parameter values other than default
    get_options(argc, argv, array_size, blocksize,
                no_sub_buffers, sub_buffer_capacity,
                page_size, verbose);

    const int no_blocks = (array_size + blocksize - 1) / blocksize;

    float *src, *dst;
    CHK_HIP_ERR(hipMalloc(&src, array_size * sizeof(float)));
    CHK_HIP_ERR(hipMalloc(&dst, array_size * sizeof(float)));

    {
        dh_comms::dh_comms dh_comms(no_sub_buffers, sub_buffer_capacity, verbose);
        dh_comms.append_handler(std::make_unique<dh_comms::memory_heatmap_t>(page_size, verbose));
        printf("first kernel dispatch\n");
        dh_comms.start();
        // if dh_comms sub-buffers get full during running of the kernel,
        // device code notifies host code to process the full buffers and
        // clear them
        for (int i = 0; i < 20; i++)
            test<<<no_blocks, blocksize>>>(dst, src, 3.14, array_size, dh_comms.get_dev_rsrc_ptr());
        // make sure kernels are done before stopping dh_comms, or device messages will get lost
        CHK_HIP_ERR(hipDeviceSynchronize());
        dh_comms.stop();
        dh_comms.report();

        // do it again to see if start/stop works, and add a handler for time intervals
        dh_comms.append_handler(std::make_unique<dh_comms::time_interval_handler_t>(verbose));
        printf("second kernel dispatch\n");
        dh_comms.start();
        test<<<no_blocks, blocksize>>>(dst, src, 3.14, array_size, dh_comms.get_dev_rsrc_ptr());
        CHK_HIP_ERR(hipDeviceSynchronize());
        dh_comms.stop();
        dh_comms.report();

        // run once more, but first delete the handlers, so that all messages will be dropped
        printf("third kernel dispatch\n");
        dh_comms.start();
        test<<<no_blocks, blocksize>>>(dst, src, 3.14, array_size, dh_comms.get_dev_rsrc_ptr());
        CHK_HIP_ERR(hipDeviceSynchronize());
        dh_comms.stop();
        dh_comms.report();
        dh_comms.delete_handlers();

    }

    CHK_HIP_ERR(hipFree(src));
    CHK_HIP_ERR(hipFree(dst));
}
