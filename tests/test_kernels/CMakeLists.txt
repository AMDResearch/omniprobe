################################################################################
# Test kernels for end-to-end omniprobe testing
################################################################################

# Compiler flags for test kernels: treat warnings as errors
set(TEST_KERNEL_COMPILE_FLAGS
    -fgpu-rdc
    -Werror                         # Treat all warnings as errors
    -Wno-error=unused-parameter     # Allow unused parameters (common in kernels)
)

# Path to instrumentation plugin in build directory
set(INST_PLUGIN "${CMAKE_BINARY_DIR}/external/instrument-amdgpu-kernels-rocm/build/lib/libAMDGCNSubmitAddressMessages-rocm.so")

# Copy bitcode files from dh_comms to plugin directories for build-tree testing.
# The plugin expects bitcode files to be in the same directory as the .so file.
# ROCm uses co6 (code object version 6), Triton uses co5.
set(ROCM_PLUGIN_LIB_DIR "${CMAKE_BINARY_DIR}/external/instrument-amdgpu-kernels-rocm/build/lib")
set(DH_COMMS_LIB_DIR "${CMAKE_BINARY_DIR}/external/dh_comms/lib")

# Copy co6 bitcode files to rocm plugin directory
add_custom_target(copy_bitcode_to_rocm ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ROCM_PLUGIN_LIB_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna2_co6.bc
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna3_co6.bc
        ${ROCM_PLUGIN_LIB_DIR}/
    DEPENDS dh_comms_bc instrument-amdgpu-kernels-rocm
    COMMENT "Copying co6 bitcode files to ROCm plugin directory"
)

# Copy co5 bitcode files to triton plugin directory (if triton build is enabled)
if(DEFINED TRITON_LLVM)
    set(TRITON_PLUGIN_LIB_DIR "${CMAKE_BINARY_DIR}/external/instrument-amdgpu-kernels-triton/build/lib")
    add_custom_target(copy_bitcode_to_triton ALL
        COMMAND ${CMAKE_COMMAND} -E make_directory ${TRITON_PLUGIN_LIB_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna2_co5.bc
            ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna3_co5.bc
            ${TRITON_PLUGIN_LIB_DIR}/
        DEPENDS dh_comms_bc instrument-amdgpu-kernels-triton
        COMMENT "Copying co5 bitcode files to Triton plugin directory"
    )
endif()

# Simple heatmap test kernel
add_executable(simple_heatmap_test simple_heatmap_test.cpp)
set_source_files_properties(simple_heatmap_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_heatmap_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(simple_heatmap_test PRIVATE -fgpu-rdc)
add_dependencies(simple_heatmap_test copy_bitcode_to_rocm)

# Simple memory analysis test kernel
add_executable(simple_memory_analysis_test simple_memory_analysis_test.cpp)
set_source_files_properties(simple_memory_analysis_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_memory_analysis_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(simple_memory_analysis_test PRIVATE -fgpu-rdc)
add_dependencies(simple_memory_analysis_test copy_bitcode_to_rocm)

# Dual kernel test - dispatches two kernels to test scanning frequency
add_executable(dual_kernel_test dual_kernel_test.cpp)
set_source_files_properties(dual_kernel_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(dual_kernel_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(dual_kernel_test PRIVATE -fgpu-rdc)
add_dependencies(dual_kernel_test copy_bitcode_to_rocm)

# Block filter test kernel
add_executable(block_filter_test block_filter_test.cpp)
set_source_files_properties(block_filter_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(block_filter_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(block_filter_test PRIVATE -fgpu-rdc)
add_dependencies(block_filter_test copy_bitcode_to_rocm)

# Sub-8B argument test kernel (regression test for issue:
# "Error with sub-8B kernel arguments").  A kernel whose explicit argument list
# ends at a non-8-byte-aligned offset (pointer args + int args) used to trigger
# an assertion in fixupKernArgs due to incorrect explicit_args_length rounding.
add_executable(sub8b_args_test sub8b_args_test.cpp)
set_source_files_properties(sub8b_args_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(sub8b_args_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(sub8b_args_test PRIVATE -fgpu-rdc)
add_dependencies(sub8b_args_test copy_bitcode_to_rocm)

