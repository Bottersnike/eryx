# set(dyncall_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/dyncall-1.4")
include(FetchContent)
FetchContent_Declare(
    dyncall
    URL https://dyncall.org/r1.4/dyncall-1.4.zip
)
FetchContent_GetProperties(dyncall)
FetchContent_Populate(dyncall)
if(WIN32)
    enable_language(ASM_MASM)
    set(_DYNCALL_ASM_SRC "${dyncall_SOURCE_DIR}/dyncall/dyncall_call_x64_generic_masm.asm")
else()
    enable_language(ASM)
    set(_DYNCALL_ASM_SRC "${dyncall_SOURCE_DIR}/dyncall/dyncall_call_x64.S")
endif()
set(DYNCALL_SRCS
    # For now we just support x64, so that's all we pull in
    "${dyncall_SOURCE_DIR}/dyncall/dyncall_api.c"
    "${dyncall_SOURCE_DIR}/dyncall/dyncall_callf.c"
    "${dyncall_SOURCE_DIR}/dyncall/dyncall_callvm_base.c"
    "${dyncall_SOURCE_DIR}/dyncall/dyncall_callvm.c"
    "${dyncall_SOURCE_DIR}/dyncall/dyncall_callvm_x64.c"
    "${dyncall_SOURCE_DIR}/dyncall/dyncall_vector.c"
    "${_DYNCALL_ASM_SRC}"
)
add_library(dyncall STATIC ${DYNCALL_SRCS})
target_include_directories(dyncall PUBLIC "${dyncall_SOURCE_DIR}/dyncall")
