
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
#include <cstdint>

#include "plugin.h"
#include "inc/pyHandler.h"
#include "inc/time_interval_handler.h"

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>

// Forwards address and time-interval messages to a user-supplied Python module.
// The module is named by OMNIPROBE_PYTHON_HANDLER: either a path to a .py file
// or a module name importable through PYTHONPATH. See inc/pyHandler.h for the
// functions the module must define.

namespace {

class python_bridge_handler_t : public dh_comms::message_handler_base {
public:
    python_bridge_handler_t(const std::string& module, const std::string& kernel, uint64_t dispatch_id)
        : py_(module, kernel, dispatch_id) {}

    bool handle(const dh_comms::message_t& message) override
    {
        switch (message.wave_header().user_type) {
        case dh_comms::message_type::address:
            if (message.data_item_size() != sizeof(uint64_t))
                return false;
            for (size_t i = 0; i != message.no_data_items(); ++i)
                py_.addressMessage(reinterpret_cast<void*>(*static_cast<const uint64_t*>(message.data_item(i))));
            return true;
        case dh_comms::message_type::time_interval:
            if (message.data_item_size() != sizeof(dh_comms::time_interval))
                return false;
            for (size_t i = 0; i != message.no_data_items(); ++i) {
                auto ti = *static_cast<const dh_comms::time_interval*>(message.data_item(i));
                py_.timingMessage(ti.stop - ti.start);
            }
            return true;
        default:
            return false;
        }
    }

    void report() override { py_.report(); }

private:
    pythonMessageHandler py_;
};

} // namespace

extern "C"{
    PUBLIC_API void getMessageHandlers(const std::string& kernel, uint64_t dispatch_id, std::vector<dh_comms::message_handler_base *>& outHandlers)
    {
        const char* module = std::getenv("OMNIPROBE_PYTHON_HANDLER");
        if (module == NULL || *module == '\0') {
            std::cerr << "PythonHandler: set OMNIPROBE_PYTHON_HANDLER to a .py file or a module name; no Python handler installed" << std::endl;
            return;
        }
        try {
            outHandlers.push_back(new python_bridge_handler_t(module, kernel, dispatch_id));
        } catch (const std::exception& e) {
            std::cerr << "PythonHandler: " << e.what() << "; no Python handler installed" << std::endl;
        }
    }
}
