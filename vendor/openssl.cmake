include(FetchContent)

set(ERYX_OPENSSL_VERSION "3.5.6" CACHE STRING "Pinned prebuilt OpenSSL version used by Eryx")
set(
    ERYX_OPENSSL_RELEASE_BASE_URL
    "https://github.com/Bottersnike/openssl-static/releases/download/v${ERYX_OPENSSL_VERSION}"
    CACHE STRING
    "Base URL for prebuilt OpenSSL release assets"
)

if(WIN32)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|x86_64)$")
        set(_eryx_openssl_asset_name "openssl-${ERYX_OPENSSL_VERSION}-windows-x64-msvc-static.zip")
    else()
        message(FATAL_ERROR "Unsupported OpenSSL prebuilt Windows architecture: ${CMAKE_SYSTEM_PROCESSOR}")
    endif()
elseif(APPLE)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
        set(_eryx_openssl_asset_name "openssl-${ERYX_OPENSSL_VERSION}-macos-arm64-static.tar.gz")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
        set(_eryx_openssl_asset_name "openssl-${ERYX_OPENSSL_VERSION}-macos-x86_64-static.tar.gz")
    else()
        message(FATAL_ERROR "Unsupported OpenSSL prebuilt macOS architecture: ${CMAKE_SYSTEM_PROCESSOR}")
    endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
        set(_eryx_openssl_asset_name "openssl-${ERYX_OPENSSL_VERSION}-linux-x86_64-static.tar.gz")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
        set(_eryx_openssl_asset_name "openssl-${ERYX_OPENSSL_VERSION}-linux-aarch64-static.tar.gz")
    else()
        message(FATAL_ERROR "Unsupported OpenSSL prebuilt Linux architecture: ${CMAKE_SYSTEM_PROCESSOR}")
    endif()
else()
    message(FATAL_ERROR "Unsupported OpenSSL prebuilt platform: ${CMAKE_SYSTEM_NAME}")
endif()

set(_eryx_openssl_url "${ERYX_OPENSSL_RELEASE_BASE_URL}/${_eryx_openssl_asset_name}")

FetchContent_Declare(
    eryx_openssl_prebuilt
    URL "${_eryx_openssl_url}"
    DOWNLOAD_EXTRACT_TIMESTAMP OFF
)

FetchContent_GetProperties(eryx_openssl_prebuilt)
if(NOT eryx_openssl_prebuilt_POPULATED)
    FetchContent_Populate(eryx_openssl_prebuilt)
endif()

set(OPENSSL_PREBUILT_ROOT "${eryx_openssl_prebuilt_SOURCE_DIR}")
include("${OPENSSL_PREBUILT_ROOT}/cmake/OpenSSLPrebuilt.cmake")

