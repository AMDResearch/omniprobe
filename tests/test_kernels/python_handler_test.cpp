// Many dispatches with an exactly known address stream, for the PythonHandler
// test (tests/test_python_handler.sh).
//
// Usage: python_handler_test <streams> <launches_per_stream> <threads> <loads>
//
// Each thread loads in[i] <loads> times and stores out[i] once, in disjoint
// buffers. So every dispatch produces exactly threads * (loads + 1) address
// messages over exactly 2 * threads distinct addresses. <threads> must be a
// multiple of 64.
//
// Launch l on every stream forms a group that meets at a device-side barrier
// before touching memory, so the group runs concurrently. With many loads per
// wave, each wave fills its 256 KiB dh_comms sub-buffer while running, so
// several dh_comms threads deliver messages to the handler at the same time
// (a small kernel's messages are all drained at completion, one dispatch at a
// time). The barrier uses atomics only: the address-message pass instruments
// loads and stores, not atomicrmw, so it adds nothing to the address stream. It
// gives up after about a second, so a runtime that serializes the streams slows
// the test down instead of hanging it.

#include <hip/hip_runtime.h>
#include <cstdlib>
#include <iostream>
#include <vector>
#include "hip_test_utils.h"

constexpr int BLOCK = 64;

__global__ void python_handler_kernel(const int* in, int* out, int loads, unsigned* arrived, unsigned group_blocks) {
    if (threadIdx.x == 0) {
        atomicAdd(arrived, 1u);
        const uint64_t give_up = wall_clock64() + 100000000;   // ~1 s at 100 MHz
        while (atomicAdd(arrived, 0u) < group_blocks && wall_clock64() < give_up)
            __builtin_amdgcn_s_sleep(10);
    }
    __syncthreads();
    // BLOCK, not blockDim.x: reading blockDim is itself an instrumented load.
    int i = blockIdx.x * BLOCK + threadIdx.x;
    const volatile int* v = in;   // volatile: every iteration really loads
    int sum = 0;
    for (int r = 0; r < loads; ++r)
        sum += v[i];
    out[i] = sum / loads + 1;
}

int main(int argc, char** argv) {
    if (argc != 5) {
        std::cerr << "usage: " << argv[0] << " <streams> <launches_per_stream> <threads> <loads>" << std::endl;
        return 2;
    }
    const int streams = std::atoi(argv[1]);
    const int launches = std::atoi(argv[2]);
    const int threads = std::atoi(argv[3]);
    const int loads = std::atoi(argv[4]);
    if (streams < 1 || launches < 1 || loads < 1 || threads < BLOCK || threads % BLOCK) {
        std::cerr << "bad arguments" << std::endl;
        return 2;
    }
    const int total = streams * launches;

    std::vector<hipStream_t> s(streams);
    std::vector<int*> in(total), out(total);
    std::vector<int> host(threads);
    for (int i = 0; i < threads; ++i) host[i] = i;
    for (auto& st : s) CHECK_HIP(hipStreamCreate(&st));
    for (int d = 0; d < total; ++d) {
        CHECK_HIP(hipMalloc(&in[d], threads * sizeof(int)));
        CHECK_HIP(hipMalloc(&out[d], threads * sizeof(int)));
        CHECK_HIP(hipMemcpy(in[d], host.data(), threads * sizeof(int), hipMemcpyHostToDevice));
    }
    unsigned* arrived;   // one barrier counter per launch group
    CHECK_HIP(hipMalloc(&arrived, launches * sizeof(unsigned)));
    CHECK_HIP(hipMemset(arrived, 0, launches * sizeof(unsigned)));
    const unsigned group_blocks = streams * (threads / BLOCK);
    for (int l = 0; l < launches; ++l)
        for (int k = 0; k < streams; ++k) {
            int d = l * streams + k;
            hipLaunchKernelGGL(python_handler_kernel, dim3(threads / BLOCK), dim3(BLOCK), 0, s[k], in[d], out[d],
                               loads, arrived + l, group_blocks);
            CHECK_HIP(hipGetLastError());
        }
    CHECK_HIP(hipDeviceSynchronize());

    int bad = 0;
    for (int d = 0; d < total; ++d) {
        CHECK_HIP(hipMemcpy(host.data(), out[d], threads * sizeof(int), hipMemcpyDeviceToHost));
        for (int i = 0; i < threads; ++i) bad += host[i] != i + 1;
        CHECK_HIP(hipFree(in[d]));
        CHECK_HIP(hipFree(out[d]));
    }
    CHECK_HIP(hipFree(arrived));
    for (auto& st : s) CHECK_HIP(hipStreamDestroy(st));
    std::cerr << "python_handler_test: " << total << " dispatches, " << bad << " wrong results" << std::endl;
    return bad ? 1 : 0;
}
