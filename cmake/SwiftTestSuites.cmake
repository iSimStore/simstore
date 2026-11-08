function(add_swift_test_suite name target)
    cmake_parse_arguments(SUITE "RUN_SERIAL;NO_DISCOVERY" "TIMEOUT" "ARGS" ${ARGN})
    if(NOT SUITE_TIMEOUT)
        message(FATAL_ERROR "${name} requires a per-case TIMEOUT")
    endif()
    target_sources(${target} PRIVATE "${PROJECT_SOURCE_DIR}/tests/TestSuite.swift")
    set(marker "${CMAKE_CURRENT_BINARY_DIR}/${target}.discovery-ready")
    # Older binaries must not execute their entire suite during --list-tests discovery.
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E touch "${marker}"
        VERBATIM
    )
    set(extra_arguments)
    foreach(argument IN LISTS SUITE_ARGS)
        string(APPEND extra_arguments " [==[${argument}]==]")
    endforeach()
    set(include_file "${CMAKE_CURRENT_BINARY_DIR}/${target}_cases.cmake")
    file(GENERATE OUTPUT "${include_file}" CONTENT
"set(SWIFT_TEST_CMAKE_COMMAND [==[${CMAKE_COMMAND}]==])
include([==[${PROJECT_SOURCE_DIR}/cmake/DiscoverSwiftTests.cmake]==])
discover_swift_tests([==[$<TARGET_FILE:${target}>]==] [==[${marker}]==]
    [==[${name}]==] ${SUITE_TIMEOUT} [==[${SUITE_RUN_SERIAL}]==]
    [==[${CMAKE_CURRENT_BINARY_DIR}]==]${extra_arguments})
")
    if(NOT SUITE_NO_DISCOVERY)
        set_property(DIRECTORY APPEND PROPERTY TEST_INCLUDE_FILES "${include_file}")
    endif()
endfunction()
