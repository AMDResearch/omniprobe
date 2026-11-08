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
#pragma once

#include <Python.h>
#include <cstdint>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

//! What a wave message says about where and how it was produced.
struct pyWaveInfo {
    uint64_t exec = 0;
    uint64_t timestamp = 0;
    uint32_t block_idx[3] = {0, 0, 0};
    uint32_t wave_num = 0, xcc_id = 0, se_id = 0, cu_id = 0;
    std::string source_file;
    uint32_t line = 0, column = 0;
};

//! One instrumented memory instruction executed by one wave.
struct pyAddressWave {
    pyWaveInfo wave;
    std::vector<uint64_t> addresses;   //!< one per active lane, increasing lane order
    std::vector<uint32_t> lanes;       //!< the lane id of each address
    std::string access_type;           //!< "read", "write", "readwrite" or "undefined"
    std::string memory_space;          //!< "global", "shared", "flat", ...
    uint32_t access_size = 0;          //!< bytes of the accessed type
};

//! One basic-block (or user-defined) time interval from one wave.
struct pyTimeInterval {
    pyWaveInfo wave;
    uint64_t start = 0, stop = 0;
    uint32_t block_id = 0;             //!< the instrumentation's user_data (BBInterval: block index)
};

//! Calls functions in a user-supplied Python module for each message.
//!
//! The module defines any of (at least one is required):
//!   handleAddressWave(dict)     once per wave per instrumented memory instruction
//!   handleAddressMessage(dict)  once per active lane (the original, per-lane form)
//!   handleTimeMessage(dict)     once per time-interval message
//!   handleReport(dict)          once per dispatch, after its last message
//! Every dict carries "kernel" and "dispatch_id"; see docs/usage.md for the rest.
//!
//! Every method may be called on a different thread (dispatch, dh_comms processing,
//! completion), so each one takes the GIL itself. The interpreter is process-wide:
//! it is started once, by the first handler if the host process has none, and is
//! never finalized here, because handlers are created and destroyed per dispatch.
class pythonMessageHandler {
public:
    pythonMessageHandler(const std::string& module_name, const std::string& kernel = "",
                         uint64_t dispatch_id = 0);
    ~pythonMessageHandler();
    pythonMessageHandler(const pythonMessageHandler&) = delete;
    pythonMessageHandler& operator=(const pythonMessageHandler&) = delete;
    bool wantsAddressLanes() const { return pAddressFunc_ != nullptr; }
    bool wantsAddressWaves() const { return pAddressWaveFunc_ != nullptr; }
    bool wantsTimeIntervals() const { return pTimingFunc_ != nullptr; }
    void addressMessage(void *address);
    void addressWave(const pyAddressWave& w);
    void timingMessage(const pyTimeInterval& t);
    void report();
private:
    void call(PyObject* func, const char* key, PyObject* value);
    void callDict(PyObject* func, PyObject* dict);   // steals dict
    PyObject* waveDict(const pyWaveInfo& w);         // new reference, or nullptr
    std::string module_name_;
    PyObject *pModule_ = nullptr;
    PyObject *pAddressFunc_ = nullptr;      // optional
    PyObject *pAddressWaveFunc_ = nullptr;  // optional
    PyObject *pTimingFunc_ = nullptr;       // optional
    PyObject *pReportFunc_ = nullptr;       // optional
    PyObject *pKernel_ = nullptr;
    PyObject *pDispatchId_ = nullptr;
};
