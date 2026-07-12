#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../LuaUtil.hpp"
#include "../modules/module_api.h"
#include "../runtime/_wrapper_lib.hpp"
#include "../runtime/lexception.hpp"
#include "../runtime/lmarshall.hpp"
#include "../runtime/lrequire.hpp"
#include "../runtime/runtime_host.hpp"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_thread",
};
LUAU_MODULE_INFO()

static const char* THREAD_HANDLE_MT = "ThreadHandle";
static const char* THREAD_FUTURE_MT = "ThreadFuture";
static const char* THREAD_POOL_MT = "ThreadPool";
static const char* THREAD_WORKER_MT = "ThreadWorker";

enum class ThreadStatus {
    Starting,
    Running,
    Finished,
    Error,
    Killed,
    Interrupted,
};

enum class FutureStatus {
    Queued,
    Running,
    Finished,
    Error,
    Cancelled,
};

struct ThreadShared;
struct FutureShared;
struct PoolShared;
struct WorkerShared;
static void thread_async_close_cb(uv_handle_t* handle);

struct PendingJob {
    EryxRuntimeEntry entry;
    std::vector<uint8_t> context;
    std::shared_ptr<FutureShared> future;
};

struct ThreadAsyncData {
    std::shared_ptr<ThreadShared> shared;
};

struct ThreadShared : std::enable_shared_from_this<ThreadShared> {
    std::mutex mutex;

    EryxRuntime* parentRuntime = nullptr;
    EryxRuntime* childRuntime = nullptr;
    uv_async_t* mainAsync = nullptr;
    uv_async_t* childAsync = nullptr;
    bool mainAsyncInitialized = false;
    bool childAsyncInitialized = false;
    bool mainAsyncCloseRequested = false;

    EryxRuntimeEntry entry;
    std::vector<uint8_t> initialContext;

    std::deque<std::vector<uint8_t>> mainToChild;
    std::deque<std::vector<uint8_t>> childToMain;

    int mainRecvWaiterRef = LUA_NOREF;
    int mainJoinWaiterRef = LUA_NOREF;
    int childRecvWaiterRef = LUA_NOREF;

    ThreadStatus status = ThreadStatus::Starting;
    std::string terminalMessage;
    std::unique_ptr<LuaExceptionSnapshot> errorSnapshot;
    std::vector<uint8_t> joinValue;
    bool hasJoinValue = false;
    std::vector<uint8_t> completedJoinValue;
    bool hasCompletedJoinValue = false;
    bool errorNotified = false;
    std::weak_ptr<FutureShared> future;

    bool killRequested = false;
    bool interruptRequested = false;
    int onErrorRef = LUA_NOREF;
    int onErrorHandleRef = LUA_NOREF;

    std::thread worker;
};

struct ThreadHandleBox {
    std::shared_ptr<ThreadShared> shared;
};

struct FutureShared {
    std::mutex mutex;

    EryxRuntime* parentRuntime = nullptr;
    std::shared_ptr<ThreadShared> runningThread;
    std::shared_ptr<PoolShared> pool;
    std::shared_ptr<WorkerShared> worker;

    FutureStatus status = FutureStatus::Queued;
    std::unique_ptr<LuaExceptionSnapshot> errorSnapshot;
    std::vector<uint8_t> resultValue;
    bool hasResultValue = false;
    std::vector<uint8_t> latestUpdate;
    bool hasUpdate = false;

    int waiterRef = LUA_NOREF;
    int onErrorRef = LUA_NOREF;
    int onUpdateRef = LUA_NOREF;
    int selfRef = LUA_NOREF;
};

struct PoolShared {
    std::mutex mutex;

    EryxRuntime* parentRuntime = nullptr;
    size_t workerLimit = 1;
    size_t activeCount = 0;
    std::deque<PendingJob> queuedJobs;

    int onErrorRef = LUA_NOREF;
    int onUpdateRef = LUA_NOREF;
};

struct WorkerShared {
    std::mutex mutex;

    EryxRuntime* parentRuntime = nullptr;
    EryxRuntimeEntry job;
    std::shared_ptr<PoolShared> pool;

    int onErrorRef = LUA_NOREF;
    int onUpdateRef = LUA_NOREF;
};

struct FutureHandleBox {
    std::shared_ptr<FutureShared> shared;
};

struct PoolHandleBox {
    std::shared_ptr<PoolShared> shared;
};

struct WorkerHandleBox {
    std::shared_ptr<WorkerShared> shared;
};

static std::mutex g_thread_registry_mutex;
static std::unordered_map<EryxRuntime*, std::vector<std::weak_ptr<ThreadShared>>> g_threads_by_rt;
static std::unordered_set<EryxRuntime*> g_interrupt_hooks;

static void thread_worker(const std::shared_ptr<ThreadShared>& shared);
static bool thread_start_shared(lua_State* L, const std::shared_ptr<ThreadShared>& shared,
                                std::string& error);
static void pool_maybe_start_jobs(lua_State* L, const std::shared_ptr<PoolShared>& pool);

static bool thread_status_terminal(ThreadStatus status) {
    return status == ThreadStatus::Finished || status == ThreadStatus::Error ||
           status == ThreadStatus::Killed || status == ThreadStatus::Interrupted;
}

static const char* thread_status_name(ThreadStatus status) {
    switch (status) {
        case ThreadStatus::Starting:
            return "starting";
        case ThreadStatus::Running:
            return "running";
        case ThreadStatus::Finished:
            return "finished";
        case ThreadStatus::Error:
            return "error";
        case ThreadStatus::Killed:
            return "killed";
        case ThreadStatus::Interrupted:
            return "interrupted";
    }

    return "unknown";
}

static const char* future_status_name(FutureStatus status) {
    switch (status) {
        case FutureStatus::Queued:
            return "queued";
        case FutureStatus::Running:
            return "running";
        case FutureStatus::Finished:
            return "finished";
        case FutureStatus::Error:
            return "error";
        case FutureStatus::Cancelled:
            return "cancelled";
    }

    return "unknown";
}

static std::string thread_default_message(ThreadStatus status) {
    switch (status) {
        case ThreadStatus::Finished:
            return "";
        case ThreadStatus::Error:
            return "thread failed";
        case ThreadStatus::Killed:
            return "thread was killed";
        case ThreadStatus::Interrupted:
            return "thread was interrupted";
        case ThreadStatus::Starting:
        case ThreadStatus::Running:
            return "thread is still running";
    }

    return "thread failed";
}

static void shared_ptr_dtor(void* userdata) {
    auto* box = static_cast<std::shared_ptr<ThreadShared>*>(userdata);
    box->~shared_ptr<ThreadShared>();
}

static udataRef* check_udata_ref(lua_State* L, const char* name) {
    udataRef* ref = eryxUdata_getudata(L, name);
    if (!ref) {
        luaL_error(L, "%s userdata is not registered", name);
        return nullptr;
    }
    return ref;
}

static std::shared_ptr<ThreadShared> check_thread_handle(lua_State* L, int idx) {
    auto* box = static_cast<ThreadHandleBox*>(
        eryxUdata_checkudata(L, check_udata_ref(L, THREAD_HANDLE_MT), idx));
    if (!box->shared) {
        luaL_error(L, "thread handle is invalid");
    }
    return box->shared;
}

static std::shared_ptr<FutureShared> check_future_handle(lua_State* L, int idx) {
    auto* box = static_cast<FutureHandleBox*>(
        eryxUdata_checkudata(L, check_udata_ref(L, THREAD_FUTURE_MT), idx));
    if (!box->shared) {
        luaL_error(L, "future handle is invalid");
    }
    return box->shared;
}

static std::shared_ptr<PoolShared> check_pool_handle(lua_State* L, int idx) {
    auto* box = static_cast<PoolHandleBox*>(
        eryxUdata_checkudata(L, check_udata_ref(L, THREAD_POOL_MT), idx));
    if (!box->shared) {
        luaL_error(L, "thread pool is invalid");
    }
    return box->shared;
}

static std::shared_ptr<WorkerShared> check_worker_handle(lua_State* L, int idx) {
    auto* box = static_cast<WorkerHandleBox*>(
        eryxUdata_checkudata(L, check_udata_ref(L, THREAD_WORKER_MT), idx));
    if (!box->shared) {
        luaL_error(L, "thread worker is invalid");
    }
    return box->shared;
}

static std::shared_ptr<ThreadShared>* check_shared_box_upvalue(lua_State* L) {
    auto* box = static_cast<std::shared_ptr<ThreadShared>*>(lua_touserdata(L, lua_upvalueindex(1)));
    if (!box || !*box) {
        luaL_error(L, "thread context is invalid");
    }
    return box;
}

static void thread_signal_main(const std::shared_ptr<ThreadShared>& shared) {
    std::lock_guard lock(shared->mutex);
    if (shared->mainAsyncInitialized && shared->mainAsync) {
        uv_async_send(shared->mainAsync);
    }
}

static void thread_signal_child(const std::shared_ptr<ThreadShared>& shared) {
    std::lock_guard lock(shared->mutex);
    if (shared->childAsyncInitialized && shared->childAsync) {
        uv_async_send(shared->childAsync);
    }
}

static void thread_close_main_async(const std::shared_ptr<ThreadShared>& shared) {
    uv_async_t* async = nullptr;
    {
        std::lock_guard lock(shared->mutex);
        if (shared->mainAsyncInitialized && shared->mainAsync) {
            async = shared->mainAsync;
            shared->mainAsync = nullptr;
            shared->mainAsyncInitialized = false;
        }
    }

    if (async) {
        uv_close(reinterpret_cast<uv_handle_t*>(async), thread_async_close_cb);
    }
}

static void thread_close_child_async(const std::shared_ptr<ThreadShared>& shared) {
    uv_async_t* async = nullptr;
    {
        std::lock_guard lock(shared->mutex);
        if (shared->childAsyncInitialized && shared->childAsync) {
            async = shared->childAsync;
            shared->childAsync = nullptr;
            shared->childAsyncInitialized = false;
        }
    }

    if (async) {
        uv_close(reinterpret_cast<uv_handle_t*>(async), thread_async_close_cb);
    }
}

static void thread_store_marshaled_value(lua_State* L, int idx, std::vector<uint8_t>& out) {
    out.clear();
    eryx_marshall(L, idx, out);
}

static void thread_store_marshaled_nil(lua_State* L, std::vector<uint8_t>& out) {
    lua_pushnil(L);
    eryx_marshall(L, -1, out);
    lua_pop(L, 1);
}

static const char* thread_exception_type_name(const std::string& type) {
    if (type == ETYPE_RUNTIME) return ETYPE_RUNTIME;
    if (type == ETYPE_ASSERT) return ETYPE_ASSERT;
    if (type == ETYPE_THROWN) return ETYPE_THROWN;
    if (type == ETYPE_SYNTAX) return ETYPE_SYNTAX;
    if (type == ETYPE_REQUIRE) return ETYPE_REQUIRE;
    if (type == ETYPE_USER) return ETYPE_USER;
    if (type == ETYPE_INTERRUPT) return ETYPE_INTERRUPT;
    if (type == ETYPE_SYSTEM_EXIT) return ETYPE_SYSTEM_EXIT;
    return ETYPE_RUNTIME;
}

static std::unique_ptr<LuaExceptionSnapshot> thread_copy_exception_snapshot(
    const LuaExceptionSnapshot* snapshot) {
    if (!snapshot) return nullptr;

    auto copy = std::make_unique<LuaExceptionSnapshot>();
    copy->type = snapshot->type;
    copy->message = snapshot->message;
    copy->traceback = snapshot->traceback;
    copy->parent = thread_copy_exception_snapshot(snapshot->parent.get());
    return copy;
}

static std::unique_ptr<LuaExceptionSnapshot> thread_make_message_exception_snapshot(
    const std::string& message, const char* type = ETYPE_RUNTIME) {
    auto snapshot = std::make_unique<LuaExceptionSnapshot>();
    snapshot->type = type ? type : ETYPE_RUNTIME;
    snapshot->message = message;
    return snapshot;
}

static void thread_push_exception_copy(lua_State* L, const LuaExceptionSnapshot* source) {
    if (!source) {
        eryx_exception_push_exception(L, ETYPE_RUNTIME, "thread failed", nullptr);
        return;
    }

    lua_checkstack(L, 2);

    LuaException* exception = eryx_exception_push_userdata(L);
    exception->type = thread_exception_type_name(source->type);
    exception->message = source->message;
    exception->traceback = source->traceback;
    exception->parent = thread_copy_exception_snapshot(source->parent.get());
}

static void thread_schedule_marshaled_callback(EryxRuntime* rt, int callbackRef, int selfRef,
                                               const std::vector<uint8_t>& value) {
    if (!rt || callbackRef == LUA_NOREF || selfRef == LUA_NOREF) return;

    lua_State* GL = rt->GL;
    lua_State* TL = lua_newthread(GL);

    lua_getref(GL, callbackRef);
    lua_xmove(GL, TL, 1);

    lua_getref(GL, selfRef);
    lua_xmove(GL, TL, 1);

    eryx_unmarshall(TL, value.data(), value.size());

    int threadRef = lua_ref(GL, -1);
    lua_pop(GL, 1);
    eryx_push_thread(rt, threadRef, 2, false);
}

static void thread_schedule_exception_callback(EryxRuntime* rt, int callbackRef, int selfRef,
                                               const LuaExceptionSnapshot* errorSnapshot) {
    if (!rt || callbackRef == LUA_NOREF || selfRef == LUA_NOREF) return;

    lua_State* GL = rt->GL;
    lua_State* TL = lua_newthread(GL);

    lua_getref(GL, callbackRef);
    lua_xmove(GL, TL, 1);

    lua_getref(GL, selfRef);
    lua_xmove(GL, TL, 1);

    thread_push_exception_copy(TL, errorSnapshot);

    int threadRef = lua_ref(GL, -1);
    lua_pop(GL, 1);
    eryx_push_thread(rt, threadRef, 2, false);
}

static void thread_resume_value(EryxRuntime* rt, int threadRef, const std::vector<uint8_t>& value) {
    if (!rt || threadRef == LUA_NOREF) return;

    lua_getref(rt->GL, threadRef);
    lua_State* TL = lua_tothread(rt->GL, -1);
    lua_pop(rt->GL, 1);
    if (!TL) {
        lua_unref(rt->GL, threadRef);
        return;
    }

    eryx_unmarshall(TL, value.data(), value.size());
    eryx_push_thread(rt, threadRef, 1, false);
}

static void thread_resume_nil(EryxRuntime* rt, int threadRef) {
    if (!rt || threadRef == LUA_NOREF) return;

    lua_getref(rt->GL, threadRef);
    lua_State* TL = lua_tothread(rt->GL, -1);
    lua_pop(rt->GL, 1);
    if (!TL) {
        lua_unref(rt->GL, threadRef);
        return;
    }

    lua_pushnil(TL);
    eryx_push_thread(rt, threadRef, 1, false);
}

static void thread_resume_error(EryxRuntime* rt, int threadRef, const std::string& message) {
    if (!rt || threadRef == LUA_NOREF) return;

    lua_getref(rt->GL, threadRef);
    lua_State* TL = lua_tothread(rt->GL, -1);
    lua_pop(rt->GL, 1);
    if (!TL) {
        lua_unref(rt->GL, threadRef);
        return;
    }

    lua_pushlstring(TL, message.data(), message.size());
    eryx_push_thread(rt, threadRef, 1, true);
}

static void thread_resume_exception(EryxRuntime* rt, int threadRef,
                                    const LuaExceptionSnapshot* exception) {
    if (!rt || threadRef == LUA_NOREF) return;

    lua_getref(rt->GL, threadRef);
    lua_State* TL = lua_tothread(rt->GL, -1);
    lua_pop(rt->GL, 1);
    if (!TL) {
        lua_unref(rt->GL, threadRef);
        return;
    }

    thread_push_exception_copy(TL, exception);
    eryx_push_thread(rt, threadRef, 1, true);
}

static void thread_mark_terminal(const std::shared_ptr<ThreadShared>& shared, ThreadStatus status,
                                 std::string message, std::vector<uint8_t> joinValue,
                                 bool hasJoinValue,
                                 std::unique_ptr<LuaExceptionSnapshot> errorSnapshot = nullptr) {
    bool alreadyTerminal = false;
    {
        std::lock_guard lock(shared->mutex);
        if (thread_status_terminal(shared->status)) {
            alreadyTerminal = true;
        } else {
            shared->status = status;
            shared->terminalMessage =
                message.empty() ? thread_default_message(status) : std::move(message);
            if (status == ThreadStatus::Error) {
                shared->errorSnapshot =
                    errorSnapshot ? std::move(errorSnapshot)
                                  : thread_make_message_exception_snapshot(shared->terminalMessage);
            }
            shared->joinValue = std::move(joinValue);
            shared->hasJoinValue = hasJoinValue;
            shared->mainAsyncCloseRequested = true;
        }
    }

    if (alreadyTerminal) {
        return;
    }

    thread_signal_main(shared);
}

static void thread_async_close_cb(uv_handle_t* handle) {
    auto* data = static_cast<ThreadAsyncData*>(handle->data);
    delete data;
    delete reinterpret_cast<uv_async_t*>(handle);
}

static void thread_main_async_cb(uv_async_t* handle) {
    auto* data = static_cast<ThreadAsyncData*>(handle->data);
    std::shared_ptr<ThreadShared> shared = data->shared;

    EryxRuntime* parentRt = nullptr;
    std::shared_ptr<FutureShared> future;
    int recvWaiterRef = LUA_NOREF;
    int joinWaiterRef = LUA_NOREF;
    bool recvHasValue = false;
    bool recvShouldReturnNil = false;
    std::vector<uint8_t> recvValue;
    std::vector<std::vector<uint8_t>> futureUpdates;
    bool joinHasValue = false;
    bool joinShouldError = false;
    std::string joinMessage;
    std::vector<uint8_t> joinValue;
    std::unique_ptr<LuaExceptionSnapshot> joinException;
    bool shouldNotifyError = false;
    int onErrorRef = LUA_NOREF;
    int onErrorHandleRef = LUA_NOREF;
    std::unique_ptr<LuaExceptionSnapshot> notifiedException;
    bool closeRequested = false;
    int releaseOnErrorRef = LUA_NOREF;
    int releaseOnErrorHandleRef = LUA_NOREF;
    bool futureTerminal = false;
    FutureStatus futureTerminalStatus = FutureStatus::Queued;
    int futureWaiterRef = LUA_NOREF;
    std::vector<uint8_t> futureResultValue;
    bool futureHasResultValue = false;
    int futureErrorCallbackRef = LUA_NOREF;
    int futureUpdateCallbackRef = LUA_NOREF;
    int futureSelfRef = LUA_NOREF;
    int releaseFutureSelfRef = LUA_NOREF;
    bool schedulePoolPump = false;
    std::shared_ptr<PoolShared> completedPool;
    std::shared_ptr<WorkerShared> futureWorker;

    {
        std::lock_guard lock(shared->mutex);
        parentRt = shared->parentRuntime;
        future = shared->future.lock();

        if (future) {
            while (!shared->childToMain.empty()) {
                futureUpdates.push_back(std::move(shared->childToMain.front()));
                shared->childToMain.pop_front();
            }
        } else if (shared->mainRecvWaiterRef != LUA_NOREF) {
            if (!shared->childToMain.empty()) {
                recvWaiterRef = shared->mainRecvWaiterRef;
                shared->mainRecvWaiterRef = LUA_NOREF;
                recvValue = std::move(shared->childToMain.front());
                shared->childToMain.pop_front();
                recvHasValue = true;
            } else if (thread_status_terminal(shared->status)) {
                recvWaiterRef = shared->mainRecvWaiterRef;
                shared->mainRecvWaiterRef = LUA_NOREF;
                recvShouldReturnNil = true;
            }
        }

        if (shared->mainJoinWaiterRef != LUA_NOREF && thread_status_terminal(shared->status)) {
            joinWaiterRef = shared->mainJoinWaiterRef;
            shared->mainJoinWaiterRef = LUA_NOREF;
            if (shared->status == ThreadStatus::Finished) {
                if (shared->hasJoinValue) {
                    joinHasValue = true;
                    joinValue = shared->joinValue;
                } else if (shared->hasCompletedJoinValue) {
                    joinHasValue = true;
                    joinValue = shared->completedJoinValue;
                }
            } else {
                joinShouldError = true;
                joinMessage = shared->terminalMessage;
                if (shared->status == ThreadStatus::Error && shared->errorSnapshot) {
                    joinException = thread_copy_exception_snapshot(shared->errorSnapshot.get());
                }
            }
        }

        if (!future && shared->status == ThreadStatus::Error && !shared->errorNotified) {
            shared->errorNotified = true;
            shouldNotifyError = true;
            onErrorRef = shared->onErrorRef;
            onErrorHandleRef = shared->onErrorHandleRef;
            if (shared->errorSnapshot) {
                notifiedException = thread_copy_exception_snapshot(shared->errorSnapshot.get());
            } else {
                notifiedException = thread_make_message_exception_snapshot(shared->terminalMessage);
            }
        }

        closeRequested = shared->mainAsyncCloseRequested;
        if (closeRequested) {
            releaseOnErrorRef = shared->onErrorRef;
            releaseOnErrorHandleRef = shared->onErrorHandleRef;
            shared->onErrorRef = LUA_NOREF;
            shared->onErrorHandleRef = LUA_NOREF;
        }
    }

    if (recvWaiterRef != LUA_NOREF) {
        if (recvHasValue) {
            thread_resume_value(parentRt, recvWaiterRef, recvValue);
        } else if (recvShouldReturnNil) {
            thread_resume_nil(parentRt, recvWaiterRef);
        }
    }

    if (joinWaiterRef != LUA_NOREF) {
        if (joinShouldError) {
            if (joinException) {
                thread_resume_exception(parentRt, joinWaiterRef, joinException.get());
            } else {
                thread_resume_error(parentRt, joinWaiterRef, joinMessage);
            }
        } else if (joinHasValue) {
            if (!joinValue.empty()) {
                thread_resume_value(parentRt, joinWaiterRef, joinValue);
            } else {
                thread_resume_nil(parentRt, joinWaiterRef);
            }
        }
    }

    if (future && parentRt) {
        for (const std::vector<uint8_t>& updateValue : futureUpdates) {
            int callbackRef = LUA_NOREF;
            int selfRef = LUA_NOREF;

            {
                std::lock_guard futureLock(future->mutex);
                future->latestUpdate = updateValue;
                future->hasUpdate = true;
                callbackRef = future->onUpdateRef;
                selfRef = future->selfRef;
            }

            if (callbackRef == LUA_NOREF) {
                futureWorker = future->worker;
                if (futureWorker) {
                    std::lock_guard workerLock(futureWorker->mutex);
                    callbackRef = futureWorker->onUpdateRef;
                }
            }
            if (callbackRef == LUA_NOREF) {
                std::shared_ptr<PoolShared> futurePool = future->pool;
                if (futurePool) {
                    std::lock_guard poolLock(futurePool->mutex);
                    callbackRef = futurePool->onUpdateRef;
                }
            }

            if (callbackRef != LUA_NOREF && selfRef != LUA_NOREF) {
                thread_schedule_marshaled_callback(parentRt, callbackRef, selfRef, updateValue);
            }
        }

        if (thread_status_terminal(shared->status)) {
            int callbackRef = LUA_NOREF;
            int selfRef = LUA_NOREF;

            {
                std::lock_guard futureLock(future->mutex);
                futureTerminal = true;
                selfRef = future->selfRef;
                if (shared->status == ThreadStatus::Finished) {
                    const bool useCompletedFallback =
                        !shared->hasJoinValue && shared->hasCompletedJoinValue;

                    future->status = FutureStatus::Finished;
                    future->resultValue =
                        useCompletedFallback ? shared->completedJoinValue : shared->joinValue;
                    future->hasResultValue = shared->hasJoinValue || shared->hasCompletedJoinValue;
                    futureTerminalStatus = FutureStatus::Finished;
                    futureResultValue = future->resultValue;
                    futureHasResultValue = future->hasResultValue;
                } else if (shared->status == ThreadStatus::Error) {
                    future->status = FutureStatus::Error;
                    if (shared->errorSnapshot) {
                        future->errorSnapshot =
                            thread_copy_exception_snapshot(shared->errorSnapshot.get());
                    } else {
                        future->errorSnapshot =
                            thread_make_message_exception_snapshot(shared->terminalMessage);
                    }
                    futureTerminalStatus = FutureStatus::Error;
                    notifiedException = thread_copy_exception_snapshot(future->errorSnapshot.get());
                } else {
                    future->status = FutureStatus::Cancelled;
                    future->errorSnapshot = thread_make_message_exception_snapshot(
                        shared->terminalMessage, shared->status == ThreadStatus::Interrupted
                                                     ? ETYPE_INTERRUPT
                                                     : ETYPE_RUNTIME);
                    futureTerminalStatus = FutureStatus::Cancelled;
                }

                future->runningThread.reset();
                futureWaiterRef = future->waiterRef;
                future->waiterRef = LUA_NOREF;
                futureErrorCallbackRef = future->onErrorRef;
                futureSelfRef = selfRef;
                releaseFutureSelfRef = future->selfRef;
                future->selfRef = LUA_NOREF;
            }

            if (futureTerminalStatus == FutureStatus::Error) {
                callbackRef = futureErrorCallbackRef;
                if (callbackRef == LUA_NOREF) {
                    futureWorker = future->worker;
                    if (futureWorker) {
                        std::lock_guard workerLock(futureWorker->mutex);
                        callbackRef = futureWorker->onErrorRef;
                    }
                }
                if (callbackRef == LUA_NOREF) {
                    std::shared_ptr<PoolShared> futurePool = future->pool;
                    if (futurePool) {
                        std::lock_guard poolLock(futurePool->mutex);
                        callbackRef = futurePool->onErrorRef;
                    }
                }
                if (callbackRef != LUA_NOREF && futureSelfRef != LUA_NOREF && notifiedException) {
                    thread_schedule_exception_callback(parentRt, callbackRef, futureSelfRef,
                                                       notifiedException.get());
                } else if (notifiedException) {
                    std::string text = shared->terminalMessage;
                    if (!text.empty()) {
                        std::fprintf(stderr, "%s", text.c_str());
                        if (text.back() != '\n') {
                            std::fprintf(stderr, "\n");
                        }
                        std::fflush(stderr);
                    }
                }
            }

            completedPool = future->pool;
            if (completedPool) {
                {
                    std::lock_guard poolLock(completedPool->mutex);
                    if (completedPool->activeCount > 0) {
                        completedPool->activeCount--;
                    }
                }
                schedulePoolPump = true;
            }
        }
    }

    if (shouldNotifyError && parentRt) {
        if (onErrorRef != LUA_NOREF && onErrorHandleRef != LUA_NOREF) {
            lua_State* GL = parentRt->GL;
            lua_State* TL = lua_newthread(GL);

            lua_getref(GL, onErrorRef);
            lua_xmove(GL, TL, 1);

            lua_getref(GL, onErrorHandleRef);
            lua_xmove(GL, TL, 1);

            thread_push_exception_copy(TL, notifiedException.get());

            int threadRef = lua_ref(GL, -1);
            lua_pop(GL, 1);
            eryx_push_thread(parentRt, threadRef, 2, false);
        } else {
            std::string text = shared->terminalMessage;
            if (!text.empty()) {
                std::fprintf(stderr, "%s", text.c_str());
                if (text.back() != '\n') {
                    std::fprintf(stderr, "\n");
                }
                std::fflush(stderr);
            }
        }
    }

    if (futureTerminal && parentRt && futureWaiterRef != LUA_NOREF) {
        if (futureTerminalStatus == FutureStatus::Finished) {
            if (futureHasResultValue && !futureResultValue.empty()) {
                thread_resume_value(parentRt, futureWaiterRef, futureResultValue);
            } else {
                thread_resume_nil(parentRt, futureWaiterRef);
            }
        } else if (notifiedException) {
            thread_resume_exception(parentRt, futureWaiterRef, notifiedException.get());
        } else {
            thread_resume_error(parentRt, futureWaiterRef, shared->terminalMessage);
        }
    }

    if (closeRequested && parentRt) {
        lua_State* GL = parentRt->GL;
        if (releaseOnErrorRef != LUA_NOREF) {
            lua_unref(GL, releaseOnErrorRef);
        }
        if (releaseOnErrorHandleRef != LUA_NOREF) {
            lua_unref(GL, releaseOnErrorHandleRef);
        }
        if (releaseFutureSelfRef != LUA_NOREF) {
            lua_unref(GL, releaseFutureSelfRef);
        }
    }

    if (schedulePoolPump && completedPool && parentRt) {
        pool_maybe_start_jobs(parentRt->GL, completedPool);
    }

    if (closeRequested) {
        thread_close_main_async(shared);
    }
}

static void thread_child_async_cb(uv_async_t* handle) {
    auto* data = static_cast<ThreadAsyncData*>(handle->data);
    std::shared_ptr<ThreadShared> shared = data->shared;

    EryxRuntime* childRt = nullptr;
    int recvWaiterRef = LUA_NOREF;
    bool recvHasValue = false;
    bool recvShouldError = false;
    std::vector<uint8_t> recvValue;
    std::string recvError;
    bool killRequested = false;
    bool interruptRequested = false;

    {
        std::lock_guard lock(shared->mutex);
        childRt = shared->childRuntime;
        killRequested = shared->killRequested;
        interruptRequested = shared->interruptRequested;

        if (shared->childRecvWaiterRef != LUA_NOREF) {
            if (!shared->mainToChild.empty()) {
                recvWaiterRef = shared->childRecvWaiterRef;
                shared->childRecvWaiterRef = LUA_NOREF;
                recvValue = std::move(shared->mainToChild.front());
                shared->mainToChild.pop_front();
                recvHasValue = true;
            } else if (killRequested || interruptRequested) {
                recvWaiterRef = shared->childRecvWaiterRef;
                shared->childRecvWaiterRef = LUA_NOREF;
                recvShouldError = true;
                recvError = killRequested ? "thread was killed" : "thread was interrupted";
            }
        }
    }

    if (recvWaiterRef != LUA_NOREF) {
        if (recvHasValue) {
            thread_resume_value(childRt, recvWaiterRef, recvValue);
        } else if (recvShouldError) {
            thread_resume_error(childRt, recvWaiterRef, recvError);
        }
    }

    if ((killRequested || interruptRequested) && childRt) {
        eryx_interrupt_runtime(childRt);
    }
}

static void thread_register_interrupt_hook(EryxRuntime* rt) {
    if (!rt) return;

    bool shouldRegister = false;
    {
        std::lock_guard lock(g_thread_registry_mutex);
        shouldRegister = g_interrupt_hooks.insert(rt).second;
    }

    if (!shouldRegister) return;

    eryx_register_interrupt_callback(
        rt,
        [](EryxRuntime* interruptedRt, void*) {
            std::vector<std::shared_ptr<ThreadShared>> threads;
            {
                std::lock_guard lock(g_thread_registry_mutex);
                auto it = g_threads_by_rt.find(interruptedRt);
                if (it != g_threads_by_rt.end()) {
                    auto& entries = it->second;
                    for (auto weakIt = entries.begin(); weakIt != entries.end();) {
                        if (std::shared_ptr<ThreadShared> shared = weakIt->lock()) {
                            threads.push_back(std::move(shared));
                            ++weakIt;
                        } else {
                            weakIt = entries.erase(weakIt);
                        }
                    }
                }
            }

            for (const std::shared_ptr<ThreadShared>& shared : threads) {
                {
                    std::lock_guard lock(shared->mutex);
                    if (thread_status_terminal(shared->status)) {
                        continue;
                    }
                    shared->interruptRequested = true;
                }
                thread_signal_child(shared);
            }
        },
        nullptr);
}

static void thread_track_parent(EryxRuntime* rt, const std::shared_ptr<ThreadShared>& shared) {
    if (!rt) return;
    thread_register_interrupt_hook(rt);

    std::lock_guard lock(g_thread_registry_mutex);
    g_threads_by_rt[rt].push_back(shared);
}

static bool thread_start_shared(lua_State* L, const std::shared_ptr<ThreadShared>& shared,
                                std::string& error) {
    EryxRuntime* parentRt = eryx_get_runtime(L);
    shared->parentRuntime = parentRt;

    uv_async_t* mainAsync = new uv_async_t;
    auto* mainAsyncData = new ThreadAsyncData{ shared };
    int asyncStatus = uv_async_init(parentRt->loop, mainAsync, thread_main_async_cb);
    if (asyncStatus != 0) {
        delete mainAsyncData;
        delete mainAsync;
        error =
            std::string("failed to create parent thread async handle: ") + uv_strerror(asyncStatus);
        return false;
    }
    mainAsync->data = mainAsyncData;

    {
        std::lock_guard lock(shared->mutex);
        shared->mainAsync = mainAsync;
        shared->mainAsyncInitialized = true;
    }

    thread_track_parent(parentRt, shared);

    shared->worker = std::thread(thread_worker, shared);
    shared->worker.detach();
    return true;
}

static int thread_context_send(lua_State* L) {
    auto* box = check_shared_box_upvalue(L);
    std::shared_ptr<ThreadShared> shared = *box;

    std::vector<uint8_t> payload;
    if (lua_gettop(L) >= 2) {
        thread_store_marshaled_value(L, 2, payload);
    } else {
        thread_store_marshaled_nil(L, payload);
    }

    bool shouldError = false;
    {
        std::lock_guard lock(shared->mutex);
        if (thread_status_terminal(shared->status)) {
            shouldError = true;
        } else {
            shared->childToMain.push_back(std::move(payload));
        }
    }

    if (shouldError) {
        luaL_error(L, "thread is no longer running");
    }

    thread_signal_main(shared);
    return 0;
}

static int thread_context_recv(lua_State* L) {
    auto* box = check_shared_box_upvalue(L);
    std::shared_ptr<ThreadShared> shared = *box;

    std::vector<uint8_t> payload;
    bool hasPayload = false;
    bool shouldError = false;
    std::string errorMessage;
    bool duplicateRecv = false;

    {
        std::lock_guard lock(shared->mutex);
        if (!shared->mainToChild.empty()) {
            payload = std::move(shared->mainToChild.front());
            shared->mainToChild.pop_front();
            hasPayload = true;
        } else if (shared->killRequested) {
            shouldError = true;
            errorMessage = "thread was killed";
        } else if (shared->interruptRequested) {
            shouldError = true;
            errorMessage = "thread was interrupted";
        } else if (shared->childRecvWaiterRef != LUA_NOREF) {
            duplicateRecv = true;
        } else {
            lua_pushthread(L);
            shared->childRecvWaiterRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }
    }

    if (hasPayload) {
        eryx_unmarshall(L, payload.data(), payload.size());
        return 1;
    }
    if (shouldError) {
        luaL_error(L, "%s", errorMessage.c_str());
    }
    if (duplicateRecv) {
        luaL_error(L, "a recv is already pending on this thread context");
    }
    return lua_yield(L, 0);
}

static void thread_prepare_context(lua_State* L, const std::shared_ptr<ThreadShared>& shared) {
    if (!shared->initialContext.empty()) {
        eryx_unmarshall(L, shared->initialContext.data(), shared->initialContext.size());
    } else {
        lua_pushnil(L);
    }

    // Child entrypoints always receive a wrapper context object with the
    // user-supplied payload stored at `.value`.
    lua_newtable(L);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "value");
    lua_remove(L, -2);

    void* ud = lua_newuserdatadtor(L, sizeof(std::shared_ptr<ThreadShared>), shared_ptr_dtor);
    new (ud) std::shared_ptr<ThreadShared>(shared);

    lua_pushvalue(L, -1);
    lua_pushcclosurek(L, thread_context_send, "send", 1, nullptr);
    lua_setfield(L, -3, "send");

    lua_pushvalue(L, -1);
    lua_pushcclosurek(L, thread_context_send, "update", 1, nullptr);
    lua_setfield(L, -3, "update");

    lua_pushvalue(L, -1);
    lua_pushcclosurek(L, thread_context_recv, "recv", 1, nullptr);
    lua_setfield(L, -3, "recv");

    lua_pop(L, 1);
}

static EryxRuntimeHookResult thread_runtime_after_init(EryxRuntimeHost* host, void* userdata,
                                                       std::string& error) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared || !host || !host->GL || !host->rt) {
        error = "thread runtime context is invalid";
        return EryxRuntimeHookResult::Fail;
    }

    // Thread workers create and compile entry chunks concurrently across many
    // isolated runtimes. Keep them on the interpreter path for now to avoid
    // cross-runtime native codegen races.
    host->rt->nativeCodegenMode = EryxNativeCodegenMode::Disabled;

    {
        std::lock_guard lock(shared->mutex);
        shared->childRuntime = host->rt;
    }

    lua_callbacks(host->GL)->userdata = shared;
    lua_callbacks(host->GL)->interrupt = [](lua_State* L, int gc) {
        if (gc >= 0) return;

        auto* shared = static_cast<ThreadShared*>(lua_callbacks(L)->userdata);
        if (!shared) return;

        bool shouldInterrupt = false;
        {
            std::lock_guard lock(shared->mutex);
            shouldInterrupt = shared->killRequested || shared->interruptRequested;
        }

        if (!shouldInterrupt) return;

        eryx_exception_push_keyboard_interrupt(L);
        lua_error(L);
    };

    std::shared_ptr<ThreadShared> sharedRef = shared->shared_from_this();
    uv_async_t* childAsync = new uv_async_t;
    auto* childAsyncData = new ThreadAsyncData{ sharedRef };
    int asyncStatus = uv_async_init(host->rt->loop, childAsync, thread_child_async_cb);
    if (asyncStatus != 0) {
        delete childAsyncData;
        delete childAsync;
        error =
            std::string("failed to create child thread async handle: ") + uv_strerror(asyncStatus);
        return EryxRuntimeHookResult::Fail;
    }
    childAsync->data = childAsyncData;

    {
        std::lock_guard lock(shared->mutex);
        shared->childAsync = childAsync;
        shared->childAsyncInitialized = true;
        shared->status = ThreadStatus::Running;
    }

    if (!shared->mainToChild.empty() || shared->killRequested || shared->interruptRequested) {
        thread_signal_child(sharedRef);
    }

    return EryxRuntimeHookResult::Continue;
}

static EryxRuntimeHookResult thread_runtime_after_load(EryxRuntimeHost*, lua_State* rootThread,
                                                       int* rootArgCount, void* userdata,
                                                       std::string& error) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared || !rootThread || !rootArgCount) {
        error = "thread runtime load state is invalid";
        return EryxRuntimeHookResult::Fail;
    }

    thread_prepare_context(rootThread, shared->shared_from_this());
    *rootArgCount = 1;
    return EryxRuntimeHookResult::Continue;
}

static EryxRuntimeHookResult thread_runtime_on_load_failure(EryxRuntimeHost*, lua_State* rootThread,
                                                            lua_State*, void* userdata,
                                                            std::string& error) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared) {
        if (error.empty()) {
            error = "thread failed to load";
        }
        return EryxRuntimeHookResult::Fail;
    }

    auto* exception = rootThread ? eryx_get_exception(rootThread, -1) : nullptr;
    thread_mark_terminal(shared->shared_from_this(), ThreadStatus::Error,
                         error.empty() ? "failed to load script" : error, {}, false,
                         exception ? eryx_copy_exception(exception) : nullptr);
    return EryxRuntimeHookResult::Stop;
}

static EryxRuntimeHookResult thread_runtime_before_tick(EryxRuntimeHost*, lua_State*,
                                                        void* userdata, std::string&) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared) {
        return EryxRuntimeHookResult::Fail;
    }

    std::lock_guard lock(shared->mutex);
    return thread_status_terminal(shared->status) ? EryxRuntimeHookResult::Stop
                                                  : EryxRuntimeHookResult::Continue;
}

static EryxRuntimeHookResult thread_runtime_on_no_work(EryxRuntimeHost* host, lua_State*,
                                                       void* userdata, std::string&) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared) {
        return EryxRuntimeHookResult::Fail;
    }

    if (eryx_runtime_has_work(host->rt)) {
        return EryxRuntimeHookResult::Continue;
    }

    thread_mark_terminal(shared->shared_from_this(), ThreadStatus::Error,
                         "thread reached a no-work state without publishing a terminal result", {},
                         false);
    return EryxRuntimeHookResult::Stop;
}

static EryxRuntimeHookResult thread_runtime_on_error(EryxRuntimeHost*, lua_State*,
                                                     lua_State* runningLua, void* userdata,
                                                     std::string&) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared) {
        return EryxRuntimeHookResult::Fail;
    }

    ThreadStatus terminalStatus = ThreadStatus::Error;
    std::string message = "thread failed";
    {
        std::lock_guard lock(shared->mutex);
        if (shared->killRequested) {
            terminalStatus = ThreadStatus::Killed;
            message = "thread was killed";
        } else if (shared->interruptRequested) {
            terminalStatus = ThreadStatus::Interrupted;
            message = "thread was interrupted";
        }
    }

    if (terminalStatus == ThreadStatus::Error && runningLua) {
        message = eryx_format_exception(runningLua, -1, false);
    }

    auto* exception = terminalStatus == ThreadStatus::Error && runningLua
                          ? eryx_get_exception(runningLua, -1)
                          : nullptr;
    thread_mark_terminal(shared->shared_from_this(), terminalStatus, message, {}, false,
                         exception ? eryx_copy_exception(exception) : nullptr);
    return EryxRuntimeHookResult::Stop;
}

static EryxRuntimeHookResult thread_runtime_on_root_completed(EryxRuntimeHost*,
                                                              lua_State* rootThread, lua_State*,
                                                              void* userdata, std::string& error) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared || !rootThread) {
        error = "thread completion state is invalid";
        return EryxRuntimeHookResult::Fail;
    }

    std::vector<uint8_t> result;
    bool hasJoinValue = false;
    int top = lua_gettop(rootThread);
    if (top >= 1) {
        thread_store_marshaled_value(rootThread, 1, result);
        hasJoinValue = true;
    }

    {
        std::lock_guard lock(shared->mutex);
        shared->completedJoinValue = result;
        shared->hasCompletedJoinValue = hasJoinValue;
    }

    thread_mark_terminal(shared->shared_from_this(), ThreadStatus::Finished, "", std::move(result),
                         hasJoinValue);
    return EryxRuntimeHookResult::Stop;
}

static void thread_runtime_cleanup(EryxRuntimeHost*, lua_State*, void* userdata) {
    auto* shared = static_cast<ThreadShared*>(userdata);
    if (!shared) {
        return;
    }

    {
        std::lock_guard lock(shared->mutex);
        shared->childRecvWaiterRef = LUA_NOREF;
        shared->childRuntime = nullptr;
    }

    thread_close_child_async(shared->shared_from_this());
}

static void thread_worker(const std::shared_ptr<ThreadShared>& shared) {
    auto fail = [&](ThreadStatus status, const std::string& message,
                    std::unique_ptr<LuaExceptionSnapshot> errorSnapshot = nullptr) {
        thread_mark_terminal(shared, status, message, {}, false, std::move(errorSnapshot));
    };

    try {
        std::string error;
        EryxRuntimeRunHooks hooks;
        hooks.userdata = shared.get();
        hooks.afterInit = thread_runtime_after_init;
        hooks.afterLoad = thread_runtime_after_load;
        hooks.onLoadFailure = thread_runtime_on_load_failure;
        hooks.beforeTick = thread_runtime_before_tick;
        hooks.onNoWork = thread_runtime_on_no_work;
        hooks.onRuntimeError = thread_runtime_on_error;
        hooks.onRootCompleted = thread_runtime_on_root_completed;
        hooks.onCleanup = thread_runtime_cleanup;

        if (!eryx_runtime_run_entry(shared->entry, &hooks, error)) {
            fail(ThreadStatus::Error, error.empty() ? "thread worker failed" : error);
        }
        thread_signal_main(shared);
    } catch (const std::exception& ex) {
        fail(ThreadStatus::Error, std::string("thread worker failed: ") + ex.what());
        thread_signal_main(shared);
    } catch (...) {
        fail(ThreadStatus::Error, "thread worker failed");
        thread_signal_main(shared);
    }
}

static int thread_handle_send(lua_State* L) {
    std::shared_ptr<ThreadShared> shared = check_thread_handle(L, 1);

    std::vector<uint8_t> payload;
    if (lua_gettop(L) >= 2) {
        thread_store_marshaled_value(L, 2, payload);
    } else {
        thread_store_marshaled_nil(L, payload);
    }

    bool shouldError = false;
    {
        std::lock_guard lock(shared->mutex);
        if (thread_status_terminal(shared->status)) {
            shouldError = true;
        } else {
            shared->mainToChild.push_back(std::move(payload));
        }
    }

    if (shouldError) {
        luaL_error(L, "thread is no longer running");
    }

    thread_signal_child(shared);
    return 0;
}

static int thread_handle_recv(lua_State* L) {
    std::shared_ptr<ThreadShared> shared = check_thread_handle(L, 1);

    std::vector<uint8_t> payload;
    bool hasPayload = false;
    bool returnNil = false;
    bool duplicateRecv = false;

    {
        std::lock_guard lock(shared->mutex);
        if (!shared->childToMain.empty()) {
            payload = std::move(shared->childToMain.front());
            shared->childToMain.pop_front();
            hasPayload = true;
        } else if (thread_status_terminal(shared->status)) {
            returnNil = true;
        } else if (shared->mainRecvWaiterRef != LUA_NOREF) {
            duplicateRecv = true;
        } else {
            lua_pushthread(L);
            shared->mainRecvWaiterRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }
    }

    if (hasPayload) {
        eryx_unmarshall(L, payload.data(), payload.size());
        return 1;
    }
    if (returnNil) {
        lua_pushnil(L);
        return 1;
    }
    if (duplicateRecv) {
        luaL_error(L, "a recv is already pending on this thread handle");
    }
    return lua_yield(L, 0);
}

static int thread_handle_index(lua_State* L) {
    std::shared_ptr<ThreadShared> shared = check_thread_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "status") == 0) {
        ThreadStatus status;
        {
            std::lock_guard lock(shared->mutex);
            status = shared->status;
        }

        lua_pushstring(L, thread_status_name(status));
        return 1;
    }

    if (strcmp(key, "error") == 0) {
        std::unique_ptr<LuaExceptionSnapshot> errorSnapshot;
        {
            std::lock_guard lock(shared->mutex);
            if (shared->status == ThreadStatus::Error && shared->errorSnapshot) {
                errorSnapshot = thread_copy_exception_snapshot(shared->errorSnapshot.get());
            }
        }

        if (!errorSnapshot) {
            lua_pushnil(L);
            return 1;
        }

        thread_push_exception_copy(L, errorSnapshot.get());
        return 1;
    }

    if (strcmp(key, "onError") == 0) {
        int onErrorRef = LUA_NOREF;
        {
            std::lock_guard lock(shared->mutex);
            onErrorRef = shared->onErrorRef;
        }

        if (onErrorRef == LUA_NOREF) {
            lua_pushnil(L);
            return 1;
        }

        lua_getref(L, onErrorRef);
        return 1;
    }

    return 0;
}

static int thread_handle_newindex(lua_State* L) {
    std::shared_ptr<ThreadShared> shared = check_thread_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "onError") == 0) {
        if (!lua_isnil(L, 3) && !lua_isfunction(L, 3)) {
            luaL_typeerror(L, 3, "function or nil");
        }

        int oldRef = LUA_NOREF;
        int oldHandleRef = LUA_NOREF;
        int newRef = LUA_NOREF;

        if (!lua_isnil(L, 3)) {
            lua_pushvalue(L, 3);
            newRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }

        {
            std::lock_guard lock(shared->mutex);
            oldRef = shared->onErrorRef;
            oldHandleRef = LUA_NOREF;
            shared->onErrorRef = newRef;

            if (newRef == LUA_NOREF) {
                oldHandleRef = shared->onErrorHandleRef;
                shared->onErrorHandleRef = LUA_NOREF;
            } else if (shared->onErrorHandleRef == LUA_NOREF) {
                lua_pushvalue(L, 1);
                shared->onErrorHandleRef = lua_ref(L, -1);
                lua_pop(L, 1);
            }
        }

        if (oldRef != LUA_NOREF) {
            lua_unref(L, oldRef);
        }
        if (oldHandleRef != LUA_NOREF) {
            lua_unref(L, oldHandleRef);
        }
        return 0;
    }

    if (strcmp(key, "status") == 0 || strcmp(key, "error") == 0) {
        luaL_error(L, "thread handle field '%s' is read-only", key);
    }

    luaL_error(L, "thread handle field '%s' is not writable", key);
    return 0;
}

static int thread_handle_join(lua_State* L) {
    std::shared_ptr<ThreadShared> shared = check_thread_handle(L, 1);

    ThreadStatus status;
    std::vector<uint8_t> joinValue;
    bool hasJoinValue = false;
    std::string message;
    std::unique_ptr<LuaExceptionSnapshot> errorSnapshot;
    bool duplicateJoin = false;
    bool shouldYield = false;

    {
        std::lock_guard lock(shared->mutex);
        status = shared->status;
        if (status == ThreadStatus::Finished) {
            if (shared->hasJoinValue) {
                joinValue = shared->joinValue;
                hasJoinValue = true;
            } else if (shared->hasCompletedJoinValue) {
                joinValue = shared->completedJoinValue;
                hasJoinValue = true;
            }
        } else if (status == ThreadStatus::Error || status == ThreadStatus::Killed ||
                   status == ThreadStatus::Interrupted) {
            message = shared->terminalMessage;
            if (status == ThreadStatus::Error && shared->errorSnapshot) {
                errorSnapshot = thread_copy_exception_snapshot(shared->errorSnapshot.get());
            }
        } else if (shared->mainJoinWaiterRef != LUA_NOREF) {
            duplicateJoin = true;
        } else {
            lua_pushthread(L);
            shared->mainJoinWaiterRef = lua_ref(L, -1);
            lua_pop(L, 1);
            shouldYield = true;
        }
    }

    if (duplicateJoin) {
        luaL_error(L, "a join is already pending on this thread handle");
    }
    if (shouldYield) {
        return lua_yield(L, 0);
    }

    if (status == ThreadStatus::Finished) {
        if (hasJoinValue && !joinValue.empty()) {
            eryx_unmarshall(L, joinValue.data(), joinValue.size());
        } else {
            lua_pushnil(L);
        }
        return 1;
    }

    if (status == ThreadStatus::Error && errorSnapshot) {
        thread_push_exception_copy(L, errorSnapshot.get());
        lua_error(L);
        return 0;
    }

    luaL_error(L, "%s", message.c_str());
    return 0;
}

static int thread_handle_kill(lua_State* L) {
    std::shared_ptr<ThreadShared> shared = check_thread_handle(L, 1);

    {
        std::lock_guard lock(shared->mutex);
        if (thread_status_terminal(shared->status)) {
            return 0;
        }
        shared->killRequested = true;
    }

    thread_signal_child(shared);
    return 0;
}

static void thread_handle_dtor(lua_State* L, void* ud) {
    auto* box = static_cast<ThreadHandleBox*>(ud);
    if (box->shared) {
        ThreadStatus status;
        int onErrorRef = LUA_NOREF;
        int onErrorHandleRef = LUA_NOREF;
        {
            std::lock_guard lock(box->shared->mutex);
            status = box->shared->status;
            onErrorRef = box->shared->onErrorRef;
            onErrorHandleRef = box->shared->onErrorHandleRef;
            box->shared->onErrorRef = LUA_NOREF;
            box->shared->onErrorHandleRef = LUA_NOREF;
        }

        if (!thread_status_terminal(status)) {
            std::fprintf(stderr,
                         "[thread] warning: thread handle was garbage collected while the child "
                         "thread was still %s\n",
                         thread_status_name(status));
        }

        if (onErrorRef != LUA_NOREF) {
            lua_unref(L, onErrorRef);
        }
        if (onErrorHandleRef != LUA_NOREF) {
            lua_unref(L, onErrorHandleRef);
        }

        box->shared.reset();
    }
    box->~ThreadHandleBox();
}

static int thread_push_future_handle(lua_State* L, const std::shared_ptr<FutureShared>& future) {
    auto* box =
        static_cast<FutureHandleBox*>(eryxUdata_pushudata(L, check_udata_ref(L, THREAD_FUTURE_MT)));
    new (box) FutureHandleBox{ future };

    {
        std::lock_guard lock(future->mutex);
        if (future->selfRef == LUA_NOREF) {
            lua_pushvalue(L, -1);
            future->selfRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }
    }

    return 1;
}

static int thread_push_pool_handle(lua_State* L, const std::shared_ptr<PoolShared>& pool) {
    auto* box =
        static_cast<PoolHandleBox*>(eryxUdata_pushudata(L, check_udata_ref(L, THREAD_POOL_MT)));
    new (box) PoolHandleBox{ pool };
    return 1;
}

static int thread_push_worker_handle(lua_State* L, const std::shared_ptr<WorkerShared>& worker) {
    auto* box =
        static_cast<WorkerHandleBox*>(eryxUdata_pushudata(L, check_udata_ref(L, THREAD_WORKER_MT)));
    new (box) WorkerHandleBox{ worker };
    return 1;
}

static void thread_future_fail_now(lua_State* L, const std::shared_ptr<FutureShared>& future,
                                   const std::string& message,
                                   const std::shared_ptr<PoolShared>& pool,
                                   const std::shared_ptr<WorkerShared>& worker) {
    auto errorSnapshot = thread_make_message_exception_snapshot(message);
    int waiterRef = LUA_NOREF;
    int callbackRef = LUA_NOREF;
    int selfRef = LUA_NOREF;
    int releaseSelfRef = LUA_NOREF;

    {
        std::lock_guard futureLock(future->mutex);
        future->status = FutureStatus::Error;
        future->errorSnapshot = thread_copy_exception_snapshot(errorSnapshot.get());
        waiterRef = future->waiterRef;
        future->waiterRef = LUA_NOREF;
        callbackRef = future->onErrorRef;
        selfRef = future->selfRef;
        releaseSelfRef = future->selfRef;
        future->selfRef = LUA_NOREF;
    }

    if (callbackRef == LUA_NOREF && worker) {
        std::lock_guard workerLock(worker->mutex);
        callbackRef = worker->onErrorRef;
    }
    if (callbackRef == LUA_NOREF && pool) {
        std::lock_guard poolLock(pool->mutex);
        callbackRef = pool->onErrorRef;
    }

    EryxRuntime* rt = eryx_get_runtime(L);
    if (callbackRef != LUA_NOREF && selfRef != LUA_NOREF) {
        thread_schedule_exception_callback(rt, callbackRef, selfRef, errorSnapshot.get());
    } else if (!message.empty()) {
        std::fprintf(stderr, "%s", message.c_str());
        if (message.back() != '\n') {
            std::fprintf(stderr, "\n");
        }
        std::fflush(stderr);
    }

    if (waiterRef != LUA_NOREF) {
        thread_resume_exception(rt, waiterRef, errorSnapshot.get());
    }

    if (releaseSelfRef != LUA_NOREF) {
        lua_unref(L, releaseSelfRef);
    }
}

static size_t thread_check_workers_option(lua_State* L, int idx) {
    luaL_checktype(L, idx, LUA_TTABLE);
    lua_getfield(L, idx, "workers");
    int workers = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    luaL_argcheck(L, workers > 0, idx, "workers must be greater than zero");
    return size_t(workers);
}

static std::shared_ptr<FutureShared> thread_enqueue_prepared_job(
    lua_State* L, const std::shared_ptr<PoolShared>& pool,
    const std::shared_ptr<WorkerShared>& worker, const EryxRuntimeEntry& entry, int contextIdx) {
    auto future = std::make_shared<FutureShared>();
    future->parentRuntime = eryx_get_runtime(L);
    future->pool = pool;
    if (worker) {
        future->worker = worker;
    }

    PendingJob job;
    job.entry = entry;
    job.future = future;
    if (contextIdx != 0 && contextIdx <= lua_gettop(L)) {
        thread_store_marshaled_value(L, contextIdx, job.context);
    } else {
        thread_store_marshaled_nil(L, job.context);
    }

    {
        std::lock_guard lock(pool->mutex);
        pool->queuedJobs.push_back(std::move(job));
    }

    thread_push_future_handle(L, future);
    pool_maybe_start_jobs(L, pool);
    return future;
}

static void pool_maybe_start_jobs(lua_State* L, const std::shared_ptr<PoolShared>& pool) {
    while (true) {
        PendingJob job;
        {
            std::lock_guard lock(pool->mutex);
            if (pool->activeCount >= pool->workerLimit || pool->queuedJobs.empty()) {
                return;
            }

            job = std::move(pool->queuedJobs.front());
            pool->queuedJobs.pop_front();
            pool->activeCount++;
        }

        auto shared = std::make_shared<ThreadShared>();
        shared->entry = job.entry;
        shared->initialContext = std::move(job.context);
        shared->future = job.future;

        {
            std::lock_guard futureLock(job.future->mutex);
            job.future->status = FutureStatus::Running;
            job.future->runningThread = shared;
        }

        std::string error;
        if (!thread_start_shared(L, shared, error)) {
            {
                std::lock_guard lock(pool->mutex);
                if (pool->activeCount > 0) {
                    pool->activeCount--;
                }
            }
            thread_future_fail_now(L, job.future, error, pool, job.future->worker);
        }
    }
}

static int thread_future_index(lua_State* L) {
    std::shared_ptr<FutureShared> future = check_future_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "status") == 0) {
        FutureStatus status;
        {
            std::lock_guard lock(future->mutex);
            status = future->status;
        }
        lua_pushstring(L, future_status_name(status));
        return 1;
    }

    if (strcmp(key, "error") == 0) {
        std::unique_ptr<LuaExceptionSnapshot> errorSnapshot;
        {
            std::lock_guard lock(future->mutex);
            if (future->status == FutureStatus::Error ||
                future->status == FutureStatus::Cancelled) {
                if (future->errorSnapshot) {
                    errorSnapshot = thread_copy_exception_snapshot(future->errorSnapshot.get());
                }
            }
        }
        if (!errorSnapshot) {
            lua_pushnil(L);
            return 1;
        }
        thread_push_exception_copy(L, errorSnapshot.get());
        return 1;
    }

    if (strcmp(key, "update") == 0) {
        std::vector<uint8_t> updateValue;
        bool hasUpdate = false;
        {
            std::lock_guard lock(future->mutex);
            hasUpdate = future->hasUpdate;
            updateValue = future->latestUpdate;
        }
        if (!hasUpdate) {
            lua_pushnil(L);
            return 1;
        }
        eryx_unmarshall(L, updateValue.data(), updateValue.size());
        return 1;
    }

    if (strcmp(key, "onError") == 0 || strcmp(key, "onUpdate") == 0) {
        int callbackRef = LUA_NOREF;
        {
            std::lock_guard lock(future->mutex);
            callbackRef = strcmp(key, "onError") == 0 ? future->onErrorRef : future->onUpdateRef;
        }
        if (callbackRef == LUA_NOREF) {
            lua_pushnil(L);
            return 1;
        }
        lua_getref(L, callbackRef);
        return 1;
    }

    return 0;
}

static int thread_future_newindex(lua_State* L) {
    std::shared_ptr<FutureShared> future = check_future_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "onError") == 0 || strcmp(key, "onUpdate") == 0) {
        if (!lua_isnil(L, 3) && !lua_isfunction(L, 3)) {
            luaL_typeerror(L, 3, "function or nil");
        }

        int oldRef = LUA_NOREF;
        int newRef = LUA_NOREF;
        if (!lua_isnil(L, 3)) {
            lua_pushvalue(L, 3);
            newRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }

        {
            std::lock_guard lock(future->mutex);
            oldRef = strcmp(key, "onError") == 0 ? future->onErrorRef : future->onUpdateRef;
            if (strcmp(key, "onError") == 0) {
                future->onErrorRef = newRef;
            } else {
                future->onUpdateRef = newRef;
            }
        }

        if (oldRef != LUA_NOREF) {
            lua_unref(L, oldRef);
        }
        return 0;
    }

    if (strcmp(key, "status") == 0 || strcmp(key, "error") == 0 || strcmp(key, "update") == 0) {
        luaL_error(L, "future field '%s' is read-only", key);
    }

    luaL_error(L, "future field '%s' is not writable", key);
    return 0;
}

static int thread_future_wait(lua_State* L) {
    std::shared_ptr<FutureShared> future = check_future_handle(L, 1);

    FutureStatus status;
    std::vector<uint8_t> resultValue;
    bool hasResultValue = false;
    std::unique_ptr<LuaExceptionSnapshot> errorSnapshot;
    bool duplicateWait = false;
    bool shouldYield = false;

    {
        std::lock_guard lock(future->mutex);
        status = future->status;
        if (status == FutureStatus::Finished) {
            resultValue = future->resultValue;
            hasResultValue = future->hasResultValue;
        } else if (status == FutureStatus::Error || status == FutureStatus::Cancelled) {
            if (future->errorSnapshot) {
                errorSnapshot = thread_copy_exception_snapshot(future->errorSnapshot.get());
            }
        } else if (future->waiterRef != LUA_NOREF) {
            duplicateWait = true;
        } else {
            lua_pushthread(L);
            future->waiterRef = lua_ref(L, -1);
            lua_pop(L, 1);
            shouldYield = true;
        }
    }

    if (duplicateWait) {
        luaL_error(L, "a wait is already pending on this future");
    }
    if (shouldYield) {
        return lua_yield(L, 0);
    }

    if (status == FutureStatus::Finished) {
        if (hasResultValue && !resultValue.empty()) {
            eryx_unmarshall(L, resultValue.data(), resultValue.size());
        } else {
            lua_pushnil(L);
        }
        return 1;
    }

    if (errorSnapshot) {
        thread_push_exception_copy(L, errorSnapshot.get());
        lua_error(L);
        return 0;
    }

    luaL_error(L, "future is not ready");
    return 0;
}

static void thread_future_dtor(lua_State* L, void* ud) {
    auto* box = static_cast<FutureHandleBox*>(ud);
    if (box->shared) {
        int onErrorRef = LUA_NOREF;
        int onUpdateRef = LUA_NOREF;
        int selfRef = LUA_NOREF;
        {
            std::lock_guard lock(box->shared->mutex);
            onErrorRef = box->shared->onErrorRef;
            onUpdateRef = box->shared->onUpdateRef;
            selfRef = box->shared->selfRef;
            box->shared->onErrorRef = LUA_NOREF;
            box->shared->onUpdateRef = LUA_NOREF;
            box->shared->selfRef = LUA_NOREF;
        }
        if (onErrorRef != LUA_NOREF) {
            lua_unref(L, onErrorRef);
        }
        if (onUpdateRef != LUA_NOREF) {
            lua_unref(L, onUpdateRef);
        }
        if (selfRef != LUA_NOREF) {
            lua_unref(L, selfRef);
        }
        box->shared.reset();
    }
    box->~FutureHandleBox();
}

static int thread_pool_index(lua_State* L) {
    std::shared_ptr<PoolShared> pool = check_pool_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "workers") == 0 || strcmp(key, "active") == 0 || strcmp(key, "queued") == 0) {
        size_t workers = 0;
        size_t active = 0;
        size_t queued = 0;
        {
            std::lock_guard lock(pool->mutex);
            workers = pool->workerLimit;
            active = pool->activeCount;
            queued = pool->queuedJobs.size();
        }
        if (strcmp(key, "workers") == 0) {
            lua_pushinteger(L, int(workers));
        } else if (strcmp(key, "active") == 0) {
            lua_pushinteger(L, int(active));
        } else {
            lua_pushinteger(L, int(queued));
        }
        return 1;
    }

    if (strcmp(key, "onError") == 0 || strcmp(key, "onUpdate") == 0) {
        int callbackRef = LUA_NOREF;
        {
            std::lock_guard lock(pool->mutex);
            callbackRef = strcmp(key, "onError") == 0 ? pool->onErrorRef : pool->onUpdateRef;
        }
        if (callbackRef == LUA_NOREF) {
            lua_pushnil(L);
            return 1;
        }
        lua_getref(L, callbackRef);
        return 1;
    }

    return 0;
}

static int thread_pool_newindex(lua_State* L) {
    std::shared_ptr<PoolShared> pool = check_pool_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "onError") == 0 || strcmp(key, "onUpdate") == 0) {
        if (!lua_isnil(L, 3) && !lua_isfunction(L, 3)) {
            luaL_typeerror(L, 3, "function or nil");
        }

        int oldRef = LUA_NOREF;
        int newRef = LUA_NOREF;
        if (!lua_isnil(L, 3)) {
            lua_pushvalue(L, 3);
            newRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }

        {
            std::lock_guard lock(pool->mutex);
            oldRef = strcmp(key, "onError") == 0 ? pool->onErrorRef : pool->onUpdateRef;
            if (strcmp(key, "onError") == 0) {
                pool->onErrorRef = newRef;
            } else {
                pool->onUpdateRef = newRef;
            }
        }

        if (oldRef != LUA_NOREF) {
            lua_unref(L, oldRef);
        }
        return 0;
    }

    luaL_error(L, "thread pool field '%s' is not writable", key);
    return 0;
}

static int thread_pool_spawn(lua_State* L) {
    std::shared_ptr<PoolShared> pool = check_pool_handle(L, 1);

    EryxRuntimeEntry entry;
    std::string error;
    if (!eryx_runtime_prepare_entry(L, 2, true, entry, error)) {
        luaL_error(L, "%s", error.c_str());
    }

    thread_enqueue_prepared_job(L, pool, nullptr, entry, lua_gettop(L) >= 3 ? 3 : 0);
    return 1;
}

static void thread_pool_dtor(lua_State* L, void* ud) {
    auto* box = static_cast<PoolHandleBox*>(ud);
    if (box->shared) {
        int onErrorRef = LUA_NOREF;
        int onUpdateRef = LUA_NOREF;
        {
            std::lock_guard lock(box->shared->mutex);
            onErrorRef = box->shared->onErrorRef;
            onUpdateRef = box->shared->onUpdateRef;
            box->shared->onErrorRef = LUA_NOREF;
            box->shared->onUpdateRef = LUA_NOREF;
        }
        if (onErrorRef != LUA_NOREF) {
            lua_unref(L, onErrorRef);
        }
        if (onUpdateRef != LUA_NOREF) {
            lua_unref(L, onUpdateRef);
        }
        box->shared.reset();
    }
    box->~PoolHandleBox();
}

static int thread_worker_index(lua_State* L) {
    std::shared_ptr<WorkerShared> worker = check_worker_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "workers") == 0 || strcmp(key, "active") == 0 || strcmp(key, "queued") == 0) {
        std::shared_ptr<PoolShared> pool = worker->pool;
        size_t workers = 0;
        size_t active = 0;
        size_t queued = 0;
        {
            std::lock_guard lock(pool->mutex);
            workers = pool->workerLimit;
            active = pool->activeCount;
            queued = pool->queuedJobs.size();
        }
        if (strcmp(key, "workers") == 0) {
            lua_pushinteger(L, int(workers));
        } else if (strcmp(key, "active") == 0) {
            lua_pushinteger(L, int(active));
        } else {
            lua_pushinteger(L, int(queued));
        }
        return 1;
    }

    if (strcmp(key, "onError") == 0 || strcmp(key, "onUpdate") == 0) {
        int callbackRef = LUA_NOREF;
        {
            std::lock_guard lock(worker->mutex);
            callbackRef = strcmp(key, "onError") == 0 ? worker->onErrorRef : worker->onUpdateRef;
        }
        if (callbackRef == LUA_NOREF) {
            lua_pushnil(L);
            return 1;
        }
        lua_getref(L, callbackRef);
        return 1;
    }

    return 0;
}

static int thread_worker_newindex(lua_State* L) {
    std::shared_ptr<WorkerShared> worker = check_worker_handle(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "onError") == 0 || strcmp(key, "onUpdate") == 0) {
        if (!lua_isnil(L, 3) && !lua_isfunction(L, 3)) {
            luaL_typeerror(L, 3, "function or nil");
        }

        int oldRef = LUA_NOREF;
        int newRef = LUA_NOREF;
        if (!lua_isnil(L, 3)) {
            lua_pushvalue(L, 3);
            newRef = lua_ref(L, -1);
            lua_pop(L, 1);
        }

        {
            std::lock_guard lock(worker->mutex);
            oldRef = strcmp(key, "onError") == 0 ? worker->onErrorRef : worker->onUpdateRef;
            if (strcmp(key, "onError") == 0) {
                worker->onErrorRef = newRef;
            } else {
                worker->onUpdateRef = newRef;
            }
        }

        if (oldRef != LUA_NOREF) {
            lua_unref(L, oldRef);
        }
        return 0;
    }

    luaL_error(L, "thread worker field '%s' is not writable", key);
    return 0;
}

static int thread_worker_submit(lua_State* L) {
    std::shared_ptr<WorkerShared> worker = check_worker_handle(L, 1);
    int itemCount = lua_gettop(L) - 1;
    luaL_argcheck(L, itemCount > 0, 2, "expected at least one item");

    if (itemCount == 1) {
        thread_enqueue_prepared_job(L, worker->pool, worker, worker->job, 2);
        return 1;
    }

    lua_createtable(L, itemCount, 0);
    for (int i = 0; i < itemCount; ++i) {
        thread_enqueue_prepared_job(L, worker->pool, worker, worker->job, i + 2);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

static void thread_worker_dtor(lua_State* L, void* ud) {
    auto* box = static_cast<WorkerHandleBox*>(ud);
    if (box->shared) {
        int onErrorRef = LUA_NOREF;
        int onUpdateRef = LUA_NOREF;
        {
            std::lock_guard lock(box->shared->mutex);
            onErrorRef = box->shared->onErrorRef;
            onUpdateRef = box->shared->onUpdateRef;
            box->shared->onErrorRef = LUA_NOREF;
            box->shared->onUpdateRef = LUA_NOREF;
        }
        if (onErrorRef != LUA_NOREF) {
            lua_unref(L, onErrorRef);
        }
        if (onUpdateRef != LUA_NOREF) {
            lua_unref(L, onUpdateRef);
        }
        box->shared.reset();
    }
    box->~WorkerHandleBox();
}

static luaL_Reg threadHandleMethods[] = {
    { "send", thread_handle_send }, { "recv", thread_handle_recv }, { "join", thread_handle_join },
    { "kill", thread_handle_kill }, { nullptr, nullptr },
};

static udataDef threadHandleDef = {
    .name = THREAD_HANDLE_MT,
    .size = sizeof(ThreadHandleBox),
    .fields = nullptr,
    .indexFallback = thread_handle_index,
    .newindexFallback = thread_handle_newindex,
    .metamethods = nullptr,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = threadHandleMethods,
    .destructor = thread_handle_dtor,
};

static luaL_Reg threadFutureMethods[] = {
    { "wait", thread_future_wait },
    { nullptr, nullptr },
};

static udataDef threadFutureDef = {
    .name = THREAD_FUTURE_MT,
    .size = sizeof(FutureHandleBox),
    .fields = nullptr,
    .indexFallback = thread_future_index,
    .newindexFallback = thread_future_newindex,
    .metamethods = nullptr,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = threadFutureMethods,
    .destructor = thread_future_dtor,
};

static luaL_Reg threadPoolMethods[] = {
    { "spawn", thread_pool_spawn },
    { nullptr, nullptr },
};

static udataDef threadPoolDef = {
    .name = THREAD_POOL_MT,
    .size = sizeof(PoolHandleBox),
    .fields = nullptr,
    .indexFallback = thread_pool_index,
    .newindexFallback = thread_pool_newindex,
    .metamethods = nullptr,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = threadPoolMethods,
    .destructor = thread_pool_dtor,
};

static luaL_Reg threadWorkerMethods[] = {
    { "submit", thread_worker_submit },
    { nullptr, nullptr },
};

static udataDef threadWorkerDef = {
    .name = THREAD_WORKER_MT,
    .size = sizeof(WorkerHandleBox),
    .fields = nullptr,
    .indexFallback = thread_worker_index,
    .newindexFallback = thread_worker_newindex,
    .metamethods = nullptr,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = threadWorkerMethods,
    .destructor = thread_worker_dtor,
};

static int thread_spawn(lua_State* L) {
    auto shared = std::make_shared<ThreadShared>();
    EryxRuntimeEntry entry;
    std::string error;
    if (!eryx_runtime_prepare_entry(L, 1, false, entry, error)) {
        luaL_error(L, "%s", error.c_str());
    }
    shared->entry = entry;

    if (lua_gettop(L) >= 2) {
        thread_store_marshaled_value(L, 2, shared->initialContext);
    } else {
        thread_store_marshaled_nil(L, shared->initialContext);
    }

    if (!thread_start_shared(L, shared, error)) {
        luaL_error(L, "%s", error.c_str());
    }

    auto* box =
        static_cast<ThreadHandleBox*>(eryxUdata_pushudata(L, check_udata_ref(L, THREAD_HANDLE_MT)));
    new (box) ThreadHandleBox{ shared };

    return 1;
}

static int thread_pool(lua_State* L) {
    auto pool = std::make_shared<PoolShared>();
    pool->parentRuntime = eryx_get_runtime(L);
    pool->workerLimit = thread_check_workers_option(L, 1);
    return thread_push_pool_handle(L, pool);
}

static int thread_cpu_count(lua_State* L) {
    unsigned int count = std::thread::hardware_concurrency();
    lua_pushinteger(L, count == 0 ? 1 : int(count));
    return 1;
}

static int thread_worker_create(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    auto worker = std::make_shared<WorkerShared>();
    worker->parentRuntime = eryx_get_runtime(L);
    worker->pool = std::make_shared<PoolShared>();
    worker->pool->parentRuntime = worker->parentRuntime;
    worker->pool->workerLimit = thread_check_workers_option(L, 1);

    lua_getfield(L, 1, "job");
    std::string error;
    if (!eryx_runtime_prepare_entry(L, -1, true, worker->job, error)) {
        lua_pop(L, 1);
        luaL_error(L, "%s", error.c_str());
    }
    lua_pop(L, 1);

    return thread_push_worker_handle(L, worker);
}

LUAU_MODULE_EXPORT int luauopen_thread(lua_State* L) {
    eryxUdata_registerudata(L, &threadHandleDef);
    eryxUdata_registerudata(L, &threadFutureDef);
    eryxUdata_registerudata(L, &threadPoolDef);
    eryxUdata_registerudata(L, &threadWorkerDef);

    lua_newtable(L);
    lua_pushcfunction(L, thread_spawn, "spawn");
    lua_setfield(L, -2, "spawn");
    lua_pushcfunction(L, thread_cpu_count, "cpuCount");
    lua_setfield(L, -2, "cpuCount");
    lua_pushcfunction(L, thread_pool, "pool");
    lua_setfield(L, -2, "pool");
    lua_pushcfunction(L, thread_worker_create, "worker");
    lua_setfield(L, -2, "worker");
    lua_setreadonly(L, -1, true);
    return 1;
}
