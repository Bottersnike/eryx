#include "runtime_host.hpp"

#include <csignal>
#include <fstream>
#include <iterator>

#include "../LuaUtil.hpp"
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

static bool eryx_runtime_read_file(const std::string& path, std::string& source,
                                   std::string& error) {
    std::ifstream scriptFile(path, std::ios::binary);
    if (!scriptFile.is_open()) {
        error = "failed to open file \"" + path + "\"";
        return false;
    }

    source.assign((std::istreambuf_iterator<char>(scriptFile)), std::istreambuf_iterator<char>());
    return true;
}

static bool eryx_runtime_validate_source_entry(lua_State* L, const std::string& source,
                                               const std::string& chunkName, std::string& error) {
    lua_State* TL = lua_newthread(L);
    luaL_sandboxthread(TL);

    bool loaded = eryx_load_and_prepare_script(TL, source, chunkName);
    if (!loaded) {
        error = eryx_format_exception(TL, -1, false);
    }

    lua_pop(L, 1);
    return loaded;
}

static EryxRuntimeHookResult eryx_runtime_invoke_tick_hook(EryxRuntimeTickHook hook,
                                                           EryxRuntimeHost* host,
                                                           lua_State* rootThread, void* userdata,
                                                           std::string& error) {
    if (!hook) {
        return EryxRuntimeHookResult::Continue;
    }

    return hook(host, rootThread, userdata, error);
}

static EryxRuntimeHookResult eryx_runtime_invoke_error_hook(EryxRuntimeErrorHook hook,
                                                            EryxRuntimeHost* host,
                                                            lua_State* rootThread,
                                                            lua_State* runningLua, void* userdata,
                                                            std::string& error) {
    if (!hook) {
        if (error.empty()) {
            if (runningLua) {
                error = eryx_format_exception(runningLua, -1, false);
            } else {
                error = "runtime failed";
            }
        }
        return EryxRuntimeHookResult::Fail;
    }

    return hook(host, rootThread, runningLua, userdata, error);
}

static bool eryx_runtime_apply_hook_result(EryxRuntimeHookResult result, bool& shouldStop,
                                           std::string& error) {
    switch (result) {
        case EryxRuntimeHookResult::Continue:
            return true;
        case EryxRuntimeHookResult::Stop:
            shouldStop = true;
            return true;
        case EryxRuntimeHookResult::Fail:
            if (error.empty()) {
                error = "runtime callback failed";
            }
            return false;
    }

    error = "runtime callback returned an invalid state";
    return false;
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

    eryx_shutdown_runtime(host->rt);

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

ERYX_API bool eryx_runtime_prepare_entry(lua_State* L, int idx, bool snapshotFiles,
                                         EryxRuntimeEntry& out, std::string& error) {
    out = EryxRuntimeEntry{};

    if (lua_type(L, idx) == LUA_TSTRING) {
        std::string path = luaL_checkpathlike(L, idx);
        if (!snapshotFiles) {
            out.kind = EryxRuntimeEntryKind::File;
            out.program = path;
            out.chunkName = "@" + path;
            return true;
        }

        if (!eryx_runtime_read_file(path, out.source, error)) {
            return false;
        }

        out.kind = EryxRuntimeEntryKind::Source;
        out.program = path;
        out.chunkName = "@" + path;
        return eryx_runtime_validate_source_entry(L, out.source, out.chunkName, error);
    }

    if (lua_type(L, idx) == LUA_TFUNCTION) {
        std::string bytecode;
        std::string chunkName;
        if (!eryx_prepare_thread_entry_function(L, idx, bytecode, chunkName, error)) {
            return false;
        }

        out.kind = EryxRuntimeEntryKind::Bytecode;
        out.bytecode = std::move(bytecode);
        out.chunkName = std::move(chunkName);
        out.program = out.chunkName;
        if (!out.program.empty() && out.program[0] == '@') {
            out.program.erase(0, 1);
        }
        return true;
    }

    error = std::string("string or function expected, got ") + luaL_typename(L, idx);
    return false;
}

ERYX_API bool eryx_runtime_load_entry(lua_State* L, const EryxRuntimeEntry& entry,
                                      std::string& error) {
    if (!L) {
        error = "runtime entry load target is invalid";
        return false;
    }

    switch (entry.kind) {
        case EryxRuntimeEntryKind::File: {
            std::string source;
            if (!eryx_runtime_read_file(entry.program, source, error)) {
                return false;
            }
            bool loaded = eryx_load_and_prepare_script(L, source, entry.chunkName);
            if (!loaded) {
                error = eryx_format_exception(L, -1, false);
            }
            return loaded;
        }
        case EryxRuntimeEntryKind::Source: {
            bool loaded = eryx_load_and_prepare_script(L, entry.source, entry.chunkName);
            if (!loaded) {
                error = eryx_format_exception(L, -1, false);
            }
            return loaded;
        }
        case EryxRuntimeEntryKind::Bytecode: {
            bool loaded = eryx_load_and_prepare_bytecode(L, entry.bytecode, entry.chunkName);
            if (!loaded) {
                error = eryx_format_exception(L, -1, false);
            }
            return loaded;
        }
    }

    error = "runtime entry kind is invalid";
    return false;
}

ERYX_API bool eryx_runtime_run_entry(const EryxRuntimeEntry& entry,
                                     const EryxRuntimeRunHooks* hooks, std::string& error) {
    EryxRuntimeHost host;
    lua_State* rootThread = nullptr;
    bool shouldStop = false;
    void* userdata = hooks ? hooks->userdata : nullptr;

    auto cleanup = [&] {
        if (!host.GL && !host.rt && !host.loopInitialized) {
            return;
        }

        if (hooks && hooks->onCleanup) {
            hooks->onCleanup(&host, rootThread, userdata);
        }
        eryx_runtime_host_close(&host);
    };

    auto apply = [&](EryxRuntimeHookResult result) {
        return eryx_runtime_apply_hook_result(result, shouldStop, error);
    };

    try {
        std::string sourceFilename =
            hooks && hooks->sourceFilename
                ? hooks->sourceFilename
                : (!entry.program.empty() ? entry.program : entry.chunkName);
        if (!eryx_runtime_host_init(&host,
                                    sourceFilename.empty() ? nullptr : sourceFilename.c_str())) {
            error = "failed to create Luau state";
            return false;
        }

        if (hooks && hooks->afterInit) {
            if (!apply(hooks->afterInit(&host, userdata, error))) {
                cleanup();
                return false;
            }
            if (shouldStop) {
                cleanup();
                return true;
            }
        }

        rootThread = eryx_runtime_host_create_thread(&host);
        if (!rootThread) {
            error = "failed to create Luau thread";
            cleanup();
            return false;
        }

        if (!eryx_runtime_load_entry(rootThread, entry, error)) {
            EryxRuntimeHookResult result =
                eryx_runtime_invoke_error_hook(hooks ? hooks->onLoadFailure : nullptr, &host,
                                               rootThread, rootThread, userdata, error);
            if (result == EryxRuntimeHookResult::Continue) {
                result = EryxRuntimeHookResult::Stop;
            }
            if (!apply(result)) {
                cleanup();
                return false;
            }

            cleanup();
            return true;
        }

        int rootArgCount = hooks ? hooks->rootArgCount : 0;
        if (hooks && hooks->afterLoad) {
            if (!apply(hooks->afterLoad(&host, rootThread, &rootArgCount, userdata, error))) {
                cleanup();
                return false;
            }
            if (shouldStop) {
                cleanup();
                return true;
            }
        }

        if (!eryx_runtime_host_enqueue_thread(&host, rootThread, rootArgCount, false)) {
            error = "failed to enqueue Luau thread";
            cleanup();
            return false;
        }

        while (!shouldStop) {
            if (hooks && hooks->beforeTick) {
                if (!apply(hooks->beforeTick(&host, rootThread, userdata, error))) {
                    cleanup();
                    return false;
                }
                if (shouldStop) {
                    break;
                }
            }

            lua_State* runningLua = nullptr;
            bool rootCompleted = false;
            EryxRuntimeRunResult status = eryx_runtime_run_once(
                &host, &runningLua, &rootCompleted, hooks ? hooks->idleMode : UV_RUN_ONCE);

            if (status == EryxRuntimeRunResult::NoWork) {
                EryxRuntimeHookResult result = eryx_runtime_invoke_tick_hook(
                    hooks ? hooks->onNoWork : nullptr, &host, rootThread, userdata, error);
                if (!apply(result)) {
                    cleanup();
                    return false;
                }
                if (!eryx_runtime_has_work(host.rt)) {
                    shouldStop = true;
                }
                continue;
            }

            if (status == EryxRuntimeRunResult::Error) {
                EryxRuntimeHookResult result =
                    eryx_runtime_invoke_error_hook(hooks ? hooks->onRuntimeError : nullptr, &host,
                                                   rootThread, runningLua, userdata, error);
                if (!apply(result)) {
                    cleanup();
                    return false;
                }
                continue;
            }

            if (runningLua == rootThread && rootCompleted) {
                EryxRuntimeHookResult result =
                    eryx_runtime_invoke_error_hook(hooks ? hooks->onRootCompleted : nullptr, &host,
                                                   rootThread, rootThread, userdata, error);
                if (!apply(result)) {
                    cleanup();
                    return false;
                }
            }
        }

        cleanup();
        return true;
    } catch (const std::exception& ex) {
        cleanup();
        error = std::string("isolated runtime failed: ") + ex.what();
        return false;
    } catch (...) {
        cleanup();
        error = "isolated runtime failed";
        return false;
    }
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
        // It still counts as completed for outer runtime-loop shutdown, even
        // though there is no fresh resume result to inspect here.
        if (completed) {
            *completed = true;
        }
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
        case LUA_BREAK:
            if (!eryx_runtime_host_enqueue_thread(host, L, 0, false)) {
                return EryxRuntimeRunResult::Error;
            }
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
