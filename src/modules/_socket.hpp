#pragma once

#ifndef _WIN32
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
using SOCKET = int;
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR (-1)
#endif

#include "../runtime/userdata.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"

struct LuaSocket {
    SOCKET fd;
    int family;
    int type;
    int proto;
    double timeout;  // seconds, <0 means blocking (default)
};

static LuaSocket* check_socket(lua_State* L, int idx) {
    udataRef* socketRef = eryxUdata_getudata(L, "Socket");
    if (!socketRef) {
        luaL_error(L, "Socket userdata type is not registered in this environment");
        return nullptr;
    }

    return (LuaSocket*)eryxUdata_checkudata(L, socketRef, idx);
}
