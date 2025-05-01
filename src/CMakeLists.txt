################################################################################
# Copyright (c) 2018 Advanced Micro Devices, Inc. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
################################################################################
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O0")

set ( TARGET_LIB "${TARGET_NAME}" )
set ( LIB_SRC
  ${LIB_DIR}/interceptor.cc
  ${LIB_DIR}/utils.cc
  ${LIB_DIR}/hsa_mem_mgr.cc
  ${LIB_DIR}/comms_mgr.cc
  ${LIB_DIR}/pyHandler.cc
  ${LIB_DIR}/memory_heatmap_wrapper.cc
  ${LIB_DIR}/time_interval_handler_wrapper.cc
)

set (HEATMAP_EXAMPLE "example_heatmap")

set (TEST_SRC
    ${LIB_DIR}/test/stresstest.cc
)

set (HEATMAP_SRC
    ${LIB_DIR}/test/heatmap_example.cc
)

find_package(Python COMPONENTS Development)

include_directories(${CMAKE_CURRENT_BINARY_DIR})

function(generate_hsaco TARGET_ID INPUT_FILE OUTPUT_FILE)
    separate_arguments(
        CLANG_ARG_LIST
        UNIX_COMMAND
        "-O2 -x cl -Xclang -finclude-default-header -cl-denorms-are-zero -cl-std=CL2.0 -Wl,--build-id=sha1
    -target amdgcn-amd-amdhsa -mcpu=${TARGET_ID} -o ${OUTPUT_FILE} ${INPUT_FILE}")
    message("generate_hsaco: ${PROJECT_BINARY_DIR} ${INPUT_FILE} ${TARGET_ID}")
    add_custom_command(
        OUTPUT ${PROJECT_BINARY_DIR}/test_kernels/${OUTPUT_FILE}
        COMMAND ${clang} ${CLANG_ARG_LIST}
        COMMAND ${CMAKE_COMMAND} -E copy
            ${PROJECT_BINARY_DIR}/test_kernels/${OUTPUT_FILE}
            ${PROJECT_BINARY_DIR}/test_kernels/${target_id}_copy.hsaco
        WORKING_DIRECTORY ${PROJECT_BINARY_DIR}/test_kernels/
        DEPENDS ${INPUT_FILE}
        COMMENT "Building ${OUTPUT_FILE}..."
        VERBATIM)
    set(HSACO_TARGET_LIST
        ${HSACO_TARGET_LIST}
        ${PROJECT_BINARY_DIR}/test_kernels/${OUTPUT_FILE}
        PARENT_SCOPE)
endfunction(generate_hsaco)

set(GPU_LIST "gfx900" "gfx906" "gfx908" "gfx90a" "gfx942" "gfx1030" "gfx1031" "gfx1032" "gfx1100" "gfx1101" "gfx1102")
# Create test_kernels directory if it doesn't exist
file(MAKE_DIRECTORY ${PROJECT_BINARY_DIR}/test_kernels)
# Run generate_hsaco for each target
foreach(target_id ${GPU_LIST})
    # generate kernel bitcodes
    message("${CMAKE_CURRENT_SOURCE_DIR}")
    generate_hsaco(${target_id} ${CMAKE_CURRENT_SOURCE_DIR}/src/test_kernels/copy.cl
                   ${target_id}_copy.hsaco)
    install(
        FILES
            "${PROJECT_BINARY_DIR}/test_kernels/${target_id}_copy.hsaco"
        DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/${PROJECT_NAME}/test_kernels"
        COMPONENT tests)

endforeach(target_id)
message("${HSACO_TARGET_LIST}")
add_custom_target(hsaco_targets DEPENDS ${HSACO_TARGET_LIST})


link_directories(${ROCM_ROOT_DIR}/lib $ENV{HOME}/.local/lib64 ${CMAKE_INSTALL_PREFIX}/lib)
add_library ( ${TARGET_LIB} SHARED ${LIB_SRC})
add_dependencies(${TARGET_LIB} hsaco_targets dh_comms)

target_include_directories (
    ${TARGET_LIB}
  PRIVATE
    ${LIB_DIR}
    ${ROCM_ROOT_DIR}/include
    ${ROOT_DIR}
    ${HSA_RUNTIME_INC_PATH}
    ${HSA_KMT_LIB_PATH}/..
    ${DH_COMMS_INCLUDE_DIR}
    ${CMAKE_INSTALL_PREFIX}/include
    ${Python_INCLUDE_DIRS}
)

target_link_libraries(
    ${TARGET_LIB}
  PRIVATE
    ${HSA_RUNTIME_LIB}
    c
    stdc++
    stdc++fs
    ${DH_COMMS_LIBRARIES}/libdh_comms.so
    kernelDB64
    amd_comgr
)

find_path(LIBDWARF_INCLUDE_DIR
  NAMES libdwarf.h dwarf.h
  HINTS ${CMAKE_INCLUDE_PATH}
  PATHS
    ${CMAKE_INCLUDE_PATH}
    /usr/include/libdwarf-0
    /usr/include/libdwarf
    /usr/local/include/libdwarf-0
    /usr/local/include/libdwarf
  DOC "Path to libdwarf header files")

add_executable(${STRESSTEST_NAME} ${TEST_SRC})

set_source_files_properties(${TEST_SRC} PROPERTIES LANGUAGE HIP)

target_compile_options(${STRESSTEST_NAME} PRIVATE -fgpu-rdc  -Werror -Wall -Wextra)
add_dependencies(${STRESSTEST_NAME} dh_comms)

target_link_libraries(
    ${STRESSTEST_NAME}
  PRIVATE
    ${ROCM_PATH}/lib/libhiprtc.so
    ${DH_COMMS_LIBRARIES}/libdh_comms.so
)

target_include_directories (
    ${STRESSTEST_NAME}
  PRIVATE
    ${LIB_DIR}/test
    ${ROCM_ROOT_DIR}/include
    ${CMAKE_INSTALL_PREFIX}/include
    ${ROOT_DIR}
    ${HSA_RUNTIME_INC_PATH}
    ${DH_COMMS_INCLUDE_DIR}
    ${LIBDWARF_INCLUDE_DIR}
)
target_link_options (
    ${STRESSTEST_NAME}
  PRIVATE
    -fgpu-rdc
)

add_executable(${HEATMAP_EXAMPLE} ${HEATMAP_SRC})

set_source_files_properties(${HEATMAP_SRC} PROPERTIES LANGUAGE HIP)

target_compile_options(${HEATMAP_EXAMPLE} PRIVATE -fgpu-rdc  -Werror -Wall -Wextra)

add_dependencies(${HEATMAP_EXAMPLE} dh_comms)

target_link_libraries(
    ${HEATMAP_EXAMPLE}
  PRIVATE
    ${ROCM_PATH}/lib/libhiprtc.so
    ${DH_COMMS_LIBRARIES}/libdh_comms.so
)

target_include_directories (
    ${HEATMAP_EXAMPLE}
  PRIVATE
    ${LIB_DIR}/test
    ${ROOT_DIR}
    ${ROCM_ROOT_DIR}/include
    ${CMAKE_INSTALL_PREFIX}/include
    ${HSA_RUNTIME_INC_PATH}
    ${DH_COMMS_INCLUDE_DIR}
    ${LIBDWARF_INCLUDE_DIR}
)
target_link_options (
    ${HEATMAP_EXAMPLE}
  PRIVATE
    -fgpu-rdc
)
