// A shared library with an instrumented kernel, loaded by a Python host through
// ctypes (tests/test_python_host.sh): omniprobe's PythonHandler then runs
// inside a process whose main program is itself a Python interpreter.
//
// py_host_run(launches, threads, loads): each thread loads in[i] <loads> times
// and stores out[i] once, so every dispatch produces exactly
// threads * (loads + 1) address-message lanes. With many loads each wave fills
// its dh_comms sub-buffer while running, so the kernel can only finish if the
// host drains -- i.e. if the Python handler can run -- during the dispatch.
// Returns 0 if every dispatch computed the right result.

#include <hip/hip_runtime.h>
#include <vector>

constexpr int BLOCK = 64;

__global__ void py_host_kernel(const int* in, int* out, int loads) {
    int i = blockIdx.x * BLOCK + threadIdx.x;
    const volatile int* v = in;
    int sum = 0;
    for (int r = 0; r < loads; ++r)
        sum += v[i];
    out[i] = sum / loads + 1;
}

extern "C" int py_host_run(int launches, int threads, int loads) {
    if (launches < 1 || loads < 1 || threads < BLOCK || threads % BLOCK)
        return 2;
    int *in, *out;
    std::vector<int> host(threads), result(threads);
    for (int i = 0; i < threads; ++i) host[i] = i;
    if (hipMalloc(&in, threads * sizeof(int)) != hipSuccess || hipMalloc(&out, threads * sizeof(int)) != hipSuccess)
        return 3;
    if (hipMemcpy(in, host.data(), threads * sizeof(int), hipMemcpyHostToDevice) != hipSuccess)
        return 3;
    int bad = 0;
    for (int l = 0; l < launches; ++l) {
        hipLaunchKernelGGL(py_host_kernel, dim3(threads / BLOCK), dim3(BLOCK), 0, 0, in, out, loads);
        if (hipDeviceSynchronize() != hipSuccess)
            return 4;
        if (hipMemcpy(result.data(), out, threads * sizeof(int), hipMemcpyDeviceToHost) != hipSuccess)
            return 4;
        for (int i = 0; i < threads; ++i)
            bad += result[i] != i + 1;
    }
    (void)hipFree(in);
    (void)hipFree(out);
    return bad ? 1 : 0;
}
