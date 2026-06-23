include_guard(GLOBAL)

include("${CMAKE_CURRENT_LIST_DIR}/gmp.cmake")

add_library(MPFR STATIC IMPORTED GLOBAL)
set_target_properties(MPFR PROPERTIES
    INTERFACE_LINK_LIBRARIES GMP
)

if(WIN32)
    set(MPFR_VENDOR_DIR
        "${CMAKE_SOURCE_DIR}/vendor/mpfr/installed/windows-x64-msvc-static-md"
    )

    set_target_properties(MPFR PROPERTIES
        IMPORTED_LOCATION "${MPFR_VENDOR_DIR}/lib/mpfr.lib"
        INTERFACE_INCLUDE_DIRECTORIES "${MPFR_VENDOR_DIR}/include"
    )

else()
    include(ExternalProject)

    set(MPFR_VERSION "4.2.1")

    find_program(MAKE_EXECUTABLE NAMES gmake make REQUIRED)

    set(MPFR_PREFIX "${CMAKE_BINARY_DIR}/_deps/mpfr")
    set(MPFR_INSTALL_DIR "${MPFR_PREFIX}/install")
    set(MPFR_LIBRARY "${MPFR_INSTALL_DIR}/lib/libmpfr.a")

    file(MAKE_DIRECTORY "${MPFR_INSTALL_DIR}/include")

    set(MPFR_HOST "")
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
            set(MPFR_HOST "x86_64-pc-linux-gnu")
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
            set(MPFR_HOST "aarch64-unknown-linux-gnu")
        endif()
    endif()

    set(MPFR_CONFIGURE_ARGS
        "--prefix=${MPFR_INSTALL_DIR}"
        "--enable-static"
        "--disable-shared"
        "--with-pic"
        "--with-gmp=${GMP_INSTALL_DIR}"
    )

    if(MPFR_HOST)
        list(APPEND MPFR_CONFIGURE_ARGS
            "--build=${MPFR_HOST}"
            "--host=${MPFR_HOST}"
        )
    endif()

    ExternalProject_Add(mpfr_external
        URL
            "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VERSION}.tar.xz"
            "https://www.mpfr.org/mpfr-${MPFR_VERSION}/mpfr-${MPFR_VERSION}.tar.xz"
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        PREFIX "${MPFR_PREFIX}"

        DEPENDS GMP

        CONFIGURE_COMMAND
            <SOURCE_DIR>/configure ${MPFR_CONFIGURE_ARGS}

        BUILD_COMMAND
            "${MAKE_EXECUTABLE}" -j MAKEINFO=true

        INSTALL_COMMAND
            "${MAKE_EXECUTABLE}" install MAKEINFO=true

        BUILD_BYPRODUCTS
            "${MPFR_LIBRARY}"
    )

    set_target_properties(MPFR PROPERTIES
        IMPORTED_LOCATION "${MPFR_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${MPFR_INSTALL_DIR}/include"
    )

    add_dependencies(MPFR mpfr_external)
endif()
