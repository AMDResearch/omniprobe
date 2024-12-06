function(ext_proj_add)
    cmake_parse_arguments(EXT_PROJ_ADD 
        "INCLUDE_DIRS" #options
        "NAME" # single-arg options
        "" # multi-arg options
        ${ARGN}
    )
    set (EXTERNAL_PROJ_DIR ${CMAKE_CURRENT_SOURCE_DIR}/external/${EXT_PROJ_ADD_NAME})
    
    if (EXT_PROJ_ADD_INCLUDE_DIRS)
        include_directories(${EXTERNAL_PROJ_DIR}/include)
        message(STATUS "Including directory: ${EXTERNAL_PROJ_DIR}/include")
    endif()
    add_subdirectory(${EXTERNAL_PROJ_DIR})
    set("${EXT_PROJ_ADD_NAME}_INCLUDE_DIRS" ${EXTERNAL_PROJ_DIR}/include PARENT_SCOPE)
    set("${EXT_PROJ_ADD_NAME}_LIBRARIES"  ${CMAKE_CURRENT_BINARY_DIR}/external/${EXT_PROJ_ADD_NAME}/lib PARENT_SCOPE)
    
endfunction()