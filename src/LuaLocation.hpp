#pragma once

#include "Luau/Location.h"
#include "lua.h"
#include "lualib.h"
#include "pch.hpp"

struct EryxLuaLocation {
    int beginline;
    int begincolumn;
    int endline;
    int endcolumn;
};

static constexpr const char* ERYX_LUA_LOCATION_METATABLE = "Location";

static int eryx_lua_location_index(lua_State* L) {
    EryxLuaLocation* location =
        static_cast<EryxLuaLocation*>(luaL_checkudata(L, 1, ERYX_LUA_LOCATION_METATABLE));
    if (!lua_isstring(L, 2)) {
        lua_pushnil(L);
        return 1;
    }

    const char* key = lua_tostring(L, 2);

    if (strcmp(key, "beginline") == 0)
        lua_pushinteger(L, location->beginline);
    else if (strcmp(key, "begincolumn") == 0)
        lua_pushinteger(L, location->begincolumn);
    else if (strcmp(key, "endline") == 0)
        lua_pushinteger(L, location->endline);
    else if (strcmp(key, "endcolumn") == 0)
        lua_pushinteger(L, location->endcolumn);
    else
        lua_pushnil(L);

    return 1;
}

static int eryx_lua_location_tostring(lua_State* L) {
    EryxLuaLocation* location =
        static_cast<EryxLuaLocation*>(luaL_checkudata(L, 1, ERYX_LUA_LOCATION_METATABLE));
    lua_pushfstring(L, "Location(%d:%d-%d:%d)", location->beginline, location->begincolumn,
                    location->endline, location->endcolumn);
    return 1;
}

static void eryx_lua_register_location(lua_State* L) {
    if (luaL_newmetatable(L, ERYX_LUA_LOCATION_METATABLE)) {
        lua_pushcfunction(L, eryx_lua_location_index, "__index");
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, eryx_lua_location_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }

    lua_pop(L, 1);
}

static void eryx_lua_push_location(lua_State* L, const Luau::Location& location) {
    eryx_lua_register_location(L);

    EryxLuaLocation* value =
        static_cast<EryxLuaLocation*>(lua_newuserdata(L, sizeof(EryxLuaLocation)));
    luaL_getmetatable(L, ERYX_LUA_LOCATION_METATABLE);
    lua_setmetatable(L, -2);

    value->beginline = location.begin.line + 1;
    value->begincolumn = location.begin.column + 1;
    value->endline = location.end.line + 1;
    value->endcolumn = location.end.column + 1;
}
