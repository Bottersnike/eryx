#include "runtime_host.hpp"

#include <csignal>

#include "lexception.hpp"
#include "lrequire.hpp"

static int eryx_runtime_find_exception_index(lua_State* L) {
    for (int index = lua_gettop(L); index >= 1; --index) {
        if (eryx_get_exception(L, index)) {
            return index;
        }
    }

    return 0;
}

ERYX_API bool eryx_runtime_host_init(EryxRuntimeHost* host, const char* sourceFilename) {
    if (!host) return false;

    host->GL = eryx_initialise_environment(sourceFilename);
    if (!host->GL) {
        return false;
    }

    if (uv_loop_init(&host->loop) != 0) {
        lua_close(host->GL);
        host->GL = nullptr;
        return false;
    }
    host->loopInitialized = true;
    host->rt = eryx_setup_runtime(&host->loop, host->GL);
    lua_setthreaddata(host->GL, host->rt);
    return true;
}

ERYX_API void eryx_runtime_host_close(EryxRuntimeHost* host) {
    if (!host) return;

    if (host->GL) {
        lua_close(host->GL);
    }

    if (host->loopInitialized) {
        uv_run(&host->loop, UV_RUN_NOWAIT);
        uv_loop_close(&host->loop);
    }

    delete host->rt;
    host->GL = nullptr;
    host->rt = nullptr;
    host->loopInitialized = false;
}

ERYX_API bool eryx_runtime_host_install_sigint(EryxRuntimeHost* host) {
    if (!host || !host->rt || !host->rt->loop) return false;

    uv_signal_t* sigint = new uv_signal_t;
    if (uv_signal_init(host->rt->loop, sigint) != 0) {
        delete sigint;
        return false;
    }

    uv_unref((uv_handle_t*)sigint);
    sigint->data = host->rt;
    host->rt->sigint = sigint;
    int status = uv_signal_start(
        sigint,
        [](uv_signal_t* handle, int) {
            EryxRuntime* rt = (EryxRuntime*)handle->data;
            eryx_interrupt_runtime(rt);
        },
        SIGINT);
    if (status != 0) {
        uv_close((uv_handle_t*)sigint, [](uv_handle_t* h) { delete (uv_signal_t*)h; });
        host->rt->sigint = nullptr;
        return false;
    }

    return true;
}

ERYX_API lua_State* eryx_runtime_host_create_thread(EryxRuntimeHost* host) {
    if (!host || !host->GL) return nullptr;

    lua_State* thread = lua_newthread(host->GL);
    luaL_sandboxthread(thread);
    return thread;
}

ERYX_API bool eryx_runtime_host_enqueue_thread(EryxRuntimeHost* host, lua_State* thread, int nargs,
                                               bool inError) {
    if (!host || !host->rt || !thread) return false;

    lua_rawcheckstack(thread, 1);
    lua_pushthread(thread);
    eryx_push_thread(host->rt, lua_ref(thread, -1), nargs, inError);
    lua_pop(thread, 1);
    return true;
}

ERYX_API bool eryx_runtime_has_work(EryxRuntime* rt) {
    return rt && (!rt->threads.empty() || uv_loop_alive(rt->loop));
}

ERYX_API EryxRuntimeRunResult eryx_runtime_run_once(EryxRuntimeHost* host, lua_State** runningLua,
                                                    bool* completed, uv_run_mode idleMode) {
    if (runningLua) {
        *runningLua = nullptr;
    }
    if (completed) {
        *completed = false;
    }
    if (!host || !host->GL || !host->rt) {
        return EryxRuntimeRunResult::Error;
    }

    uv_run(host->rt->loop, !host->rt->threads.empty() ? UV_RUN_NOWAIT : idleMode);

    if (host->rt->threads.empty()) {
        return EryxRuntimeRunResult::NoWork;
    }

    EryxThreadInfo thread = eryx_pop_thread(host->rt);

    lua_getref(host->GL, thread.threadRef);
    lua_State* L = lua_tothread(host->GL, -1);
    if (L == nullptr) {
        lua_pop(host->GL, 1);
        lua_unref(host->GL, thread.threadRef);
        return EryxRuntimeRunResult::Error;
    }
    if (runningLua) {
        *runningLua = L;
    }
    lua_pop(host->GL, 1);

    int coStatus = lua_costatus(host->GL, L);
    if (coStatus != LUA_COSUS) {
        // This thread was already terminal before this scheduler tick.
        // Don't report it as a fresh completion; callers that need a return
        // value should only capture results from the resume that produced LUA_OK.
        lua_unref(host->GL, thread.threadRef);
        return EryxRuntimeRunResult::Success;
    }

    int status =
        thread.inError ? lua_resumeerror(L, nullptr) : lua_resume(L, nullptr, thread.nargs);
    bool finished = status == LUA_OK;

    // A queued coroutine ref only belongs to the scheduler for this single
    // resume. If it yields again, the yield path must create a fresh ref.
    lua_unref(host->GL, thread.threadRef);

    if (!thread.inError && eryx_require_maybe_finalize_loader(host->GL, L, status)) {
        if (completed) {
            *completed = finished;
        }
        return EryxRuntimeRunResult::Success;
    }

    switch (status) {
        case LUA_YIELD:
            if (completed) {
                *completed = false;
            }
            return EryxRuntimeRunResult::Success;
        case LUA_OK:
            if (completed) {
                *completed = true;
            }
            return EryxRuntimeRunResult::Success;
        default:
            if (int exceptionIndex = eryx_runtime_find_exception_index(L)) {
                lua_settop(L, exceptionIndex);
                return EryxRuntimeRunResult::Error;
            }

            // Preserve call-stack context before the dead coroutine's frames
            // are discarded by wrapping raw string errors here.
            eryx_coerce_to_exception(L);
            return EryxRuntimeRunResult::Error;
    }
}
