// task.cpp -- Roblox-compatible task scheduling library backed by libuv timers.
//
//   task.spawn(f, ...)      -> thread   (resume immediately)
//   task.defer(f, ...)      -> thread   (resume next resumption cycle)
//   task.delay(d, f, ...)   -> thread   (resume after d seconds)
//   task.wait(d?)           -> number   (yield for d seconds, returns elapsed)
//   task.cancel(t)                      (cancel a pending thread)
// ---------------------------------------------------------------------------

#include <cstdio>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "uv.h"

// ---------------------------------------------------------------------------
// Luau module definition
// ---------------------------------------------------------------------------
static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_task",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Timer callback payload
// ---------------------------------------------------------------------------
struct TaskTimerData {
    EryxRuntime* rt;
    int threadRef;
    int nargs;
    uint64_t startMs;  // for task.wait elapsed calculation
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static const char* COROUTINE_STATUS[] = { "running", "suspended", "normal", "finished",
                                          "finished (with error)" };

// Accepts a function or thread at stack index 1.
// If function: creates a new thread, moves the function onto it, replaces index 1 with the thread.
// If thread: leaves it in place.
// Returns the lua_State* for the thread.
static lua_State* coerce_to_thread(lua_State* L) {
    if (lua_isfunction(L, 1)) {
        lua_State* TL = lua_newthread(L);
        lua_xpush(L, TL, 1);   // push function onto new thread
        lua_remove(L, 1);      // remove original function
        lua_insert(L, 1);      // put thread at index 1
        return TL;
    }
    if (lua_isthread(L, 1)) {
        return lua_tothread(L, 1);
    }
    luaL_error(L, "function or thread expected, got %s", luaL_typename(L, 1));
    return nullptr;
}

// Move args from L (index 2..top) onto TL. Returns count moved.
static int move_args(lua_State* L, lua_State* TL) {
    int nargs = lua_gettop(L) - 1;  // everything after the thread at index 1
    if (nargs > 0) {
        lua_xmove(L, TL, nargs);
    }
    return nargs;
}

// ---------------------------------------------------------------------------
// task.spawn(functionOrThread, ...)
// ---------------------------------------------------------------------------
static int task_spawn(lua_State* L) {
    auto rt = eryx_get_runtime(L);
    bool wasExistingThread = lua_isthread(L, 1);
    lua_State* TL = coerce_to_thread(L);

    // If spawning an already-scheduled thread, cancel its pending schedule
    if (wasExistingThread) {
        eryx_cancel_thread(rt, lua_mainthread(L), TL);
    }

    int nargs = move_args(L, TL);

    int status = lua_costatus(L, TL);
    if (status != LUA_COSUS) {
        luaL_error(L, "cannot resume %s coroutine", COROUTINE_STATUS[status]);
    }

    int res = lua_resume(TL, L, nargs);
    if (res != LUA_OK && res != LUA_YIELD && res != LUA_BREAK) {
        // Propagate the error from the spawned thread
        lua_xmove(TL, L, 1);
        lua_error(L);
    }

    // Return the thread (it's still at index 1)
    lua_settop(L, 1);
    return 1;
}

// ---------------------------------------------------------------------------
// task.defer(functionOrThread, ...)
// ---------------------------------------------------------------------------
static int task_defer(lua_State* L) {
    auto rt = eryx_get_runtime(L);
    lua_State* TL = coerce_to_thread(L);

    int nargs = move_args(L, TL);

    // Create a ref to keep the thread alive
    lua_pushvalue(L, 1);  // push thread again for ref
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);

    eryx_push_thread(rt, ref, nargs, false);

    // Return the thread
    lua_settop(L, 1);
    return 1;
}

// ---------------------------------------------------------------------------
// task.delay(seconds, functionOrThread, ...)
// ---------------------------------------------------------------------------
static void delay_timer_cb(uv_timer_t* handle) {
    auto* data = (TaskTimerData*)handle->data;
    EryxRuntime* rt = data->rt;

    // Remove from pending timers map
    rt->pendingTimers.erase(data->threadRef);

    eryx_push_thread(rt, data->threadRef, data->nargs, false);

    delete data;
    uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_timer_t*)h; });
}

static int task_delay(lua_State* L) {
    auto rt = eryx_get_runtime(L);

    double seconds = luaL_checknumber(L, 1);
    if (seconds < 0) seconds = 0;
    lua_remove(L, 1);  // remove seconds, now function/thread is at index 1

    lua_State* TL = coerce_to_thread(L);
    int nargs = move_args(L, TL);

    // Ref the thread
    lua_pushvalue(L, 1);
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);

    // Create UV timer
    auto* timer = new uv_timer_t;
    uv_timer_init(rt->loop, timer);

    auto* data = new TaskTimerData{ rt, ref, nargs, 0 };
    timer->data = data;

    uint64_t ms = (uint64_t)(seconds * 1000.0);
    uv_timer_start(timer, delay_timer_cb, ms, 0);

    rt->pendingTimers[ref] = timer;

    // Return the thread
    lua_settop(L, 1);
    return 1;
}

// ---------------------------------------------------------------------------
// task.wait(seconds?)
// ---------------------------------------------------------------------------
static void wait_timer_cb(uv_timer_t* handle) {
    auto* data = (TaskTimerData*)handle->data;
    EryxRuntime* rt = data->rt;

    // Remove from pending timers map
    rt->pendingTimers.erase(data->threadRef);

    // Push elapsed time onto the thread's stack as the resume value
    lua_getref(rt->GL, data->threadRef);
    lua_State* TL = lua_tothread(rt->GL, -1);
    lua_pop(rt->GL, 1);

    double elapsed = (uv_now(rt->loop) - data->startMs) / 1000.0;
    lua_pushnumber(TL, elapsed);

    eryx_push_thread(rt, data->threadRef, 1, false);

    delete data;
    uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_timer_t*)h; });
}

static int task_wait(lua_State* L) {
    auto rt = eryx_get_runtime(L);

    double seconds = luaL_optnumber(L, 1, 0);
    if (seconds < 0) seconds = 0;

    // Ref the current thread
    lua_pushthread(L);
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);

    // Create UV timer
    auto* timer = new uv_timer_t;
    uv_timer_init(rt->loop, timer);

    auto* data = new TaskTimerData{ rt, ref, 0, uv_now(rt->loop) };
    timer->data = data;

    uint64_t ms = (uint64_t)(seconds * 1000.0);
    uv_timer_start(timer, wait_timer_cb, ms, 0);

    rt->pendingTimers[ref] = timer;

    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// task.cancel(thread)
// ---------------------------------------------------------------------------
static int task_cancel(lua_State* L) {
    auto rt = eryx_get_runtime(L);
    lua_State* GL = lua_mainthread(L);

    lua_State* target = lua_tothread(L, 1);
    luaL_argexpected(L, target != nullptr, 1, "thread");

    eryx_cancel_thread(rt, GL, target);

    return 0;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------
LUAU_MODULE_EXPORT int luauopen_task(lua_State* L) {
    lua_newtable(L);

    lua_pushcfunction(L, task_spawn, "spawn");
    lua_setfield(L, -2, "spawn");
    lua_pushcfunction(L, task_defer, "defer");
    lua_setfield(L, -2, "defer");
    lua_pushcfunction(L, task_delay, "delay");
    lua_setfield(L, -2, "delay");
    lua_pushcfunction(L, task_wait, "wait");
    lua_setfield(L, -2, "wait");
    lua_pushcfunction(L, task_cancel, "cancel");
    lua_setfield(L, -2, "cancel");

    return 1;
}
