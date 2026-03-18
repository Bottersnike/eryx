include(FetchContent)

set(WGPU_VERSION v27.0.4.0)

if(WIN32)
    set(WGPU_ARCHIVE wgpu-windows-x86_64-msvc-release.zip)
elseif(APPLE)
    set(WGPU_ARCHIVE wgpu-macos-x86_64-release.zip)
elseif(UNIX)
    set(WGPU_ARCHIVE wgpu-linux-x86_64-release.zip)
else()
    error("Unsupported platform for WGPU")
endif()

set(WGPU_URL
    https://github.com/gfx-rs/wgpu-native/releases/download/${WGPU_VERSION}/${WGPU_ARCHIVE}
)

FetchContent_Declare(
    wgpu
    URL ${WGPU_URL}
)

FetchContent_GetProperties(wgpu)
if(NOT wgpu_POPULATED)
    FetchContent_Populate(wgpu)
endif()

add_library(wgpu_native STATIC IMPORTED)

if(WIN32)
    set(WGPU_LIB_NAME "wgpu_native.lib")
else()
    set(WGPU_LIB_NAME "libwgpu_native.a")
endif()

set_target_properties(wgpu_native PROPERTIES
    IMPORTED_LOCATION "${wgpu_SOURCE_DIR}/lib/${WGPU_LIB_NAME}"
    INTERFACE_INCLUDE_DIRECTORIES "${wgpu_SOURCE_DIR}/include"
)
