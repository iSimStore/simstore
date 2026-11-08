function(discover_swift_tests executable marker prefix timeout serial working_directory)
    if(NOT EXISTS "${executable}" OR NOT EXISTS "${marker}" OR
       NOT "${marker}" IS_NEWER_THAN "${executable}")
        add_test("${prefix}.not-built" "${SWIFT_TEST_CMAKE_COMMAND}" -E false)
        set_tests_properties("${prefix}.not-built" PROPERTIES LABELS "${prefix}")
        return()
    endif()
    execute_process(COMMAND "${executable}" --list-tests
        RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error
        TIMEOUT 10
    )
    string(STRIP "${output}" output)
    string(REPLACE "\r\n" "\n" output "${output}")
    string(REPLACE "\n" ";" cases "${output}")
    set(unique_cases ${cases})
    list(REMOVE_DUPLICATES unique_cases)
    list(LENGTH cases count)
    list(LENGTH unique_cases unique_count)
    set(valid TRUE)
    foreach(case IN LISTS cases)
        if(NOT case MATCHES "^[A-Za-z0-9_.-]+$")
            set(valid FALSE)
        endif()
    endforeach()
    if(NOT result STREQUAL "0" OR count EQUAL 0 OR NOT count EQUAL unique_count OR NOT valid)
        message(WARNING "Could not discover ${prefix}: ${result}\n${output}\n${error}")
        add_test("${prefix}.discovery-error" "${SWIFT_TEST_CMAKE_COMMAND}" -E false)
        set_tests_properties("${prefix}.discovery-error" PROPERTIES LABELS "${prefix}")
        return()
    endif()
    foreach(case IN LISTS cases)
        add_test("${prefix}.${case}" "${executable}" --case "${case}" ${ARGN})
        set_tests_properties("${prefix}.${case}" PROPERTIES
            TIMEOUT "${timeout}" RUN_SERIAL "${serial}" LABELS "${prefix}"
            WORKING_DIRECTORY "${working_directory}"
        )
    endforeach()
endfunction()
