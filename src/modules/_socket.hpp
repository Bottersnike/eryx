#pragma once

#ifndef _WIN32
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
using SOCKET = int;
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR   (-1)
#endif

#include "lua.h"
#include "lualib.h"
#include "module_api.h"


static const char* SOCKET_METATABLE = "Socket";

struct LuaSocket {
    SOCKET fd;
    int family;
    int type;
    int proto;
    double timeout;  // seconds, <0 means blocking (default)
};

/**
 * @brief Check for a Socket userdata on the stack
 *
 * @param L Lua state
 * @param idx Stack index
 * @return LuaSocket* Validated Socket
 */
static LuaSocket* check_socket(lua_State* L, int idx) {
    return (LuaSocket*)luaL_checkudata(L, idx, SOCKET_METATABLE);
}