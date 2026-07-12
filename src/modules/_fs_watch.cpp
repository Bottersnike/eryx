// _fs_watch.cpp -- Low-level filesystem watcher with normalized event delivery.
//
//   _fs_watch.create(path, recursive, callback) -> WatchHandle
//   WatchHandle:stop()
//
// The callback receives a single event table:
//   {
//       kind = "create" | "remove" | "modify" | "rename" | "overflow" | "unknown",
//       path = string,
//       oldPath = string?,
//       filename = string?,
//       oldFilename = string?,
//       relativePath = string?,
//       oldRelativePath = string?,
//       isDirectory = boolean?,
//       rawKind = string?,
//   }
//
// Native watcher callbacks are bridged through uv_async_t before touching Luau.
// ---------------------------------------------------------------------------

#include <atomic>
#include <cstdio>
#include <cstring>
#include <efsw/efsw.hpp>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include "../LuaUtil.hpp"
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
// WatchHandle
// ---------------------------------------------------------------------------
udataRef* fsWatchHandleRef;

struct NormalizedEvent {
    std::string kind;
    std::string path;
    std::string oldPath;
    std::string filename;
    std::string oldFilename;
    std::string relativePath;
    std::string oldRelativePath;
    std::string rawKind;
    bool hasOldPath = false;
    bool hasFilename = false;
    bool hasOldFilename = false;
    bool hasRelativePath = false;
    bool hasOldRelativePath = false;
    bool hasIsDirectory = false;
    bool isDirectory = false;
};

class WatchBackend {
   public:
    virtual ~WatchBackend() = default;
    virtual bool start(std::string& error) = 0;
    virtual void stop() = 0;
};

struct WatchHandle {
    uv_async_t async;
    EryxRuntime* rt = nullptr;
    int callbackRef = LUA_NOREF;  // ref to the Lua callback function
    int selfRef = LUA_NOREF;      // ref to the userdata itself (prevent GC while active)
    std::atomic<bool> active{ false };
    bool asyncInitialized = false;
    bool asyncClosed = false;
    bool refed = false;
    bool refsReleased = false;
    std::unique_ptr<WatchBackend> backend;
    std::mutex eventMutex;
    std::vector<NormalizedEvent> pendingEvents;

    WatchHandle() = default;

    WatchHandle(const WatchHandle&) = delete;
    WatchHandle& operator=(const WatchHandle&) = delete;

    ~WatchHandle() {
        if (backend) {
            backend->stop();
            backend.reset();
        }
    }
};

static std::string path_to_utf8(const std::filesystem::path& path) {
    return path.lexically_normal().generic_string();
}

static bool path_is_directory(const std::filesystem::path& path) {
    std::error_code ec;
    return std::filesystem::is_directory(path, ec);
}

static std::filesystem::path absolute_path(const std::filesystem::path& path) {
    std::error_code ec;
    std::filesystem::path absolute = std::filesystem::absolute(path, ec);
    if (ec) {
        return path;
    }
    return absolute.lexically_normal();
}

static std::string relative_path_to_utf8(const std::filesystem::path& path,
                                         const std::filesystem::path& root) {
    std::filesystem::path relative = path.lexically_relative(root);
    if (relative.empty()) {
        return path_to_utf8(path);
    }
    return relative.generic_string();
}

static std::string efsw_action_kind(efsw::Action action) {
    switch (action) {
        case efsw::Actions::Add:
            return "create";
        case efsw::Actions::Delete:
            return "remove";
        case efsw::Actions::Modified:
            return "modify";
        case efsw::Actions::Moved:
            return "rename";
        default:
            return "unknown";
    }
}

static std::string efsw_action_raw_kind(efsw::Action action) {
    switch (action) {
        case efsw::Actions::Add:
            return "add";
        case efsw::Actions::Delete:
            return "delete";
        case efsw::Actions::Modified:
            return "modified";
        case efsw::Actions::Moved:
            return "moved";
        default:
            return "unknown";
    }
}

static void push_event_table(lua_State* L, const NormalizedEvent& event) {
    lua_createtable(L, 0, 9);

    lua_pushstring(L, event.kind.c_str());
    lua_setfield(L, -2, "kind");

    lua_pushstring(L, event.path.c_str());
    lua_setfield(L, -2, "path");

    if (event.hasOldPath) {
        lua_pushstring(L, event.oldPath.c_str());
        lua_setfield(L, -2, "oldPath");
    }

    if (event.hasFilename) {
        lua_pushstring(L, event.filename.c_str());
        lua_setfield(L, -2, "filename");
    }

    if (event.hasOldFilename) {
        lua_pushstring(L, event.oldFilename.c_str());
        lua_setfield(L, -2, "oldFilename");
    }

    if (event.hasRelativePath) {
        lua_pushstring(L, event.relativePath.c_str());
        lua_setfield(L, -2, "relativePath");
    }

    if (event.hasOldRelativePath) {
        lua_pushstring(L, event.oldRelativePath.c_str());
        lua_setfield(L, -2, "oldRelativePath");
    }

    if (event.hasIsDirectory) {
        lua_pushboolean(L, event.isDirectory);
        lua_setfield(L, -2, "isDirectory");
    }

    if (!event.rawKind.empty()) {
        lua_pushstring(L, event.rawKind.c_str());
        lua_setfield(L, -2, "rawKind");
    }
}

static void queue_event(WatchHandle* wh, NormalizedEvent event) {
    if (!wh->active.load()) return;

    {
        std::lock_guard<std::mutex> lock(wh->eventMutex);
        if (!wh->active.load()) return;
        wh->pendingEvents.push_back(std::move(event));
    }

    uv_async_send(&wh->async);
}

static void drain_events(uv_async_t* handle) {
    auto* wh = (WatchHandle*)handle->data;
    if (!wh) return;

    if (!wh->active.load()) {
        std::lock_guard<std::mutex> lock(wh->eventMutex);
        wh->pendingEvents.clear();
        return;
    }

    std::vector<NormalizedEvent> events;
    {
        std::lock_guard<std::mutex> lock(wh->eventMutex);
        events.swap(wh->pendingEvents);
    }

    lua_State* GL = wh->rt->GL;

    for (const NormalizedEvent& event : events) {
        if (!wh->active.load()) break;

        lua_State* TL = lua_newthread(GL);

        lua_getref(GL, wh->callbackRef);
        lua_xmove(GL, TL, 1);

        push_event_table(TL, event);

        int threadRef = lua_ref(GL, -1);
        lua_pop(GL, 1);

        eryx_push_thread(wh->rt, threadRef, 1, false);
    }
}

class EfswBackend final : public WatchBackend, public efsw::FileWatchListener {
   public:
    EfswBackend(WatchHandle* handle, std::filesystem::path requestedPath, bool recursive)
        : handle(handle), requestedPath(absolute_path(requestedPath)), recursive(recursive) {
        std::error_code ec;
        targetIsDirectory = std::filesystem::is_directory(this->requestedPath, ec);

        if (targetIsDirectory) {
            watchedDirectory = this->requestedPath;
        } else {
            watchedDirectory = this->requestedPath.parent_path();
            targetFilename = this->requestedPath.filename().generic_string();
        }

        if (watchedDirectory.empty()) {
            watchedDirectory = std::filesystem::current_path(ec);
        }
    }

    ~EfswBackend() override { stop(); }

    bool start(std::string& error) override {
        if (watching) return true;

#ifdef __APPLE__
        watcher = std::make_unique<efsw::FileWatcher>(true, 25);
#else
        watcher = std::make_unique<efsw::FileWatcher>();
#endif
        watchId = watcher->addWatch(path_to_utf8(watchedDirectory), this, recursive);
        if (watchId <= 0) {
            error = efsw::Errors::Log::getLastErrorLog();
            if (error.empty()) {
                error = "efsw failed to add watch";
            }
            watcher.reset();
            return false;
        }

        watcher->watch();
        watching = true;
        return true;
    }

    void stop() override {
        if (!watcher) return;

        if (watching && watchId > 0) {
            watcher->removeWatch(watchId);
        }

        watching = false;
        watchId = 0;
        watcher.reset();
    }

    void handleFileAction(efsw::WatchID watchid, const std::string& dir,
                          const std::string& filename, efsw::Action action,
                          const std::string& oldFilename = "") override {
        if (watchid != watchId || !handle->active.load()) return;
        if (!targetIsDirectory && filename != targetFilename &&
            (oldFilename.empty() || oldFilename != targetFilename)) {
            return;
        }

        std::filesystem::path dirPath = absolute_path(std::filesystem::path(dir));
        std::filesystem::path eventPath = absolute_path(dirPath / filename);

        NormalizedEvent event;
        event.kind = efsw_action_kind(action);
        event.path = path_to_utf8(eventPath);
        event.rawKind = efsw_action_raw_kind(action);
        event.filename = filename;
        event.hasFilename = !filename.empty();
        event.relativePath = relative_path_to_utf8(eventPath, watchedDirectory);
        event.hasRelativePath = !event.relativePath.empty();
        event.hasIsDirectory = true;
        event.isDirectory = path_is_directory(eventPath);

        if (!oldFilename.empty()) {
            std::filesystem::path oldEventPath = absolute_path(dirPath / oldFilename);
            event.oldPath = path_to_utf8(oldEventPath);
            event.hasOldPath = true;
            event.oldFilename = oldFilename;
            event.hasOldFilename = true;
            event.oldRelativePath = relative_path_to_utf8(oldEventPath, watchedDirectory);
            event.hasOldRelativePath = !event.oldRelativePath.empty();
        }

        queue_event(handle, std::move(event));
    }

    void handleMissedFileActions(efsw::WatchID watchid, const std::string& dir) override {
        if (watchid != watchId || !handle->active.load()) return;

        NormalizedEvent event;
        event.kind = "overflow";
        event.path = path_to_utf8(absolute_path(std::filesystem::path(dir)));
        event.rawKind = "missed";

        queue_event(handle, std::move(event));
    }

   private:
    WatchHandle* handle;
    std::filesystem::path requestedPath;
    std::filesystem::path watchedDirectory;
    std::string targetFilename;
    bool recursive = false;
    bool targetIsDirectory = false;
    bool watching = false;
    efsw::WatchID watchId = 0;
    std::unique_ptr<efsw::FileWatcher> watcher;
};

// Close callback -- invoked after uv_close finishes. Safe to release refs now.
static void on_async_close(uv_handle_t* handle) {
    auto* wh = (WatchHandle*)handle->data;
    if (!wh) return;
    wh->asyncClosed = true;

    if (wh->refsReleased) return;
    wh->refsReleased = true;

    lua_State* GL = wh->rt ? wh->rt->GL : nullptr;
    if (GL) {
        if (wh->callbackRef != LUA_NOREF) {
            lua_unref(GL, wh->callbackRef);
        }
        if (wh->selfRef != LUA_NOREF) {
            lua_unref(GL, wh->selfRef);
        }
    }

    wh->callbackRef = LUA_NOREF;
    wh->selfRef = LUA_NOREF;
}

static void release_lua_refs_now(WatchHandle* wh) {
    if (wh->refsReleased) return;
    wh->refsReleased = true;

    lua_State* GL = wh->rt ? wh->rt->GL : nullptr;
    if (GL) {
        if (wh->callbackRef != LUA_NOREF) {
            lua_unref(GL, wh->callbackRef);
        }
        if (wh->selfRef != LUA_NOREF) {
            lua_unref(GL, wh->selfRef);
        }
    }

    wh->callbackRef = LUA_NOREF;
    wh->selfRef = LUA_NOREF;
}

static int ref_value_on_main(lua_State* L, lua_State* GL, int index) {
    index = lua_absindex(L, index);
    lua_pushvalue(L, index);
    if (L != GL) {
        lua_xmove(L, GL, 1);
    }

    int ref = lua_ref(GL, -1);
    lua_pop(GL, 1);
    return ref;
}

static void stop_watcher(WatchHandle* wh) {
    if (!wh->active.exchange(false)) return;

    if (wh->backend) {
        wh->backend->stop();
        wh->backend.reset();
    }

    {
        std::lock_guard<std::mutex> lock(wh->eventMutex);
        wh->pendingEvents.clear();
    }

    if (wh->asyncInitialized && !wh->asyncClosed && !uv_is_closing((uv_handle_t*)&wh->async)) {
        uv_close((uv_handle_t*)&wh->async, on_async_close);
    } else {
        release_lua_refs_now(wh);
    }
}

// WatchHandle:stop()
static int watchhandle_stop(lua_State* L) {
    auto* wh = (WatchHandle*)eryxUdata_checkudata(L, fsWatchHandleRef, 1);
    stop_watcher(wh);
    return 0;
}

// WatchHandle:ref() - make this handle keep the event loop alive.
static int watchhandle_ref(lua_State* L) {
    auto* wh = (WatchHandle*)eryxUdata_checkudata(L, fsWatchHandleRef, 1);
    if (wh->active.load() && wh->asyncInitialized && !wh->refed) {
        uv_ref((uv_handle_t*)&wh->async);
        wh->refed = true;
    }
    return 0;
}

// WatchHandle:unref() - allow the event loop to exit even if this handle is active.
static int watchhandle_unref(lua_State* L) {
    auto* wh = (WatchHandle*)eryxUdata_checkudata(L, fsWatchHandleRef, 1);
    if (wh->active.load() && wh->asyncInitialized && wh->refed) {
        uv_unref((uv_handle_t*)&wh->async);
        wh->refed = false;
    }
    return 0;
}

static void watchhandle_dtor(lua_State* L, void* ud);

luaL_Reg fsWatchHandleMethods[] = {
    { "stop", watchhandle_stop },
    { "ref", watchhandle_ref },
    { "unref", watchhandle_unref },
    { nullptr, nullptr },
};

udataDef fsWatchHandleDef = {
    .name = "FsWatchHandle",
    .size = sizeof(WatchHandle),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = nullptr,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = fsWatchHandleMethods,
    .destructor = watchhandle_dtor,
};

static void watchhandle_dtor(lua_State* L, void* ud) {
    auto* wh = (WatchHandle*)ud;

    if (wh->active.exchange(false)) {
        if (wh->backend) {
            wh->backend->stop();
            wh->backend.reset();
        }

        std::lock_guard<std::mutex> lock(wh->eventMutex);
        wh->pendingEvents.clear();
    }

    wh->~WatchHandle();
}

// ---------------------------------------------------------------------------
// _fs_watch.create(path, recursive, callback) -> WatchHandle
// ---------------------------------------------------------------------------
static int fswatch_create(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    bool recursive = lua_toboolean(L, 2) != 0;
    luaL_checktype(L, 3, LUA_TFUNCTION);

    std::filesystem::path requestedPath(path);
    std::filesystem::path parentPath = requestedPath.parent_path();
    if (!parentPath.empty()) {
        std::error_code ec;
        if (!std::filesystem::exists(parentPath, ec)) {
            luaL_error(L, "Failed to watch '%s': parent directory does not exist", path.c_str());
            return 0;
        }
    }

    auto* rt = eryx_get_runtime(L);

    auto* wh = new (eryxUdata_pushudata(L, fsWatchHandleRef)) WatchHandle();

    wh->rt = rt;

    int r = uv_async_init(rt->loop, &wh->async, drain_events);
    if (r < 0) {
        luaL_error(L, "Failed to init fs watcher async bridge: %s", uv_strerror(r));
        return 0;
    }
    wh->asyncInitialized = true;
    wh->async.data = wh;

    wh->callbackRef = ref_value_on_main(L, rt->GL, 3);

    wh->backend = std::make_unique<EfswBackend>(wh, requestedPath, recursive);

    std::string error;
    if (!wh->backend->start(error)) {
        wh->backend.reset();
        if (wh->callbackRef != LUA_NOREF) {
            lua_unref(wh->rt->GL, wh->callbackRef);
            wh->callbackRef = LUA_NOREF;
        }
        uv_close((uv_handle_t*)&wh->async, nullptr);
        uv_run(rt->loop, UV_RUN_NOWAIT);
        luaL_error(L, "Failed to watch '%s': %s", path.c_str(), error.c_str());
        return 0;
    }

    wh->active = true;

    wh->selfRef = ref_value_on_main(L, rt->GL, -1);

    uv_unref((uv_handle_t*)&wh->async);
    wh->refed = false;

    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------
LUAU_MODULE_EXPORT int luauopen__fs_watch(lua_State* L) {
    fsWatchHandleRef = eryxUdata_registerudata(L, &fsWatchHandleDef);

    lua_newtable(L);

    lua_pushcfunction(L, fswatch_create, "create");
    lua_setfield(L, -2, "create");

    lua_setreadonly(L, -1, true);
    return 1;
}
