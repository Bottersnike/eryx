# Platform-specific system libraries used by various modules
if(WIN32)
    set(_PLAT_SOCK_LIBS ws2_32.lib)
    set(_PLAT_CRYPT_LIBS crypt32.lib)
    set(_PLAT_SECURITY_LIBS advapi32.lib)
else()
    set(_PLAT_SOCK_LIBS "")
    set(_PLAT_CRYPT_LIBS "")
    set(_PLAT_SECURITY_LIBS "")
endif()

add_luau_module(task src/modules/task.cpp src/modules/task.luau)
add_luau_module(_socket src/modules/_socket.cpp src/modules/_socket.luau
    EXTRA_LIBS ${_PLAT_SOCK_LIBS}
)

if(WIN32)
# TODO: Implement FFI on platforms other than Windows
add_luau_module(_native/_ffi src/modules/_ffi.cpp src/modules/_native/stub.luau
    EXTRA_LIBS dyncall
    EXTRA_INCLUDES "${dyncall_SOURCE_DIR}/dyncall"
)
endif()

if(ERYX_USE_CRYPTOGRAPHY)
    add_luau_module(_native/_ssl src/modules/_ssl.cpp src/modules/_native/stub.luau
        EXTRA_LIBS OpenSSL::SSL OpenSSL::Crypto ${_PLAT_SOCK_LIBS} ${_PLAT_CRYPT_LIBS}
                   "$<$<BOOL:${APPLE}>:-framework Security>"
                   "$<$<BOOL:${APPLE}>:-framework CoreFoundation>"
    )

    add_luau_module(crypto/hazmat/_native src/modules/crypto/hazmat/_crypto.cpp src/modules/_native/stub.luau
        ENTRYPOINT luauopen__crypto
        EXTRA_LIBS OpenSSL::Crypto ${_PLAT_SOCK_LIBS} ${_PLAT_CRYPT_LIBS}
    )

    add_luau_module(crypto/hazmat/argon2 src/modules/crypto/hazmat/argon2.cpp src/modules/crypto/hazmat/argon2.luau
        EXTRA_LIBS phc_argon2
        EXTRA_INCLUDES "${ARGON2_DIR}/include"
                       "${ARGON2_DIR}/src"
    )

    add_luau_script_module(crypto/hazmat/
        src/modules/crypto/hazmat/hash.luau
        src/modules/crypto/hazmat/hmac.luau
        src/modules/crypto/hazmat/aes.luau
        src/modules/crypto/hazmat/camellia.luau
        src/modules/crypto/hazmat/des.luau
        src/modules/crypto/hazmat/chacha20.luau
        src/modules/crypto/hazmat/pkcs7.luau
        src/modules/crypto/hazmat/kdf.luau
        src/modules/crypto/hazmat/rsa.luau
        src/modules/crypto/hazmat/ecc.luau
        src/modules/crypto/hazmat/pem.luau
        src/modules/crypto/hazmat/asn1.luau
        src/modules/crypto/hazmat/random.luau
    )

    add_luau_script_module(crypto/
        src/modules/crypto/hash.luau
        src/modules/crypto/hmac.luau
        src/modules/crypto/password.luau
        src/modules/crypto/secretbox.luau
    )
endif()

if(ERYX_USE_ZLIB)
    add_luau_module(compression/zlib
        src/modules/compression/zlib.cpp
        src/modules/compression/zlib.luau
        EXTRA_LIBS zlibstatic
        EXTRA_INCLUDES "${ZLIB_DIR}"
    )

    add_luau_module(compression/gzip
        src/modules/compression/gzip.cpp
        src/modules/compression/gzip.luau
        EXTRA_LIBS zlibstatic
        EXTRA_INCLUDES "${ZLIB_DIR}"
    )

    add_luau_module(archive/zip src/modules/archive/zip.cpp src/modules/archive/zip.luau
        EXTRA_LIBS minizip-ng
    )
endif()
if(ERYX_USE_BZIP2)
    add_luau_module(compression/bzip2
        src/modules/compression/bzip2.cpp
        src/modules/compression/bzip2.luau
        EXTRA_LIBS bz2_static
        EXTRA_INCLUDES "${BZIP2_DIR}"
    )
endif()
if(ERYX_USE_BROTLI)
    add_luau_module(compression/brotli
        src/modules/compression/brotli.cpp
        src/modules/compression/brotli.luau
        EXTRA_LIBS brotlicommon brotlidec brotlienc
        EXTRA_INCLUDES "${BROTLI_DIR}/c/include"
    )
endif()
if(ERYX_USE_ZSTD)
    add_luau_module(compression/zstd
        src/modules/compression/zstd.cpp
        src/modules/compression/zstd.luau
        EXTRA_LIBS libzstd_static
        EXTRA_INCLUDES "${ZSTD_DIR}/lib"
    )
endif()

add_luau_module(luau/_parse_native src/modules/luau/parse.cpp src/modules/_native/stub.luau
    ENTRYPOINT luauopen_parse_native
    EXTRA_INCLUDES "${LUAU_DIR}/Ast/include"
                   "${LUAU_DIR}/Compiler/include"
                   "${LUAU_DIR}/Common/include"
                   "${LUAU_DIR}/VM/src"
    EXTRA_SOURCES
                   src/modules/luau/native.cpp
                   "${LUAU_DIR}/Config/src/Config.cpp"
                   "${LUAU_DIR}/Config/src/LinterConfig.cpp"
)

add_luau_module(luau/_vm_native src/modules/luau/vm.cpp src/modules/_native/stub.luau
    ENTRYPOINT luauopen_vm_native
    EXTRA_INCLUDES "${LUAU_DIR}/Ast/include"
                   "${LUAU_DIR}/Compiler/include"
                   "${LUAU_DIR}/Common/include"
                   "${LUAU_DIR}/VM/src"
    EXTRA_SOURCES
                   src/modules/luau/native.cpp
                   "${LUAU_DIR}/Config/src/Config.cpp"
                   "${LUAU_DIR}/Config/src/LinterConfig.cpp"
)

add_luau_module(luau/_analysis_native src/modules/luau/analysis.cpp src/modules/_native/stub.luau
    ENTRYPOINT luauopen_analysis_native
    EXTRA_INCLUDES "${LUAU_DIR}/Ast/include"
                   "${LUAU_DIR}/Compiler/include"
                   "${LUAU_DIR}/Common/include"
                   "${LUAU_DIR}/VM/src"
    EXTRA_SOURCES
                   src/modules/luau/native.cpp
                   "${LUAU_DIR}/Config/src/Config.cpp"
                   "${LUAU_DIR}/Config/src/LinterConfig.cpp"
)

add_luau_module(date src/modules/date.cpp src/modules/date.luau)

if(ERYX_USE_XML)
    add_luau_module(_native/xml src/modules/data/xml.cpp src/modules/_native/stub.luau
        EXTRA_LIBS pugixml
        EXTRA_INCLUDES "${VENDOR_DIR}"
    )
endif()

add_luau_module(os src/modules/os.cpp src/modules/os.luau
    EXTRA_LIBS ${_PLAT_SECURITY_LIBS}
)

if(ERYX_USE_SQLITE3)
    include(FetchContent)
    FetchContent_Declare(
        sqlite3
        URL "https://sqlite.org/2026/sqlite-amalgamation-3510300.zip"
    )
    FetchContent_MakeAvailable(sqlite3)
    set(SQLITE3_DIR "${sqlite3_SOURCE_DIR}")
    add_luau_module(_native/sqlite3 src/modules/sqlite3.cpp src/modules/_native/stub.luau
        EXTRA_SOURCES "${SQLITE3_DIR}/sqlite3.c"
        EXTRA_INCLUDES "${SQLITE3_DIR}"
    )
endif()

add_luau_module(stdio src/modules/stdio.cpp src/modules/stdio.luau
    EXTRA_LIBS uv_a
)
add_luau_module(exception src/modules/exception.cpp src/modules/exception.luau)
add_luau_module(fs src/modules/fs.cpp src/modules/fs.luau
    EXTRA_LIBS ${_PLAT_SECURITY_LIBS}
)
add_luau_module(_native/_path src/modules/_path_native.cpp src/modules/_native/_path.luau)
add_luau_module(vfs src/modules/vfs.cpp src/modules/vfs.luau)
if(ERYX_EMBED_MODULES)
    add_luau_module(_embedded src/modules/_embedded.cpp src/modules/_embedded.luau
        ENTRYPOINT luauopen_embedded
    )
endif()
add_luau_module(_fs_watch src/modules/_fs_watch.cpp src/modules/_fs_watch.luau
    EXTRA_LIBS uv_a
)
add_luau_module(image src/modules/image.cpp src/modules/image.luau
    EXTRA_LIBS png_static webp turbojpeg_external
    EXTRA_INCLUDES "${VENDOR_DIR}/stb"  # for stb_image.h
                   "${PNG_DIR}"
                   "${CMAKE_BINARY_DIR}/vendor/libpng"
                   "${WEBP_DIR}/src"
                   "${JPEGTURBO_DIR}/src"
)

if(ERYX_USE_PCRE2)
    add_luau_module(_native/regex src/modules/regex.cpp src/modules/_native/stub.luau
        EXTRA_LIBS pcre2-8-static
        EXTRA_INCLUDES "${PCRE2_DIR}/src" "${CMAKE_BINARY_DIR}/vendor/pcre2"
    )
endif()

# -- WebView module
# On windows, we're going to need to pull WebView2 down with nuget
if(WIN32)
add_luau_module(_native/webview src/modules/webview.cpp src/modules/_native/stub.luau)

set(NUGET_EXE ${CMAKE_BINARY_DIR}/nuget.exe)
if(NOT EXISTS ${NUGET_EXE})
    file(DOWNLOAD
        https://dist.nuget.org/win-x86-commandline/latest/nuget.exe
        ${NUGET_EXE}
        SHOW_PROGRESS
    )
endif()
execute_process(COMMAND ${NUGET_EXE} install "Microsoft.Web.WebView2" -Version 1.0.2592.51 -ExcludeVersion -OutputDirectory ${CMAKE_BINARY_DIR}/packages)
execute_process(COMMAND ${NUGET_EXE} install "Microsoft.Windows.ImplementationLibrary" -Version 1.0.240122.1 -ExcludeVersion -OutputDirectory ${CMAKE_BINARY_DIR}/packages)

set(WEBVIEW2_DIR ${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2)
set(WIL_DIR ${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary)

if(ERYX_EMBED_MODULES)
target_include_directories(eryx PUBLIC ${WEBVIEW2_DIR}/build/native/include)
target_include_directories(eryx PUBLIC ${WIL_DIR}/include)
target_link_libraries(eryx PUBLIC ${WEBVIEW2_DIR}/build/native/x64/WebView2LoaderStatic.lib)
else()
target_include_directories(mod__native_webview PUBLIC ${WEBVIEW2_DIR}/build/native/include)
target_include_directories(mod__native_webview PUBLIC ${WIL_DIR}/include)
target_link_libraries(mod__native_webview PUBLIC ${WEBVIEW2_DIR}/build/native/x64/WebView2LoaderStatic.lib)
endif()
endif()

# -- GFX module (SDL3 + WGPU + FreeType + miniaudio) -------------------------
# This is a custom target rather than add_luau_module because it has many
# source files spread across src/ and complex link dependencies.

if(ERYX_MODULE_GFX)
    set(GFX_SOURCES
        src/modules/gfx/_gfx.cpp
        src/modules/gfx/Font.cpp
        src/modules/gfx/GFX.cpp
        src/modules/gfx/GPU.cpp
        src/modules/gfx/LL_Font.cpp
        src/modules/gfx/LL_Render.cpp
        src/modules/gfx/LL_Texture.cpp
        src/modules/gfx/Shader.cpp
        src/modules/gfx/Sound.cpp
        src/modules/gfx/Texture.cpp
        src/modules/gfx/Window.cpp
        src/modules/gfx/Mouse.cpp
        src/modules/gfx/Particles.cpp
    )

    set(GFX_EXTRA_INCLUDES
        "${LUAU_DIR}/VM/include"
        "${LUAU_DIR}/Common/include"
        "${LUAU_DIR}/Compiler/include"
        "${LUAU_DIR}/CodeGen/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/src/modules"
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
        "${LIBUV_DIR}/include"
        wgpu_native
        "${MINIAUDIO_INCLUDE_DIR}"
        "${FREETYPE_DIR}/include"
        "${VENDOR_DIR}/stb"  # for stb_image.h
    )

    set(GFX_EXTRA_LIBS
        SDL3::SDL3-static
        freetype
        wgpu_native
    )
    if(WIN32)
        list(APPEND GFX_EXTRA_LIBS
            ws2_32.lib          # Winsock2 (required by WGPU)
            userenv.lib         # User environment
            opengl32.lib        # OpenGL for WGL
            ntdll.lib           # NT API
            ole32.lib           # COM
            oleaut32.lib        # COM Variant
            runtimeobject.lib   # Windows Runtime
            propsys.lib         # Property System
        )
    elseif(APPLE)
        list(APPEND GFX_EXTRA_LIBS
            "-framework Metal"
            "-framework QuartzCore"
        )
    endif()

    # Copy Luau wrapper scripts into modules/gfx/
    set(GFX_LUAU_WRAPPERS
        src/modules/gfx/window.luau
        src/modules/gfx/mouse.luau
        src/modules/gfx/texture.luau
        src/modules/gfx/font.luau
        src/modules/gfx/shader.luau
        src/modules/gfx/sound.luau
        src/modules/gfx/particles.luau
        src/modules/gfx/init.luau
    )

    if(ERYX_EMBED_MODULES)
        # Attach GFX sources/includes/libs to the embed target immediately so
        # generator-specific cache timing does not drop them from the link.
        foreach(_src ${GFX_SOURCES})
            target_sources(eryx PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/${_src}")
        endforeach()
        target_include_directories(eryx PRIVATE ${GFX_EXTRA_INCLUDES})
        target_link_libraries(eryx PRIVATE ${GFX_EXTRA_LIBS})
        set(ERYX_EMBED_NATIVE_ENTRIES ${ERYX_EMBED_NATIVE_ENTRIES} "gfx/_gfx|luauopen__gfx" CACHE INTERNAL "")

        # Accumulate the GFX Luau wrappers as script modules
        foreach(WRAPPER ${GFX_LUAU_WRAPPERS})
            get_filename_component(FNAME "${WRAPPER}" NAME)
            string(REGEX REPLACE "\\.luau$" "" _mod_key "gfx/${FNAME}")
            set(ERYX_EMBED_SCRIPT_ENTRIES ${ERYX_EMBED_SCRIPT_ENTRIES}
                "${_mod_key}|${CMAKE_CURRENT_SOURCE_DIR}/${WRAPPER}" CACHE INTERNAL "")
        endforeach()
    else()
        add_library(mod_gfx__gfx SHARED ${GFX_SOURCES})

        target_include_directories(mod_gfx__gfx PRIVATE ${GFX_EXTRA_INCLUDES})

        target_compile_definitions(mod_gfx__gfx PRIVATE
            LUAU_GIT_HASH="${LUAU_GIT_HASH}"
            LUAU_APPROX_VERSION="${LUAU_APPROX_VERSION}"
            MA_ENABLE_VORBIS
        )
        if(WIN32)
            target_compile_definitions(mod_gfx__gfx PRIVATE
                "LUA_API=extern \"C\" __declspec(dllimport)"
                "LUACODE_API=extern \"C\" __declspec(dllimport)"
                "LUACODEGEN_API=extern \"C\" __declspec(dllimport)"
            )
        else()
            target_compile_definitions(mod_gfx__gfx PRIVATE
                "LUA_API=extern \"C\" __attribute__((visibility(\"default\")))"
                "LUACODE_API=extern \"C\" __attribute__((visibility(\"default\")))"
                "LUACODEGEN_API=extern \"C\" __attribute__((visibility(\"default\")))"
            )
        endif()

        set_target_properties(mod_gfx__gfx PROPERTIES CXX_STANDARD 23 PREFIX "")

        target_link_libraries(mod_gfx__gfx PRIVATE
            EryxShared
            Luau.Compiler
            Luau.Common
            Luau.Ast
            ${GFX_EXTRA_LIBS}
        )

        # Copy _gfx module into modules/gfx/ next to eryx
        add_custom_command(TARGET mod_gfx__gfx POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:eryx>/modules/gfx"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                $<TARGET_FILE:mod_gfx__gfx>
                "$<TARGET_FILE_DIR:eryx>/modules/gfx/_gfx$<TARGET_FILE_SUFFIX:mod_gfx__gfx>"
            COMMENT "Copying _gfx module to modules/gfx/"
        )

        foreach(WRAPPER ${GFX_LUAU_WRAPPERS})
            get_filename_component(FNAME "${WRAPPER}" NAME)
            add_custom_command(TARGET mod_gfx__gfx POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${CMAKE_CURRENT_SOURCE_DIR}/${WRAPPER}"
                    "$<TARGET_FILE_DIR:eryx>/modules/gfx/${FNAME}"
            )
        endforeach()

        add_dependencies(eryx mod_gfx__gfx)
    endif()
endif()

if(WIN32)
    set(_PLAT_SERIAL_LIBS "setupapi")  # uses Win32 API directly
else()
    set(_PLAT_SERIAL_LIBS "")  # uses POSIX termios directly
endif()
add_luau_module(serial src/modules/serial.cpp src/modules/serial.luau
    EXTRA_LIBS ${_PLAT_SERIAL_LIBS}
)

include(vendor/gmp.cmake)
include(vendor/mpfr.cmake)
add_luau_module(number src/modules/number.cpp src/modules/number.luau
    EXTRA_LIBS GMP MPFR
)
add_luau_module(thread src/modules/thread.cpp src/modules/thread.luau
    EXTRA_LIBS uv_a
)
add_luau_module(debugger src/modules/debugger.cpp src/modules/debugger.luau
    EXTRA_LIBS uv_a
)
