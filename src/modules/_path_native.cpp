#include <cstring>
#include <filesystem>
#include <string>

#include "../LuaUtil.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"

namespace fs = std::filesystem;

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__path",
};
LUAU_MODULE_INFO()

static int path_canonicalize(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    fs::path canon = fs::weakly_canonical(path, ec);
    if (ec) {
        luaL_error(L, "Failed to canonicalize path: %s (%s)", path.c_str(), ec.message().c_str());
        return 0;
    }

    std::string result = canon.string();
    lua_pushstring(L, result.c_str());
    return 1;
}

LUAU_MODULE_EXPORT int luauopen__path(lua_State* L) {
    lua_newtable(L);

    lua_pushcfunction(L, path_canonicalize, "canonicalize");
    lua_setfield(L, -2, "canonicalize");

    lua_setreadonly(L, -1, true);
    return 1;
}
