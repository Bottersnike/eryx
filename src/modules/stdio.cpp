// stdio.cpp – Standard I/O module for Luau
// Provides synchronous and asynchronous access to stdin, stdout, and stderr.

#include <cstdio>
#include <cstring>
#include <string>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "uv.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_stdio",
};
LUAU_MODULE_INFO()

// ── Async stdin state ─────────────────────────────────────────────────────────

struct AsyncReadData {
    EryxRuntime* rt;
    uv_pipe_t pipe;
    int threadRef;
    size_t maxBytes;
    bool initialized;
};

// Module-level async stdin state (one per process)
static AsyncReadData g_asyncStdin = {};

static void async_alloc_cb(uv_handle_t* handle, size_t suggested, uv_buf_t* buf) {
    auto* data = (AsyncReadData*)handle->data;
    size_t sz = data->maxBytes > 0 ? data->maxBytes : suggested;
    if (sz > suggested) sz = suggested;
    buf->base = new char[sz];
#ifdef _WIN32
    buf->len = (ULONG)sz;
#else
    buf->len = sz;
#endif
}

static void async_read_cb(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf) {
    auto* data = (AsyncReadData*)stream->data;

    // Stop reading after first chunk (single-read semantics)
    uv_read_stop(stream);

    if (data->threadRef == LUA_NOREF) {
        if (buf->base) delete[] buf->base;
        return;
    }

    EryxRuntime* rt = data->rt;
    lua_State* GL = rt->GL;

    lua_getref(GL, data->threadRef);
    lua_State* TL = lua_tothread(GL, -1);
    lua_pop(GL, 1);

    if (nread > 0) {
        lua_pushlstring(TL, buf->base, (size_t)nread);
    } else {
        // EOF or error
        lua_pushnil(TL);
    }

    int ref = data->threadRef;
    data->threadRef = LUA_NOREF;
    eryx_push_thread(rt, ref, 1, false);

    if (buf->base) delete[] buf->base;
}

// ── Synchronous functions ─────────────────────────────────────────────────────

// stdio.read(bytes?: number) -> string?
static int stdio_read(lua_State* L) {
    int bytes = (int)luaL_optinteger(L, 1, 4096);
    if (bytes <= 0) luaL_error(L, "read size must be positive");

    char* buf = new char[bytes];
    size_t n = fread(buf, 1, bytes, stdin);

    if (n > 0) {
        lua_pushlstring(L, buf, n);
    } else {
        lua_pushnil(L);
    }

    delete[] buf;
    return 1;
}

// stdio.readln() -> string?
static int stdio_readln(lua_State* L) {
    std::string line;
    int c;
    while ((c = fgetc(stdin)) != EOF) {
        if (c == '\n') break;
        line += (char)c;
    }

    if (c == EOF && line.empty()) {
        lua_pushnil(L);
    } else {
        // Strip trailing \r for Windows line endings
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lua_pushlstring(L, line.data(), line.size());
    }
    return 1;
}

// stdio.write(data: string) -> ()
static int stdio_write(lua_State* L) {
    size_t len;
    const char* data = luaL_checklstring(L, 1, &len);
    fwrite(data, 1, len, stdout);
    return 0;
}

// stdio.writeerr(data: string) -> ()
static int stdio_writeerr(lua_State* L) {
    size_t len;
    const char* data = luaL_checklstring(L, 1, &len);
    fwrite(data, 1, len, stderr);
    return 0;
}

// stdio.flush() -> ()
static int stdio_flush(lua_State* L) {
    fflush(stdout);
    return 0;
}

// stdio.flusherr() -> ()
static int stdio_flusherr(lua_State* L) {
    fflush(stderr);
    return 0;
}

// ── Asynchronous functions ────────────────────────────────────────────────────

// stdio.readasync(bytes?: number) -> string?  (yields)
static int stdio_readasync(lua_State* L) {
    auto rt = eryx_get_runtime(L);
    size_t maxBytes = (size_t)luaL_optinteger(L, 1, 4096);

    // Initialize the pipe on first use
    if (!g_asyncStdin.initialized) {
        uv_pipe_init(rt->loop, &g_asyncStdin.pipe, 0);
        uv_pipe_open(&g_asyncStdin.pipe, 0); // fd 0 = stdin
        g_asyncStdin.pipe.data = &g_asyncStdin;
        g_asyncStdin.threadRef = LUA_NOREF;
        g_asyncStdin.initialized = true;
    }

    if (g_asyncStdin.threadRef != LUA_NOREF) {
        luaL_error(L, "another readasync is already pending");
    }

    g_asyncStdin.rt = rt;
    g_asyncStdin.maxBytes = maxBytes;

    // Ref the current thread so it stays alive while yielded
    lua_pushthread(L);
    g_asyncStdin.threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    uv_read_start((uv_stream_t*)&g_asyncStdin.pipe, async_alloc_cb, async_read_cb);

    return lua_yield(L, 0);
}

// ── Utility functions ─────────────────────────────────────────────────────────

// stdio.isatty() -> { stdin: boolean, stdout: boolean, stderr: boolean }
static int stdio_isatty(lua_State* L) {
    lua_createtable(L, 0, 3);

    lua_pushboolean(L, uv_guess_handle(0) == UV_TTY);
    lua_setfield(L, -2, "stdin");

    lua_pushboolean(L, uv_guess_handle(1) == UV_TTY);
    lua_setfield(L, -2, "stdout");

    lua_pushboolean(L, uv_guess_handle(2) == UV_TTY);
    lua_setfield(L, -2, "stderr");

    return 1;
}

// ── Module entry ──────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_stdio(lua_State* L) {
    lua_newtable(L);

    // Sync
    lua_pushcfunction(L, stdio_read, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, stdio_readln, "readln");
    lua_setfield(L, -2, "readln");
    lua_pushcfunction(L, stdio_write, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, stdio_writeerr, "writeerr");
    lua_setfield(L, -2, "writeerr");
    lua_pushcfunction(L, stdio_flush, "flush");
    lua_setfield(L, -2, "flush");
    lua_pushcfunction(L, stdio_flusherr, "flusherr");
    lua_setfield(L, -2, "flusherr");

    // Async
    lua_pushcfunction(L, stdio_readasync, "readasync");
    lua_setfield(L, -2, "readasync");

    // Utility
    lua_pushcfunction(L, stdio_isatty, "isatty");
    lua_setfield(L, -2, "isatty");

    return 1;
}
