#pragma once

#include <string>

#include "_wrapper_lib.hpp"

enum class EryxRuntimeRunResult {
    NoWork,
    Error,
    Success,
};

enum class EryxRuntimeEntryKind {
    File,
    Source,
    Bytecode,
};

struct EryxRuntimeEntry {
    EryxRuntimeEntryKind kind = EryxRuntimeEntryKind::File;
    std::string program;
    std::string chunkName;
    std::string source;
    std::string bytecode;
};

enum class EryxRuntimeHookResult {
    Continue,
    Stop,
    Fail,
};

struct EryxRuntimeHost {
    lua_State* GL = nullptr;
    EryxRuntime* rt = nullptr;
    uv_loop_t loop = {};
    bool loopInitialized = false;
};

using EryxRuntimeAfterInitHook = EryxRuntimeHookResult (*)(EryxRuntimeHost* host, void* userdata,
                                                           std::string& error);
using EryxRuntimeAfterLoadHook = EryxRuntimeHookResult (*)(EryxRuntimeHost* host,
                                                           lua_State* rootThread, int* rootArgCount,
                                                           void* userdata, std::string& error);
using EryxRuntimeTickHook = EryxRuntimeHookResult (*)(EryxRuntimeHost* host, lua_State* rootThread,
                                                      void* userdata, std::string& error);
using EryxRuntimeErrorHook = EryxRuntimeHookResult (*)(EryxRuntimeHost* host, lua_State* rootThread,
                                                       lua_State* runningLua, void* userdata,
                                                       std::string& error);
using EryxRuntimeCleanupHook = void (*)(EryxRuntimeHost* host, lua_State* rootThread,
                                        void* userdata);

struct EryxRuntimeRunHooks {
    const char* sourceFilename = nullptr;
    void* userdata = nullptr;
    uv_run_mode idleMode = UV_RUN_ONCE;
    int rootArgCount = 0;
    EryxRuntimeAfterInitHook afterInit = nullptr;
    EryxRuntimeAfterLoadHook afterLoad = nullptr;
    EryxRuntimeErrorHook onLoadFailure = nullptr;
    EryxRuntimeTickHook beforeTick = nullptr;
    EryxRuntimeTickHook onNoWork = nullptr;
    EryxRuntimeErrorHook onRuntimeError = nullptr;
    EryxRuntimeErrorHook onRootCompleted = nullptr;
    EryxRuntimeCleanupHook onCleanup = nullptr;
};

ERYX_API bool eryx_runtime_host_init(EryxRuntimeHost* host, const char* sourceFilename);
ERYX_API void eryx_runtime_host_close(EryxRuntimeHost* host);
ERYX_API bool eryx_runtime_host_install_sigint(EryxRuntimeHost* host);
ERYX_API lua_State* eryx_runtime_host_create_thread(EryxRuntimeHost* host);
ERYX_API bool eryx_runtime_host_enqueue_thread(EryxRuntimeHost* host, lua_State* thread, int nargs,
                                               bool inError);
ERYX_API bool eryx_runtime_has_work(EryxRuntime* rt);
ERYX_API bool eryx_runtime_prepare_entry(lua_State* L, int idx, bool snapshotFiles,
                                         EryxRuntimeEntry& out, std::string& error);
ERYX_API bool eryx_runtime_load_entry(lua_State* L, const EryxRuntimeEntry& entry,
                                      std::string& error);
ERYX_API bool eryx_runtime_run_entry(const EryxRuntimeEntry& entry,
                                     const EryxRuntimeRunHooks* hooks, std::string& error);
ERYX_API EryxRuntimeRunResult eryx_runtime_run_once(EryxRuntimeHost* host, lua_State** runningLua,
                                                    bool* completed = nullptr,
                                                    uv_run_mode idleMode = UV_RUN_ONCE);
