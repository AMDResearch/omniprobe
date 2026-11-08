
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
#include "inc/kdb_message_handler_base.h"
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

class python_bridge_handler_t : public kdb_message_handler_base {
public:
    python_bridge_handler_t(const std::string& module, const std::string& kernel, uint64_t dispatch_id)
        : py_(module, kernel, dispatch_id) {}

    bool handle(const dh_comms::message_t& message) override
    {
        const auto& hdr = message.wave_header();
        switch (hdr.user_type) {
        case dh_comms::message_type::address: {
            if (message.data_item_size() != sizeof(uint64_t))
                return false;
            if (py_.wantsAddressLanes())
                for (size_t i = 0; i != message.no_data_items(); ++i)
                    py_.addressMessage(reinterpret_cast<void*>(*static_cast<const uint64_t*>(message.data_item(i))));
            if (py_.wantsAddressWaves())
                py_.addressWave(addressWave(message));
            return true;
        }
        case dh_comms::message_type::time_interval:
            if (message.data_item_size() != sizeof(dh_comms::time_interval))
                return false;
            if (py_.wantsTimeIntervals())
                for (size_t i = 0; i != message.no_data_items(); ++i) {
                    auto ti = *static_cast<const dh_comms::time_interval*>(message.data_item(i));
                    pyTimeInterval t;
                    t.wave = waveInfo(hdr);
                    t.start = ti.start;
                    t.stop = ti.stop;
                    t.block_id = hdr.user_data;
                    py_.timingMessage(t);
                }
            return true;
        default:
            return false;
        }
    }

    void report() override { py_.report(); }

private:
    pyWaveInfo waveInfo(const dh_comms::wave_header_t& hdr)
    {
        pyWaveInfo w;
        w.exec = hdr.exec;
        w.timestamp = hdr.timestamp;
        w.block_idx[0] = hdr.block_idx_x;
        w.block_idx[1] = hdr.block_idx_y;
        w.block_idx[2] = hdr.block_idx_z;
        w.wave_num = hdr.wave_num;
        w.xcc_id = hdr.xcc_id;
        w.se_id = hdr.se_id;
        w.cu_id = hdr.cu_id;
        w.source_file = sourceFileForHash(hdr.dwarf_fname_hash);
        w.line = hdr.dwarf_line;
        w.column = hdr.dwarf_column;
        return w;
    }

    pyAddressWave addressWave(const dh_comms::message_t& message)
    {
        static const char* spaces[] = {"flat", "global", "gds", "shared", "constant", "scratch"};
        static const char* kinds[] = {"undefined", "read", "write", "readwrite"};
        const auto& hdr = message.wave_header();
        pyAddressWave w;
        w.wave = waveInfo(hdr);
        for (size_t i = 0; i != message.no_data_items(); ++i)
            w.addresses.push_back(*static_cast<const uint64_t*>(message.data_item(i)));
        // Addresses come one per active lane in increasing lane order (see
        // AddressLogger), so the i-th address belongs to the i-th set exec bit.
        for (uint32_t lane = 0; lane != 64; ++lane)
            if ((hdr.exec >> lane) & 1)
                w.lanes.push_back(lane);
        if (w.lanes.size() != w.addresses.size())
            w.lanes.clear();   // not as documented: do not guess
        uint32_t space = (hdr.user_data >> 2) & 0xf;
        w.memory_space = space < 6 ? spaces[space] : "undefined";
        w.access_type = kinds[hdr.user_data & 0b11];
        w.access_size = (hdr.user_data >> 6) & 0xffff;
        return w;
    }

    pythonMessageHandler py_;
};

} // namespace

extern "C"{
    // Called once when omniprobe loads this plugin, before any kernel runs: a
    // module that cannot be used ends the run with an error, instead of every
    // dispatch silently falling back to the default handlers (exit status 0).
    PUBLIC_API bool omniprobeValidateHandlers(std::string& error)
    {
        const char* module = std::getenv("OMNIPROBE_PYTHON_HANDLER");
        if (module == NULL || *module == '\0') {
            error = "PythonHandler: set OMNIPROBE_PYTHON_HANDLER to a .py file or an importable module name";
            return false;
        }
        try {
            pythonMessageHandler probe(module);   // imports the module and checks its functions
        } catch (const std::exception& e) {
            error = std::string("PythonHandler: ") + e.what();
            return false;
        }
        return true;
    }

    PUBLIC_API void getMessageHandlers(const std::string& kernel, uint64_t dispatch_id, std::vector<dh_comms::message_handler_base *>& outHandlers)
    {
        // Validated at load time; a failure here is unexpected, so say so loudly.
        const char* module = std::getenv("OMNIPROBE_PYTHON_HANDLER");
        try {
            outHandlers.push_back(new python_bridge_handler_t(module ? module : "", kernel, dispatch_id));
        } catch (const std::exception& e) {
            std::cerr << "omniprobe: ERROR: PythonHandler: " << e.what() << "; dispatch " << dispatch_id
                      << " of " << kernel << " gets no Python handler" << std::endl;
        }
    }
}
