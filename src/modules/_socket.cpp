// _socket.cpp  –  Low-level BSD-style socket API for Luau (Win32 / Winsock2)
//
// All sockets are permanently non-blocking at the OS level.  Async I/O is
// driven by libuv's event loop via uv_poll_t (watching raw Winsock handles).
// Virtual blocking and timeouts are layered on top using uv_timer_t.
//
// Exposed surface (mirrors a subset of Python's `socket` module):
//
//   socket.socket(family, type [, proto])  -> Socket userdata
//   socket.getaddrinfo(host, service [, family, type, proto, flags])
//   socket.getnameinfo(host, port [, flags]) -> hostname, servicename
//   socket.htons(x) / socket.ntohs(x) / socket.htonl(x) / socket.ntohl(x)
//   socket.poll([timeout])  -- no-op, kept for API compat
//
//   Socket:bind(host, port)
//   Socket:listen([backlog])
//   Socket:accept()           -> Socket, host, port
//   Socket:connect(host, port)
//   Socket:close()
//   Socket:shutdown(how)
//   Socket:send(buf)          -> bytes_sent
//   Socket:sendall(buf)
//   Socket:sendto(buf, host, port) -> bytes_sent
//   Socket:recv(bufsize)       -> buffer
//   Socket:recvfrom(bufsize)   -> buffer, host, port
//   Socket:setsockopt(level, optname, value)
//   Socket:getsockopt(level, optname)  -> value
//   Socket:setblocking(flag)
//   Socket:settimeout(seconds)
//   Socket:getpeername() -> host, port
//   Socket:getsockname() -> host, port
//   Socket:fileno()      -> raw socket handle (number)
// ---------------------------------------------------------------------------

#include "_socket.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../runtime/lexception.hpp"
#include "uv.h"

// ---------------------------------------------------------------------------
// Platform socket compatibility
// ---------------------------------------------------------------------------
#ifdef _WIN32
#  define sock_errno()             WSAGetLastError()
#  define sock_is_would_block(e)   ((e) == WSAEWOULDBLOCK)
#  define sock_is_in_progress(e)   ((e) == WSAEWOULDBLOCK || (e) == WSAEINPROGRESS)
#  define sock_would_block()       sock_is_would_block(WSAGetLastError())
#  define sock_in_progress()       sock_is_in_progress(WSAGetLastError())
#  define sock_fd_close(fd)        closesocket(fd)
static std::string sock_strerror_str(int err) {
    char buf[256];
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, err, 0, buf,
                   sizeof(buf), nullptr);
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = '\0';
    return std::string(buf, len);
}
static const char* sock_gai_strerror(int rc) { return gai_strerrorA(rc); }
#else
#  define sock_errno()             errno
#  define sock_is_would_block(e)   ((e) == EWOULDBLOCK || (e) == EAGAIN)
#  define sock_is_in_progress(e)   ((e) == EINPROGRESS || (e) == EWOULDBLOCK)
#  define sock_would_block()       sock_is_would_block(errno)
#  define sock_in_progress()       sock_is_in_progress(errno)
#  define sock_fd_close(fd)        close(fd)
static std::string sock_strerror_str(int err) { return strerror(err); }
static const char* sock_gai_strerror(int rc) { return gai_strerror(rc); }
#  define SD_RECEIVE               SHUT_RD
#  define SD_SEND                  SHUT_WR
#  define SD_BOTH                  SHUT_RDWR
#endif

static void
#ifdef _WIN32
    __declspec(noreturn)
#else
    __attribute__((noreturn))
#endif
    sock_error_with(lua_State* L, const char* prefix, int err) {
    std::string msg = sock_strerror_str(err);
    luaL_error(L, "%s: [%d] %s", prefix, err, msg.c_str());
#ifdef _WIN32
    __assume(0);
#else
    __builtin_unreachable();
#endif
}

static void
#ifdef _WIN32
    __declspec(noreturn)
#else
    __attribute__((noreturn))
#endif
    sock_error(lua_State* L, const char* prefix) {
    sock_error_with(L, prefix, sock_errno());
}

// ---------------------------------------------------------------------------
// Luau module definition
// ---------------------------------------------------------------------------
static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__socket",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static int resolve_addr(lua_State* L, const char* host, int port, int family, int socktype,
                        int proto, struct sockaddr_storage* out, int* outlen) {
    struct addrinfo hints {};
    hints.ai_family = family;
    hints.ai_socktype = socktype;
    hints.ai_protocol = proto;
    if (!host || host[0] == '\0') hints.ai_flags = AI_PASSIVE;

    char portbuf[16];
    snprintf(portbuf, sizeof(portbuf), "%d", port);

    struct addrinfo* res = nullptr;
    int rc = getaddrinfo(host && host[0] ? host : nullptr, portbuf, &hints, &res);
    if (rc != 0) {
        luaL_error(L, "getaddrinfo failed: %s", sock_gai_strerror(rc));
        return -1;
    }
    memcpy(out, res->ai_addr, res->ai_addrlen);
    *outlen = (int)res->ai_addrlen;
    freeaddrinfo(res);
    return 0;
}

static void push_sockaddr(lua_State* L, const struct sockaddr* sa, socklen_t salen) {
    char host[NI_MAXHOST];
    char serv[NI_MAXSERV];
    int rc = getnameinfo(sa, salen, host, sizeof(host), serv, sizeof(serv),
                         NI_NUMERICHOST | NI_NUMERICSERV);
    if (rc != 0) {
        lua_pushstring(L, "?");
        lua_pushinteger(L, 0);
        return;
    }
    lua_pushstring(L, host);
    lua_pushinteger(L, atoi(serv));
}

// Make a socket non-blocking (all sockets are always non-blocking at OS level)
static void make_nonblocking(SOCKET fd) {
#ifdef _WIN32
    u_long mode = 1;
    ioctlsocket(fd, FIONBIO, &mode);
#else
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
}

// ---------------------------------------------------------------------------
// Async I/O via uv_poll_t
//
// When a socket operation would block, we create a SocketPendingOp that holds
// a uv_poll_t (watching the fd) and optionally a uv_timer_t (for timeout).
// The coroutine yields; whichever fires first resumes it.
// ---------------------------------------------------------------------------

enum class OpType { RECV, RECVFROM, SEND, SENDALL, SENDTO, ACCEPT, CONNECT };

struct SocketPendingOp {
    lua_State* thread;
    int threadRef;  // registry ref to keep thread alive
    LuaSocket* socket;
    OpType op;
    EryxRuntime* runtime;

    // RECV / RECVFROM
    int bufsize;

    // SEND / SENDALL
    const char* data;
    size_t data_len;
    size_t data_sent;

    uv_poll_t poll;
    uv_timer_t timer;
    bool has_timer;
    bool finished;  // guard against double-fire

    int handles_closing;  // count of handles pending close
};

// Module-local storage for pending socket ops by runtime
static std::unordered_map<EryxRuntime*, std::unordered_map<int, SocketPendingOp*>>
    g_pendingSocketOps;
static std::unordered_set<EryxRuntime*> g_registeredRuntimes;

// Forward declarations
static void poll_cb(uv_poll_t* handle, int status, int events);
static void timeout_cb(uv_timer_t* handle);
static void execute_ready_op(SocketPendingOp* op);

static void handle_close_cb(uv_handle_t* handle) {
    SocketPendingOp* op = (SocketPendingOp*)handle->data;
    if (!op) return;
    op->handles_closing--;
    if (op->handles_closing <= 0) {
        delete op;
    }
}

static void cleanup_pending_op(SocketPendingOp* op) {
    if (op->threadRef != LUA_NOREF) {
        lua_unref(op->runtime->GL, op->threadRef);
        op->threadRef = LUA_NOREF;
    }

    // Count handles to close
    op->handles_closing = 0;

    if (!uv_is_closing((uv_handle_t*)&op->poll)) {
        op->handles_closing++;
        uv_poll_stop(&op->poll);
        uv_close((uv_handle_t*)&op->poll, handle_close_cb);
    }
    if (op->has_timer && !uv_is_closing((uv_handle_t*)&op->timer)) {
        op->handles_closing++;
        uv_timer_stop(&op->timer);
        uv_close((uv_handle_t*)&op->timer, handle_close_cb);
    }

    // If no handles needed closing, free immediately
    if (op->handles_closing <= 0) {
        delete op;
    }

    // Remove from module-local pending map if present
    auto& m = g_pendingSocketOps[op->runtime];
    // try to erase by threadRef first
    if (op->threadRef != LUA_NOREF) {
        m.erase(op->threadRef);
    } else {
        for (auto it = m.begin(); it != m.end(); ++it) {
            if (it->second == op) {
                m.erase(it);
                break;
            }
        }
    }
}

// Interrupt callback invoked from the generic runtime interrupt dispatcher.
static void socket_interrupt_all(EryxRuntime* rt, void* /*ctx*/) {
    if (!rt) return;
    auto itmap = g_pendingSocketOps.find(rt);
    if (itmap == g_pendingSocketOps.end()) return;

    // Collect refs to avoid iterator invalidation
    std::vector<int> refs;
    for (auto& kv : itmap->second) refs.push_back(kv.first);

    for (int ref : refs) {
        auto it = itmap->second.find(ref);
        if (it == itmap->second.end()) continue;
        SocketPendingOp* op = it->second;
        if (!op || op->finished) {
            itmap->second.erase(it);
            continue;
        }

        op->finished = true;

        // Push keyboard interrupt onto the thread stack and queue as error
        if (op->thread && op->threadRef != LUA_NOREF) {
            eryx_exception_push_keyboard_interrupt(op->thread);
            int tref = op->threadRef;
            op->threadRef = LUA_NOREF;
            eryx_push_thread(rt, tref, 1, true);
        }

        // Close poll/timer handles
        op->handles_closing = 0;
        if (!uv_is_closing((uv_handle_t*)&op->poll)) {
            op->handles_closing++;
            uv_poll_stop(&op->poll);
            uv_close((uv_handle_t*)&op->poll, handle_close_cb);
        }
        if (op->has_timer && !uv_is_closing((uv_handle_t*)&op->timer)) {
            op->handles_closing++;
            uv_timer_stop(&op->timer);
            uv_close((uv_handle_t*)&op->timer, handle_close_cb);
        }

        if (op->handles_closing <= 0) delete op;

        itmap->second.erase(ref);
    }
}

// Schedule an async socket operation: creates uv_poll_t + optional uv_timer_t.
// Caller must return lua_yield(L, 0) immediately after calling this.
static void schedule_socket_op(lua_State* L, LuaSocket* s, OpType op,
                               int events,  // UV_READABLE or UV_WRITABLE
                               int bufsize = 0, const char* data = nullptr, size_t data_len = 0) {
    EryxRuntime* rt = eryx_get_runtime(L);

    // Create a registry ref to keep the thread alive
    lua_pushthread(L);
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);

    SocketPendingOp* pending = new SocketPendingOp;
    pending->thread = L;
    pending->threadRef = ref;
    pending->socket = s;
    pending->op = op;
    pending->runtime = rt;
    pending->bufsize = bufsize;
    pending->data = data;
    pending->data_len = data_len;
    pending->data_sent = 0;
    pending->has_timer = false;
    pending->finished = false;
    pending->handles_closing = 0;

    // Init and start poll
#ifdef _WIN32
    uv_poll_init_socket(rt->loop, &pending->poll, s->fd);
#else
    uv_poll_init(rt->loop, &pending->poll, s->fd);
#endif
    pending->poll.data = pending;
    uv_poll_start(&pending->poll, events, poll_cb);
    // Track pending socket op so it can be interrupted (module-local map)
    g_pendingSocketOps[rt][ref] = pending;

    // Ensure we've registered an interrupt callback for this runtime
    if (g_registeredRuntimes.find(rt) == g_registeredRuntimes.end()) {
        eryx_register_interrupt_callback(rt, socket_interrupt_all, nullptr);
        g_registeredRuntimes.insert(rt);
    }

    // Init timeout timer if socket has a positive timeout
    if (s->timeout > 0) {
        uv_timer_init(rt->loop, &pending->timer);
        pending->timer.data = pending;
        pending->has_timer = true;
        uint64_t timeout_ms = (uint64_t)(s->timeout * 1000.0);
        uv_timer_start(&pending->timer, timeout_cb, timeout_ms, 0);
    }
}

// ---------------------------------------------------------------------------
// Poll callback: socket is ready for I/O
// ---------------------------------------------------------------------------
static void execute_ready_op(SocketPendingOp* op) {
    lua_State* L = op->thread;
    EryxRuntime* rt = op->runtime;
    int nresults = 0;

    switch (op->op) {
        case OpType::RECV: {
            char stackbuf[8192];
            char* tmp = (op->bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[op->bufsize];
            int n = ::recv(op->socket->fd, tmp, op->bufsize, 0);
            if (n >= 0) {
                void* buf = lua_newbuffer(L, n);
                memcpy(buf, tmp, n);
                nresults = 1;
            }
            if (tmp != stackbuf) delete[] tmp;
            break;
        }

        case OpType::RECVFROM: {
            char stackbuf[8192];
            char* tmp = (op->bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[op->bufsize];
            struct sockaddr_storage addr {};
            socklen_t addrlen = sizeof(addr);
            int n =
                recvfrom(op->socket->fd, tmp, op->bufsize, 0, (struct sockaddr*)&addr, &addrlen);
            if (n >= 0) {
                void* buf = lua_newbuffer(L, n);
                memcpy(buf, tmp, n);
                push_sockaddr(L, (struct sockaddr*)&addr, addrlen);
                nresults = 3;
            }
            if (tmp != stackbuf) delete[] tmp;
            break;
        }

        case OpType::ACCEPT: {
            struct sockaddr_storage addr {};
            socklen_t addrlen = sizeof(addr);
            SOCKET client = accept(op->socket->fd, (struct sockaddr*)&addr, &addrlen);
            if (client != INVALID_SOCKET) {
                make_nonblocking(client);
                LuaSocket* cs = (LuaSocket*)lua_newuserdata(L, sizeof(LuaSocket));
                cs->fd = client;
                cs->family = op->socket->family;
                cs->type = op->socket->type;
                cs->proto = op->socket->proto;
                cs->timeout = op->socket->timeout;
                luaL_getmetatable(L, SOCKET_METATABLE);
                lua_setmetatable(L, -2);
                push_sockaddr(L, (struct sockaddr*)&addr, addrlen);
                nresults = 3;
            }
            break;
        }

        case OpType::CONNECT: {
            int sockerr = 0;
            socklen_t sockerrlen = sizeof(sockerr);
            getsockopt(op->socket->fd, SOL_SOCKET, SO_ERROR, (char*)&sockerr, &sockerrlen);
            nresults = 0;
            break;
        }

        case OpType::SEND: {
            int sent = ::send(op->socket->fd, op->data, (int)op->data_len, 0);
            if (sent >= 0) {
                lua_pushinteger(L, sent);
                nresults = 1;
            }
            break;
        }

        case OpType::SENDALL: {
            while (op->data_sent < op->data_len) {
                int sent = ::send(op->socket->fd, op->data + op->data_sent,
                                  (int)(op->data_len - op->data_sent), 0);
                if (sent > 0) {
                    op->data_sent += (size_t)sent;
                    continue;
                }
                if (sent == 0) break;
                if (sock_would_block()) {
                    // Still more to send -- re-arm the poll and return without resuming
                    op->finished = false;
                    uv_poll_start(&op->poll, UV_WRITABLE, poll_cb);
                    return;  // don't resume yet, don't cleanup
                }
                break;  // error
            }

            lua_pushboolean(L, true);
            nresults = 1;
            break;
        }

        case OpType::SENDTO: {
            // sendto resolves the address before scheduling, so we just retry the send
            int sent = ::send(op->socket->fd, op->data, (int)op->data_len, 0);
            if (sent >= 0) {
                lua_pushinteger(L, sent);
                nresults = 1;
            }
            break;
        }
    }

    // Transfer ref ownership to the scheduler
    int ref = op->threadRef;
    op->threadRef = LUA_NOREF;  // prevent cleanup from unrefing
    eryx_push_thread(rt, ref, nresults, false);
    cleanup_pending_op(op);
}

static void poll_cb(uv_poll_t* handle, int status, int events) {
    SocketPendingOp* op = (SocketPendingOp*)handle->data;
    if (!op || op->finished) return;
    op->finished = true;

    uv_poll_stop(handle);

    if (op->has_timer && !uv_is_closing((uv_handle_t*)&op->timer)) {
        uv_timer_stop(&op->timer);
    }

    if (status < 0) {
        lua_pushnil(op->thread);
        lua_pushstring(op->thread, uv_strerror(status));
        int ref = op->threadRef;
        op->threadRef = LUA_NOREF;
        eryx_push_thread(op->runtime, ref, 2, false);
        cleanup_pending_op(op);
        return;
    }

    execute_ready_op(op);
}

static void timeout_cb(uv_timer_t* handle) {
    SocketPendingOp* op = (SocketPendingOp*)handle->data;
    if (!op || op->finished) return;
    op->finished = true;

    uv_poll_stop(&op->poll);

    const char* opname = "operation";
    switch (op->op) {
        case OpType::RECV:
            opname = "recv";
            break;
        case OpType::RECVFROM:
            opname = "recvfrom";
            break;
        case OpType::SEND:
        case OpType::SENDTO:
            opname = "send";
            break;
        case OpType::SENDALL:
            opname = "sendall";
            break;
        case OpType::ACCEPT:
            opname = "accept";
            break;
        case OpType::CONNECT:
            opname = "connect";
            break;
    }

    lua_pushnil(op->thread);
    lua_pushfstring(op->thread, "%s timed out", opname);
    int ref = op->threadRef;
    op->threadRef = LUA_NOREF;
    eryx_push_thread(op->runtime, ref, 2, false);
    cleanup_pending_op(op);
}

// ---------------------------------------------------------------------------
// Socket methods
// ---------------------------------------------------------------------------

static int sock_bind(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    const char* host = luaL_optstring(L, 2, "");
    int port = luaL_checkinteger(L, 3);

    struct sockaddr_storage addr {};
    int addrlen = 0;
    resolve_addr(L, host, port, s->family, s->type, s->proto, &addr, &addrlen);

    if (bind(s->fd, (struct sockaddr*)&addr, addrlen) == SOCKET_ERROR) sock_error(L, "bind");
    return 0;
}

static int sock_listen(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    int backlog = luaL_optinteger(L, 2, SOMAXCONN);
    if (listen(s->fd, backlog) == SOCKET_ERROR) sock_error(L, "listen");
    return 0;
}

static int sock_accept(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);

    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    SOCKET client = accept(s->fd, (struct sockaddr*)&addr, &addrlen);

    if (client != INVALID_SOCKET) {
        make_nonblocking(client);
        LuaSocket* cs = (LuaSocket*)lua_newuserdata(L, sizeof(LuaSocket));
        cs->fd = client;
        cs->family = s->family;
        cs->type = s->type;
        cs->proto = s->proto;
        cs->timeout = s->timeout;
        luaL_getmetatable(L, SOCKET_METATABLE);
        lua_setmetatable(L, -2);
        push_sockaddr(L, (struct sockaddr*)&addr, addrlen);
        return 3;
    }

    if (!sock_would_block()) sock_error(L, "accept");
    if (s->timeout == 0) {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushnil(L);
        return 3;
    }

    schedule_socket_op(L, s, OpType::ACCEPT, UV_READABLE);
    return lua_yield(L, 0);
}

static int sock_connect(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    const char* host = luaL_checkstring(L, 2);
    int port = luaL_checkinteger(L, 3);

    struct sockaddr_storage addr {};
    int addrlen = 0;
    resolve_addr(L, host, port, s->family, s->type, s->proto, &addr, &addrlen);

    int rc = connect(s->fd, (struct sockaddr*)&addr, addrlen);
    if (rc == 0) return 0;

    if (!sock_in_progress()) sock_error(L, "connect");

    schedule_socket_op(L, s, OpType::CONNECT, UV_WRITABLE);
    return lua_yield(L, 0);
}

static int sock_close(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    if (s->fd != INVALID_SOCKET) {
        sock_fd_close(s->fd);
        s->fd = INVALID_SOCKET;
    }
    return 0;
}

static int sock_shutdown(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    int how = luaL_checkinteger(L, 2);
    if (shutdown(s->fd, how) == SOCKET_ERROR) sock_error(L, "shutdown");
    return 0;
}

static int sock_send(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    size_t len = 0;
    const char* data = (const char*)luaL_checkbuffer(L, 2, &len);

    int sent = ::send(s->fd, data, (int)len, 0);
    if (sent >= 0) {
        lua_pushinteger(L, sent);
        return 1;
    }

    if (!sock_would_block()) sock_error(L, "send");
    if (s->timeout == 0) {
        lua_pushnil(L);
        return 1;
    }

    schedule_socket_op(L, s, OpType::SEND, UV_WRITABLE, 0, data, len);
    return lua_yield(L, 0);
}

static int sock_sendall(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    size_t len = 0;
    const char* data = (const char*)luaL_checkbuffer(L, 2, &len);

    size_t total = 0;
    while (total < len) {
        int sent = ::send(s->fd, data + total, (int)(len - total), 0);
        if (sent > 0) {
            total += (size_t)sent;
            continue;
        }
        if (sent == 0) break;

        if (!sock_would_block()) sock_error(L, "sendall");
        if (total == 0 && s->timeout == 0) {
            lua_pushboolean(L, false);
            return 1;
        }

        schedule_socket_op(L, s, OpType::SENDALL, UV_WRITABLE, 0, data + total, len - total);
        return lua_yield(L, 0);
    }

    lua_pushboolean(L, true);
    return 1;
}

static int sock_sendto(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    size_t len = 0;
    const char* data = (const char*)luaL_checkbuffer(L, 2, &len);
    const char* host = luaL_checkstring(L, 3);
    int port = luaL_checkinteger(L, 4);

    struct sockaddr_storage addr {};
    int addrlen = 0;
    resolve_addr(L, host, port, s->family, s->type, s->proto, &addr, &addrlen);

    int sent = sendto(s->fd, data, (int)len, 0, (struct sockaddr*)&addr, addrlen);
    if (sent >= 0) {
        lua_pushinteger(L, sent);
        return 1;
    }

    if (!sock_would_block()) sock_error(L, "sendto");
    if (s->timeout == 0) {
        lua_pushnil(L);
        return 1;
    }

    schedule_socket_op(L, s, OpType::SENDTO, UV_WRITABLE, 0, data, len);
    return lua_yield(L, 0);
}

static int sock_recv(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    int bufsize = luaL_checkinteger(L, 2);
    if (bufsize <= 0) luaL_argerror(L, 2, "bufsize must be > 0");

    char stackbuf[8192];
    char* tmp = (bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[bufsize];

    int n = ::recv(s->fd, tmp, bufsize, 0);
    if (n >= 0) {
        void* out = lua_newbuffer(L, n);
        memcpy(out, tmp, n);
        if (tmp != stackbuf) delete[] tmp;
        return 1;
    }

    bool wouldblock = sock_would_block();
    if (tmp != stackbuf) delete[] tmp;

    if (!wouldblock) sock_error(L, "recv");
    if (s->timeout == 0) {
        lua_pushnil(L);
        return 1;
    }

    schedule_socket_op(L, s, OpType::RECV, UV_READABLE, bufsize);
    return lua_yield(L, 0);
}

static int sock_recvfrom(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    int bufsize = luaL_checkinteger(L, 2);
    if (bufsize <= 0) luaL_argerror(L, 2, "bufsize must be > 0");

    char stackbuf[8192];
    char* tmp = (bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[bufsize];

    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    int n = recvfrom(s->fd, tmp, bufsize, 0, (struct sockaddr*)&addr, &addrlen);

    if (n >= 0) {
        void* out = lua_newbuffer(L, n);
        memcpy(out, tmp, n);
        if (tmp != stackbuf) delete[] tmp;
        push_sockaddr(L, (struct sockaddr*)&addr, addrlen);
        return 3;
    }

    bool wouldblock = sock_would_block();
    if (tmp != stackbuf) delete[] tmp;

    if (!wouldblock) sock_error(L, "recvfrom");
    if (s->timeout == 0) {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushnil(L);
        return 3;
    }

    schedule_socket_op(L, s, OpType::RECVFROM, UV_READABLE, bufsize);
    return lua_yield(L, 0);
}

static int sock_setsockopt(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    int level = luaL_checkinteger(L, 2);
    int optname = luaL_checkinteger(L, 3);

    if (lua_type(L, 4) == LUA_TBOOLEAN) {
        int val = lua_toboolean(L, 4) ? 1 : 0;
        if (setsockopt(s->fd, level, optname, (const char*)&val, sizeof(val)) == SOCKET_ERROR)
            sock_error(L, "setsockopt");
    } else {
        int val = luaL_checkinteger(L, 4);
        if (setsockopt(s->fd, level, optname, (const char*)&val, sizeof(val)) == SOCKET_ERROR)
            sock_error(L, "setsockopt");
    }
    return 0;
}

static int sock_getsockopt(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    int level = luaL_checkinteger(L, 2);
    int optname = luaL_checkinteger(L, 3);

    int val = 0;
    socklen_t vallen = sizeof(val);
    if (getsockopt(s->fd, level, optname, (char*)&val, &vallen) == SOCKET_ERROR)
        sock_error(L, "getsockopt");

    lua_pushinteger(L, val);
    return 1;
}

// setblocking/settimeout only update the virtual timeout field.
// The OS socket stays non-blocking always.
static int sock_setblocking(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    luaL_checktype(L, 2, LUA_TBOOLEAN);
    bool blocking = lua_toboolean(L, 2);
    s->timeout = blocking ? -1.0 : 0.0;
    return 0;
}

static int sock_settimeout(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    if (lua_isnoneornil(L, 2)) {
        s->timeout = -1.0;
    } else {
        s->timeout = luaL_checknumber(L, 2);
    }
    return 0;
}

static int sock_getpeername(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    if (getpeername(s->fd, (struct sockaddr*)&addr, &addrlen) == SOCKET_ERROR)
        sock_error(L, "getpeername");
    push_sockaddr(L, (struct sockaddr*)&addr, addrlen);
    return 2;
}

static int sock_getsockname(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    if (getsockname(s->fd, (struct sockaddr*)&addr, &addrlen) == SOCKET_ERROR)
        sock_error(L, "getsockname");
    push_sockaddr(L, (struct sockaddr*)&addr, addrlen);
    return 2;
}

static int sock_fileno(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    lua_pushnumber(L, (double)(uintptr_t)s->fd);
    return 1;
}

static int sock_tostring(lua_State* L) {
    LuaSocket* s = check_socket(L, 1);
    char buf[128];
    if (s->fd == INVALID_SOCKET)
        snprintf(buf, sizeof(buf), "Socket(closed)");
    else
        snprintf(buf, sizeof(buf), "Socket(fd=%llu, family=%d, type=%d)", (unsigned long long)s->fd,
                 s->family, s->type);
    lua_pushstring(L, buf);
    return 1;
}

static int sock_gc(lua_State* L) {
    LuaSocket* s = (LuaSocket*)luaL_checkudata(L, 1, SOCKET_METATABLE);
    if (s) {
        if (s->fd != INVALID_SOCKET) {
            sock_fd_close(s->fd);
            s->fd = INVALID_SOCKET;
        }
        s->~LuaSocket();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Module-level functions
// ---------------------------------------------------------------------------

static int socket_socket(lua_State* L) {
    int family = luaL_checkinteger(L, 1);
    int type = luaL_checkinteger(L, 2);
    int proto = luaL_optinteger(L, 3, 0);

    SOCKET fd = ::socket(family, type, proto);
    if (fd == INVALID_SOCKET) sock_error(L, "socket");

    // All sockets are permanently non-blocking at the OS level
    make_nonblocking(fd);

    LuaSocket* s = (LuaSocket*)lua_newuserdata(L, sizeof(LuaSocket));
    s->fd = fd;
    s->family = family;
    s->type = type;
    s->proto = proto;
    s->timeout = -1.0;  // virtual "blocking" by default

    luaL_getmetatable(L, SOCKET_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// socket.poll([timeout]) -> 0   (no-op, kept for API compatibility)
static int socket_poll(lua_State* L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int socket_getaddrinfo(lua_State* L) {
    const char* host = lua_isnil(L, 1) ? nullptr : luaL_checkstring(L, 1);
    const char* service = nullptr;
    char svbuf[16];
    if (lua_isnumber(L, 2)) {
        snprintf(svbuf, sizeof(svbuf), "%d", lua_tointeger(L, 2));
        service = svbuf;
    } else if (lua_isstring(L, 2)) {
        service = lua_tostring(L, 2);
    }

    struct addrinfo hints {};
    hints.ai_family = luaL_optinteger(L, 3, AF_UNSPEC);
    hints.ai_socktype = luaL_optinteger(L, 4, 0);
    hints.ai_protocol = luaL_optinteger(L, 5, 0);
    hints.ai_flags = luaL_optinteger(L, 6, 0);

    struct addrinfo* res = nullptr;
    int rc = getaddrinfo(host, service, &hints, &res);
    if (rc != 0) luaL_error(L, "getaddrinfo: %s", sock_gai_strerror(rc));

    lua_newtable(L);
    int idx = 1;
    for (struct addrinfo* p = res; p; p = p->ai_next) {
        lua_newtable(L);

        lua_pushinteger(L, p->ai_family);
        lua_setfield(L, -2, "family");

        lua_pushinteger(L, p->ai_socktype);
        lua_setfield(L, -2, "type");

        lua_pushinteger(L, p->ai_protocol);
        lua_setfield(L, -2, "proto");

        lua_pushstring(L, p->ai_canonname ? p->ai_canonname : "");
        lua_setfield(L, -2, "canonname");

        char host_buf[NI_MAXHOST];
        char serv_buf[NI_MAXSERV];
        getnameinfo(p->ai_addr, (int)p->ai_addrlen, host_buf, sizeof(host_buf), serv_buf,
                    sizeof(serv_buf), NI_NUMERICHOST | NI_NUMERICSERV);
        lua_pushstring(L, host_buf);
        lua_setfield(L, -2, "addr");

        lua_pushinteger(L, atoi(serv_buf));
        lua_setfield(L, -2, "port");

        lua_rawseti(L, -2, idx++);
    }
    freeaddrinfo(res);
    return 1;
}

static int socket_getnameinfo(lua_State* L) {
    const char* host = luaL_checkstring(L, 1);
    int port = luaL_checkinteger(L, 2);
    int flags = luaL_optinteger(L, 3, 0);

    struct sockaddr_storage addr {};
    struct addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_NUMERICHOST;

    char portbuf[16];
    snprintf(portbuf, sizeof(portbuf), "%d", port);

    struct addrinfo* res = nullptr;
    int rc = getaddrinfo(host, portbuf, &hints, &res);
    if (rc != 0) luaL_error(L, "getnameinfo: getaddrinfo failed: %s", sock_gai_strerror(rc));

    char hbuf[NI_MAXHOST];
    char sbuf[NI_MAXSERV];
    rc = getnameinfo(res->ai_addr, (int)res->ai_addrlen, hbuf, sizeof(hbuf), sbuf, sizeof(sbuf),
                     flags);
    freeaddrinfo(res);
    if (rc != 0) luaL_error(L, "getnameinfo: %s", sock_gai_strerror(rc));

    lua_pushstring(L, hbuf);
    lua_pushstring(L, sbuf);
    return 2;
}

static int socket_htons(lua_State* L) {
    lua_pushinteger(L, htons((uint16_t)luaL_checkinteger(L, 1)));
    return 1;
}
static int socket_ntohs(lua_State* L) {
    lua_pushinteger(L, ntohs((uint16_t)luaL_checkinteger(L, 1)));
    return 1;
}
static int socket_htonl(lua_State* L) {
    lua_pushinteger(L, htonl((uint32_t)luaL_checkinteger(L, 1)));
    return 1;
}
static int socket_ntohl(lua_State* L) {
    lua_pushinteger(L, ntohl((uint32_t)luaL_checkinteger(L, 1)));
    return 1;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
static void register_socket_metatable(lua_State* L) {
    luaL_newmetatable(L, SOCKET_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, sock_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, sock_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, sock_bind, "Bind");
    lua_setfield(L, -2, "Bind");

    lua_pushcfunction(L, sock_listen, "Listen");
    lua_setfield(L, -2, "Listen");

    lua_pushcfunction(L, sock_accept, "Accept");
    lua_setfield(L, -2, "Accept");

    lua_pushcfunction(L, sock_connect, "Connect");
    lua_setfield(L, -2, "Connect");

    lua_pushcfunction(L, sock_close, "Close");
    lua_setfield(L, -2, "Close");

    lua_pushcfunction(L, sock_shutdown, "Shutdown");
    lua_setfield(L, -2, "Shutdown");

    lua_pushcfunction(L, sock_send, "Send");
    lua_setfield(L, -2, "Send");

    lua_pushcfunction(L, sock_sendall, "SendAll");
    lua_setfield(L, -2, "SendAll");

    lua_pushcfunction(L, sock_sendto, "SendTo");
    lua_setfield(L, -2, "SendTo");

    lua_pushcfunction(L, sock_recv, "Recv");
    lua_setfield(L, -2, "Recv");

    lua_pushcfunction(L, sock_recvfrom, "RecvFrom");
    lua_setfield(L, -2, "RecvFrom");

    lua_pushcfunction(L, sock_setsockopt, "SetSockOpt");
    lua_setfield(L, -2, "SetSockOpt");

    lua_pushcfunction(L, sock_getsockopt, "GetSockOpt");
    lua_setfield(L, -2, "GetSockOpt");

    lua_pushcfunction(L, sock_setblocking, "SetBlocking");
    lua_setfield(L, -2, "SetBlocking");

    lua_pushcfunction(L, sock_settimeout, "SetTimeout");
    lua_setfield(L, -2, "SetTimeout");

    lua_pushcfunction(L, sock_getpeername, "GetPeerName");
    lua_setfield(L, -2, "GetPeerName");

    lua_pushcfunction(L, sock_getsockname, "GetSockName");
    lua_setfield(L, -2, "GetSockName");

    lua_pushcfunction(L, sock_fileno, "FileNo");
    lua_setfield(L, -2, "FileNo");

    lua_pop(L, 1);
}

#define SETCONST(name)              \
    do {                            \
        lua_pushinteger(L, name);   \
        lua_setfield(L, -2, #name); \
    } while (0)

LUAU_MODULE_EXPORT int luauopen__socket(lua_State* L) {
#ifdef _WIN32
    WSADATA wsa;
    int rc = WSAStartup(MAKEWORD(2, 2), &wsa);
    if (rc != 0) luaL_error(L, "WSAStartup failed: %d", rc);
#endif

    register_socket_metatable(L);

    lua_newtable(L);

    lua_pushcfunction(L, socket_socket, "socket");
    lua_setfield(L, -2, "socket");

    lua_pushcfunction(L, socket_getaddrinfo, "getAddrInfo");
    lua_setfield(L, -2, "getAddrInfo");

    lua_pushcfunction(L, socket_getnameinfo, "getNameInfo");
    lua_setfield(L, -2, "getNameInfo");

    lua_pushcfunction(L, socket_poll, "poll");
    lua_setfield(L, -2, "poll");

    lua_pushcfunction(L, socket_htons, "htons");
    lua_setfield(L, -2, "htons");

    lua_pushcfunction(L, socket_ntohs, "ntohs");
    lua_setfield(L, -2, "ntohs");

    lua_pushcfunction(L, socket_htonl, "htonl");
    lua_setfield(L, -2, "htonl");

    lua_pushcfunction(L, socket_ntohl, "ntohl");
    lua_setfield(L, -2, "ntohl");

    SETCONST(AF_UNSPEC);
    SETCONST(AF_INET);
    SETCONST(AF_INET6);

    SETCONST(SOCK_STREAM);
    SETCONST(SOCK_DGRAM);
    SETCONST(SOCK_RAW);

    SETCONST(IPPROTO_TCP);
    SETCONST(IPPROTO_UDP);

    SETCONST(SOL_SOCKET);
    SETCONST(IPPROTO_IP);
    SETCONST(IPPROTO_IPV6);

    SETCONST(SO_REUSEADDR);
    SETCONST(SO_BROADCAST);
    SETCONST(SO_KEEPALIVE);
    SETCONST(SO_RCVBUF);
    SETCONST(SO_SNDBUF);
    SETCONST(SO_RCVTIMEO);
    SETCONST(SO_SNDTIMEO);
    SETCONST(SO_ERROR);
    SETCONST(SO_LINGER);

    SETCONST(TCP_NODELAY);
    SETCONST(IPV6_V6ONLY);

    lua_pushinteger(L, SD_RECEIVE);
    lua_setfield(L, -2, "SHUT_RD");
    lua_pushinteger(L, SD_SEND);
    lua_setfield(L, -2, "SHUT_WR");
    lua_pushinteger(L, SD_BOTH);
    lua_setfield(L, -2, "SHUT_RDWR");

    SETCONST(AI_PASSIVE);
    SETCONST(AI_CANONNAME);
    SETCONST(AI_NUMERICHOST);

    SETCONST(NI_NUMERICHOST);
    SETCONST(NI_NUMERICSERV);
    SETCONST(NI_DGRAM);

    return 1;
}
#undef SETCONST
