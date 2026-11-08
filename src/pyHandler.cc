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
#include "inc/pyHandler.h"

namespace {

// Holds the GIL for its lifetime, on whatever thread constructs it.
struct gil_lock {
    PyGILState_STATE state = PyGILState_Ensure();
    ~gil_lock() { PyGILState_Release(state); }
};

// Starts the interpreter once per process, unless the host already runs one (a
// Triton/PyTorch application). Py_InitializeEx leaves the GIL held by this
// thread; release it, or no other thread can ever take it. Never finalized:
// handlers are per dispatch, the interpreter is per process.
void ensure_interpreter()
{
    static std::once_flag once;
    std::call_once(once, [] {
        if (Py_IsInitialized())
            return;
        Py_InitializeEx(0);   // 0: leave the host's signal handlers alone
        if (!Py_IsInitialized())
            throw std::runtime_error("Python initialization failed");
        PyEval_SaveThread();
    });
}

// "dir/name.py" -> put dir on sys.path and return "name"; anything else is a
// module name resolved through sys.path (PYTHONPATH) as is.
std::string resolve_module(const std::string& spec)
{
    const std::string ext = ".py";
    if (spec.size() <= ext.size() || spec.compare(spec.size() - ext.size(), ext.size(), ext) != 0)
        return spec;
    std::string stem = spec.substr(0, spec.size() - ext.size());
    std::string dir = ".";
    auto slash = stem.rfind('/');
    if (slash != std::string::npos) {
        dir = slash ? stem.substr(0, slash) : "/";
        stem = stem.substr(slash + 1);
    }
    PyObject* path = PySys_GetObject("path");   // borrowed
    PyObject* pdir = PyUnicode_FromString(dir.c_str());
    if (path && pdir && PySequence_Contains(path, pdir) == 0)
        PyList_Insert(path, 0, pdir);
    Py_XDECREF(pdir);
    return stem;
}

} // namespace

pythonMessageHandler::pythonMessageHandler(const std::string& module_name, const std::string& kernel,
                                           uint64_t dispatch_id)
    : module_name_(module_name)
{
    ensure_interpreter();
    gil_lock gil;
    std::string error;
    pModule_ = PyImport_ImportModule(resolve_module(module_name_).c_str());
    if (!pModule_) {
        error = "Failed to load Python module '" + module_name_ + "'";
    } else {
        pAddressFunc_ = PyObject_GetAttrString(pModule_, "handleAddressMessage");
        if (!pAddressFunc_ || !PyCallable_Check(pAddressFunc_))
            error = "Python module '" + module_name_ + "' has no callable handleAddressMessage";
        pTimingFunc_ = PyObject_GetAttrString(pModule_, "handleTimeMessage");
        if (error.empty() && (!pTimingFunc_ || !PyCallable_Check(pTimingFunc_)))
            error = "Python module '" + module_name_ + "' has no callable handleTimeMessage";
        if (PyObject_HasAttrString(pModule_, "handleReport"))
            pReportFunc_ = PyObject_GetAttrString(pModule_, "handleReport");
    }
    if (error.empty()) {
        pKernel_ = PyUnicode_FromString(kernel.c_str());
        pDispatchId_ = PyLong_FromUnsignedLongLong(dispatch_id);
        if (!pKernel_ || !pDispatchId_)
            error = "Failed to create Python objects for the dispatch";
    }
    if (!error.empty()) {
        if (PyErr_Occurred())
            PyErr_Print();
        Py_CLEAR(pModule_); Py_CLEAR(pAddressFunc_); Py_CLEAR(pTimingFunc_);
        Py_CLEAR(pReportFunc_); Py_CLEAR(pKernel_); Py_CLEAR(pDispatchId_);
        throw std::runtime_error(error);
    }
}

pythonMessageHandler::~pythonMessageHandler()
{
    if (!Py_IsInitialized())   // the host finalized its own interpreter first
        return;
    gil_lock gil;
    Py_CLEAR(pAddressFunc_);
    Py_CLEAR(pTimingFunc_);
    Py_CLEAR(pReportFunc_);
    Py_CLEAR(pModule_);
    Py_CLEAR(pKernel_);
    Py_CLEAR(pDispatchId_);
}

// Calls func({"kernel": ..., "dispatch_id": ..., key: value}). Steals value.
// Caller holds the GIL.
void pythonMessageHandler::call(PyObject* func, const char* key, PyObject* value)
{
    PyObject* pDict = PyDict_New();
    if (!pDict || (key && !value)) {
        Py_XDECREF(pDict);
        Py_XDECREF(value);
        if (PyErr_Occurred())
            PyErr_Print();
        std::cerr << "pythonMessageHandler: failed to build the message dict" << std::endl;
        return;
    }
    PyDict_SetItemString(pDict, "kernel", pKernel_);
    PyDict_SetItemString(pDict, "dispatch_id", pDispatchId_);
    if (key) {
        PyDict_SetItemString(pDict, key, value);   // does not steal
        Py_DECREF(value);
    }
    PyObject* pValue = PyObject_CallFunctionObjArgs(func, pDict, NULL);
    if (!pValue) {
        PyErr_Print();
        std::cerr << "pythonMessageHandler: call into module '" << module_name_ << "' failed" << std::endl;
    }
    Py_XDECREF(pValue);
    Py_DECREF(pDict);
}

void pythonMessageHandler::addressMessage(void *address)
{
    gil_lock gil;
    call(pAddressFunc_, "address", PyLong_FromUnsignedLongLong(reinterpret_cast<uintptr_t>(address)));
}

void pythonMessageHandler::timingMessage(uint64_t time)
{
    gil_lock gil;
    call(pTimingFunc_, "elapsed_time", PyLong_FromUnsignedLongLong(time));
}

void pythonMessageHandler::report()
{
    if (!pReportFunc_)
        return;
    gil_lock gil;
    call(pReportFunc_, nullptr, nullptr);
}
