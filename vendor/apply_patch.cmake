# Check if patch is already applied
execute_process(
    COMMAND git apply --check --reverse "${PATCH_FILE}"
    RESULT_VARIABLE ALREADY_APPLIED
    OUTPUT_QUIET
    ERROR_QUIET
)

if(ALREADY_APPLIED EQUAL 0)
    message(STATUS "Patch already applied, skipping: ${PATCH_FILE}")
    return()
endif()

# Check if patch can be applied cleanly
execute_process(
    COMMAND git apply --check "${PATCH_FILE}"
    RESULT_VARIABLE CAN_APPLY
    OUTPUT_QUIET
    ERROR_QUIET
)

if(CAN_APPLY EQUAL 0)
    execute_process(
        COMMAND git apply "${PATCH_FILE}"
        RESULT_VARIABLE PATCH_RESULT
    )
    if(NOT PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to apply patch: ${PATCH_FILE}")
    endif()
    message(STATUS "Patch applied: ${PATCH_FILE}")
else()
    message(WARNING "Patch cannot be applied (may be partially applied). Resetting and retrying: ${PATCH_FILE}")
    execute_process(COMMAND git checkout -- . OUTPUT_QUIET ERROR_QUIET)
    execute_process(
        COMMAND git apply "${PATCH_FILE}"
        RESULT_VARIABLE PATCH_RESULT
    )
    if(NOT PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to apply patch after reset: ${PATCH_FILE}")
    endif()
endif()
