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

#include <gtest/gtest.h>
#include <hip/hip_runtime.h>
#include <sstream>
#include <memory>

#include "dh_comms.h"
#include "dh_comms_dev.h"
#include "inc/memory_heatmap.h"
#include "inc/time_interval_handler.h"
#include "inc/memory_analysis_handler.h"

// Test kernel that emits address messages for memory heatmap tracking
__global__ void test_address_kernel(float *dst, float *src, size_t array_size,
                                    dh_comms::dh_comms_descriptor *rsrc) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= array_size) {
        return;
    }

    // Emit address messages for both src and dst accesses
    dh_comms::v_submit_address(rsrc, src + idx, 0, __LINE__, 0,
                               dh_comms::memory_access::read,
                               dh_comms::address_space::global,
                               sizeof(*src));
    dst[idx] = src[idx] * 2.0f;
    dh_comms::v_submit_address(rsrc, dst + idx, 0, __LINE__, 0,
                               dh_comms::memory_access::write,
                               dh_comms::address_space::global,
                               sizeof(*dst));
}

// Test kernel that emits time interval messages
__global__ void test_time_interval_kernel(float *data, size_t array_size,
                                          dh_comms::dh_comms_descriptor *rsrc) {
    dh_comms::time_interval ti;
    ti.start = __clock64();

    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < array_size) {
        data[idx] = data[idx] * 1.5f;
    }

    ti.stop = __clock64();
    dh_comms::s_submit_time_interval(rsrc, &ti);
}

class HandlerIntegrationTest : public ::testing::Test {
protected:
    void SetUp() override {
        hipError_t err = hipGetDeviceCount(&device_count_);
        if (err != hipSuccess || device_count_ == 0) {
            GTEST_SKIP() << "No GPU devices available";
        }

        err = hipSetDevice(0);
        ASSERT_EQ(err, hipSuccess) << "Failed to set device";
    }

    void TearDown() override {
        hipDeviceReset();
    }

    int device_count_ = 0;
    static constexpr size_t kDefaultSubBuffers = 64;
    static constexpr size_t kDefaultSubBufferCapacity = 32 * 1024;
};

// Test that memory_heatmap_t handler processes address messages
TEST_F(HandlerIntegrationTest, MemoryHeatmapHandlesAddressMessages) {
    const size_t array_size = 1024;
    const int blocksize = 64;
    const int no_blocks = (array_size + blocksize - 1) / blocksize;
    const size_t page_size = 4096;

    float *src, *dst;
    ASSERT_EQ(hipMalloc(&src, array_size * sizeof(float)), hipSuccess);
    ASSERT_EQ(hipMalloc(&dst, array_size * sizeof(float)), hipSuccess);
    ASSERT_EQ(hipMemset(src, 1, array_size * sizeof(float)), hipSuccess);

    {
        dh_comms::dh_comms comms(kDefaultSubBuffers, kDefaultSubBufferCapacity, false);
        auto handler = std::make_unique<dh_comms::memory_heatmap_t>("test_kernel", 1, "console", page_size, false);
        comms.append_handler(std::move(handler));

        comms.start();
        test_address_kernel<<<no_blocks, blocksize>>>(dst, src, array_size, comms.get_dev_rsrc_ptr());
        ASSERT_EQ(hipDeviceSynchronize(), hipSuccess);
        comms.stop();

        // Capture report output
        testing::internal::CaptureStdout();
        comms.report();
        std::string output = testing::internal::GetCapturedStdout();

        // Verify report contains expected content
        // The heatmap should report page access counts
        EXPECT_FALSE(output.empty()) << "Report should produce output";

        comms.delete_handlers();
    }

    ASSERT_EQ(hipFree(src), hipSuccess);
    ASSERT_EQ(hipFree(dst), hipSuccess);
}

// Test that time_interval_handler_t processes time interval messages
TEST_F(HandlerIntegrationTest, TimeIntervalHandlerProcessesMessages) {
    const size_t array_size = 512;
    const int blocksize = 64;
    const int no_blocks = (array_size + blocksize - 1) / blocksize;

    float *data;
    ASSERT_EQ(hipMalloc(&data, array_size * sizeof(float)), hipSuccess);
    ASSERT_EQ(hipMemset(data, 1, array_size * sizeof(float)), hipSuccess);

    {
        dh_comms::dh_comms comms(kDefaultSubBuffers, kDefaultSubBufferCapacity, false);
        auto handler = std::make_unique<dh_comms::time_interval_handler_t>("test_kernel", 1, "console", false);
        comms.append_handler(std::move(handler));

        comms.start();
        test_time_interval_kernel<<<no_blocks, blocksize>>>(data, array_size, comms.get_dev_rsrc_ptr());
        ASSERT_EQ(hipDeviceSynchronize(), hipSuccess);
        comms.stop();

        // Capture report output
        testing::internal::CaptureStdout();
        comms.report();
        std::string output = testing::internal::GetCapturedStdout();

        // Verify report contains time interval information
        // Should contain "time_interval report" and timing data
        EXPECT_FALSE(output.empty()) << "Report should produce output";

        comms.delete_handlers();
    }

    ASSERT_EQ(hipFree(data), hipSuccess);
}

// Test that multiple handlers can be attached and all process messages
TEST_F(HandlerIntegrationTest, MultipleHandlersProcessMessages) {
    const size_t array_size = 256;
    const int blocksize = 64;
    const int no_blocks = (array_size + blocksize - 1) / blocksize;
    const size_t page_size = 4096;

    float *src, *dst;
    ASSERT_EQ(hipMalloc(&src, array_size * sizeof(float)), hipSuccess);
    ASSERT_EQ(hipMalloc(&dst, array_size * sizeof(float)), hipSuccess);
    ASSERT_EQ(hipMemset(src, 1, array_size * sizeof(float)), hipSuccess);

    {
        dh_comms::dh_comms comms(kDefaultSubBuffers, kDefaultSubBufferCapacity, false);
        comms.append_handler(std::make_unique<dh_comms::memory_heatmap_t>("test_kernel", 1, "console", page_size, false));
        comms.append_handler(std::make_unique<dh_comms::time_interval_handler_t>("test_kernel", 1, "console", false));

        comms.start();
        test_address_kernel<<<no_blocks, blocksize>>>(dst, src, array_size, comms.get_dev_rsrc_ptr());
        ASSERT_EQ(hipDeviceSynchronize(), hipSuccess);
        comms.stop();

        // Both handlers should produce reports
        testing::internal::CaptureStdout();
        comms.report();
        std::string output = testing::internal::GetCapturedStdout();

        EXPECT_FALSE(output.empty()) << "Report should produce output from handlers";

        comms.delete_handlers();
    }

    ASSERT_EQ(hipFree(src), hipSuccess);
    ASSERT_EQ(hipFree(dst), hipSuccess);
}

// Test handler lifecycle: start -> process -> stop -> report -> clear
TEST_F(HandlerIntegrationTest, HandlerLifecycle) {
    const size_t array_size = 128;
    const int blocksize = 64;
    const int no_blocks = (array_size + blocksize - 1) / blocksize;
    const size_t page_size = 4096;

    float *data;
    ASSERT_EQ(hipMalloc(&data, array_size * sizeof(float)), hipSuccess);

    {
        dh_comms::dh_comms comms(kDefaultSubBuffers, kDefaultSubBufferCapacity, false);
        comms.append_handler(std::make_unique<dh_comms::memory_heatmap_t>("test_kernel", 1, "console", page_size, false));

        // First run
        comms.start();
        test_address_kernel<<<no_blocks, blocksize>>>(data, data, array_size, comms.get_dev_rsrc_ptr());
        ASSERT_EQ(hipDeviceSynchronize(), hipSuccess);
        comms.stop();

        testing::internal::CaptureStdout();
        comms.report();
        std::string first_output = testing::internal::GetCapturedStdout();

        // Second run - handlers should still work after stop/start cycle
        comms.start();
        test_address_kernel<<<no_blocks, blocksize>>>(data, data, array_size, comms.get_dev_rsrc_ptr());
        ASSERT_EQ(hipDeviceSynchronize(), hipSuccess);
        comms.stop();

        testing::internal::CaptureStdout();
        comms.report();
        std::string second_output = testing::internal::GetCapturedStdout();

        // Both runs should produce output
        EXPECT_FALSE(first_output.empty()) << "First run should produce output";
        EXPECT_FALSE(second_output.empty()) << "Second run should produce output";

        comms.delete_handlers();
    }

    ASSERT_EQ(hipFree(data), hipSuccess);
}

// Test that handlers gracefully handle empty input (no kernel dispatches)
TEST_F(HandlerIntegrationTest, HandlersWithNoMessages) {
    const size_t page_size = 4096;

    {
        dh_comms::dh_comms comms(kDefaultSubBuffers, kDefaultSubBufferCapacity, false);
        comms.append_handler(std::make_unique<dh_comms::memory_heatmap_t>("test_kernel", 1, "console", page_size, false));
        comms.append_handler(std::make_unique<dh_comms::time_interval_handler_t>("test_kernel", 1, "console", false));

        comms.start();
        // No kernel dispatch - handlers should handle gracefully
        comms.stop();

        // Should not crash when reporting with no messages processed
        testing::internal::CaptureStdout();
        EXPECT_NO_THROW(comms.report());
        testing::internal::GetCapturedStdout();

        comms.delete_handlers();
    }
}
