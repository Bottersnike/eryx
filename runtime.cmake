set(LUAU_BUILD_CLI OFF)
set(LUAU_BUILD_TESTS OFF)

set(LUAU_EXTERN_C ON)
set(LUAU_BUILD_SHARED OFF)

include(FetchContent)

FetchContent_Declare(
    luau
    GIT_REPOSITORY https://github.com/luau-lang/luau.git
    GIT_TAG 0.712
    PATCH_COMMAND ${CMAKE_COMMAND} -DPATCH_FILE=${CMAKE_SOURCE_DIR}/vendor/luau.diff -P ${CMAKE_SOURCE_DIR}/vendor/apply_patch.cmake
)

FetchContent_MakeAvailable(luau)

set(LUAU_DIR ${luau_SOURCE_DIR})

# Inject luau git hash
find_package(Git REQUIRED)
execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse HEAD
    WORKING_DIRECTORY ${LUAU_DIR}
    RESULT_VARIABLE LUAU_GIT_HASH_RESULT
    OUTPUT_VARIABLE LUAU_GIT_HASH
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
    COMMAND ${GIT_EXECUTABLE} describe --tags
    WORKING_DIRECTORY ${LUAU_DIR}
    RESULT_VARIABLE LUAU_APPROX_VERSION_RESULT
    OUTPUT_VARIABLE LUAU_APPROX_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(NOT LUAU_GIT_HASH_RESULT EQUAL 0)
    set(LUAU_GIT_HASH "unknown")
endif()
if(NOT LUAU_APPROX_VERSION_RESULT EQUAL 0)
    set(LUAU_APPROX_VERSION "unknown")
endif()

# In shared mode (normal or hybrid), Luau symbols must be dllexported so
# EryxShared can re-export them.  In full-embed mode this is unnecessary.
if(ERYX_EMBED AND NOT ERYX_HYBRID)
    set(_ERYX_LIB_TYPE STATIC)
    set(_ERYX_LINK_VISIBILITY PUBLIC)

    target_compile_definitions(Luau.VM PRIVATE "LUAI_FUNC=")
    target_compile_definitions(Luau.VM PRIVATE "LUAI_DATA=extern")
    # target_compile_definitions(Luau.CodeGen PRIVATE "LUAI_FUNC=extern \"C\"")
else()
    set(_ERYX_LIB_TYPE SHARED)
    set(_ERYX_LINK_VISIBILITY PRIVATE)

    if(WIN32)
        target_compile_definitions(Luau.VM PRIVATE "LUA_API=extern \"C\" __declspec(dllexport)")
        target_compile_definitions(Luau.VM PRIVATE "LUAI_FUNC=extern \"C\" __declspec(dllexport)")
        target_compile_definitions(Luau.CodeGen PRIVATE "LUACODEGEN_API=extern \"C\" __declspec(dllexport)")
        target_compile_definitions(Luau.CodeGen PRIVATE "LUAI_FUNC=extern \"C\" __declspec(dllexport)")
        target_compile_definitions(uv_a PRIVATE "UV_EXTERN=__declspec(dllexport)")
    else()
        target_compile_definitions(Luau.VM PRIVATE "LUA_API=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(Luau.VM PRIVATE "LUAI_FUNC=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(Luau.CodeGen PRIVATE "LUACODEGEN_API=extern \"C\" __attribute__((visibility(\"default\")))")
        target_compile_definitions(Luau.CodeGen PRIVATE "LUAI_FUNC=extern \"C\" __attribute__((visibility(\"default\")))")
    endif()
endif()

add_library(EryxShared ${_ERYX_LIB_TYPE}
    src/runtime/_wrapper_lib.cpp
    src/runtime/lexception.cpp
    src/runtime/lconfig.cpp
    src/runtime/lrequire.cpp
    src/runtime/lresolve.cpp
    src/runtime/lprint.cpp
    src/runtime/embedded_registry.cpp

    src/vfs.cpp  # So lexception can resolve VFS files
)
set_target_properties(EryxShared PROPERTIES CXX_STANDARD 23)

# PUBLIC in static mode so consumers transitively get Luau libs.
# PRIVATE in shared mode (WHOLEARCHIVE re-exports everything).
target_link_libraries(EryxShared ${_ERYX_LINK_VISIBILITY}
    Luau.VM
    Luau.CodeGen
    Luau.Config
    Luau.Analysis
    Luau.Compiler
    Luau.Ast
    Luau.Common
    uv_a
)

target_include_directories(EryxShared INTERFACE
    ${LUAU_DIR}/VM/include
    ${LUAU_DIR}/CodeGen/include
    ${LUAU_DIR}/Analysis/include
    ${LUAU_DIR}/Config/include
    ${LIBUV_DIR}/include
)
# lexception.cpp needs VM-internal headers (lstate.h, ldo.h, etc.)
target_include_directories(EryxShared PRIVATE
    ${LUAU_DIR}/VM/src
    ${LUAU_DIR}/Config/include
)

target_compile_definitions(EryxShared PRIVATE
    LUAU_GIT_HASH="${LUAU_GIT_HASH}"
    LUAU_APPROX_VERSION="${LUAU_APPROX_VERSION}"
)

if(NOT ERYX_EMBED OR ERYX_HYBRID)
    # Shared mode (normal or hybrid): re-export all Luau/libuv symbols
    if(WIN32)
        target_link_options(EryxShared PRIVATE
            "/WHOLEARCHIVE:$<TARGET_FILE:Luau.VM>"
            "/WHOLEARCHIVE:$<TARGET_FILE:Luau.CodeGen>"
            "/WHOLEARCHIVE:$<TARGET_FILE:Luau.Config>"
            "/WHOLEARCHIVE:$<TARGET_FILE:Luau.Analysis>"
            "/WHOLEARCHIVE:$<TARGET_FILE:uv_a>"
        )
        set_target_properties(EryxShared PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    elseif(APPLE)
        target_link_options(EryxShared PRIVATE
            "-Wl,-force_load,$<TARGET_FILE:Luau.VM>"
            "-Wl,-force_load,$<TARGET_FILE:Luau.CodeGen>"
            "-Wl,-force_load,$<TARGET_FILE:Luau.Config>"
            "-Wl,-force_load,$<TARGET_FILE:Luau.Analysis>"
            "-Wl,-force_load,$<TARGET_FILE:uv_a>"
        )
    else()
        target_link_options(EryxShared PRIVATE
            "-Wl,--whole-archive"
            "$<TARGET_FILE:Luau.VM>"
            "$<TARGET_FILE:Luau.CodeGen>"
            "$<TARGET_FILE:Luau.Config>"
            "$<TARGET_FILE:Luau.Analysis>"
            "$<TARGET_FILE:uv_a>"
            "-Wl,--no-whole-archive"
        )
    endif()
else()
    # Full embed: EryxShared is static, compiled with ERYX_EMBED
    target_compile_definitions(EryxShared PRIVATE ERYX_EMBED=1)
endif()
