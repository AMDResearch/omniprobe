#include "hip/hip_runtime.h"
#include "dh_comms.h"
#include "dh_comms_dev.h"
#include "time_interval_handler.h"
#include "memory_heatmap.h"

// Compile with hipcc -O3 --amdgpu-target=gfx908 -I${ROCM_PATH}/roctracer/include -L${ROCM_PATH}/roctracer/lib -lroctx64 test.cpp

#include <cstdio>
#include <iostream>
#include <unistd.h>
#include <hip/hip_profile.h>
//#include <roctx.h>


#define N 2560
#define num_iters 1 //KAL 1000


template<int n, int m>
__global__ void kernel(double* x) {
    for (int idx = threadIdx.x + blockIdx.x * blockDim.x; idx < N; idx += gridDim.x * blockDim.x)
    {
        #pragma unroll
        for (int i = 0; i < n; ++i)
        {
            x[idx] += i * m;
        }
    }
}

template<int n, int m>
__global__ void __amd_crk_kernel(double* x, void *ptr) {
    if (ptr)
    {
        dh_comms::dh_comms_descriptor *rsrc = (dh_comms::dh_comms_descriptor *)ptr;


        dh_comms::time_interval time_interval;
        time_interval.start = __clock64(); // time in cycles
        dh_comms::s_submit_wave_header(rsrc); // scalar message, wave header only


        size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
        if (idx >= N)
        {
            // scalar message without lane headers, single data item
        //    int meaning_of_life = 42;
         //   dh_comms::s_submit_message(rsrc, &meaning_of_life, sizeof(int), false, __LINE__);

            return;
        }

        // scalar message with lane headers, without data
        //dh_comms::s_submit_message(rsrc, nullptr, 0, true, __LINE__);

        // scalar message with lane headers, single data item
        //size_t number_of_the_beast = 666;
        //dh_comms::s_submit_message(rsrc, &number_of_the_beast, sizeof(size_t), true, __LINE__);

        for (int idx = threadIdx.x + blockIdx.x * blockDim.x; idx < N; idx += gridDim.x * blockDim.x)
        {
        //    #pragma unroll
            for (int i = 0; i < n; ++i)
            {
                dh_comms::v_submit_address(rsrc, x + idx, 0, __LINE__, 0, 0b01, 0b01, sizeof(x[0]));
                x[idx] += i * m;
            }
        }
        time_interval.stop = __clock64(); // time in cycles
        dh_comms::s_submit_time_interval(rsrc, &time_interval);
    }
    else
    {
        for (int idx = threadIdx.x + blockIdx.x * blockDim.x; idx < N; idx += gridDim.x * blockDim.x)
        {
        //    #pragma unroll
            for (int i = 0; i < n; ++i)
            {
                x[idx] += i * m;
            }
        }
    }

}


void cpuWork() {
    // Do some CPU "work".
    usleep(100);
}

inline void hip_assert(hipError_t err, const char *file, int line)
{
    if (err != hipSuccess)
    {
        fprintf(stderr,"HIP error: %s %s %d\n", hipGetErrorString(err), file, line);
        exit(-1);
    }
}

void instantiate_clones(dh_comms::dh_comms *comms)
{
    size_t array_size = 5 * 1024 * 128 + 17; // large enough to get full sub-buffers during run, and slightly unbalanced
    int blocksize = 128;
    const int no_blocks = (array_size + blocksize - 1) / blocksize;
    if (comms)
    {
        void *rsrc = comms->get_dev_rsrc_ptr();
        double foo = 0;;
        HIP_KERNEL_NAME(__amd_crk_kernel<1,1>)<<<no_blocks, blocksize>>>(&foo, rsrc);
    }
}

void print_help() {
    std::cout << "Usage: stressttest [-i iterations]\n";
    std::cout << "Options:\n";
    std::cout << "  -i <iterations>  Specify the number of iterations of the tests to run(positive integer).\n";
    std::cout << "  -h               Display this help message.\n";
}

#define hipErrorCheck(f) { hip_assert((f), __FILE__, __LINE__); }
#define kernelErrorCheck() { hipErrorCheck(hipPeekAtLastError()); }

int main(int argc, char**argv) {
    int iterations = 0;
    int opt;

    if (argc < 2)
    {
        print_help();
        return EXIT_FAILURE;
    }

    // Parse command-line options
    while ((opt = getopt(argc, argv, "i:h")) != -1) {
        switch (opt) {
            case 'i':
                iterations = std::atoi(optarg);
                if (iterations <= 0) {
                    std::cerr << "Error: iterations must be a positive integer.\n";
                    return EXIT_FAILURE;
                }
                break;
            case 'h':
                print_help();
                return EXIT_SUCCESS;
            default:
                print_help();
                return EXIT_FAILURE;
        }
    }

    double* x;
    double* x_h;

    std::cout << "Number of iterations: " << iterations << std::endl;

    std::cout << "STRESSTEST\n";

    size_t sz = N * sizeof(double);
    hipErrorCheck(hipHostMalloc(&x_h, sz));

    memset(x_h, 0, sz);
    hipErrorCheck(hipMalloc(&x, sz));
    //hipErrorCheck(hipMemset(x, 0, sz));


    hipFuncAttributes attr;

    int blocks = 80;
    int threads = 32;
    int fact = 1;//100;KAL


    dh_comms::dh_comms dh_comms(256, 65536, false);
    dh_comms.append_handler(std::make_unique<dh_comms::memory_heatmap_t>(1024*1024, false));
    dh_comms.start();
    HIP_KERNEL_NAME(__amd_crk_kernel<2,2>)<<<dim3(blocks), dim3(threads)>>>(x, dh_comms.get_dev_rsrc_ptr());
    dh_comms.stop();
    dh_comms.report();
    HIP_KERNEL_NAME(kernel<1,1>)<<<dim3(blocks), dim3(threads)>>>(x);
    kernelErrorCheck();
    hipErrorCheck(hipDeviceSynchronize());
//    exit(0);

    for (int j = 0; j < iterations; ++j) {

        for (int n = 0; n < 25*fact; ++n) {
      //      hipErrorCheck(hipMemcpy(x, x_h, sz, hipMemcpyHostToDevice));
            HIP_KERNEL_NAME(kernel<1,1>)<<<dim3(blocks), dim3(threads)>>>(x);
            kernelErrorCheck();
            hipErrorCheck(hipDeviceSynchronize());
            /*hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,2>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,3>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,4>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,5>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,6>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,7>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,8>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,9>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,10>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,11>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,12>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,13>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,14>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,15>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,16>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,17>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,18>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,19>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,20>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,20>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,21>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,22>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,23>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,24>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,25>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,26>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,27>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,28>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,29>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,30>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,30>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,31>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,32>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,33>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,34>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,35>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,36>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,37>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,38>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,39>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<1,40>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();*/
            hipErrorCheck(hipMemcpyAsync(x_h, x, sz, hipMemcpyDeviceToHost));
            hipErrorCheck(hipDeviceSynchronize());
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        hipStream_t stream;
        hipErrorCheck(hipStreamCreate(&stream));


        for (int n = 0; n < 200*fact; ++n) {
            //roctxRangePushA("range1");
            hipErrorCheck(hipFuncGetAttributes(&attr, reinterpret_cast<const void*>(kernel<10,1>)));
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<10,1>), dim3(blocks), dim3(threads), 0, stream, x);
            kernelErrorCheck();
            hipErrorCheck(hipStreamSynchronize(stream));
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        for (int n = 0; n < 30*fact; ++n) {
            //roctxRangePushA("range2");
            for (int k = 0; k < 7; ++k) {
                hipErrorCheck(hipFuncGetAttributes(&attr, reinterpret_cast<const void*>(kernel<8,1>)));
                hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<8,1>), dim3(blocks), dim3(threads), 0, 0, x);
                kernelErrorCheck();
            }
            hipErrorCheck(hipDeviceSynchronize());
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        for (int n = 0; n < 100*fact; ++n) {
            //roctxRangePushA("range3");
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,1>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,2>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,3>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,4>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,5>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipErrorCheck(hipDeviceSynchronize());
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        for (int n = 0; n < 100*fact; ++n) {
            //roctxRangePushA("range4");
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,1>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,2>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,3>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,4>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<7,5>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipErrorCheck(hipDeviceSynchronize());
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        for (int n = 0; n < 50*fact; ++n) {
            //roctxRangePushA("range5");
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,1>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,2>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,3>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,4>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,5>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,6>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,7>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<6,8>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipErrorCheck(hipDeviceSynchronize());
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        for (int n = 0; n < 50*fact; ++n) {
            //roctxRangePushA("range6");
            int val;
            hipErrorCheck(hipDeviceGetAttribute(&val, hipDeviceAttributeMaxThreadsPerBlock, 0));
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<4000,1>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipErrorCheck(hipDeviceSynchronize());
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        for (int n = 0; n < 50*fact; ++n) {
            //roctxRangePushA("range7");
            hipLaunchKernelGGL(HIP_KERNEL_NAME(kernel<5000,1>), dim3(blocks), dim3(threads), 0, 0, x);
            kernelErrorCheck();
            hipErrorCheck(hipDeviceSynchronize());
            //roctxRangePop();
        }

        hipErrorCheck(hipMemset(x, 0, sz));
        cpuWork();

        hipErrorCheck(hipDeviceSynchronize());
        hipErrorCheck(hipStreamDestroy(stream));

    }

    hipErrorCheck(hipHostFree(x_h));
    hipErrorCheck(hipFree(x));
    //hipProfilerStop();

}
