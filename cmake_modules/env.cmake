################################################################################
# Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.
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

## Build is not supported on Windows plaform
if ( WIN32 )
  message ( FATAL_ERROR "Windows build is not supported." )
endif ()

list(APPEND CMAKE_PREFIX_PATH "/opt/rocm")

## Compiler Preprocessor definitions.
add_definitions ( -D__linux__ )
add_definitions ( -DUNIX_OS )
add_definitions ( -DLINUX )
add_definitions ( -D__AMD64__ )
add_definitions ( -D__x86_64__ )
add_definitions ( -DLITTLEENDIAN_CPU=1 )
add_definitions ( -DHSA_LARGE_MODEL= )
add_definitions ( -DHSA_DEPRECATED= )

## Linux Compiler options
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++2a" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-sometimes-uninitialized" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-braced-scalar-init" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-unused-lambda-capture")
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-unused-function" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-unused-variable" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-switch-bool" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-unused-private-field" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fexceptions" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-math-errno" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-threadsafe-statics" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fmerge-all-constants" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fms-extensions" )
#set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Werror=int-in-bool-context" )
set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC" )

set ( CMAKE_SHARED_LINKER_FLAGS "-Wl,-Bdynamic -Wl,-z,noexecstack" )

####################
# RPATH settings
####################

# use, i.e. don't skip the full RPATH for the build tree
set ( CMAKE_SKIP_BUILD_RPATH FALSE )
# when building, don't use the install RPATH already
# (but later on when installing)
set(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)
set(CMAKE_INSTALL_RPATH "${CMAKE_INSTALL_PREFIX}/lib")

# add the automatically determined parts of the RPATH
# which point to directories outside the build tree to the install RPATH
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)

# the RPATH to be used when installing, but only if it's not a system directory
list(FIND CMAKE_PLATFORM_IMPLICIT_LINK_DIRECTORIES "${CMAKE_INSTALL_PREFIX}/lib" isSystemDir)
if("${isSystemDir}" STREQUAL "-1")
    set(CMAKE_INSTALL_RPATH "${CMAKE_INSTALL_PREFIX}/lib")
endif("${isSystemDir}" STREQUAL "-1")



add_definitions ( -DNEW_TRACE_API=1 )

## CLANG options
if ( "$ENV{CXX}" STREQUAL "/usr/bin/clang++" )
  set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -ferror-limit=1000000" )
endif()

## Enable debug trace
if ( DEFINED ENV{CMAKE_DEBUG_TRACE} )
  add_definitions ( -DDEBUG_TRACE=1 )
endif()

## Enable AQL-profile new API
if ( NOT DEFINED ENV{CMAKE_CURR_API} )
  add_definitions ( -DAQLPROF_NEW_API=1 )
endif()

## Enable direct loading of AQL-profile HSA extension
if ( DEFINED ENV{CMAKE_LD_AQLPROFILE} )
  add_definitions ( -DROCP_LD_AQLPROFILE=1 )
endif()

## Make env vars
if ( NOT DEFINED CMAKE_BUILD_TYPE OR "${CMAKE_BUILD_TYPE}" STREQUAL "" )
  if ( DEFINED ENV{CMAKE_BUILD_TYPE} )
    set ( CMAKE_BUILD_TYPE $ENV{CMAKE_BUILD_TYPE} )
  endif()
endif()
if ( NOT DEFINED CMAKE_PREFIX_PATH AND DEFINED ENV{CMAKE_PREFIX_PATH} )
  set ( CMAKE_PREFIX_PATH $ENV{CMAKE_PREFIX_PATH} )
endif()

## Extend Compiler flags based on build type
string ( TOLOWER "${CMAKE_BUILD_TYPE}" CMAKE_BUILD_TYPE )
if ( "${CMAKE_BUILD_TYPE}" STREQUAL debug )
  set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -ggdb" )
  set ( CMAKE_BUILD_TYPE "debug" )
else ()
  set ( CMAKE_BUILD_TYPE "release" )
endif ()

## Extend Compiler flags based on Processor architecture
if ( ${CMAKE_SYSTEM_PROCESSOR} STREQUAL "x86_64" )
  set ( NBIT 64 )
  set ( NBITSTR "64" )
  set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m64  -msse -msse2" )
elseif ( ${CMAKE_SYSTEM_PROCESSOR} STREQUAL "x86" )
  set ( NBIT 32 )
  set ( NBITSTR "" )
  set ( CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m32" )
endif ()

## Find hsa-runtime headers/lib
find_file ( HSA_RUNTIME_INC "hsa/hsa.h" )
find_library ( HSA_RUNTIME_LIB "libhsa-runtime${NBIT}.so" )
get_filename_component ( HSA_RUNTIME_INC_PATH "${HSA_RUNTIME_INC}" DIRECTORY )
get_filename_component ( HSA_RUNTIME_LIB_PATH "${HSA_RUNTIME_LIB}" DIRECTORY )

#find_library ( HSA_KMT_LIB "libhsakmt.so" )
find_library ( HSA_KMT_LIB "libhsakmt.a" )
get_filename_component ( HSA_KMT_LIB_PATH "${HSA_KMT_LIB}" DIRECTORY )
get_filename_component ( ROCM_ROOT_DIR "${HSA_KMT_LIB_PATH}" DIRECTORY )

find_library ( COMGR_LIB "libamd_comgr.so" )
get_filename_component ( COMGR_LIB_PATH "${COMGR_LIB}" DIRECTORY )


## Basic Tool Chain Information
message ( "----------------NBit: ${NBIT}" )
message ( "----------Build-Type: ${CMAKE_BUILD_TYPE}" )
message ( "------------Compiler: ${CMAKE_CXX_COMPILER}" )
message ( "----Compiler-Version: ${CMAKE_CXX_COMPILER_VERSION}" )
message ( "-----HSA-Runtime-Inc: ${HSA_RUNTIME_INC_PATH}" )
message ( "-----HSA-Runtime-Lib: ${HSA_RUNTIME_LIB_PATH}" )
message ( "----HSA_KMT_LIB_PATH: ${HSA_KMT_LIB_PATH}" )
message ( "----COMGR_LIB_PATH  : ${COMGR_LIB_PATH}" )
message ( "-------ROCM_ROOT_DIR: ${ROCM_ROOT_DIR}" )
message ( "-----CMAKE_CXX_FLAGS: ${CMAKE_CXX_FLAGS}" )
message ( "---CMAKE_PREFIX_PATH: ${CMAKE_PREFIX_PATH}" )
message ( "---------GPU_TARGETS: ${GPU_TARGETS}" )

## Check the ROCm pathes
if ( "${HSA_RUNTIME_INC_PATH}" STREQUAL "" )
  message ( FATAL_ERROR "HSA_RUNTIME_INC_PATH is not found." )
endif ()
if ( "${HSA_RUNTIME_LIB_PATH}" STREQUAL "" )
  message ( FATAL_ERROR "HSA_RUNTIME_LIB_PATH is not found." )
endif ()
if ( "${HSA_KMT_LIB_PATH}" STREQUAL "" )
  message ( FATAL_ERROR "HSA_KMT_LIB_PATH is not found." )
endif ()
if ( "${COMGR_LIB_PATH}" STREQUAL "" )
  message ( FATAL_ERROR "COMGR_LIB_PATH is not found." )
endif ()
if ( "${ROCM_ROOT_DIR}" STREQUAL "" )
  message ( FATAL_ERROR "ROCM_ROOT_DIR is not found." )
endif ()
