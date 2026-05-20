#pragma once

#include "_wrapper_lib.hpp"

enum class EryxRuntimeRunResult {
    NoWork,
    Error,
    Success,
};

struct EryxRuntimeHost {
    lua_State* GL = nullptr;
    EryxRuntime* rt = nullptr;
    uv_loop_t loop = {};
    bool loopInitialized = false;
};

ERYX_API bool eryx_runtime_host_init(EryxRuntimeHost* host, const char* sourceFilename);
ERYX_API void eryx_runtime_host_close(EryxRuntimeHost* host);
ERYX_API bool eryx_runtime_host_install_sigint(EryxRuntimeHost* host);
ERYX_API lua_State* eryx_runtime_host_create_thread(EryxRuntimeHost* host);
ERYX_API bool eryx_runtime_host_enqueue_thread(EryxRuntimeHost* host, lua_State* thread, int nargs,
                                               bool inError);
ERYX_API bool eryx_runtime_has_work(EryxRuntime* rt);
ERYX_API EryxRuntimeRunResult eryx_runtime_run_once(EryxRuntimeHost* host, lua_State** runningLua,
                                                    bool* completed = nullptr,
                                                    uv_run_mode idleMode = UV_RUN_ONCE);
