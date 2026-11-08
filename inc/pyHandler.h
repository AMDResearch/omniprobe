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

//! Calls functions in a user-supplied Python module for each message.
//!
//! The module must define handleAddressMessage(dict) and handleTimeMessage(dict);
//! handleReport(dict) is optional and is called once per dispatch, after its last
//! message. Every dict carries "kernel" and "dispatch_id".
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
    void addressMessage(void *address);
    void timingMessage(uint64_t time);
    void report();
private:
    void call(PyObject* func, const char* key, PyObject* value);
    std::string module_name_;
    PyObject *pModule_ = nullptr;
    PyObject *pAddressFunc_ = nullptr;
    PyObject *pTimingFunc_ = nullptr;
    PyObject *pReportFunc_ = nullptr;   // optional
    PyObject *pKernel_ = nullptr;
    PyObject *pDispatchId_ = nullptr;
};
