cmake_minimum_required(VERSION 3.24)

project(vendor-mpfr NONE)

set(MPFR_TRIPLET "x64-windows-static-md")

set(MPFR_VENDOR_DIR
    "${CMAKE_CURRENT_LIST_DIR}/installed/windows-x64-msvc-static-md"
)

set(VCPKG_ROOT "${CMAKE_BINARY_DIR}/vcpkg")
set(VCPKG_EXE "${VCPKG_ROOT}/vcpkg.exe")

if(NOT EXISTS "${VCPKG_EXE}")
    if(NOT EXISTS "${VCPKG_ROOT}/.git")
        message(STATUS "Cloning vcpkg")

        execute_process(
            COMMAND git clone https://github.com/microsoft/vcpkg.git "${VCPKG_ROOT}"
            COMMAND_ERROR_IS_FATAL ANY
        )
    endif()

    message(STATUS "Bootstrapping vcpkg")

    execute_process(
        COMMAND "${VCPKG_ROOT}/bootstrap-vcpkg.bat" -disableMetrics
        WORKING_DIRECTORY "${VCPKG_ROOT}"
        COMMAND_ERROR_IS_FATAL ANY
    )
endif()

message(STATUS "Installing MPFR")

execute_process(
    COMMAND "${VCPKG_EXE}" install "mpfr:${MPFR_TRIPLET}" --clean-after-build
    WORKING_DIRECTORY "${VCPKG_ROOT}"
    COMMAND_ERROR_IS_FATAL ANY
)

set(installed "${VCPKG_ROOT}/installed/${MPFR_TRIPLET}")

find_file(mpfr_header
    NAMES mpfr.h
    PATHS "${installed}/include"
    NO_DEFAULT_PATH
    REQUIRED
)

find_library(mpfr_library
    NAMES mpfr libmpfr
    PATHS "${installed}/lib"
    NO_DEFAULT_PATH
    REQUIRED
)

file(REMOVE_RECURSE "${MPFR_VENDOR_DIR}")

file(MAKE_DIRECTORY
    "${MPFR_VENDOR_DIR}/include"
    "${MPFR_VENDOR_DIR}/lib"
)

file(COPY "${mpfr_header}"
    DESTINATION "${MPFR_VENDOR_DIR}/include"
)

file(COPY "${mpfr_library}"
    DESTINATION "${MPFR_VENDOR_DIR}/lib"
)

get_filename_component(mpfr_library_name "${mpfr_library}" NAME)

file(RENAME
    "${MPFR_VENDOR_DIR}/lib/${mpfr_library_name}"
    "${MPFR_VENDOR_DIR}/lib/mpfr.lib"
)

add_custom_target(mpfr ALL
    COMMENT "Vendored MPFR available at ${MPFR_VENDOR_DIR}"
)
