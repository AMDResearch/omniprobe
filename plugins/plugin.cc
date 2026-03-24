
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
#include "plugin.h"
#include "inc/time_interval_handler.h"
#include "inc/memory_heatmap.h"

extern "C"{
    PUBLIC_API void getMessageHandlers(const std::string& kernel, uint64_t dispatch_id, std::vector<dh_comms::message_handler_base *>& outHandlers)
    {
        std::string location = "console";
        const char* logDurLogLocation = std::getenv("LOGDUR_LOG_LOCATION");
        if (logDurLogLocation != NULL)
            location = logDurLogLocation;
        outHandlers.push_back(new dh_comms::time_interval_handler_t(kernel, dispatch_id, location, false));
        outHandlers.push_back(new dh_comms::memory_heatmap_t(kernel, dispatch_id, location, 1024*1024, false));
    }
}
