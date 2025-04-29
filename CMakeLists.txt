################################################################################
# Copyright (c) 2022 Advanced Micro Devices, Inc. All rights reserved.
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

cmake_minimum_required(VERSION 3.15 FATAL_ERROR)

# Install prefix
set(CMAKE_INSTALL_PREFIX "/" CACHE PATH "Install path prefix default")

# Verbose output.
set(CMAKE_VERBOSE_MAKEFILE TRUE CACHE BOOL "Verbose Output" FORCE)

# Adding default path cmake modules
list(INSERT CMAKE_MODULE_PATH 0 "${CMAKE_CURRENT_SOURCE_DIR}/cmake_modules")

set(CMAKE_CXX_FLAGS_DEBUG_INIT "-ggdb")

# Ensure that lib files are installed in the correct directory for both Ubuntu and RHEL flavors
set(CMAKE_INSTALL_LIBDIR lib CACHE PATH "Output directory for libraries")

include(utils)

get_version("1.0.0")

if(DEFINED ENV{ROCM_PATH})
    set(ROCM_PATH $ENV{ROCM_PATH})
else()
    # Set a default value if ROCM_PATH is not set
    set(ROCM_PATH "/opt/rocm")
endif()

message("ROCM_PATH: ${ROCM_PATH}")

set(clang "${ROCM_PATH}/llvm/bin/clang")

find_program(
    HIPCC_EXECUTABLE
    #NAMES g++
    NAMES hipcc
    HINTS ${CMAKE_INSTALL_PREFIX}
    PATHS ${CMAKE_INSTALL_PREFIX}
    PATH_SUFFIXES bin)

set(CMAKE_CXX_COMPILER
    ${HIPCC_EXECUTABLE}
    CACHE FILEPATH "C++ compiler" FORCE)

# Set module name and project name.
set(INTERCEPTOR_NAME "logDuration")
set(INTERCEPTOR_TARGET "logDuration64")
set(INTERCEPTOR_LIBRARY "lib${INTERCEPTOR_TARGET}")
set(STRESSTEST_NAME "stresstest")

project(
    ${INTERCEPTOR_NAME}
    LANGUAGES CXX HIP
    VERSION ${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}
    DESCRIPTION "Log Kernel Duration"
    HOMEPAGE_URL "https://github.com/AARInternal/logduration")

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if("${CMAKE_PROJECT_NAME}" STREQUAL "${PROJECT_NAME}")
    set(INTERCEPTOR_TOPLEVEL_PROJECT ON)
else()
    set(INTERCEPTOR_TOPLEVEL_PROJECT OFF)
endif()

find_package(hip REQUIRED)

if(INTERCEPTOR_TOPLEVEL_PROJECT)
    set(CMAKE_CXX_STANDARD
        20
        CACHE STRING "Description")
    option(CMAKE_CXX_STANDARD_REQUIRED "C++ required standard" ON)
    option(CMAKE_CXX_EXTENSIONS "C++ extensions" ON)
else()
    set(CMAKE_CXX_STANDARD 20)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_CXX_EXTENSIONS OFF)
endif()

# Generate a configuration file
if(DEFINED TRITON_LLVM)
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/runtime_config.txt "triton_llvm=true\n")
else()
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/runtime_config.txt "triton_llvm=false\n")
endif()
file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/runtime_config.txt "build_dir=${CMAKE_BINARY_DIR}\n")
file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/runtime_config.txt "install_dir=${CMAKE_INSTALL_PREFIX}\n")

# Set build environment
include ( env )

set(BUILD_VERSION_MAJOR ${VERSION_MAJOR})
set(BUILD_VERSION_MINOR ${VERSION_MINOR})
set(BUILD_VERSION_PATCH ${VERSION_PATCH})
if(DEFINED VERSION_BUILD AND NOT ${VERSION_BUILD} STREQUAL "")
  message("VERSION BUILD DEFINED ${VERSION_BUILD}")
  set(BUILD_VERSION_PATCH "${BUILD_VERSION_PATCH}-${VERSION_BUILD}")
endif()
set(BUILD_VERSION_STRING "${BUILD_VERSION_MAJOR}.${BUILD_VERSION_MINOR}.${BUILD_VERSION_PATCH}")

set(LIB_VERSION_MAJOR ${VERSION_MAJOR})
set(LIB_VERSION_MINOR ${VERSION_MINOR})
if(${ROCM_PATCH_VERSION})
    set(LIB_VERSION_PATCH ${ROCM_PATCH_VERSION})
else()
    set(LIB_VERSION_PATCH ${VERSION_PATCH})
endif()
set(LIB_VERSION_STRING "${LIB_VERSION_MAJOR}.${LIB_VERSION_MINOR}.${LIB_VERSION_PATCH}")
message("-- LIB-VERSION STRING: ${LIB_VERSION_STRING}")

# Build subprojects
include(ext_proj_add)

ext_proj_add(
    NAME kerneldb
    INCLUDE_DIRS
)
ext_proj_add(
    NAME dh_comms
    INCLUDE_DIRS
)
ext_proj_add(
    NAME instrument-amdgpu-kernels
    C_COMPILER ${ROCM_PATH}/llvm/bin/clang
    CXX_COMPILER ${ROCM_PATH}/llvm/bin/clang++
    BINARY_SUFFIX "-rocm"
)

if(DEFINED TRITON_LLVM)
    set(LLVM_INSTALL_DIR ${TRITON_LLVM})
endif()
ext_proj_add(
    NAME instrument-amdgpu-kernels
    C_COMPILER ${ROCM_PATH}/llvm/bin/clang
    CXX_COMPILER ${ROCM_PATH}/llvm/bin/clang++
    BINARY_SUFFIX "-triton"
)

# Set target and root/lib/test directory
set(TARGET_NAME "${INTERCEPTOR_TARGET}")
set(DEFAULT_PLUGIN_NAME "defaultMessageHandlers64")
set(DEFAULT_PLUGIN_LIB "lib${DEFAULT_PLUGIN_NAME}")
set(ROOT_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(LIB_DIR "${ROOT_DIR}/src")
set(TEST_DIR "${ROOT_DIR}/test_code")
set(PLUGIN_DIR "${ROOT_DIR}/plugins")

# Enable tracing API
if (NOT USE_PROF_API)
  set(USE_PROF_API 1)
endif()

# Build libraries
include(${LIB_DIR}/CMakeLists.txt)
include(${PLUGIN_DIR}/CMakeLists.txt)
#include(${TEST_DIR}/CMakeLists.txt)

# Set the VERSION and SOVERSION values
set_property(TARGET ${TARGET_NAME} PROPERTY VERSION "${LIB_VERSION_STRING}")
set_property(TARGET ${TARGET_NAME} PROPERTY SOVERSION "${LIB_VERSION_MAJOR}")
# If the library is a release, strip the target library
if("${CMAKE_BUILD_TYPE}" STREQUAL release)
  add_custom_command(TARGET ${INTERCEPTOR_TARGET} POST_BUILD COMMAND ${CMAKE_STRIP} *.so)
endif()

# Build tests
option(INTERCEPTOR_BUILD_TESTING "Build test examples" OFF)
if(INTERCEPTOR_BUILD_TESTING)
    include(CTest)
    enable_testing()
    add_subdirectory(examples)
    add_subdirectory(test)
endif()

# Installation and packaging
set(DEST_NAME ${INTERCEPTOR_NAME})
if(DEFINED CPACK_PACKAGING_INSTALL_PREFIX)
  get_filename_component(pkg_name ${CPACK_PACKAGING_INSTALL_PREFIX} NAME)
  get_filename_component(pkg_dir ${CPACK_PACKAGING_INSTALL_PREFIX} DIRECTORY)
  if(pkg_name STREQUAL ${DEST_NAME})
    set(CPACK_PACKAGING_INSTALL_PREFIX ${pkg_dir})
  endif()
else()
  set(CPACK_PACKAGING_INSTALL_PREFIX ${CMAKE_INSTALL_PREFIX})
endif()
message("CMake-install-prefix: ${CMAKE_INSTALL_PREFIX}")
message("CPack-install-prefix: ${CPACK_PACKAGING_INSTALL_PREFIX}")
message("-----------Dest-name: ${DEST_NAME}")

# Install header and library
install(TARGETS ${INTERCEPTOR_TARGET} LIBRARY DESTINATION lib/${DEST_NAME})
install(PROGRAMS ${ROOT_DIR}/omniprobe/omniprobe DESTINATION bin/${DEST_NAME})
install(DIRECTORY ${ROOT_DIR}/omniprobe/config DESTINATION bin/${DEST_NAME} FILES_MATCHING PATTERN "*")
install(FILES "${CMAKE_BINARY_DIR}/runtime_config.txt" DESTINATION bin/${DEST_NAME})

# Packaging directives
set(CPACK_GENERATOR "DEB" "RPM" "TGZ")
set(CPACK_PACKAGE_NAME "${INTERCEPTOR_NAME}-dev")
set(CPACK_PACKAGE_VENDOR "AMD" )
set(CPACK_PACKAGE_VERSION_MAJOR ${BUILD_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${BUILD_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${BUILD_VERSION_PATCH})
set(CPACK_PACKAGE_CONTACT "Advanced Micro Devices Inc.")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Log all HSA kernel durations")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")

# Debian package specific variables
set(CPACK_DEBIAN_PACKAGE_DEPENDS "hsa-rocr-dev, rocminfo")
set(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA "${CMAKE_CURRENT_SOURCE_DIR}/DEBIAN/postinst;${CMAKE_CURRENT_SOURCE_DIR}/DEBIAN/prerm")

# RPM package specific variables
set(CPACK_RPM_PACKAGE_DEPENDS "hsa-rocr-dev, rocminfo")
set(CPACK_RPM_POST_INSTALL_SCRIPT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/RPM/rpm_post")
set(CPACK_RPM_POST_UNINSTALL_SCRIPT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/RPM/rpm_postun")

include(CPack)
