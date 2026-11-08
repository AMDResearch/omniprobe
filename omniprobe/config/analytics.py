[
    {
        "name": "AddressLogger",
        "description": "Log raw memory traces",
        "lib_name": "libLogMessages64.so",
    },
    {
        "name": "BasicBlockLogger",
        "description": "Log one record per wave per basic block entered (needs a BBStart-instrumented binary)",
        "lib_name": "libLogMessages64.so",
        "llvm_plugin": "libAMDGCNSubmitBBStart-triton.so" 
    },
    {
        "name": "Heatmap",
        "description": "Produce a per dispatch memory heatmap",
        "lib_name": "libdefaultMessageHandlers64.so"
    },
    {
        "name": "MemoryAnalysis",
        "description": "Analyze memory access efficiency",
        "lib_name": "libMemAnalysis64.so"
    },
    {
        "name": "BasicBlockAnalysis",
        "description": "Count wave entries and active lanes per basic block (needs a BBStart-instrumented binary)",
        "lib_name": "libBasicBlocks64.so",
        "llvm_plugin": "libAMDGCNSubmitBBStart-triton.so" 
    },
    {
        "name": "PythonHandler",
        "description": "Pass each address and timing message to your own Python module, named by OMNIPROBE_PYTHON_HANDLER (a .py file or an importable module); it must define handleAddressMessage(dict) and handleTimeMessage(dict), and may define handleReport(dict), called once per dispatch",
        "lib_name": "libPythonHandler64.so"
    }
]
