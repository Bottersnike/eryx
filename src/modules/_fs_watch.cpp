// _fs_watch.cpp -- Low-level filesystem watcher backed by libuv's uv_fs_event.
//
//   _fs_watch.create(path, recursive, callback) -> WatchHandle
//   WatchHandle:stop()
//
// The callback receives (eventType: "change"|"rename", filename: string?).
// This module is wrapped by the pure-Luau `fs_watch` module which provides
// a Signal-based API.
// ---------------------------------------------------------------------------

#include <cstdio>
#include <cstring>

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
    .entry = "luauopen__fs_watch",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// WatchHandle -- userdata wrapping a uv_fs_event_t
// ---------------------------------------------------------------------------
static const char* WATCH_HANDLE_MT = "FsWatchHandle";

struct WatchHandle {
    uv_fs_event_t fsEvent;
    EryxRuntime* rt;
    int callbackRef;  // ref to the Lua callback function
    int selfRef;      // ref to the userdata itself (prevent GC while active)
    bool active;
};

// Called by libuv when a filesystem event occurs.
static void fs_event_cb(uv_fs_event_t* handle, const char* filename, int events, int status) {
    auto* wh = (WatchHandle*)handle->data;
    if (!wh->active) return;
    if (status < 0) return;  // silently ignore errors

    lua_State* GL = wh->rt->GL;

    // Create a new thread for this callback invocation
    lua_State* TL = lua_newthread(GL);

    // Push the callback function onto the thread's stack
    lua_getref(GL, wh->callbackRef);
    lua_xmove(GL, TL, 1);

    // Arg 1: event type
    if (events & UV_RENAME) {
        lua_pushstring(TL, "rename");
    } else {
        lua_pushstring(TL, "change");
    }

    // Arg 2: filename (may be nil on some platforms)
    if (filename && filename[0] != '\0') {
        lua_pushstring(TL, filename);
    } else {
        lua_pushnil(TL);
    }

    // Ref the thread to keep it alive, then schedule it
    int threadRef = lua_ref(GL, -1);
    lua_pop(GL, 1);

    eryx_push_thread(wh->rt, threadRef, 2, false);
}

// Close callback -- invoked after uv_close finishes. Safe to release refs now.
static void on_close(uv_handle_t* handle) {
    auto* wh = (WatchHandle*)handle->data;
    if (wh->callbackRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->callbackRef);
        wh->callbackRef = LUA_NOREF;
    }
    if (wh->selfRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->selfRef);
        wh->selfRef = LUA_NOREF;
    }
}

static void stop_watcher(WatchHandle* wh) {
    if (!wh->active) return;
    wh->active = false;
    uv_fs_event_stop(&wh->fsEvent);
    uv_close((uv_handle_t*)&wh->fsEvent, on_close);
}

// WatchHandle:stop()
static int watchhandle_stop(lua_State* L) {
    auto* wh = (WatchHandle*)luaL_checkudata(L, 1, WATCH_HANDLE_MT);
    stop_watcher(wh);
    return 0;
}

// WatchHandle:ref() - make this handle keep the event loop alive.
static int watchhandle_ref(lua_State* L) {
    auto* wh = (WatchHandle*)luaL_checkudata(L, 1, WATCH_HANDLE_MT);
    if (wh->active) {
        uv_ref((uv_handle_t*)&wh->fsEvent);
    }
    return 0;
}

// WatchHandle:unref() - allow the event loop to exit even if this handle is active.
static int watchhandle_unref(lua_State* L) {
    auto* wh = (WatchHandle*)luaL_checkudata(L, 1, WATCH_HANDLE_MT);
    if (wh->active) {
        uv_unref((uv_handle_t*)&wh->fsEvent);
    }
    return 0;
}

// WatchHandle.__gc (kept for explicit :stop() paths)
static int watchhandle_gc(lua_State* L) {
    auto* wh = (WatchHandle*)luaL_checkudata(L, 1, WATCH_HANDLE_MT);
    stop_watcher(wh);
    return 0;
}

// Destructor called by Luau GC (lua_newuserdatadtor).
// rt->GL is used for lua_unref so refs are released during normal GC,
// not just lua_close.  uv_close is async and may not be safe here
// (the loop might be dead), so we just stop the watcher synchronously.
static void watchhandle_dtor(void* ud) {
    auto* wh = (WatchHandle*)ud;
    if (wh->active) {
        wh->active = false;
        uv_fs_event_stop(&wh->fsEvent);
    }
    lua_State* GL = wh->rt->GL;
    if (wh->callbackRef != LUA_NOREF) {
        lua_unref(GL, wh->callbackRef);
        wh->callbackRef = LUA_NOREF;
    }
    if (wh->selfRef != LUA_NOREF) {
        lua_unref(GL, wh->selfRef);
        wh->selfRef = LUA_NOREF;
    }
}

// ---------------------------------------------------------------------------
// _fs_watch.create(path, recursive, callback) -> WatchHandle
// ---------------------------------------------------------------------------
static int fswatch_create(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    bool recursive = lua_toboolean(L, 2) != 0;
    luaL_checktype(L, 3, LUA_TFUNCTION);

    auto* rt = eryx_get_runtime(L);

    // Create the WatchHandle as a full userdata with GC destructor
    auto* wh = (WatchHandle*)lua_newuserdatadtor(L, sizeof(WatchHandle), watchhandle_dtor);
    memset(wh, 0, sizeof(WatchHandle));

    // Set up the metatable
    luaL_getmetatable(L, WATCH_HANDLE_MT);
    lua_setmetatable(L, -2);

    // Initialise fields
    wh->rt = rt;
    wh->active = false;
    wh->callbackRef = LUA_NOREF;
    wh->selfRef = LUA_NOREF;

    // Init the uv handle
    int r = uv_fs_event_init(rt->loop, &wh->fsEvent);
    if (r < 0) {
        luaL_error(L, "Failed to init fs watcher: %s", uv_strerror(r));
        return 0;
    }
    wh->fsEvent.data = wh;

    // Ref the callback (at stack index 3)
    lua_pushvalue(L, 3);
    wh->callbackRef = lua_ref(L, -1);
    lua_pop(L, 1);

    // Ref the userdata itself to prevent GC while the watcher is active.
    // The userdata is currently at the top of the stack.
    lua_pushvalue(L, -1);
    wh->selfRef = lua_ref(L, -1);
    lua_pop(L, 1);

    // Start watching
    unsigned int flags = recursive ? UV_FS_EVENT_RECURSIVE : 0;
    r = uv_fs_event_start(&wh->fsEvent, fs_event_cb, path, flags);
    if (r < 0) {
        // Clean up refs on failure
        lua_unref(L, wh->callbackRef);
        wh->callbackRef = LUA_NOREF;
        lua_unref(L, wh->selfRef);
        wh->selfRef = LUA_NOREF;
        uv_close((uv_handle_t*)&wh->fsEvent, nullptr);
        luaL_error(L, "Failed to watch '%s': %s", path, uv_strerror(r));
        return 0;
    }

    wh->active = true;

    // Unref by default so the watcher doesn't keep the event loop alive
    // on its own. The server (or other ref'd handles) keeps the loop running;
    // when they close, the loop exits and the watcher is cleaned up by GC.
    uv_unref((uv_handle_t*)&wh->fsEvent);

    // Return the userdata
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------
LUAU_MODULE_EXPORT int luauopen__fs_watch(lua_State* L) {
    // Register the WatchHandle metatable
    luaL_newmetatable(L, WATCH_HANDLE_MT);

    lua_pushcfunction(L, watchhandle_stop, "stop");
    lua_setfield(L, -2, "stop");

    lua_pushcfunction(L, watchhandle_ref, "ref");
    lua_setfield(L, -2, "ref");

    lua_pushcfunction(L, watchhandle_unref, "unref");
    lua_setfield(L, -2, "unref");

    // Note: __gc is not supported in Luau; cleanup uses lua_newuserdatadtor

    // __index = metatable itself (so :stop() works)
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pop(L, 1);  // pop metatable

    // Build the module table
    lua_newtable(L);

    lua_pushcfunction(L, fswatch_create, "create");
    lua_setfield(L, -2, "create");

    lua_setreadonly(L, -1, true);
    return 1;
}
