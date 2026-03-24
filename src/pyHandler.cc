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


std::mutex pythonMessageHandler::global_mutex_;

pythonMessageHandler::pythonMessageHandler(std::string& module_name)
{
    module_name_ = module_name;
    std::lock_guard<std::mutex> lock(global_mutex_);
    if (!Py_IsInitialized()) {
        Py_Initialize();
        if (!Py_IsInitialized())
        {
            std::cerr << "Python initialization failed!" << std::endl;
            throw std::runtime_error(std::string("Python initialization failed!"));
        }
    }
    pModule_ = PyImport_ImportModule(module_name_.c_str());
    if (!pModule_) {
        PyErr_Print();
        std::cerr << "Failed to load Python module!" << std::endl;
        Py_Finalize();
        throw std::runtime_error(std::string("Failed to load Python module!"));
    }
    
    pAddressFunc_ = PyObject_GetAttrString(pModule_, "handleAddressMessage");
    if (!pAddressFunc_ || !PyCallable_Check(pAddressFunc_)) {
        PyErr_Print();
        std::cerr << "Cannot find function '" << "handleAddressMessage" << "'!" << std::endl;
        throw std::runtime_error(std::string("Failed to find handleAddressMessage!"));
    }
    
    pTimingFunc_ = PyObject_GetAttrString(pModule_, "handleTimeMessage");
    if (!pTimingFunc_ || !PyCallable_Check(pTimingFunc_)) {
        PyErr_Print();
        std::cerr << "Cannot find function '" << "handleTimeMessage" << "'!" << std::endl;
        throw std::runtime_error(std::string("Failed to find handleTimeMessage!"));
    }
}

pythonMessageHandler::~pythonMessageHandler()
{
    if (pAddressFunc_)
        Py_DECREF(pAddressFunc_);
    if (pTimingFunc_)
        Py_DECREF(pTimingFunc_);
    if (pModule_)
        Py_DECREF(pModule_);
    Py_Finalize();
}
void pythonMessageHandler::addressMessage(void *address)
{
    PyObject* pDict = PyDict_New();
    if (!pDict) {
        PyErr_Print();
        std::cerr << "Failed to create dictionary!" << std::endl;
        throw std::runtime_error("Failed to create python dictionary in addressMessage");
    }

    // Populate the Python dictionary (add key-value pairs)
    PyDict_SetItemString(pDict, "address", PyLong_FromUnsignedLong(reinterpret_cast<unsigned long>(address)));  // Add integer value

    // Call the Python function with the dictionary as an argument
    PyObject* pArgs = PyTuple_New(1);  // Create a tuple for function arguments
    PyTuple_SetItem(pArgs, 0, pDict);  // Add dictionary to the tuple

    PyObject* pValue = PyObject_CallObject(pAddressFunc_, pArgs);
    if (!pValue) {
        PyErr_Print();
        std::cerr << "Function call to addressMessageHandler failed!" << std::endl;
    } else {
        std::cout << "Function call to addressMessageHandler succeeded!" << std::endl;
        Py_DECREF(pValue);
    }
    Py_DECREF(pArgs);
    Py_DECREF(pDict);
    return;
}

void pythonMessageHandler::timingMessage(uint64_t time)
{
    PyObject* pDict = PyDict_New();
    if (!pDict) {
        PyErr_Print();
        std::cerr << "Failed to create dictionary!" << std::endl;
        throw std::runtime_error("Failed to create python dictionary in timingMessage");
    }

    // Populate the Python dictionary (add key-value pairs)
    PyDict_SetItemString(pDict, "elapsed_time", PyLong_FromUnsignedLong(time));  // Add integer value

    // Call the Python function with the dictionary as an argument
    PyObject* pArgs = PyTuple_New(1);  // Create a tuple for function arguments
    PyTuple_SetItem(pArgs, 0, pDict);  // Add dictionary to the tuple

    PyObject* pValue = PyObject_CallObject(pTimingFunc_, pArgs);
    if (!pValue) {
        PyErr_Print();
        std::cerr << "Function call to timeMessageHandler failed!" << std::endl;
    } else {
        std::cout << "Function call to timeMessageHandler succeeded!" << std::endl;
        Py_DECREF(pValue);
    }
    Py_DECREF(pArgs);
    Py_DECREF(pDict);
    return;
}

