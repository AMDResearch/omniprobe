################################################################################
# Library Filter Chain Test
# Tests library include/exclude filtering with linked and dlopen'd libraries
################################################################################

cmake_minimum_required(VERSION 3.21)
project(library_filter_chain_test LANGUAGES CXX HIP)

# Find HIP
find_package(hip REQUIRED)

# Common compile options for HIP code
set(HIP_COMPILE_FLAGS
    -fgpu-rdc
    -Werror
    -Wno-error=unused-parameter
)

# Optional: instrumentation plugin path (set externally for instrumented builds)
# Example: cmake -DINST_PLUGIN=/path/to/libAMDGCNSubmitAddressMessages-rocm.so ..
if(INST_PLUGIN)
    message(STATUS "Building with instrumentation: ${INST_PLUGIN}")
    list(APPEND HIP_COMPILE_FLAGS -fpass-plugin=${INST_PLUGIN})
endif()

################################################################################
# Static library chain: tail -> mid -> head
# These are linked at compile time
################################################################################

# lib_static_tail (no dependencies)
add_library(static_tail SHARED lib_static_tail.hip)
set_source_files_properties(lib_static_tail.hip PROPERTIES LANGUAGE HIP)
target_compile_options(static_tail PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(static_tail PRIVATE -fgpu-rdc)
target_include_directories(static_tail PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# lib_static_mid (depends on tail)
add_library(static_mid SHARED lib_static_mid.hip)
set_source_files_properties(lib_static_mid.hip PROPERTIES LANGUAGE HIP)
target_compile_options(static_mid PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(static_mid PRIVATE -fgpu-rdc)
target_include_directories(static_mid PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(static_mid PUBLIC static_tail)

# lib_static_head (depends on mid, which depends on tail)
add_library(static_head SHARED lib_static_head.hip)
set_source_files_properties(lib_static_head.hip PROPERTIES LANGUAGE HIP)
target_compile_options(static_head PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(static_head PRIVATE -fgpu-rdc)
target_include_directories(static_head PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(static_head PUBLIC static_mid)

################################################################################
# Dynamic library chain: tail -> mid -> head
# These are loaded via dlopen at runtime
################################################################################

# lib_dynamic_tail (no dependencies)
add_library(dynamic_tail SHARED lib_dynamic_tail.hip)
set_source_files_properties(lib_dynamic_tail.hip PROPERTIES LANGUAGE HIP)
target_compile_options(dynamic_tail PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(dynamic_tail PRIVATE -fgpu-rdc)
target_include_directories(dynamic_tail PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# lib_dynamic_mid (depends on tail)
add_library(dynamic_mid SHARED lib_dynamic_mid.hip)
set_source_files_properties(lib_dynamic_mid.hip PROPERTIES LANGUAGE HIP)
target_compile_options(dynamic_mid PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(dynamic_mid PRIVATE -fgpu-rdc)
target_include_directories(dynamic_mid PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(dynamic_mid PUBLIC dynamic_tail)

# lib_dynamic_head (depends on mid, which depends on tail)
add_library(dynamic_head SHARED lib_dynamic_head.hip)
set_source_files_properties(lib_dynamic_head.hip PROPERTIES LANGUAGE HIP)
target_compile_options(dynamic_head PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(dynamic_head PRIVATE -fgpu-rdc)
target_include_directories(dynamic_head PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(dynamic_head PUBLIC dynamic_mid)

################################################################################
# Main test application
################################################################################

add_executable(library_filter_chain_app app.cpp)
set_source_files_properties(app.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(library_filter_chain_app PRIVATE ${HIP_COMPILE_FLAGS})
target_link_options(library_filter_chain_app PRIVATE -fgpu-rdc)
target_include_directories(library_filter_chain_app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Link against static library chain (head pulls in mid and tail)
target_link_libraries(library_filter_chain_app PRIVATE static_head)

# Need dl for dlopen
target_link_libraries(library_filter_chain_app PRIVATE ${CMAKE_DL_LIBS})

# Note: dynamic_head is NOT linked - it's loaded via dlopen at runtime
# The app needs LIB_DYNAMIC_HEAD_PATH environment variable set to find it

################################################################################
# Convenience target to build everything
################################################################################

add_custom_target(library_filter_chain_all
    DEPENDS
        library_filter_chain_app
        static_head static_mid static_tail
        dynamic_head dynamic_mid dynamic_tail
)
