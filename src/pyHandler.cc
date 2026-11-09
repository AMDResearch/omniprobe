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
#include "inc/kernel_dispatch.h"

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

// The attribute if the module defines it and it is callable; nullptr if it is
// absent; nullptr and an error if it exists but cannot be called. Caller holds
// the GIL.
PyObject* optionalCallable(PyObject* module, const char* name, std::string& error)
{
    if (!PyObject_HasAttrString(module, name))
        return nullptr;
    PyObject* f = PyObject_GetAttrString(module, name);
    if (!f || !PyCallable_Check(f)) {
        Py_XDECREF(f);
        if (error.empty())
            error = std::string("'") + name + "' in the Python module is not callable";
        return nullptr;
    }
    return f;
}

// d[key] = value, stealing value. Returns false if value is null.
bool setItem(PyObject* d, const char* key, PyObject* value)
{
    if (!value)
        return false;
    PyDict_SetItemString(d, key, value);
    Py_DECREF(value);
    return true;
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
        pAddressFunc_ = optionalCallable(pModule_, "handleAddressMessage", error);
        pAddressWaveFunc_ = optionalCallable(pModule_, "handleAddressWave", error);
        pTimingFunc_ = optionalCallable(pModule_, "handleTimeMessage", error);
        pReportFunc_ = optionalCallable(pModule_, "handleReport", error);
        if (error.empty() && !pAddressFunc_ && !pAddressWaveFunc_ && !pTimingFunc_)
            error = "Python module '" + module_name_ + "' defines none of handleAddressWave, "
                    "handleAddressMessage, handleTimeMessage";
    }
    if (error.empty()) {
        pKernel_ = PyUnicode_FromString(kernel.c_str());
        pDispatchId_ = PyLong_FromUnsignedLongLong(dispatch_id);
        pKernelDispatch_ = PyLong_FromUnsignedLongLong(kernelDispatchOrdinal(dispatch_id));
        if (!pKernel_ || !pDispatchId_ || !pKernelDispatch_)
            error = "Failed to create Python objects for the dispatch";
    }
    if (!error.empty()) {
        if (PyErr_Occurred())
            PyErr_Print();
        Py_CLEAR(pModule_); Py_CLEAR(pAddressFunc_); Py_CLEAR(pAddressWaveFunc_); Py_CLEAR(pTimingFunc_);
        Py_CLEAR(pReportFunc_); Py_CLEAR(pKernel_); Py_CLEAR(pDispatchId_); Py_CLEAR(pKernelDispatch_);
        throw std::runtime_error(error);
    }
}

pythonMessageHandler::~pythonMessageHandler()
{
    if (!Py_IsInitialized())   // the host finalized its own interpreter first
        return;
    gil_lock gil;
    Py_CLEAR(pAddressFunc_);
    Py_CLEAR(pAddressWaveFunc_);
    Py_CLEAR(pTimingFunc_);
    Py_CLEAR(pReportFunc_);
    Py_CLEAR(pModule_);
    Py_CLEAR(pKernel_);
    Py_CLEAR(pDispatchId_);
    Py_CLEAR(pKernelDispatch_);
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
    PyDict_SetItemString(pDict, "kernel_dispatch", pKernelDispatch_);
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
    if (!pAddressFunc_)
        return;
    gil_lock gil;
    call(pAddressFunc_, "address", PyLong_FromUnsignedLongLong(reinterpret_cast<uintptr_t>(address)));
}

// Calls func(dict) after adding "kernel", "dispatch_id" and "kernel_dispatch". Steals dict. Caller
// holds the GIL.
void pythonMessageHandler::callDict(PyObject* func, PyObject* dict)
{
    if (!dict) {
        if (PyErr_Occurred())
            PyErr_Print();
        std::cerr << "pythonMessageHandler: failed to build the message dict" << std::endl;
        return;
    }
    PyDict_SetItemString(dict, "kernel", pKernel_);
    PyDict_SetItemString(dict, "dispatch_id", pDispatchId_);
    PyDict_SetItemString(dict, "kernel_dispatch", pKernelDispatch_);
    PyObject* pValue = PyObject_CallFunctionObjArgs(func, dict, NULL);
    if (!pValue) {
        PyErr_Print();
        std::cerr << "pythonMessageHandler: call into module '" << module_name_ << "' failed" << std::endl;
    }
    Py_XDECREF(pValue);
    Py_DECREF(dict);
}

PyObject* pythonMessageHandler::waveDict(const pyWaveInfo& w)
{
    PyObject* d = PyDict_New();
    if (!d)
        return nullptr;
    bool ok = setItem(d, "exec", PyLong_FromUnsignedLongLong(w.exec))
        && setItem(d, "timestamp", PyLong_FromUnsignedLongLong(w.timestamp))
        && setItem(d, "block_idx", Py_BuildValue("(III)", w.block_idx[0], w.block_idx[1], w.block_idx[2]))
        && setItem(d, "wave_num", PyLong_FromUnsignedLong(w.wave_num))
        && setItem(d, "xcc_id", PyLong_FromUnsignedLong(w.xcc_id))
        && setItem(d, "se_id", PyLong_FromUnsignedLong(w.se_id))
        && setItem(d, "cu_id", PyLong_FromUnsignedLong(w.cu_id))
        && setItem(d, "source_file", PyUnicode_DecodeUTF8(w.source_file.data(), w.source_file.size(), "replace"))
        && setItem(d, "line", PyLong_FromUnsignedLong(w.line))
        && setItem(d, "column", PyLong_FromUnsignedLong(w.column));
    if (!ok)
        Py_CLEAR(d);
    return d;
}

void pythonMessageHandler::addressWave(const pyAddressWave& w)
{
    if (!pAddressWaveFunc_)
        return;
    gil_lock gil;
    PyObject* d = waveDict(w.wave);
    PyObject* addresses = d ? PyList_New(w.addresses.size()) : nullptr;
    PyObject* lanes = addresses ? PyList_New(w.lanes.size()) : nullptr;
    bool ok = lanes != nullptr;
    for (size_t i = 0; ok && i != w.addresses.size(); ++i) {
        PyObject* v = PyLong_FromUnsignedLongLong(w.addresses[i]);
        ok = v != nullptr;
        if (ok)
            PyList_SET_ITEM(addresses, i, v);   // steals v
    }
    for (size_t i = 0; ok && i != w.lanes.size(); ++i) {
        PyObject* v = PyLong_FromUnsignedLong(w.lanes[i]);
        ok = v != nullptr;
        if (ok)
            PyList_SET_ITEM(lanes, i, v);
    }
    if (ok)
        ok = setItem(d, "addresses", addresses) && setItem(d, "lanes", lanes)
            && setItem(d, "access_type", PyUnicode_FromString(w.access_type.c_str()))
            && setItem(d, "memory_space", PyUnicode_FromString(w.memory_space.c_str()))
            && setItem(d, "access_size", PyLong_FromUnsignedLong(w.access_size));
    else {
        Py_XDECREF(addresses);
        Py_XDECREF(lanes);
    }
    if (!ok)
        Py_CLEAR(d);
    callDict(pAddressWaveFunc_, d);
}

void pythonMessageHandler::timingMessage(const pyTimeInterval& t)
{
    if (!pTimingFunc_)
        return;
    gil_lock gil;
    PyObject* d = waveDict(t.wave);
    if (d && !(setItem(d, "elapsed_time", PyLong_FromUnsignedLongLong(t.stop - t.start))
               && setItem(d, "start", PyLong_FromUnsignedLongLong(t.start))
               && setItem(d, "stop", PyLong_FromUnsignedLongLong(t.stop))
               && setItem(d, "block_id", PyLong_FromUnsignedLong(t.block_id))))
        Py_CLEAR(d);
    callDict(pTimingFunc_, d);
}

void pythonMessageHandler::report()
{
    if (!pReportFunc_)
        return;
    gil_lock gil;
    call(pReportFunc_, nullptr, nullptr);
}
