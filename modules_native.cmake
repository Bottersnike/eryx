# Platform-specific system libraries used by various modules
if(WIN32)
    set(_PLAT_SOCK_LIBS ws2_32.lib)
    set(_PLAT_CRYPT_LIBS crypt32.lib)
else()
    set(_PLAT_SOCK_LIBS "")
    set(_PLAT_CRYPT_LIBS "")
endif()

add_luau_module(task src/modules/task.cpp src/modules/task.luau)
add_luau_module(_socket src/modules/_socket.cpp src/modules/_socket.luau
    EXTRA_LIBS ${_PLAT_SOCK_LIBS}
)

if(WIN32)
# TODO: Implement FFI on platforms other than Windows
add_luau_module(_ffi src/modules/_ffi.cpp src/modules/_ffi.luau
    EXTRA_LIBS dyncall
    EXTRA_INCLUDES "${dyncall_SOURCE_DIR}/dyncall"
)
endif()

if(ERYX_USE_CRYPTOGRAPHY)
    add_luau_module(_ssl src/modules/_ssl.cpp src/modules/_ssl.luau
        EXTRA_LIBS mbedtls mbedx509 tfpsacrypto ${_PLAT_SOCK_LIBS} ${_PLAT_CRYPT_LIBS}
                   "$<$<BOOL:${APPLE}>:-framework Security>"
                   "$<$<BOOL:${APPLE}>:-framework CoreFoundation>"
        EXTRA_INCLUDES "${mbedtls_SOURCE_DIR}/include"
                    "${mbedtls_SOURCE_DIR}/tf-psa-crypto/include"
                    "${mbedtls_SOURCE_DIR}/tf-psa-crypto/drivers/builtin/include"
    )

    add_luau_module(crypto/_crypto src/modules/crypto/_crypto.cpp src/modules/crypto/_crypto.luau
        EXTRA_LIBS mbedtls mbedx509 tfpsacrypto ${_PLAT_SOCK_LIBS} ${_PLAT_CRYPT_LIBS}
        EXTRA_INCLUDES "${mbedtls_SOURCE_DIR}/include"
                    "${mbedtls_SOURCE_DIR}/tf-psa-crypto/include"
                    "${mbedtls_SOURCE_DIR}/tf-psa-crypto/drivers/builtin/include"
    )

    add_luau_script_module(crypto/
        src/modules/crypto/hash.luau
        src/modules/crypto/hmac.luau
        src/modules/crypto/aes.luau
        src/modules/crypto/camellia.luau
        src/modules/crypto/des.luau
        src/modules/crypto/chacha20.luau
        src/modules/crypto/kdf.luau
        src/modules/crypto/rsa.luau
        src/modules/crypto/pem.luau
        src/modules/crypto/asn1.luau
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

    add_luau_module(compression/zip src/modules/compression/zip.cpp src/modules/compression/zip.luau
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

add_luau_module(luau src/modules/luau.cpp src/modules/luau.luau
    EXTRA_INCLUDES "${LUAU_DIR}/Ast/include"
                   "${LUAU_DIR}/Compiler/include"
                   "${LUAU_DIR}/Common/include"
                   "${LUAU_DIR}/VM/src"
    EXTRA_SOURCES
                #  src/lresolve.cpp
                #    src/lrequire.cpp
                #    src/runtime/lexception.cpp
                #    src/lconfig.cpp
                #    src/vfs.cpp  # So lexception can resolve VFS files
                   "${LUAU_DIR}/Config/src/Config.cpp"
                   "${LUAU_DIR}/Config/src/LinterConfig.cpp"
)

add_luau_module(date src/modules/date.cpp src/modules/date.luau)

if(ERYX_USE_XML)
    add_luau_module(xml src/modules/xml.cpp src/modules/xml.luau
        EXTRA_LIBS pugixml
        EXTRA_INCLUDES "${VENDOR_DIR}"
    )
endif()

add_luau_module(os src/modules/os.cpp src/modules/os.luau)

if(ERYX_USE_SQLITE3)
    include(FetchContent)
    FetchContent_Declare(
        sqlite3
        URL "https://sqlite.org/2026/sqlite-amalgamation-3510300.zip"
    )
    FetchContent_MakeAvailable(sqlite3)
    set(SQLITE3_DIR "${sqlite3_SOURCE_DIR}")
    add_luau_module(sqlite3 src/modules/sqlite3.cpp src/modules/sqlite3.luau
        EXTRA_SOURCES "${SQLITE3_DIR}/sqlite3.c"
        EXTRA_INCLUDES "${SQLITE3_DIR}"
    )
endif()

add_luau_module(stdio src/modules/stdio.cpp src/modules/stdio.luau
    EXTRA_LIBS uv_a
)
add_luau_module(exception src/modules/exception.cpp src/modules/exception.luau)
add_luau_module(fs src/modules/fs.cpp src/modules/fs.luau)
add_luau_module(vfs src/modules/vfs.cpp src/modules/vfs.luau)

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
        # Accumulate GFX sources/includes/libs into the embed lists
        foreach(_src ${GFX_SOURCES})
            list(APPEND ERYX_EMBED_NATIVE_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/${_src}")
        endforeach()
        set(ERYX_EMBED_NATIVE_SOURCES ${ERYX_EMBED_NATIVE_SOURCES} CACHE INTERNAL "")
        set(ERYX_EMBED_NATIVE_INCLUDES ${ERYX_EMBED_NATIVE_INCLUDES} ${GFX_EXTRA_INCLUDES} CACHE INTERNAL "")
        set(ERYX_EMBED_NATIVE_LIBS ${ERYX_EMBED_NATIVE_LIBS} ${GFX_EXTRA_LIBS} CACHE INTERNAL "")
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
