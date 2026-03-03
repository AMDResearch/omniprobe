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

# Copy bitcode files from dh_comms to plugin directory for build-tree testing
# The plugin expects bitcode files to be in the same directory as the .so file
set(PLUGIN_LIB_DIR "${CMAKE_BINARY_DIR}/external/instrument-amdgpu-kernels-rocm/build/lib")
set(DH_COMMS_LIB_DIR "${CMAKE_BINARY_DIR}/external/dh_comms/lib")

# Copy bitcode files at configure time and add dependencies to ensure they're built first
file(GLOB BC_FILES "${DH_COMMS_LIB_DIR}/*.bc")
if(BC_FILES)
    file(COPY ${BC_FILES} DESTINATION ${PLUGIN_LIB_DIR})
endif()

# Add custom command to copy bitcode files when they're rebuilt
add_custom_target(copy_bitcode_files ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory ${PLUGIN_LIB_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna2_co5.bc
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna2_co6.bc
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna3_co5.bc
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna3_co6.bc
        ${PLUGIN_LIB_DIR}/
    DEPENDS dh_comms_bc instrument-amdgpu-kernels-rocm
    COMMENT "Copying dh_comms bitcode files to instrumentation plugin directory"
)

# Simple heatmap test kernel
add_executable(simple_heatmap_test simple_heatmap_test.cpp)
set_source_files_properties(simple_heatmap_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_heatmap_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(simple_heatmap_test PRIVATE -fgpu-rdc)
add_dependencies(simple_heatmap_test copy_bitcode_files)

# Simple memory analysis test kernel
add_executable(simple_memory_analysis_test simple_memory_analysis_test.cpp)
set_source_files_properties(simple_memory_analysis_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_memory_analysis_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(simple_memory_analysis_test PRIVATE -fgpu-rdc)
add_dependencies(simple_memory_analysis_test copy_bitcode_files)

