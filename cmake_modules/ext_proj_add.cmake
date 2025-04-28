include(ExternalProject)

function(ext_proj_add)
    cmake_parse_arguments(EXT_PROJ_ADD 
        "INCLUDE_DIRS" #options
        "NAME;C_COMPILER;CXX_COMPILER;BINARY_SUFFIX" # single-arg options
        "" # multi-arg options
        ${ARGN}
    )
    set (EXTERNAL_PROJ_DIR ${CMAKE_CURRENT_SOURCE_DIR}/external/${EXT_PROJ_ADD_NAME})
    
    # Optionally include the include files
    if (EXT_PROJ_ADD_INCLUDE_DIRS)
        include_directories(${EXTERNAL_PROJ_DIR}/include)
        message(STATUS "Including directory: ${EXTERNAL_PROJ_DIR}/include")
    endif()
    
    # Add project as a subdirectory, optionally set custom compiler
    if (EXT_PROJ_ADD_C_COMPILER AND EXT_PROJ_ADD_CXX_COMPILER)
        # Resolve symlink for LLVM_INSTALL_DIR
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E realpath "${LLVM_INSTALL_DIR}"
            OUTPUT_VARIABLE LLVM_INSTALL_DIR_RESOLVED
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        set(LLVM_INSTALL_DIR "${LLVM_INSTALL_DIR_RESOLVED}")
    
        ExternalProject_Add(
            ${EXT_PROJ_ADD_NAME}${EXT_PROJ_ADD_BINARY_SUFFIX}
            PREFIX ${CMAKE_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}${EXT_PROJ_ADD_BINARY_SUFFIX}
            SOURCE_DIR ${EXTERNAL_PROJ_DIR}
            BINARY_DIR ${CMAKE_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}${EXT_PROJ_ADD_BINARY_SUFFIX}/build
            CMAKE_ARGS -DLLVM_INSTALL_DIR=${LLVM_INSTALL_DIR} -DCMAKE_C_COMPILER=${EXT_PROJ_ADD_C_COMPILER} -DCMAKE_CXX_COMPILER=${EXT_PROJ_ADD_CXX_COMPILER} -DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX}
            BUILD_ALWAYS ON   
        )
    else()
        add_subdirectory(${EXTERNAL_PROJ_DIR})
    endif()
    
    # Track include and lib directories
    string(TOUPPER "${EXT_PROJ_ADD_NAME}" CAPS_NAME)
    set("${CAPS_NAME}_INCLUDE_DIR" ${EXTERNAL_PROJ_DIR}/include PARENT_SCOPE)
    set("${CAPS_NAME}_LIBRARIES"  ${CMAKE_CURRENT_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}/lib PARENT_SCOPE)
    
endfunction()