#pragma once

#include <deque>
#include <unordered_map>

#include "../pch.hpp"
#include "Luau/CodeGen.h"
#include "lua.h"
#include "lualib.h"

typedef struct {
    int threadRef;
    int nargs;
    bool inError;
} EryxThreadInfo;

typedef void (*EryxInterruptCallback)(struct EryxRuntime* rt, void* ctx);
typedef struct EryxRuntime {
    lua_State* GL;  // main thread (for deref'ing refs in timer callbacks)
    uv_loop_t* loop;

    std::deque<EryxThreadInfo> threads;
    std::unordered_map<int, uv_timer_t*> pendingTimers;  // threadRef -> timer (for cancel)
    uv_signal_t* sigint;                                 // optional signal handle for interrupt
    std::vector<std::pair<EryxInterruptCallback, void*>> interruptCallbacks;
} EryxRuntime;
static EryxRuntime* eryx_get_runtime(lua_State* L) {
    auto rt = (EryxRuntime*)lua_getthreaddata(lua_mainthread(L));
    if (!rt) {
        luaL_error(L, "Failed to identify runtime");
    }
    return rt;
}

ERYX_API bool lua_codegen_isSupported();
ERYX_API void lua_codegen_create(lua_State* L);

ERYX_API Luau::CodeGen::CodeGenCompilationResult lua_codegen_compile(
    lua_State* L, int idx, unsigned int flags, Luau::CodeGen::CompilationStats* stats);

ERYX_API EryxRuntime* eryx_setup_runtime(uv_loop_t* loop, lua_State* GL);
ERYX_API void eryx_push_thread(EryxRuntime* rt, int ref, int nargs, bool inError);
ERYX_API EryxThreadInfo eryx_pop_thread(EryxRuntime* rt);
ERYX_API bool eryx_cancel_thread(EryxRuntime* rt, lua_State* GL, lua_State* thread);
ERYX_API void eryx_interrupt_runtime(EryxRuntime* rt);
ERYX_API void eryx_register_interrupt_callback(EryxRuntime* rt, EryxInterruptCallback cb,
                                               void* ctx);
ERYX_API void eryx_unregister_interrupt_callback(EryxRuntime* rt, EryxInterruptCallback cb,
                                                 void* ctx);

// Luau Analysis wrappers (lua_CFunction implementations living in LuauShared)
ERYX_API int eryx_luau_check(lua_State* L);
ERYX_API int eryx_luau_typeAt(lua_State* L);
ERYX_API int eryx_luau_autocomplete(lua_State* L);

// CLI args offset: number of leading argv entries to skip in os.cliargs()
// (exe, subcommand, script path, etc.). Set by main() before script execution
// so Luau code only sees user arguments.
ERYX_API void eryx_set_cliargs_offset(int offset);
ERYX_API int eryx_get_cliargs_offset();
ERYX_API void eryx_set_cliargs(int argc, const char** argv);
ERYX_API int eryx_get_cliargs_argc();
ERYX_API const char** eryx_get_cliargs_argv();

ERYX_API lua_State* eryx_initialise_environment(const char* sourceFilename);
