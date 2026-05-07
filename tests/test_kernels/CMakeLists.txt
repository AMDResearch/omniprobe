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

# Copy bitcode files from dh_comms to build/lib/bitcode/ and to plugin dirs.
# build/lib/bitcode/ is the canonical location; plugin dirs are for backward
# compatibility with getBitcodePath() until it is updated to look in ../bitcode/.
set(DH_COMMS_LIB_DIR "${CMAKE_BINARY_DIR}/external/dh_comms/lib")
set(BITCODE_DIR "${CMAKE_BINARY_DIR}/lib/bitcode")

# Build the list of bitcode files to copy (must mirror dh_comms/CMakeLists.txt)
set(BITCODE_COPY_FILES
    ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna2_co5.bc
    ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna2_co6.bc
    ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna3_co5.bc
    ${DH_COMMS_LIB_DIR}/dh_comms_dev_cdna3_co6.bc
)
foreach(ARCH IN LISTS CMAKE_HIP_ARCHITECTURES)
    # Strip arch features such as ":xnack+" so the resulting filename
    # (e.g. dh_comms_dev_gfx908_co5.bc) matches what dh_comms emits.
    string(REGEX REPLACE ":.*$" "" ARCH_BASE "${ARCH}")
    list(APPEND BITCODE_COPY_FILES
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_${ARCH_BASE}_co5.bc
        ${DH_COMMS_LIB_DIR}/dh_comms_dev_${ARCH_BASE}_co6.bc
    )
endforeach()
list(REMOVE_DUPLICATES BITCODE_COPY_FILES)

# Copy all bitcode files to build/lib/bitcode/
add_custom_target(copy_bitcode ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory ${BITCODE_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${BITCODE_COPY_FILES}
        ${BITCODE_DIR}/
    DEPENDS dh_comms_bc
    COMMENT "Copying bitcode files to build/lib/bitcode/"
)

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

# Block filter test kernel
add_executable(block_filter_test block_filter_test.cpp)
set_source_files_properties(block_filter_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(block_filter_test PRIVATE
    ${TEST_KERNEL_COMPILE_FLAGS}
    -fpass-plugin=${INST_PLUGIN}
)
target_link_options(block_filter_test PRIVATE -fgpu-rdc)
add_dependencies(block_filter_test copy_bitcode AMDGCNSubmitAddressMessages-rocm)

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

