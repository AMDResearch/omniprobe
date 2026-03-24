################################################################################
# Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
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

# GoogleTest integration tests - disabled for now, will revisit later for unit tests
# find_package(GTest REQUIRED)

# GoogleTest integration tests disabled - keeping for later unit test work
# # Find libdwarf headers (needed by kernelDB)
# find_path(LIBDWARF_INCLUDE_DIR
#     NAMES libdwarf.h dwarf.h
#     HINTS ${CMAKE_INCLUDE_PATH}
#     PATHS
#         ${CMAKE_INCLUDE_PATH}
#         /usr/include/libdwarf-0
#         /usr/include/libdwarf
#         /usr/local/include/libdwarf-0
#         /usr/local/include/libdwarf
#     DOC "Path to libdwarf header files")
#
# set(HANDLER_TEST_NAME "handler_integration_test")
#
# add_executable(${HANDLER_TEST_NAME}
#     handler_integration_test.cc
# )
#
# set_source_files_properties(handler_integration_test.cc PROPERTIES LANGUAGE HIP)
#
# target_include_directories(${HANDLER_TEST_NAME}
#     PRIVATE
#     ${ROOT_DIR}
#     ${ROOT_DIR}/inc
#     ${LIB_DIR}
#     ${DH_COMMS_INCLUDE_DIR}
#     ${ROCM_ROOT_DIR}/include
#     ${HSA_RUNTIME_INC_PATH}
#     ${CMAKE_INSTALL_PREFIX}/include
#     ${LIBDWARF_INCLUDE_DIR}
# )
#
# target_link_libraries(${HANDLER_TEST_NAME}
#     PRIVATE
#     GTest::gtest
#     GTest::gtest_main
#     ${DH_COMMS_LIBRARIES}/libdh_comms.so
#     logDuration64
#     hip::host
# )
#
# target_link_options(${HANDLER_TEST_NAME}
#     PRIVATE
#     -fgpu-rdc
# )
#
# # Register with CTest
# add_test(NAME HandlerIntegrationTest COMMAND ${HANDLER_TEST_NAME})
#
# # Set test properties
# set_tests_properties(HandlerIntegrationTest PROPERTIES
#     LABELS "integration;handlers"
#     TIMEOUT 120
# )

##############################################################################
# End-to-end tests via omniprobe
##############################################################################

# Build simple test kernels
add_subdirectory(test_kernels)
