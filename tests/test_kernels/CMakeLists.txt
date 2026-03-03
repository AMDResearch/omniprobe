################################################################################
# Test kernels for end-to-end omniprobe testing
################################################################################

# Simple heatmap test kernel
add_executable(simple_heatmap_test simple_heatmap_test.cpp)
set_source_files_properties(simple_heatmap_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_heatmap_test PRIVATE -fgpu-rdc)
target_link_options(simple_heatmap_test PRIVATE -fgpu-rdc)

# Simple memory analysis test kernel
add_executable(simple_memory_analysis_test simple_memory_analysis_test.cpp)
set_source_files_properties(simple_memory_analysis_test.cpp PROPERTIES LANGUAGE HIP)
target_compile_options(simple_memory_analysis_test PRIVATE -fgpu-rdc)
target_link_options(simple_memory_analysis_test PRIVATE -fgpu-rdc)

# Install test kernels to build directory for testing
install(TARGETS simple_heatmap_test simple_memory_analysis_test
    RUNTIME DESTINATION ${CMAKE_CURRENT_BINARY_DIR}
)
