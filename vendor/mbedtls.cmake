# Setup MbedTLS
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
# set(mbedtls_SOURCE_DIR "${VENDOR_DIR}/mbedtls-4.0.0")

# Pull MbedTLS from GitHub.
# We can't submodule this project, because we need the pre-configured version
include(FetchContent)
FetchContent_Declare(
    mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.0.0/mbedtls-4.0.0.tar.bz2
)
FetchContent_GetProperties(mbedtls)
FetchContent_MakeAvailable(mbedtls)