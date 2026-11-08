################################################################################
# Test kernels for end-to-end omniprobe testing
################################################################################

# Compiler flags for test kernels: treat warnings as errors
set(TEST_KERNEL_COMPILE_FLAGS
    -fgpu-rdc
    -g                              # Debug info required for DWARF-based analysis in handlers
    -Werror                         # Treat all warnings as errors
    -Wno-error=unused-parameter     # Allow unused parameters (common in kernels)
)

# Path to instrumentation plugin in build directory
set(INST_PLUGIN "${CMAKE_BINARY_DIR}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so")

# copy_bitcode (build/lib/bitcode/) is defined in the top-level CMakeLists.txt.

# Simple heatmap test kernel
add_executable(simple_heatmap_test simple_heatmap_test.cpp)
set_source_files_properties(simple_heatmap_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_heatmap_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(simple_heatmap_test PRIVATE -fgpu-rdc)
add_dependencies(simple_heatmap_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Simple memory analysis test kernel
add_executable(simple_memory_analysis_test simple_memory_analysis_test.cpp)
set_source_files_properties(simple_memory_analysis_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_memory_analysis_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(simple_memory_analysis_test PRIVATE -fgpu-rdc)
add_dependencies(simple_memory_analysis_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# PythonHandler test kernel - many concurrent dispatches, 2 * 1024 addresses each
add_executable(python_handler_test python_handler_test.cpp)
set_source_files_properties(python_handler_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(python_handler_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(python_handler_test PRIVATE -fgpu-rdc)
add_dependencies(python_handler_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Bank conflict test kernel - LDS bank conflicts via unpadded matrix transpose
add_executable(bank_conflict_test bank_conflict_test.cpp)
set_source_files_properties(bank_conflict_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(bank_conflict_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(bank_conflict_test PRIVATE -fgpu-rdc)
add_dependencies(bank_conflict_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Dual kernel test - dispatches two kernels to test scanning frequency
add_executable(dual_kernel_test dual_kernel_test.cpp)
set_source_files_properties(dual_kernel_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(dual_kernel_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(dual_kernel_test PRIVATE -fgpu-rdc)
add_dependencies(dual_kernel_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Same two kernels, instrumented with BBStart, so BasicBlockAnalysis has the
# block-index messages it expects (used by test_json_output.sh)
add_executable(dual_kernel_bbstart_test dual_kernel_test.cpp)
set_source_files_properties(dual_kernel_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(dual_kernel_bbstart_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${CMAKE_BINARY_DIR}/lib/plugins/libAMDGCNSubmitBBStart-rocm.so
)
target_link_options(dual_kernel_bbstart_test PRIVATE -fgpu-rdc)
add_dependencies(dual_kernel_bbstart_test copy_bitcode AMDGCNSubmitBBStart-rocm)

# Known control flow for BasicBlockAnalysis counts (test_bba_counts.sh)
add_executable(bb_counts_test bb_counts_test.cpp)
set_source_files_properties(bb_counts_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(bb_counts_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${CMAKE_BINARY_DIR}/lib/plugins/libAMDGCNSubmitBBStart-rocm.so
)
target_link_options(bb_counts_test PRIVATE -fgpu-rdc)
add_dependencies(bb_counts_test copy_bitcode AMDGCNSubmitBBStart-rocm)

# Same kernel with AddressMessages: its 1-in-4-lanes store gives divergent
# address records (test_python_api_e2e.sh)
add_executable(bb_counts_am_test bb_counts_test.cpp)
target_compile_options(bb_counts_am_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(bb_counts_am_test PRIVATE -fgpu-rdc)
add_dependencies(bb_counts_am_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# LDS accesses before any global access (test_json_output.sh)
add_executable(lds_split_test lds_split_test.cpp)
set_source_files_properties(lds_split_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(lds_split_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(lds_split_test PRIVATE -fgpu-rdc)
add_dependencies(lds_split_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Internal-linkage kernels under -fgpu-rdc (test_intern_linkage.sh). The
# .intern.<hash> suffix is derived from the compilation unit ID; fixing -cuid
# makes the hash deterministic. cuid "a" -> letter-leading hash, "c" ->
# digit-leading (the test asserts which one it got).
foreach(_flavour_cuid IN ITEMS "letter:a" "digit:c")
    string(REPLACE ":" ";" _fc "${_flavour_cuid}")
    list(GET _fc 0 _flavour)
    list(GET _fc 1 _cuid)
    add_executable(intern_${_flavour}_test intern_linkage_test.cpp)
    target_compile_options(intern_${_flavour}_test PRIVATE
        ${TEST_KERNEL_COMPILE_FLAGS}
        -cuid=${_cuid}
        -fpass-plugin=${INST_PLUGIN}
    )
    target_link_options(intern_${_flavour}_test PRIVATE -fgpu-rdc)
    add_dependencies(intern_${_flavour}_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)
endforeach()
set_source_files_properties(intern_linkage_test.cpp PROPERTIES LANGUAGE HIP)

# Block filter test kernel
add_executable(block_filter_test block_filter_test.cpp)
set_source_files_properties(block_filter_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(block_filter_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(block_filter_test PRIVATE -fgpu-rdc)
add_dependencies(block_filter_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Dynamic LDS test kernel - uses extern __shared__ with dynamicSharedMemoryBytes
# at launch to verify that instrumented dispatches preserve the dynamic portion
# of group_segment_size.
add_executable(dynamic_lds_test dynamic_lds_test.cpp)
set_source_files_properties(dynamic_lds_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(dynamic_lds_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(dynamic_lds_test PRIVATE -fgpu-rdc)
add_dependencies(dynamic_lds_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

# Module-load test: kernel compiled to standalone .hsaco, loaded via hipModuleLoad at runtime.
# This exercises the code path where instrumented kernels live in a dynamically-loaded code
# object rather than being embedded in the executable's .hip_fatbin section.
# One .hsaco per architecture (raw ELF, not a bundle) — the test script picks the right one
# based on the GPU architecture detected at runtime.

set(MODULE_LOAD_HSACO_OUTPUTS "")
foreach(ARCH IN LISTS CMAKE_HIP_ARCHITECTURES)
    set(HSACO_FILE "${CMAKE_CURRENT_BINARY_DIR}/module_load_kernel_${ARCH}.hsaco")
    add_custom_command(
        OUTPUT ${HSACO_FILE}
        COMMAND ${CMAKE_HIP_COMPILER}
            -x hip
            --offload-device-only
            --no-gpu-bundle-output
            --offload-arch=${ARCH}
            -fpass-plugin=${INST_PLUGIN}
            -Werror
            -Wno-error=unused-parameter
            -o ${HSACO_FILE}
            ${CMAKE_CURRENT_SOURCE_DIR}/module_load_kernel.hip
        DEPENDS
            ${CMAKE_CURRENT_SOURCE_DIR}/module_load_kernel.hip
            copy_bitcode
            AMDGCNSubmitAddressMessages-rocm
        COMMENT "Compiling module_load_kernel.hip → ${ARCH} .hsaco with instrumentation"
    )
    list(APPEND MODULE_LOAD_HSACO_OUTPUTS ${HSACO_FILE})
endforeach()
add_custom_target(module_load_kernel_hsaco ALL DEPENDS ${MODULE_LOAD_HSACO_OUTPUTS})

# Host program: uses hipModuleLoad to load the .hsaco at runtime.
# No -fgpu-rdc, no instrumentation plugin — this is a plain HIP host-only program.
add_executable(module_load_test module_load_test.cpp)
set_source_files_properties(module_load_test.cpp PROPERTIES LANGUAGE HIP)
target_link_libraries(module_load_test PRIVATE amdhip64)
add_dependencies(module_load_test module_load_kernel_hsaco)

