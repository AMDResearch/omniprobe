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

include(FetchContent)

function(fetch_project)
  cmake_parse_arguments(FETCH_SOURCE
    "INCLUDE_DIRS;EXCLUDE_EXAMPLES"   # options
    "NAME;GIT_REPOSITORY;GIT_TAG" # single-arg options
    ""             # multi-arg options
    ${ARGN}
  )

  set(SOURCE ${CMAKE_CURRENT_BINARY_DIR}/deps/${FETCH_SOURCE_NAME}/source)
  set(BUILD ${CMAKE_CURRENT_BINARY_DIR}/deps/${FETCH_SOURCE_NAME}/build)
  set(SUBBUILD ${CMAKE_CURRENT_BINARY_DIR}/deps/${FETCH_SOURCE_NAME}/subbuild)

#   FetchContent_Populate(${FETCH_SOURCE_NAME}
#     URL ${FETCH_SOURCE_URL}
#     DOWNLOAD_DIR ${CMAKE_SOURCE_DIR}/.anari_deps/${FETCH_SOURCE_NAME}
#     ${FETCH_SOURCE_MD5_COMMAND}
#     SOURCE_DIR ${SOURCE}
#   )

  if(FETCH_SOURCE_EXCLUDE_EXAMPLES)
    set(FETCH_SOURCE_EXCLUDE_EXAMPLES ${SOURCE}/examples)
    message(STATUS "Excluding examples from ${FETCH_SOURCE_EXCLUDE_EXAMPLES}")
  endif()

  FetchContent_Declare(${FETCH_SOURCE_NAME}
    GIT_REPOSITORY ${FETCH_SOURCE_GIT_REPOSITORY}
    GIT_TAG ${FETCH_SOURCE_GIT_TAG}
    GIT_SHALLOW ON
    SOURCE_DIR ${SOURCE}
    BINARY_DIR ${BUILD}
    CMAKE_ARGS
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}
      -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
  )
  FetchContent_MakeAvailable(${FETCH_SOURCE_NAME})

  set("${FETCH_SOURCE_NAME}_LOCATION" ${CMAKE_CURRENT_BINARY_DIR}/deps/${FETCH_SOURCE_NAME} PARENT_SCOPE)
  message(STATUS "Fetched ${FETCH_SOURCE_NAME}")

  if (FETCH_SOURCE_INCLUDE_DIRS)
    message(STATUS "Including directory ${SOURCE}")
    target_include_directories(
      ${FETCH_SOURCE_NAME}
      PUBLIC
      ${SOURCE}/include
    )
  endif()
endfunction()
