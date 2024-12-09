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
    
    # Add project as a subdirectory. Optionally set the compiler
    if (EXT_PROJ_ADD_C_COMPILER AND EXT_PROJ_ADD_CXX_COMPILER)
        execute_process(
            COMMAND cmake
            ARGS -DCMAKE_C_COMPILER=${EXT_PROJ_ADD_C_COMPILER} -DCMAKE_CXX_COMPILER=${EXT_PROJ_ADD_CXX_COMPILER}
            ${EXTERNAL_PROJ_DIR}
        )
        add_subdirectory(${EXTERNAL_PROJ_DIR} EXCLUDE_FROM_ALL)
    else()
        add_subdirectory(${EXTERNAL_PROJ_DIR})
    endif()
    
    # Track include and lib directories
    set("${EXT_PROJ_ADD_NAME}_INCLUDE_DIRS" ${EXTERNAL_PROJ_DIR}/include PARENT_SCOPE)
    set("${EXT_PROJ_ADD_NAME}_LIBRARIES"  ${CMAKE_CURRENT_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}/lib PARENT_SCOPE)
    
endfunction()