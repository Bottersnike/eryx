#include <cstring>

#include "../runtime/lexception.hpp"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_exception",
};
LUAU_MODULE_INFO()

int exception_new(lua_State* L) {
    const char* message = luaL_checkstring(L, 1);

    LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
    new (exception) LuaException();
    luaL_getmetatable(L, EXCEPTION_METATABLE);
    lua_setmetatable(L, -2);

    exception->type = ETYPE_USER;
    exception->message = message;

    // Traceback will be populated at the time we call error()

    return 1;
}

int exception_format(lua_State*L ) {
    luaL_checkudata(L, 1, EXCEPTION_METATABLE);
    lua_pushstring(L, eryx_format_exception(L, 1).c_str());
    return 1;
}

LUAU_MODULE_EXPORT int luauopen_exception(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, exception_new, "new");
    lua_setfield(L, -2, "new");
    lua_pushcfunction(L, exception_format, "format");
    lua_setfield(L, -2, "format");

    return 1;
}
