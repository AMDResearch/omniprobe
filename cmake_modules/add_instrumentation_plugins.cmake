# add_instrumentation_plugins.cmake
#
# CMake function that creates LLVM instrumentation plugin targets.
# Called once per LLVM variant (ROCm, Triton) with different SUFFIX and LLVM_DIR.
#
# Plugins are compiled using the LLVM variant's own clang++ (not the project's
# hipcc), since LLVM pass plugins must be compiled with the matching LLVM.
# This is achieved via add_custom_command for compilation and linking.
#
# Usage:
#   add_instrumentation_plugins(
#       SUFFIX rocm
#       LLVM_DIR ${ROCM_PATH}/llvm
#   )
#   add_instrumentation_plugins(
#       SUFFIX triton
#       LLVM_DIR ${TRITON_LLVM}
#       LINK_LLVM_LIBS
#   )
#
# Options:
#   SUFFIX       - Target name suffix (e.g., "rocm" or "triton")
#   LLVM_DIR     - LLVM installation or build directory (must contain bin/llvm-config)
#   LINK_LLVM_LIBS - If set, link against LLVMCore, LLVMIRReader, LLVMLinker

function(add_instrumentation_plugins)
    cmake_parse_arguments(AIP "LINK_LLVM_LIBS" "SUFFIX;LLVM_DIR" "" ${ARGN})

    if(NOT AIP_SUFFIX)
        message(FATAL_ERROR "add_instrumentation_plugins: SUFFIX is required")
    endif()
    if(NOT AIP_LLVM_DIR)
        message(FATAL_ERROR "add_instrumentation_plugins: LLVM_DIR is required")
    endif()

    # 1. Find llvm-config and clang++
    find_program(_llvm_config_${AIP_SUFFIX} llvm-config
        PATHS "${AIP_LLVM_DIR}/bin" NO_DEFAULT_PATH REQUIRED)
    set(_llvm_config "${_llvm_config_${AIP_SUFFIX}}")

    execute_process(COMMAND "${_llvm_config}" --bindir
        OUTPUT_VARIABLE _llvm_bindir OUTPUT_STRIP_TRAILING_WHITESPACE)
    set(_clangxx "${_llvm_bindir}/clang++")

    message(STATUS "[instrumentation-${AIP_SUFFIX}] Using llvm-config: ${_llvm_config}")
    message(STATUS "[instrumentation-${AIP_SUFFIX}] Using clang++: ${_clangxx}")

    # 2. Query LLVM configuration
    execute_process(COMMAND "${_llvm_config}" --cppflags
        OUTPUT_VARIABLE _llvm_cppflags OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-config --cppflags failed for ${AIP_SUFFIX}")
    endif()

    execute_process(COMMAND "${_llvm_config}" --has-rtti
        OUTPUT_VARIABLE _llvm_has_rtti OUTPUT_STRIP_TRAILING_WHITESPACE)

    # 3. Parse cppflags into a proper CMake list
    separate_arguments(_cppflags_list UNIX_COMMAND "${_llvm_cppflags}")

    # 4. Build compile flags as a CMake list (each flag is a separate element)
    string(TOUPPER "${_llvm_has_rtti}" _rtti_upper)
    set(_compile_flags_list
        -std=c++17 -fPIC
        ${_cppflags_list}
        -DLLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING
        -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function
        -fdiagnostics-color=always -fvisibility-inlines-hidden
    )
    if(_rtti_upper STREQUAL "NO")
        list(APPEND _compile_flags_list -fno-rtti)
    endif()

    message(STATUS "[instrumentation-${AIP_SUFFIX}] LLVM RTTI: ${_llvm_has_rtti}")

    # 5. Get link flags as a proper CMake list
    set(_link_flags_list -shared -fPIC)
    if(AIP_LINK_LLVM_LIBS)
        execute_process(COMMAND "${_llvm_config}" --libdir
            OUTPUT_VARIABLE _llvm_libdir OUTPUT_STRIP_TRAILING_WHITESPACE)
        list(APPEND _link_flags_list "-L${_llvm_libdir}" -lLLVMCore -lLLVMIRReader -lLLVMLinker)
        message(STATUS "[instrumentation-${AIP_SUFFIX}] LLVM libdir: ${_llvm_libdir}")
    endif()

    # 6. Create plugin targets via custom commands
    set(_src_dir "${CMAKE_CURRENT_SOURCE_DIR}/src/instrumentation")
    set(_obj_dir "${CMAKE_BINARY_DIR}/instrumentation-${AIP_SUFFIX}")
    set(_out_dir "${CMAKE_BINARY_DIR}/lib/plugins")
    set(_include_flags "-I${_src_dir}/include")

    set(_plugins AMDGCNSubmitAddressMessages AMDGCNSubmitBBStart AMDGCNSubmitBBInterval AMDGCNSubmitKernelLifecycle)
    set(_all_outputs "")

    # Collect all headers for dependency tracking
    file(GLOB _all_headers "${_src_dir}/include/*.h")

    foreach(_plugin IN LISTS _plugins)
        set(_target "${_plugin}-${AIP_SUFFIX}")
        set(_plugin_obj_dir "${_obj_dir}/${_plugin}")
        set(_output "${_out_dir}/lib${_target}.so")

        # Compile plugin source
        set(_plugin_obj "${_plugin_obj_dir}/${_plugin}.o")
        add_custom_command(
            OUTPUT "${_plugin_obj}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${_plugin_obj_dir}"
            COMMAND "${_clangxx}" ${_compile_flags_list} ${_include_flags}
                -c "${_src_dir}/${_plugin}.cpp"
                -o "${_plugin_obj}"
            DEPENDS "${_src_dir}/${_plugin}.cpp" ${_all_headers}
            COMMENT "[instrumentation-${AIP_SUFFIX}] Compiling ${_plugin}.cpp"
        )

        # Compile InstrumentationCommon (per-plugin to avoid races)
        set(_common_obj "${_plugin_obj_dir}/InstrumentationCommon.o")
        add_custom_command(
            OUTPUT "${_common_obj}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${_plugin_obj_dir}"
            COMMAND "${_clangxx}" ${_compile_flags_list} ${_include_flags}
                -c "${_src_dir}/InstrumentationCommon.cpp"
                -o "${_common_obj}"
            DEPENDS "${_src_dir}/InstrumentationCommon.cpp" ${_all_headers}
            COMMENT "[instrumentation-${AIP_SUFFIX}] Compiling InstrumentationCommon.cpp for ${_plugin}"
        )

        # Link into shared library
        add_custom_command(
            OUTPUT "${_output}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${_out_dir}"
            COMMAND "${_clangxx}" ${_link_flags_list}
                "${_plugin_obj}" "${_common_obj}"
                -o "${_output}"
            DEPENDS "${_plugin_obj}" "${_common_obj}"
            COMMENT "[instrumentation-${AIP_SUFFIX}] Linking lib${_target}.so"
        )

        # Create a named target for dependency tracking
        add_custom_target(${_target} ALL DEPENDS "${_output}")

        list(APPEND _all_outputs "${_output}")
    endforeach()

    # 7. Export and install
    set(INSTRUMENTATION_TARGETS_${AIP_SUFFIX} ${_all_outputs} PARENT_SCOPE)
    install(FILES ${_all_outputs} DESTINATION omniprobe/lib/plugins)
endfunction()
