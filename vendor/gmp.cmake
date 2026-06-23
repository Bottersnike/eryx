include_guard(GLOBAL)

add_library(GMP STATIC IMPORTED GLOBAL)

if(WIN32)
    set(GMP_VENDOR_DIR
        "${CMAKE_SOURCE_DIR}/vendor/gmp/installed/windows-x64-msvc-static-md"
    )

    set_target_properties(GMP PROPERTIES
        IMPORTED_LOCATION "${GMP_VENDOR_DIR}/lib/gmp.lib"
        INTERFACE_INCLUDE_DIRECTORIES "${GMP_VENDOR_DIR}/include"
    )

else()
    include(ExternalProject)

    set(GMP_VERSION "6.3.0")
    set(GMP_SHA256 "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898")

    find_program(MAKE_EXECUTABLE NAMES gmake make REQUIRED)

    set(GMP_PREFIX "${CMAKE_BINARY_DIR}/_deps/gmp")
    set(GMP_INSTALL_DIR "${GMP_PREFIX}/install")
    set(GMP_LIBRARY "${GMP_INSTALL_DIR}/lib/libgmp.a")

    file(MAKE_DIRECTORY "${GMP_INSTALL_DIR}/include")

    set(GMP_HOST "")
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
            set(GMP_HOST "x86_64-pc-linux-gnu")
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
            set(GMP_HOST "aarch64-unknown-linux-gnu")
        endif()
    endif()

    set(GMP_CONFIGURE_ARGS
        "--prefix=${GMP_INSTALL_DIR}"
        "--enable-static"
        "--disable-shared"
        "--with-pic"
    )

    if(GMP_HOST)
        list(APPEND GMP_CONFIGURE_ARGS
            "--build=${GMP_HOST}"
            "--host=${GMP_HOST}"
        )
    endif()

    ExternalProject_Add(gmp_external
        URL
            "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
            "https://ftpmirror.gnu.org/gmp/gmp-${GMP_VERSION}.tar.xz"
            "https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz"
        URL_HASH "SHA256=${GMP_SHA256}"
        PREFIX "${GMP_PREFIX}"

        CONFIGURE_COMMAND
            <SOURCE_DIR>/configure ${GMP_CONFIGURE_ARGS}

        BUILD_COMMAND
            "${MAKE_EXECUTABLE}" -j MAKEINFO=true

        INSTALL_COMMAND
            "${MAKE_EXECUTABLE}" install MAKEINFO=true

        BUILD_BYPRODUCTS
            "${GMP_LIBRARY}"
    )

    set_target_properties(GMP PROPERTIES
        IMPORTED_LOCATION "${GMP_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${GMP_INSTALL_DIR}/include"
    )

    add_dependencies(GMP gmp_external)
endif()
