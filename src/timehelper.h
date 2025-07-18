
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

#include <chrono>

class timeHelper
{
public:
    timeHelper()
    {
        clock_gettime(CLOCK_MONOTONIC, &ts_start);
    }
    uint64_t getStartTime()
    {
        return (ts_start.tv_sec * 1000000000) + ts_start.tv_nsec;
        //return std::chrono::time_point_cast<std::chrono::nanoseconds>(start).time_since_epoch().count();
    }
    void reset()
    {
        clock_gettime(CLOCK_MONOTONIC, &ts_start);
        start = std::chrono::steady_clock::now();
    }
    uint64_t getElapsedNanos()
    {
        std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();
        return std::chrono::duration_cast<std::chrono::nanoseconds> (end - start).count();
    }
    uint64_t getElapsedMicros()
    {
        std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();
        return (std::chrono::duration_cast<std::chrono::nanoseconds> (end - start).count()) / 1000;
    }
private:
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    struct timespec ts_start;
};
