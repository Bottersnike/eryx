#include <algorithm>
#include <cstring>
#include <string>

#include "../LuaUtil.hpp"
#include "../runtime/embedded_modules.h"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_embedded",
};
LUAU_MODULE_INFO()

static std::string normalize_embedded_path(const char* raw) {
    std::string path(raw ? raw : "");
    std::replace(path.begin(), path.end(), '\\', '/');

    constexpr const char* prefixEryxChunk = "@@eryx/";
    constexpr const char* prefixEryxAlias = "@eryx/";
    if (path.rfind(prefixEryxChunk, 0) == 0) {
        path.erase(0, strlen(prefixEryxChunk));
    } else if (path.rfind(prefixEryxAlias, 0) == 0) {
        path.erase(0, strlen(prefixEryxAlias));
    }

    while (!path.empty() && path.front() == '/') path.erase(path.begin());
    while (!path.empty() && path.back() == '/') path.pop_back();
    return path;
}

static const EmbeddedScriptModule* find_embedded_script(const std::string& path) {
    auto* scripts = eryx_get_embedded_script_modules();
    if (!scripts) return nullptr;

    for (const EmbeddedScriptModule* module = scripts; module->modulePath; ++module) {
        if (path == module->modulePath) {
            return module;
        }
    }
    return nullptr;
}

static int embedded_read(lua_State* L) {
    std::string path = normalize_embedded_path(luaL_checkstring(L, 1));
    const EmbeddedScriptModule* module = find_embedded_script(path);
    if (!module) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, module->source);
    return 1;
}

static int embedded_exists(lua_State* L) {
    std::string path = normalize_embedded_path(luaL_checkstring(L, 1));
    lua_pushboolean(L, find_embedded_script(path) != nullptr);
    return 1;
}

LUAU_MODULE_EXPORT int luauopen_embedded(lua_State* L) {
    lua_newtable(L);

    lua_pushcfunction(L, embedded_read, "read");
    lua_setfield(L, -2, "read");

    lua_pushcfunction(L, embedded_exists, "exists");
    lua_setfield(L, -2, "exists");

    lua_setreadonly(L, -1, true);
    return 1;
}
