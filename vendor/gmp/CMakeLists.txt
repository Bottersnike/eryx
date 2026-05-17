cmake_minimum_required(VERSION 3.24)

project(vendor-gmp NONE)

set(GMP_VERSION "6.3.0")
set(GMP_TRIPLET "x64-windows-static-md")

set(GMP_VENDOR_DIR
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

message(STATUS "Installing GMP")

execute_process(
    COMMAND "${VCPKG_EXE}" install "gmp:${GMP_TRIPLET}" --clean-after-build
    WORKING_DIRECTORY "${VCPKG_ROOT}"
    COMMAND_ERROR_IS_FATAL ANY
)

set(installed "${VCPKG_ROOT}/installed/${GMP_TRIPLET}")

find_file(gmp_header
    NAMES gmp.h
    PATHS "${installed}/include"
    NO_DEFAULT_PATH
    REQUIRED
)

find_library(gmp_library
    NAMES gmp libgmp
    PATHS "${installed}/lib"
    NO_DEFAULT_PATH
    REQUIRED
)

file(REMOVE_RECURSE "${GMP_VENDOR_DIR}")

file(MAKE_DIRECTORY
    "${GMP_VENDOR_DIR}/include"
    "${GMP_VENDOR_DIR}/lib"
)

file(COPY "${gmp_header}"
    DESTINATION "${GMP_VENDOR_DIR}/include"
)

file(COPY "${gmp_library}"
    DESTINATION "${GMP_VENDOR_DIR}/lib"
)

get_filename_component(gmp_library_name "${gmp_library}" NAME)

file(RENAME
    "${GMP_VENDOR_DIR}/lib/${gmp_library_name}"
    "${GMP_VENDOR_DIR}/lib/gmp.lib"
)

add_custom_target(gmp ALL
    COMMENT "Vendored GMP available at ${GMP_VENDOR_DIR}"
)
