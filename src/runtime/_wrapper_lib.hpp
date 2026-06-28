#pragma once

#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#include "../pch.hpp"
#include "Luau/CodeGen.h"
#include "Luau/ExperimentalFlags.h"
#include "lua.h"
#include "lualib.h"

typedef struct {
    int threadRef;
    int nargs;
    bool inError;
} EryxThreadInfo;

typedef void (*EryxInterruptCallback)(struct EryxRuntime* rt, void* ctx);
typedef void (*EryxDebugFunctionLoadedCallback)(lua_State* L, int funcIndex, const char* chunkName,
                                                void* ctx);

enum class EryxNativeCodegenMode {
    Disabled,
    All,
    OnlySpecified,
};

typedef struct EryxRuntime {
    lua_State* GL;  // main thread (for deref'ing refs in timer callbacks)
    uv_loop_t* loop;

    std::deque<EryxThreadInfo> threads;
    std::unordered_map<int, uv_timer_t*> pendingTimers;  // threadRef -> timer (for cancel)
    uv_signal_t* sigint;                                 // optional signal handle for interrupt
    uv_async_t* interruptAsync;                          // cross-thread process interrupt wakeup
    std::vector<std::pair<EryxInterruptCallback, void*>> interruptCallbacks;
    std::atomic_bool interruptRequested = false;

    bool hasCliArgs = false;
    std::vector<std::string> cliArgs;

    EryxNativeCodegenMode nativeCodegenMode = EryxNativeCodegenMode::All;
    int luauOptimizationLevel = 2;
    int luauDebugLevel = 1;
    int luauTypeInfoLevel = 1;

    EryxDebugFunctionLoadedCallback debugFunctionLoaded = nullptr;
    void* debugFunctionLoadedContext = nullptr;
} EryxRuntime;

enum class EryxPrintColorMode {
    Auto,
    Always,
    Never,
};

typedef struct EryxPrintConfig {
    int indentation = 4;
    bool multiline = true;
    bool multilineStrings = true;
    EryxPrintColorMode color = EryxPrintColorMode::Auto;
    int maxEntries = -1;  // -1 = unlimited
    int maxDepth = -1;    // -1 = unlimited
    bool showMetatables = true;
    bool indentGuides = false;
    bool showFrozen = true;
} EryxPrintConfig;

static EryxRuntime* eryx_get_runtime(lua_State* L) {
    auto rt = (EryxRuntime*)lua_getthreaddata(lua_mainthread(L));
    if (!rt) {
        luaL_error(L, "Failed to identify runtime");
    }
    return rt;
}

ERYX_API bool lua_codegen_isSupported();
ERYX_API void lua_codegen_create(lua_State* L);
ERYX_API void eryx_request_process_interrupt();
ERYX_API int eryx_configure_print(lua_State* L);

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
ERYX_API int eryx_pcall(lua_State* L, int nargs, int nresults, int errfunc);
ERYX_API void eryx_shutdown_runtime(EryxRuntime* rt);

// Luau Analysis wrappers (lua_CFunction implementations living in LuauShared)
ERYX_API int eryx_luau_check(lua_State* L);
ERYX_API int eryx_luau_typeAt(lua_State* L);
ERYX_API int eryx_luau_autocomplete(lua_State* L);
ERYX_API int eryx_luau_typeofModule(lua_State* L);

ERYX_API lua_State* eryx_initialise_environment(const char* sourceFilename);

// Debug helpers that need VM-private stack/proto access. Native modules call
// these through EryxShared instead of including VM internals directly.
ERYX_API int eryx_debug_register_count(lua_State* L, int frameLevel);
ERYX_API int eryx_debug_get_register(lua_State* L, int frameLevel, int reg);
ERYX_API const char* eryx_debug_get_register_local_name(lua_State* L, int frameLevel, int reg);
ERYX_API int eryx_debug_currentpc(lua_State* L, int frameLevel);
ERYX_API int eryx_debug_current_instructionpc(lua_State* L, int frameLevel);
// Paused threads resumed from debugger hooks need temporary stack/base normalization
// before stack-indexed VM helpers such as lua_getlocal/lua_pushvalue are safe to use.
struct EryxDebugPausedState {
    int status = 0;
    ptrdiff_t baseOffset = 0;
    ptrdiff_t ciTopOffset = 0;
    bool active = false;
};
ERYX_API bool eryx_debug_begin_paused_state(lua_State* L, EryxDebugPausedState* state);
ERYX_API void eryx_debug_end_paused_state(lua_State* L, const EryxDebugPausedState* state);
ERYX_API bool eryx_prepare_thread_entry_function(lua_State* L, int idx, std::string& bytecode,
                                                 std::string& chunkName, std::string& error);

// This function isn't going to be imported from our shared DLL, because
// the compiler runs in individual threads, which each need their own
// flags set!
static void eryx_enable_all_luau_flags() {
    for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next) {
        if (strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name))
            flag->value = true;
        else if (strcmp(flag->name, "DebugLuauUserDefinedClasses") == 0 ||
                 strcmp(flag->name, "DebugLuauUserDefinedClassesRuntime") == 0)
            flag->value = true;
    }
}

static bool eryx_set_luau_flag(const char* name, bool value) {
    for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next) {
        if (strcmp(flag->name, name) == 0) {
            flag->value = value;
            return true;
        }
    }
    return false;
}

static bool eryx_set_luau_flag(const char* name, int value) {
    for (Luau::FValue<int>* flag = Luau::FValue<int>::list; flag; flag = flag->next) {
        if (strcmp(flag->name, name) == 0) {
            flag->value = value;
            return true;
        }
    }
    return false;
}

// Parses a string value as bool ("true"/"false") or integer and sets the named flag.
static bool eryx_apply_flag_string(const char* name, const char* value) {
    if (strcmp(value, "true") == 0) return eryx_set_luau_flag(name, true);
    if (strcmp(value, "false") == 0) return eryx_set_luau_flag(name, false);
    char* end;
    long n = strtol(value, &end, 10);
    if (end != value && *end == '\0') return eryx_set_luau_flag(name, (int)n);
    return false;
}

// Reads options.flags = { Name = bool|number|string } and applies each flag.
// optIdx is the stack index of the options table; silently does nothing if absent.
static void eryx_apply_user_flags_opt(lua_State* L, int optIdx) {
    if (!lua_istable(L, optIdx)) return;
    lua_getfield(L, optIdx, "flags");
    if (lua_istable(L, -1)) {
        int tableIdx = lua_gettop(L);
        lua_pushnil(L);
        while (lua_next(L, tableIdx) != 0) {
            if (lua_isstring(L, -2)) {
                const char* name = lua_tostring(L, -2);
                if (lua_isboolean(L, -1))
                    eryx_set_luau_flag(name, lua_toboolean(L, -1) != 0);
                else if (lua_isnumber(L, -1))
                    eryx_set_luau_flag(name, (int)lua_tointeger(L, -1));
                else if (lua_isstring(L, -1))
                    eryx_apply_flag_string(name, lua_tostring(L, -1));
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}
