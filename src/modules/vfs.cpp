#include "../vfs.hpp"

#include <filesystem>
#include <set>
#include <vector>

#include "module_api.h"


static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_vfs",
};
LUAU_MODULE_INFO()

// vfs.isOpen() -> boolean
static int vfs_lua_isOpen(lua_State* L) {
    lua_pushboolean(L, vfs_open());
    return 1;
}

// vfs.entrypoint() -> string?
static int vfs_lua_entrypoint(lua_State* L) {
    if (!vfs_open()) {
        lua_pushnil(L);
        return 1;
    }
    auto ep = vfs_get_entrypoint();
    lua_pushlstring(L, ep.data(), ep.size());
    return 1;
}

// vfs.readFile(path: string) -> string
static int vfs_lua_readFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!vfs_open()) {
        luaL_error(L, "No VFS bundle is open");
    }
    auto data = vfs_read_file(path);
    if (data.empty()) {
        luaL_error(L, "VFS file not found: %s", path);
    }
    lua_pushlstring(L, reinterpret_cast<const char*>(data.data()), data.size());
    return 1;
}

// vfs.exists(path: string) -> boolean
static int vfs_lua_exists(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!vfs_open()) {
        lua_pushboolean(L, false);
        return 1;
    }
    auto data = vfs_read_file(path);
    lua_pushboolean(L, !data.empty());
    return 1;
}

// vfs.listDir(dir: string) -> {string}
static int vfs_lua_listDir(lua_State* L) {
    const char* dir = luaL_checkstring(L, 1);
    lua_newtable(L);
    if (!vfs_open()) return 1;

    auto files = vfs_list_dir(dir);

    // vfs_list_dir returns full paths; extract just the direct children
    std::string prefix(dir);
    if (!prefix.empty() && prefix.back() != '/') prefix += '/';

    std::set<std::string> seen;
    int index = 1;
    for (auto& f : files) {
        // Extract the part after the prefix
        std::string_view relative(f);
        if (!prefix.empty() && prefix != "/") relative = relative.substr(prefix.size());

        // Take just the first path component (file name or directory name)
        auto slash = relative.find('/');
        std::string_view entry =
            (slash != std::string_view::npos) ? relative.substr(0, slash) : relative;

        // Deduplicate (multiple files can share the same directory prefix)
        std::string entryStr(entry);
        if (!seen.insert(entryStr).second) continue;

        lua_pushinteger(L, index++);
        lua_pushlstring(L, entry.data(), entry.size());
        lua_settable(L, -3);
    }
    return 1;
}

// vfs.isFile(path: string) -> boolean
static int vfs_lua_isFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!vfs_open()) {
        lua_pushboolean(L, false);
        return 1;
    }
    lua_pushboolean(L, vfs_is_file(path));
    return 1;
}

// vfs.isDir(path: string) -> boolean
static int vfs_lua_isDir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!vfs_open()) {
        lua_pushboolean(L, false);
        return 1;
    }
    lua_pushboolean(L, vfs_is_dir(path));
    return 1;
}

// vfs.mtime(path: string) -> number
static int vfs_lua_mtime(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!vfs_open()) {
        luaL_error(L, "No VFS bundle is open");
    }
    uint64_t mt = vfs_get_mtime(path);
    if (mt == 0) {
        luaL_error(L, "VFS file not found: %s", path);
    }
    lua_pushnumber(L, static_cast<double>(mt));
    return 1;
}

// vfs.isIsolated() -> boolean
static int vfs_lua_isIsolated(lua_State* L) {
    lua_pushboolean(L, vfs_is_isolated());
    return 1;
}

// vfs.setIsolated(isolated: boolean)
static int vfs_lua_setIsolated(lua_State* L) {
    luaL_checktype(L, 1, LUA_TBOOLEAN);
    vfs_set_isolated(lua_toboolean(L, 1));
    return 0;
}

namespace fs = std::filesystem;

// vfs.build({ sourceExe?, outputExe, root, entrypoint, files })
static int vfs_lua_build(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    // outputExe (required)
    lua_getfield(L, 1, "outputExe");
    if (!lua_isstring(L, -1)) luaL_error(L, "vfs.build: 'outputExe' is required (string)");
    fs::path outputExe = lua_tostring(L, -1);
    lua_pop(L, 1);

    // root (required)
    lua_getfield(L, 1, "root");
    if (!lua_isstring(L, -1)) luaL_error(L, "vfs.build: 'root' is required (string)");
    fs::path root = lua_tostring(L, -1);
    lua_pop(L, 1);

    // entrypoint (required)
    lua_getfield(L, 1, "entrypoint");
    if (!lua_isstring(L, -1)) luaL_error(L, "vfs.build: 'entrypoint' is required (string)");
    std::string entrypoint = lua_tostring(L, -1);
    lua_pop(L, 1);

    // sourceExe (optional — defaults to current executable)
    fs::path sourceExe;
    lua_getfield(L, 1, "sourceExe");
    if (lua_isstring(L, -1)) {
        sourceExe = lua_tostring(L, -1);
    } else {
#if defined(_WIN32)
        wchar_t exebuf[MAX_PATH];
        DWORD exelen = GetModuleFileNameW(nullptr, exebuf, MAX_PATH);
        sourceExe = fs::path(std::wstring(exebuf, exelen));
#elif defined(__APPLE__)
        char exebuf[4096];
        uint32_t exelen = sizeof(exebuf);
        _NSGetExecutablePath(exebuf, &exelen);
        sourceExe = fs::canonical(exebuf);
#else
        sourceExe = fs::canonical("/proc/self/exe");
#endif
    }
    lua_pop(L, 1);

    // files (required — array of strings, or array of strings/directories to expand)
    lua_getfield(L, 1, "files");
    if (!lua_istable(L, -1)) luaL_error(L, "vfs.build: 'files' is required (array of strings)");

    std::vector<fs::path> inputs;
    int len = lua_objlen(L, -1);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, -1, i);
        if (!lua_isstring(L, -1)) luaL_error(L, "vfs.build: files[%d] must be a string", i);
        fs::path p = lua_tostring(L, -1);
        lua_pop(L, 1);

        if (fs::is_regular_file(p)) {
            inputs.push_back(p);
        } else if (fs::is_directory(p)) {
            for (auto& entry : fs::recursive_directory_iterator(p)) {
                if (entry.is_regular_file()) {
                    inputs.push_back(entry.path());
                }
            }
        } else {
            luaL_error(L, "vfs.build: '%s' is not a file or directory", p.string().c_str());
        }
    }
    lua_pop(L, 1);

    // Make sure the entrypoint is included
    fs::path entrypointPath = root / entrypoint;
    bool hasEntrypoint = false;
    for (auto& inp : inputs) {
        std::error_code ec;
        if (fs::equivalent(inp, entrypointPath, ec)) {
            hasEntrypoint = true;
            break;
        }
    }
    if (!hasEntrypoint) {
        inputs.push_back(entrypointPath);
    }

    bool ok = vfs_build_bundle(sourceExe, outputExe, root, entrypoint, inputs);
    if (!ok) {
        luaL_error(L, "Failed to build VFS bundle");
    }

    lua_pushboolean(L, true);
    return 1;
}

LUAU_MODULE_EXPORT int luauopen_vfs(lua_State* L) {
    lua_newtable(L);

    lua_pushcfunction(L, vfs_lua_isOpen, "isOpen");
    lua_setfield(L, -2, "isOpen");
    lua_pushcfunction(L, vfs_lua_entrypoint, "entrypoint");
    lua_setfield(L, -2, "entrypoint");
    lua_pushcfunction(L, vfs_lua_readFile, "readFile");
    lua_setfield(L, -2, "readFile");
    lua_pushcfunction(L, vfs_lua_exists, "exists");
    lua_setfield(L, -2, "exists");
    lua_pushcfunction(L, vfs_lua_listDir, "listDir");
    lua_setfield(L, -2, "listDir");
    lua_pushcfunction(L, vfs_lua_isFile, "isFile");
    lua_setfield(L, -2, "isFile");
    lua_pushcfunction(L, vfs_lua_isDir, "isDir");
    lua_setfield(L, -2, "isDir");
    lua_pushcfunction(L, vfs_lua_mtime, "mtime");
    lua_setfield(L, -2, "mtime");
    lua_pushcfunction(L, vfs_lua_build, "build");
    lua_setfield(L, -2, "build");
    lua_pushcfunction(L, vfs_lua_isIsolated, "isIsolated");
    lua_setfield(L, -2, "isIsolated");
    lua_pushcfunction(L, vfs_lua_setIsolated, "setIsolated");
    lua_setfield(L, -2, "setIsolated");

    return 1;
}
