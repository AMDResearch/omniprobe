include(ExternalProject)

function(ext_proj_add)
    cmake_parse_arguments(EXT_PROJ_ADD 
        "INCLUDE_DIRS" #options
        "NAME;C_COMPILER;CXX_COMPILER" # single-arg options
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
        ExternalProject_Add(
            ${EXT_PROJ_ADD_NAME}
            PREFIX ${CMAKE_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}
            SOURCE_DIR ${EXTERNAL_PROJ_DIR}
            BINARY_DIR ${CMAKE_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}/build
            CMAKE_ARGS -DLLVM_INSTALL_DIR=${LLVM_INSTALL_DIR} -DCMAKE_C_COMPILER=${EXT_PROJ_ADD_C_COMPILER} -DCMAKE_CXX_COMPILER=${EXT_PROJ_ADD_CXX_COMPILER}
            INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
            BUILD_ALWAYS ON
                
            # Prevent the install step from running automatically  
            STEP_TARGETS build  
            INSTALL_COMMAND ""
        )

        install(DIRECTORY ${CMAKE_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}/build/lib/
                TYPE LIB
                USE_SOURCE_PERMISSIONS
                FILES_MATCHING PATTERN "*.so")
    else()
        add_subdirectory(${EXTERNAL_PROJ_DIR})
    endif()
    
    # Track include and lib directories
    set("${EXT_PROJ_ADD_NAME}_INCLUDE_DIRS" ${EXTERNAL_PROJ_DIR}/include PARENT_SCOPE)
    set("${EXT_PROJ_ADD_NAME}_LIBRARIES"  ${CMAKE_CURRENT_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}/lib PARENT_SCOPE)
    
endfunction()