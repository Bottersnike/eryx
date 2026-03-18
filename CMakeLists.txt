cmake_minimum_required(VERSION 3.22)
project(LuauEmbedding LANGUAGES CXX C)

# Prevent Windows.h from defining max and min macros which conflict with std::max/min
add_compile_definitions(NOMINMAX)

set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
    cmake_policy(SET CMP0135 NEW)
endif()

# ---------------------------------------------------------------------------
option(ERYX_EMBED  "Build all modules into the eryx executable (single file, no DLL loading)" OFF)
option(ERYX_HYBRID "Embed modules into the exe but keep EryxShared as a DLL (two files, supports DLL modules)" OFF)
option(ERYX_MODULE_GFX "Compile the gfx module, adding SDL and WGPU" ON)
option(ERYX_USE_CRYPTOGRAPHY "Compile the crypto,_ssl modules, using MbedTLS" ON)
option(ERYX_USE_ZLIB "Compile the gzip,zlib,zip modules, using zlib" ON)
option(ERYX_USE_XML "Compile the xml module, using pugixml" ON)
option(ERYX_USE_ZSTD "Compile the zstd module" ON)
option(ERYX_USE_BROTLI "Compile the brotli module" ON)
option(ERYX_USE_BZIP2 "Compile the bzip2 module" ON)
option(ERYX_USE_SQLITE3 "Compile the sqlite3 module" ON)
# ---------------------------------------------------------------------------

# ERYX_HYBRID implies NOT ERYX_EMBED — hybrid keeps EryxShared as a DLL.
if(ERYX_HYBRID AND ERYX_EMBED)
    message(WARNING "ERYX_HYBRID and ERYX_EMBED are mutually exclusive. Using ERYX_HYBRID.")
    set(ERYX_EMBED OFF)
endif()

# Internal flag: should modules be compiled into the exe?
if(ERYX_EMBED OR ERYX_HYBRID)
    set(ERYX_EMBED_MODULES ON)
else()
    set(ERYX_EMBED_MODULES OFF)
endif()

# Force all vendored subdirectories to build static libraries.
# Freetype's CMakeLists has option(BUILD_SHARED_LIBS "" ON) which would
# otherwise write ON into the cache and affect brotli and other deps.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# All static libs that get linked into EryxShared.so must be position-independent.
if(NOT WIN32)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

set(VENDOR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor")

if(ERYX_MODULE_GFX)
    # Build SDL3 from source as a static library
    set(SDL_SHARED OFF CACHE BOOL "" FORCE)
    set(SDL_STATIC ON CACHE BOOL "" FORCE)
    set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
    add_subdirectory("${VENDOR_DIR}/SDL" EXCLUDE_FROM_ALL)

    set(FREETYPE_DIR "${VENDOR_DIR}/freetype")

    include(vendor/wgpu.cmake)

    # Freetype
    # Stop freetype from auto-consuming the zlib/brotli/bzip2 targets we added -
    # those are for our own modules, not for font decompression.
    set(FT_DISABLE_ZLIB   TRUE CACHE BOOL "" FORCE)
    set(FT_DISABLE_BZIP2  TRUE CACHE BOOL "" FORCE)
    set(FT_DISABLE_BROTLI TRUE CACHE BOOL "" FORCE)
    set(FT_DISABLE_PNG    TRUE CACHE BOOL "" FORCE)
    add_subdirectory("${FREETYPE_DIR}")
endif()
if(ERYX_USE_ZLIB)
    set(ZLIB_DIR "${VENDOR_DIR}/zlib")
    add_subdirectory("${ZLIB_DIR}" EXCLUDE_FROM_ALL)
endif()
if(ERYX_USE_XML)
    set(PUGIXML_DIR "${VENDOR_DIR}/pugixml")
    add_subdirectory("${PUGIXML_DIR}" EXCLUDE_FROM_ALL)
endif()
if(ERYX_USE_ZSTD)
    set(ZSTD_DIR "${VENDOR_DIR}/zstd")
    # Force zstd into static mode
    set(ZSTD_BUILD_SHARED   OFF CACHE BOOL "" FORCE)
    set(ZSTD_BUILD_STATIC   ON  CACHE BOOL "" FORCE)
    set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
    set(ZSTD_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
    set(ZSTD_BUILD_CONTRIB  OFF CACHE BOOL "" FORCE)
    add_subdirectory("${ZSTD_DIR}/build/cmake" EXCLUDE_FROM_ALL)
endif()
if(ERYX_USE_BROTLI)
    set(BROTLI_DIR "${VENDOR_DIR}/brotli")
    add_subdirectory("${BROTLI_DIR}" EXCLUDE_FROM_ALL)
endif()
if(ERYX_USE_BZIP2)
    set(BZIP2_DIR "${VENDOR_DIR}/bzip2")
    # Configure BZip2
    set(ENABLE_STATIC_LIB ON)
    set(ENABLE_LIB_ONLY ON)
    add_subdirectory("${BZIP2_DIR}" EXCLUDE_FROM_ALL)
endif()

set(LIBUV_DIR "${VENDOR_DIR}/libuv")
set(MINIZIP_NG_DIR "${VENDOR_DIR}/minizip-ng")

# Set up miniaudio
set(MINIAUDIO_INCLUDE_DIR "${VENDOR_DIR}/miniaudio")

# Lib UV
add_subdirectory("${LIBUV_DIR}" EXCLUDE_FROM_ALL)

include(runtime.cmake)

if (ERYX_USE_ZLIB)
    # minizip-ng: built directly from source against our zlibstatic.
    # We list only the sources we need (platform + zlib deflate + crypto)
    # rather than using their CMakeLists, which would fight us over find_package(ZLIB).

    # Platform-specific sources, compile definitions, and link libraries
    if(WIN32)
        set(_MZ_PLATFORM_SRCS
            "${MINIZIP_NG_DIR}/mz_os_win32.c"
            "${MINIZIP_NG_DIR}/mz_strm_os_win32.c"
            "${MINIZIP_NG_DIR}/mz_crypt_winvista.c"
            "${MINIZIP_NG_DIR}/mz_crypt_winxp.c"
            "${MINIZIP_NG_DIR}/mz_strm_wzaes.c"
        )
        set(_MZ_PLATFORM_DEFS
            _CRT_SECURE_NO_DEPRECATE
            _CRT_NONSTDC_NO_DEPRECATE
            HAVE_BCRYPT
            HAVE_WZAES
            NO_SYMLINK
            NO_READLINK
        )
        set(_MZ_PLATFORM_LIBS bcrypt.lib ncrypt.lib crypt32.lib)
    elseif(APPLE)
        set(_MZ_PLATFORM_SRCS
            "${MINIZIP_NG_DIR}/mz_os_posix.c"
            "${MINIZIP_NG_DIR}/mz_strm_os_posix.c"
            "${MINIZIP_NG_DIR}/mz_crypt_apple.c"
            "${MINIZIP_NG_DIR}/mz_strm_wzaes.c"
        )
        set(_MZ_PLATFORM_DEFS HAVE_WZAES)
        set(_MZ_PLATFORM_LIBS "-framework CoreFoundation" "-framework Security")
    else()
        # Linux: use OpenSSL for AES encryption if available, otherwise omit WZAES
        find_package(OpenSSL QUIET)
        set(_MZ_PLATFORM_SRCS
            "${MINIZIP_NG_DIR}/mz_os_posix.c"
            "${MINIZIP_NG_DIR}/mz_strm_os_posix.c"
        )
        set(_MZ_PLATFORM_DEFS "")
        set(_MZ_PLATFORM_LIBS "")
        if(OPENSSL_FOUND)
            list(APPEND _MZ_PLATFORM_SRCS
                "${MINIZIP_NG_DIR}/mz_crypt_openssl.c"
                "${MINIZIP_NG_DIR}/mz_strm_wzaes.c"
            )
            list(APPEND _MZ_PLATFORM_DEFS HAVE_WZAES)
            list(APPEND _MZ_PLATFORM_LIBS OpenSSL::SSL OpenSSL::Crypto)
        endif()
    endif()

    add_library(minizip-ng STATIC
        "${MINIZIP_NG_DIR}/mz_crypt.c"
        "${MINIZIP_NG_DIR}/mz_os.c"
        "${MINIZIP_NG_DIR}/mz_strm.c"
        "${MINIZIP_NG_DIR}/mz_strm_buf.c"
        "${MINIZIP_NG_DIR}/mz_strm_mem.c"
        "${MINIZIP_NG_DIR}/mz_strm_split.c"
        "${MINIZIP_NG_DIR}/mz_zip.c"
        "${MINIZIP_NG_DIR}/mz_zip_rw.c"
        "${MINIZIP_NG_DIR}/mz_strm_zlib.c"
        "${MINIZIP_NG_DIR}/mz_strm_pkcrypt.c"
        ${_MZ_PLATFORM_SRCS}
    )
    target_include_directories(minizip-ng PUBLIC ${MINIZIP_NG_DIR})
    target_compile_definitions(minizip-ng PRIVATE
        HAVE_STDINT_H
        HAVE_ZLIB
        ZLIB_COMPAT
        HAVE_PKCRYPT
        ${_MZ_PLATFORM_DEFS}
    )
    # PUBLIC so that the zip DLL module transitively gets these when linking minizip-ng
    target_link_libraries(minizip-ng PUBLIC zlibstatic ${_MZ_PLATFORM_LIBS})
endif()

# Setup dyncall
include(vendor/dyncall.cmake)

if(ERYX_USE_CRYPTOGRAPHY)
    include(vendor/mbedtls.cmake)
endif()

# Accumulator lists used in embed mode.  add_luau_module / add_luau_script_module
# append to these; the generated C++ files are created after all modules are declared.
set(ERYX_EMBED_NATIVE_SOURCES  "" CACHE INTERNAL "")
set(ERYX_EMBED_NATIVE_ENTRIES  "" CACHE INTERNAL "")  # "module_path;entrypoint_sym" pairs
set(ERYX_EMBED_NATIVE_INCLUDES "" CACHE INTERNAL "")
set(ERYX_EMBED_NATIVE_LIBS     "" CACHE INTERNAL "")
set(ERYX_EMBED_SCRIPT_ENTRIES  "" CACHE INTERNAL "")  # "module_path;src_file" pairs

# Actually produce the primary Eryx executable
add_executable(eryx src/main.cpp)
set_target_properties(eryx PROPERTIES CXX_STANDARD 23)

target_compile_definitions(eryx PRIVATE LUAU_GIT_HASH="${LUAU_GIT_HASH}")
target_compile_definitions(eryx PRIVATE LUAU_APPROX_VERSION="${LUAU_APPROX_VERSION}")

target_link_libraries(eryx PRIVATE
    EryxShared
    Luau.Compiler
    Luau.Ast
    Luau.Common

    isocline  # Luau provides this for us!
)
if(WIN32)
    target_link_libraries(eryx PRIVATE
        ws2_32.lib
        userenv.lib
        ntdll.lib
        ole32.lib
        oleaut32.lib
    )
endif()

if(NOT ERYX_EMBED OR ERYX_HYBRID)
    # Import Luau symbols from EryxShared DLL
    # (In hybrid mode EryxShared is still a shared library)
    if(WIN32)
        target_compile_definitions(eryx PRIVATE "LUA_API=extern \"C\" __declspec(dllimport)")
        target_compile_definitions(eryx PRIVATE "LUAI_FUNC=extern \"C\" __declspec(dllimport)")
        target_compile_definitions(eryx PRIVATE "LUACODEGEN_API=extern \"C\" __declspec(dllimport)")
    else()
        target_compile_definitions(eryx PRIVATE "LUA_API=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(eryx PRIVATE "LUAI_FUNC=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(eryx PRIVATE "LUACODEGEN_API=extern \"C\" __attribute__((visibility(\"default\")))")
    endif()
endif()

# Add includes for all our libraries
target_include_directories(eryx PRIVATE
    "${LUAU_DIR}/VM/include"
    "${LUAU_DIR}/Compiler/include"
    "${LUAU_DIR}/CodeGen/include"
    "${LUAU_DIR}/Config/include"
    "${LUAU_DIR}/Common/include"
    "${VENDOR_DIR}"
)

# ---------------------------------------------------------------------------
# Copy built-in scripts to scripts/ next to the eryx executable
file(GLOB ERYX_SCRIPTS "${CMAKE_CURRENT_SOURCE_DIR}/src/scripts/*.luau")
foreach(_script ${ERYX_SCRIPTS})
    get_filename_component(_fname "${_script}" NAME)
    add_custom_command(TARGET eryx POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:eryx>/scripts"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_script}" "$<TARGET_FILE_DIR:eryx>/scripts/${_fname}"
        COMMENT "Copying ${_fname} to scripts/"
    )
endforeach()

# ---------------------------------------------------------------------------
# add_luau_module(<name> <source_file> <types_file> [EXTRA_SOURCES ...] [EXTRA_INCLUDES ...] [EXTRA_LIBS ...])
#
# Builds a native Luau module as a shared library (DLL) and copies both
# the DLL and its type definition file into modules/ next to the
# main eryx executable after every build.
#
# <name> may contain slashes for subdirectories (e.g. "time/foo").
#
# The module automatically gets:
#   - Luau VM headers
#   - The lightweight module_api.h header
#   - The LUAU_GIT_HASH definition
#   - C++23 standard
# ---------------------------------------------------------------------------
function(add_luau_module MODULE_NAME SOURCE_FILE TYPES_FILE)
    cmake_parse_arguments(MOD "" "ENTRYPOINT" "EXTRA_SOURCES;EXTRA_INCLUDES;EXTRA_LIBS" ${ARGN})

    # Use a sanitised target name (replace / with _) since CMake targets can't have slashes
    string(REPLACE "/" "_" TARGET_NAME "mod_${MODULE_NAME}")

    # ---- Embed/hybrid mode: accumulate sources/info for the eryx target ----
    if(ERYX_EMBED_MODULES)
        # Collect all C++ sources (handle both relative and absolute paths)
        set(_all_srcs "${CMAKE_CURRENT_SOURCE_DIR}/${SOURCE_FILE}")
        foreach(_extra ${MOD_EXTRA_SOURCES})
            if(IS_ABSOLUTE "${_extra}")
                list(APPEND _all_srcs "${_extra}")
            else()
                list(APPEND _all_srcs "${CMAKE_CURRENT_SOURCE_DIR}/${_extra}")
            endif()
        endforeach()
        set(ERYX_EMBED_NATIVE_SOURCES ${ERYX_EMBED_NATIVE_SOURCES} ${_all_srcs} CACHE INTERNAL "")

        # Collect extra include dirs
        if(MOD_EXTRA_INCLUDES)
            set(ERYX_EMBED_NATIVE_INCLUDES ${ERYX_EMBED_NATIVE_INCLUDES} ${MOD_EXTRA_INCLUDES} CACHE INTERNAL "")
        endif()

        # Collect extra link libs
        if(MOD_EXTRA_LIBS)
            set(ERYX_EMBED_NATIVE_LIBS ${ERYX_EMBED_NATIVE_LIBS} ${MOD_EXTRA_LIBS} CACHE INTERNAL "")
        endif()

        # Record the module path -> entrypoint mapping.
        # The ENTRYPOINT argument is required in embed mode; fall back to the
        # INFO.entry convention (luauopen_<basename>) if not given.
        if(MOD_ENTRYPOINT)
            set(_entry "${MOD_ENTRYPOINT}")
        else()
            get_filename_component(_bn "${MODULE_NAME}" NAME)
            # Strip leading underscore for the open name (matches existing convention)
            set(_entry "luauopen_${_bn}")
        endif()

        # modules/<MODULE_NAME> is how require() will resolve the path
        set(ERYX_EMBED_NATIVE_ENTRIES ${ERYX_EMBED_NATIVE_ENTRIES} "${MODULE_NAME}|${_entry}" CACHE INTERNAL "")

        return()
    endif()
    # ---- Normal (DLL) mode ------------------------------------------------

    # Work out the output subdirectory and base filename from MODULE_NAME
    get_filename_component(MOD_SUBDIR "${MODULE_NAME}" DIRECTORY)
    get_filename_component(MOD_BASENAME "${MODULE_NAME}" NAME)

    add_library(${TARGET_NAME} SHARED ${SOURCE_FILE} ${MOD_EXTRA_SOURCES})
    set_target_properties(${TARGET_NAME} PROPERTIES CXX_STANDARD 23 OUTPUT_NAME "${MOD_BASENAME}")
    if(WIN32)
        set_target_properties(${TARGET_NAME} PROPERTIES PREFIX "")
    endif()

    target_include_directories(${TARGET_NAME} PRIVATE
        "${LUAU_DIR}/VM/include"
        "${LUAU_DIR}/Common/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/src/modules"
        "${LIBUV_DIR}/include"
    )
    if(MOD_EXTRA_INCLUDES)
        target_include_directories(${TARGET_NAME} PRIVATE ${MOD_EXTRA_INCLUDES})
    endif()

    target_compile_definitions(${TARGET_NAME} PRIVATE
        LUAU_GIT_HASH="${LUAU_GIT_HASH}"
        LUAU_APPROX_VERSION="${LUAU_APPROX_VERSION}"
    )

    # Dynamically link the shared runtime dll (VM)
    target_link_libraries(${TARGET_NAME} PRIVATE EryxShared)
    # Configure APIs exposed by EryxShared as imports
    if(WIN32)
        target_compile_definitions(${TARGET_NAME} PRIVATE "LUA_API=extern \"C\" __declspec(dllimport)")
        target_compile_definitions(${TARGET_NAME} PRIVATE "LUACODE_API=extern \"C\" __declspec(dllimport)")
        target_compile_definitions(${TARGET_NAME} PRIVATE "LUACODEGEN_API=extern \"C\" __declspec(dllimport)")
    else()
        target_compile_definitions(${TARGET_NAME} PRIVATE "LUA_API=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(${TARGET_NAME} PRIVATE "LUACODE_API=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(${TARGET_NAME} PRIVATE "LUACODEGEN_API=extern \"C\" __attribute__((visibility(\"default\")))")
    endif()
    # Statically link the rest of Luau
    target_link_libraries(${TARGET_NAME} PRIVATE
        Luau.Compiler
        Luau.Common
        Luau.Ast
    )

    if(MOD_EXTRA_LIBS)
        target_link_libraries(${TARGET_NAME} PRIVATE ${MOD_EXTRA_LIBS})
    endif()

    set(MOD_OUTPUT_DIR "$<TARGET_FILE_DIR:eryx>/modules")
    if(NOT "${MOD_SUBDIR}" STREQUAL "")
        set(MOD_OUTPUT_DIR "${MOD_OUTPUT_DIR}/${MOD_SUBDIR}")
    endif()

    # Copy the shared module into modules/ next to eryx (POST_BUILD to allow generator expressions)
    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${MOD_OUTPUT_DIR}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:${TARGET_NAME}>
            "${MOD_OUTPUT_DIR}/$<TARGET_FILE_NAME:${TARGET_NAME}>"
        COMMENT "Copying ${MODULE_NAME} module to modules/"
    )

    # Copy the type definition, re-running only when the .luau source file changes.
    # OUTPUT uses a stamp in the binary dir because MOD_OUTPUT_DIR contains a
    # generator expression which is not allowed in add_custom_command OUTPUT.
    set(_luau_src "${CMAKE_CURRENT_SOURCE_DIR}/${TYPES_FILE}")
    set(_luau_stamp "${CMAKE_CURRENT_BINARY_DIR}/stamps/${TARGET_NAME}_luau.stamp")
    add_custom_command(
        OUTPUT "${_luau_stamp}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/stamps"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${MOD_OUTPUT_DIR}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_luau_src}" "${MOD_OUTPUT_DIR}/${MOD_BASENAME}.luau"
        COMMAND ${CMAKE_COMMAND} -E touch "${_luau_stamp}"
        DEPENDS "${_luau_src}"
        COMMENT "Copying ${MODULE_NAME} types to modules/"
    )
    add_custom_target(${TARGET_NAME}_luau DEPENDS "${_luau_stamp}")
    add_dependencies(${TARGET_NAME} ${TARGET_NAME}_luau)
endfunction()

# ---------------------------------------------------------------------------
# add_luau_script_module(<name> <luau_files>...)
#
# Copies one or more .luau files into modules/ next to the main executable.
# The first file is the module entry point.  <name> may contain slashes for
# subdirectories (e.g. "time/utils").
#
# Examples:
#   add_luau_script_module(helpers src/modules/helpers.luau)
#   add_luau_script_module(time/utils
#       src/modules/time/utils.luau
#       src/modules/time/constants.luau
#   )
# ---------------------------------------------------------------------------
function(add_luau_script_module MODULE_NAME)
    set(LUAU_FILES ${ARGN})
    list(LENGTH LUAU_FILES FILE_COUNT)
    if(FILE_COUNT LESS 1)
        message(FATAL_ERROR "add_luau_script_module(${MODULE_NAME}) requires at least one .luau file")
    endif()

    # Detect folder-style module (trailing slash means "copy files into this directory")
    string(REGEX MATCH "/$" _IS_FOLDER "${MODULE_NAME}")
    if(_IS_FOLDER)
        string(REGEX REPLACE "/$" "" MODULE_NAME "${MODULE_NAME}")
    endif()

    # ---- Embed/hybrid mode: record source files for bundling ----------------
    if(ERYX_EMBED_MODULES)
        foreach(LUAU_FILE ${LUAU_FILES})
            get_filename_component(FNAME "${LUAU_FILE}" NAME)
            if(_IS_FOLDER)
                set(_mod_path "${MODULE_NAME}/${FNAME}")
            else()
                get_filename_component(_subdir "${MODULE_NAME}" DIRECTORY)
                if(NOT "${_subdir}" STREQUAL "")
                    set(_mod_path "${_subdir}/${FNAME}")
                else()
                    set(_mod_path "${FNAME}")
                endif()
            endif()
            # Strip .luau extension from the key so it matches require() paths
            string(REGEX REPLACE "\\.luau$" "" _mod_key "${_mod_path}")
            set(ERYX_EMBED_SCRIPT_ENTRIES ${ERYX_EMBED_SCRIPT_ENTRIES}
                "${_mod_key}|${CMAKE_CURRENT_SOURCE_DIR}/${LUAU_FILE}" CACHE INTERNAL "")
        endforeach()
        return()
    endif()
    # ---- Normal mode -------------------------------------------------------

    string(REPLACE "/" "_" TARGET_NAME "luamod_${MODULE_NAME}")

    # Work out output subdirectory
    set(MOD_OUTPUT_DIR "$<TARGET_FILE_DIR:eryx>/modules")
    if(_IS_FOLDER)
        # Folder module: the entire (stripped) name is the subdirectory
        set(MOD_OUTPUT_DIR "${MOD_OUTPUT_DIR}/${MODULE_NAME}")
    else()
        # File module: only the directory component is the subdirectory
        get_filename_component(MOD_SUBDIR "${MODULE_NAME}" DIRECTORY)
        if(NOT "${MOD_SUBDIR}" STREQUAL "")
            set(MOD_OUTPUT_DIR "${MOD_OUTPUT_DIR}/${MOD_SUBDIR}")
        endif()
    endif()

    # Per-file OUTPUT-tracked copy commands so files are only re-copied when changed.
    # Stamp files in the binary dir are used because MOD_OUTPUT_DIR contains a
    # generator expression which is not allowed in add_custom_command OUTPUT.
    set(_stamp_dir "${CMAKE_CURRENT_BINARY_DIR}/stamps/${TARGET_NAME}")
    set(_stamp_files)
    foreach(LUAU_FILE ${LUAU_FILES})
        get_filename_component(FNAME "${LUAU_FILE}" NAME)
        set(_stamp "${_stamp_dir}/${FNAME}.stamp")
        add_custom_command(
            OUTPUT "${_stamp}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${_stamp_dir}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${MOD_OUTPUT_DIR}"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${CMAKE_CURRENT_SOURCE_DIR}/${LUAU_FILE}"
                "${MOD_OUTPUT_DIR}/${FNAME}"
            COMMAND ${CMAKE_COMMAND} -E touch "${_stamp}"
            DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${LUAU_FILE}"
            COMMENT "Copying ${LUAU_FILE} to modules/"
        )
        list(APPEND _stamp_files "${_stamp}")
    endforeach()

    add_custom_target(${TARGET_NAME} ALL DEPENDS ${_stamp_files})

    add_dependencies(eryx ${TARGET_NAME})
endfunction()

include(modules_native.cmake)
include(modules_script.cmake)

# ---------------------------------------------------------------------------
# Embed/hybrid-mode code generation
# ---------------------------------------------------------------------------
if(ERYX_EMBED_MODULES)
    set(EMBED_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
    file(MAKE_DIRECTORY "${EMBED_GEN_DIR}")

    # -- 1. embedded_modules.cpp  (null-terminated entrypoint table) ---------
    set(_em_content "// Auto-generated by CMake -- do not edit\n")
    string(APPEND _em_content "#include \"runtime/embedded_modules.h\"\n")
    string(APPEND _em_content "#include \"lua.h\"\n\n")

    # Forward-declare every entrypoint
    foreach(_entry ${ERYX_EMBED_NATIVE_ENTRIES})
        string(REPLACE "|" ";" _parts "${_entry}")
        list(GET _parts 1 _sym)
        string(APPEND _em_content "extern \"C\" int ${_sym}(lua_State* L);\n")
    endforeach()

    string(APPEND _em_content "\nextern const EmbeddedNativeModule g_embedded_native_modules[] = {\n")
    foreach(_entry ${ERYX_EMBED_NATIVE_ENTRIES})
        string(REPLACE "|" ";" _parts "${_entry}")
        list(GET _parts 0 _path)
        list(GET _parts 1 _sym)
        string(APPEND _em_content "    { \"${_path}\", ${_sym} },\n")
    endforeach()
    string(APPEND _em_content "    { nullptr, nullptr },\n")
    string(APPEND _em_content "};\n")

    file(WRITE "${EMBED_GEN_DIR}/embedded_modules.cpp" "${_em_content}")

    # -- 2. embedded_sources.cpp  (source-code lookup table) -----------------
    set(_es_content "// Auto-generated by CMake -- do not edit\n")
    string(APPEND _es_content "#include \"runtime/embedded_modules.h\"\n\n")

    # Read each script file and emit it as concatenated raw string chunks.
    # MSVC has a 16,380-char limit per string literal (C2026), so we split
    # into ~14,000-char chunks joined by implicit string literal concatenation.
    # We use string(SUBSTRING) instead of line splitting to avoid CMake's
    # semicolon list-separator mangling the source content.
    set(_CHUNK_LIMIT 14000)
    set(_es_idx 0)
    foreach(_entry ${ERYX_EMBED_SCRIPT_ENTRIES})
        string(REPLACE "|" ";" _parts "${_entry}")
        list(GET _parts 1 _src_file)
        file(READ "${_src_file}" _file_contents)

        string(LENGTH "${_file_contents}" _total_len)
        if(_total_len LESS_EQUAL ${_CHUNK_LIMIT})
            # Small enough for a single literal
            string(APPEND _es_content "static const char s_src_${_es_idx}[] = R\"SRCDELIM(${_file_contents})SRCDELIM\";\n\n")
        else()
            # Split into fixed-size substring chunks
            string(APPEND _es_content "static const char s_src_${_es_idx}[] =\n")
            set(_offset 0)
            while(_offset LESS _total_len)
                math(EXPR _remaining "${_total_len} - ${_offset}")
                if(_remaining LESS_EQUAL ${_CHUNK_LIMIT})
                    set(_chunk_len ${_remaining})
                else()
                    set(_chunk_len ${_CHUNK_LIMIT})
                endif()
                string(SUBSTRING "${_file_contents}" ${_offset} ${_chunk_len} _chunk)
                string(APPEND _es_content "    R\"SRCDELIM(${_chunk})SRCDELIM\"\n")
                math(EXPR _offset "${_offset} + ${_chunk_len}")
            endwhile()
            string(APPEND _es_content ";\n\n")
        endif()
        math(EXPR _es_idx "${_es_idx} + 1")
    endforeach()

    string(APPEND _es_content "extern const EmbeddedScriptModule g_embedded_script_modules[] = {\n")
    set(_es_idx 0)
    foreach(_entry ${ERYX_EMBED_SCRIPT_ENTRIES})
        string(REPLACE "|" ";" _parts "${_entry}")
        list(GET _parts 0 _path)
        string(APPEND _es_content "    { \"${_path}\", s_src_${_es_idx} },\n")
        math(EXPR _es_idx "${_es_idx} + 1")
    endforeach()
    string(APPEND _es_content "    { nullptr, nullptr },\n")
    string(APPEND _es_content "};\n")

    file(WRITE "${EMBED_GEN_DIR}/embedded_sources.cpp" "${_es_content}")

    # -- 3. Add generated files + all module sources to eryx -----------------
    target_sources(eryx PRIVATE
        "${EMBED_GEN_DIR}/embedded_modules.cpp"
        "${EMBED_GEN_DIR}/embedded_sources.cpp"
        ${ERYX_EMBED_NATIVE_SOURCES}
    )
    target_include_directories(eryx PRIVATE
        ${EMBED_GEN_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src/modules
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${ERYX_EMBED_NATIVE_INCLUDES}
    )
    target_link_libraries(eryx PRIVATE ${ERYX_EMBED_NATIVE_LIBS})
    target_compile_definitions(eryx PRIVATE ERYX_EMBED=1 MA_ENABLE_VORBIS)
    if(ERYX_HYBRID)
        target_compile_definitions(eryx PRIVATE ERYX_HYBRID=1)
    endif()
endif()
