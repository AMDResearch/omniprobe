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

set(LOGGER_PLUGIN_NAME  "LogMessages64")
set(MEM_ANALYSIS_PLUGIN_NAME  "MemAnalysis64")

set ( PLUGIN_LIB "${DEFAULT_PLUGIN_NAME}" )

set ( DEFAULT_PLUGIN_SRC
  ${LIB_DIR}/memory_heatmap_wrapper.cc
  ${LIB_DIR}/time_interval_handler_wrapper.cc
  ${PLUGIN_DIR}/plugin.cc
)

set (LOGGER_PLUGIN_SRC
  ${LIB_DIR}/message_logger.cc
  ${PLUGIN_DIR}/logger_plugin.cc
)

set(MEM_ANALYSIS_SRC
  ${LIB_DIR}/memory_analysis_wrapper.cc
  ${PLUGIN_DIR}/memory_analysis_plugin.cc
)

include_directories(${CMAKE_CURRENT_BINARY_DIR})

link_directories(${ROCM_ROOT_DIR}/lib $ENV{HOME}/.local/lib64 ${CMAKE_INSTALL_PREFIX}/lib)
add_library ( ${DEFAULT_PLUGIN_NAME} SHARED ${DEFAULT_PLUGIN_SRC})
add_library ( ${LOGGER_PLUGIN_NAME} SHARED ${LOGGER_PLUGIN_SRC})
add_library ( ${MEM_ANALYSIS_PLUGIN_NAME} SHARED ${MEM_ANALYSIS_SRC})

target_include_directories (
    ${DEFAULT_PLUGIN_NAME}
  PRIVATE
    ${LIB_DIR}
    ${CMAKE_INSTALL_PREFIX}/include
    ${ROCM_ROOT_DIR}/include
    ${ROOT_DIR}
    ${HSA_RUNTIME_INC_PATH}
    ${HSA_KMT_LIB_PATH}/..
    ${DH_COMMS_INCLUDE_DIR}
    ${Python_INCLUDE_DIRS}
)

target_include_directories (
    ${LOGGER_PLUGIN_NAME}
  PRIVATE
    ${LIB_DIR}
    ${CMAKE_INSTALL_PREFIX}/include
    ${ROCM_ROOT_DIR}/include
    ${ROOT_DIR}
    ${HSA_RUNTIME_INC_PATH}
    ${HSA_KMT_LIB_PATH}/..
    ${DH_COMMS_INCLUDE_DIR}
    ${Python_INCLUDE_DIRS}
)

target_include_directories (
    ${MEM_ANALYSIS_PLUGIN_NAME}
  PRIVATE
    ${LIB_DIR}
    ${CMAKE_INSTALL_PREFIX}/include
    ${ROCM_ROOT_DIR}/include
    ${ROOT_DIR}
    ${HSA_RUNTIME_INC_PATH}
    ${HSA_KMT_LIB_PATH}/..
    ${DH_COMMS_INCLUDE_DIR}
    ${Python_INCLUDE_DIRS}
)

target_link_libraries(
    ${LOGGER_PLUGIN_NAME}
  PRIVATE
    ${HSA_RUNTIME_LIB}
    c
    stdc++
    stdc++fs
    ${DH_COMMS_LIBRARIES}/libdh_comms.so
    kernelDB64
)

target_link_libraries(
    ${DEFAULT_PLUGIN_NAME}
  PRIVATE
    ${HSA_RUNTIME_LIB}
    c
    stdc++
    stdc++fs
    ${DH_COMMS_LIBRARIES}/libdh_comms.so
    kernelDB64
)

target_link_libraries(
    ${MEM_ANALYSIS_PLUGIN_NAME}
  PRIVATE
    ${HSA_RUNTIME_LIB}
    c
    stdc++
    stdc++fs
    ${DH_COMMS_LIBRARIES}/libdh_comms.so
    kernelDB64
)



