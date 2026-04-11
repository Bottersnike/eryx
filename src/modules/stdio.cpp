// stdio.cpp – Standard I/O module for Luau
// Provides synchronous and asynchronous access to stdin, stdout, and stderr.

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

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
    bool returnBuffer;
    bool initialized;
};

// Module-level async stdin state (one per process)
static AsyncReadData g_asyncStdin = {};

struct AsyncWriteData {
    EryxRuntime* rt;
    uv_work_t req;
    int threadRef;
    bool toStderr;
    bool isFlush;
    std::string payload;
    size_t written;
    int errNo;
};

static const char* stdio_check_bytes_arg(lua_State* L, int idx, size_t* len) {
    const void* bufData = lua_tobuffer(L, idx, len);
    if (bufData) return (const char*)bufData;
    return luaL_checklstring(L, idx, len);
}

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

    if (data->threadRef == LUA_NOREF) {
        if (buf->base) delete[] buf->base;
        return;
    }

    // libuv can report "no data yet" with nread == 0. Keep waiting.
    if (nread == 0) {
        if (buf->base) delete[] buf->base;
        return;
    }

    // Stop reading after first meaningful chunk/error (single-read semantics)
    uv_read_stop(stream);

    EryxRuntime* rt = data->rt;
    lua_State* GL = rt->GL;

    lua_getref(GL, data->threadRef);
    lua_State* TL = lua_tothread(GL, -1);
    lua_pop(GL, 1);

    bool inError = false;
    if (nread > 0) {
        if (data->returnBuffer) {
            void* out = lua_newbuffer(TL, (size_t)nread);
            if (nread > 0) memcpy(out, buf->base, (size_t)nread);
        } else {
            lua_pushlstring(TL, buf->base, (size_t)nread);
        }
    } else if (nread == UV_EOF) {
        lua_pushnil(TL);
    } else {
        lua_pushstring(TL, uv_strerror((int)nread));
        inError = true;
    }

    int ref = data->threadRef;
    data->threadRef = LUA_NOREF;
    eryx_push_thread(rt, ref, 1, inError);

    if (buf->base) delete[] buf->base;
}

static void async_write_work_cb(uv_work_t* req) {
    auto* data = (AsyncWriteData*)req->data;
    FILE* stream = data->toStderr ? stderr : stdout;

    data->written = 0;
    data->errNo = 0;

    if (data->isFlush) {
        if (fflush(stream) != 0) {
            data->errNo = errno;
        }
        return;
    }

    data->written = fwrite(data->payload.data(), 1, data->payload.size(), stream);
    if (data->written < data->payload.size()) {
        data->errNo = errno != 0 ? errno : EIO;
    }
}

static std::string stdio_error_message(const char* prefix, int errNo) {
    if (errNo == 0) return std::string(prefix) + ": unknown error";
    int uvErr = uv_translate_sys_error(errNo);
    return std::string(prefix) + ": " + uv_strerror(uvErr);
}

static void async_write_after_cb(uv_work_t* req, int status) {
    auto* data = (AsyncWriteData*)req->data;
    EryxRuntime* rt = data->rt;
    lua_State* GL = rt->GL;

    lua_getref(GL, data->threadRef);
    lua_State* TL = lua_tothread(GL, -1);
    lua_pop(GL, 1);

    if (status < 0) {
        std::string msg = std::string("async stdio work failed: ") + uv_strerror(status);
        lua_pushlstring(TL, msg.data(), msg.size());
        eryx_push_thread(rt, data->threadRef, 1, true);
    } else if (data->errNo != 0) {
        std::string msg = stdio_error_message(
            data->toStderr ? "stderr write failed" : "stdout write failed", data->errNo);
        if (data->isFlush) {
            msg = stdio_error_message(
                data->toStderr ? "stderr flush failed" : "stdout flush failed", data->errNo);
        }
        lua_pushlstring(TL, msg.data(), msg.size());
        eryx_push_thread(rt, data->threadRef, 1, true);
    } else if (data->isFlush) {
        eryx_push_thread(rt, data->threadRef, 0, false);
    } else {
        lua_pushinteger(TL, (lua_Integer)data->written);
        eryx_push_thread(rt, data->threadRef, 1, false);
    }

    delete data;
}

// ── Synchronous functions ─────────────────────────────────────────────────────

// stdio.readSync(bytes?: number) -> string?
static int stdio_readSync(lua_State* L) {
    lua_Integer bytesArg = luaL_optinteger(L, 1, 4096);
    if (bytesArg < 0) luaL_error(L, "read size must be non-negative");
    if (bytesArg == 0) {
        lua_pushliteral(L, "");
        return 1;
    }
    size_t bytes = (size_t)bytesArg;

    std::vector<char> buf(bytes);
    size_t n = fread(buf.data(), 1, bytes, stdin);

    if (n > 0) {
        lua_pushlstring(L, buf.data(), n);
    } else {
        if (ferror(stdin)) luaL_error(L, "stdin read failed");
        lua_pushnil(L);
    }

    return 1;
}

// stdio.readBufferSync(bytes?: number) -> buffer?
static int stdio_readBufferSync(lua_State* L) {
    lua_Integer bytesArg = luaL_optinteger(L, 1, 4096);
    if (bytesArg < 0) luaL_error(L, "read size must be non-negative");
    if (bytesArg == 0) {
        lua_newbuffer(L, 0);
        return 1;
    }
    size_t bytes = (size_t)bytesArg;

    std::vector<char> buf(bytes);
    size_t n = fread(buf.data(), 1, bytes, stdin);

    if (n > 0) {
        void* out = lua_newbuffer(L, n);
        memcpy(out, buf.data(), n);
    } else {
        if (ferror(stdin)) luaL_error(L, "stdin read failed");
        lua_pushnil(L);
    }

    return 1;
}

// stdio.readall(chunkSize?: number) -> string
static int stdio_readall(lua_State* L) {
    int chunkSize = (int)luaL_optinteger(L, 1, 64 * 1024);
    if (chunkSize <= 0) luaL_error(L, "chunk size must be positive");

    std::vector<char> chunk((size_t)chunkSize);
    std::string out;

    while (true) {
        size_t n = fread(chunk.data(), 1, chunk.size(), stdin);
        if (n > 0) out.append(chunk.data(), n);

        if (n < chunk.size()) {
            if (ferror(stdin)) luaL_error(L, "stdin read failed");
            break;  // EOF reached
        }
    }

    lua_pushlstring(L, out.data(), out.size());
    return 1;
}

// stdio.readline() -> string?
static int stdio_readline(lua_State* L) {
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

// stdio.writeSync(data: string) -> number
static int stdio_writeSync(lua_State* L) {
    size_t len;
    const char* data = stdio_check_bytes_arg(L, 1, &len);
    size_t written = fwrite(data, 1, len, stdout);
    if (written < len) luaL_error(L, "stdout write failed: %s", strerror(errno));
    lua_pushinteger(L, (lua_Integer)written);
    return 1;
}

// stdio.writeerrSync(data: string) -> number
static int stdio_writeerrSync(lua_State* L) {
    size_t len;
    const char* data = stdio_check_bytes_arg(L, 1, &len);
    size_t written = fwrite(data, 1, len, stderr);
    if (written < len) luaL_error(L, "stderr write failed: %s", strerror(errno));
    lua_pushinteger(L, (lua_Integer)written);
    return 1;
}

// stdio.flushSync() -> ()
static int stdio_flushSync(lua_State* L) {
    if (fflush(stdout) != 0) luaL_error(L, "stdout flush failed: %s", strerror(errno));
    return 0;
}

// stdio.flusherrSync() -> ()
static int stdio_flusherrSync(lua_State* L) {
    if (fflush(stderr) != 0) luaL_error(L, "stderr flush failed: %s", strerror(errno));
    return 0;
}

// ── Asynchronous functions ────────────────────────────────────────────────────

// stdio.read(bytes?: number) -> string?  (yields)
static int stdio_read(lua_State* L) {
    auto rt = eryx_get_runtime(L);
    lua_Integer bytesArg = luaL_optinteger(L, 1, 4096);
    if (bytesArg < 0) luaL_error(L, "read size must be non-negative");
    if (bytesArg == 0) {
        lua_pushliteral(L, "");
        return 1;
    }
    size_t maxBytes = (size_t)bytesArg;

    // Initialize the pipe on first use
    if (!g_asyncStdin.initialized) {
        int initRc = uv_pipe_init(rt->loop, &g_asyncStdin.pipe, 0);
        if (initRc != 0) {
            luaL_error(L, "failed to initialize stdin pipe: %s", uv_strerror(initRc));
        }

        int openRc = uv_pipe_open(&g_asyncStdin.pipe, 0);  // fd 0 = stdin
        if (openRc != 0) {
            luaL_error(L, "failed to open stdin pipe: %s", uv_strerror(openRc));
        }

        g_asyncStdin.pipe.data = &g_asyncStdin;
        g_asyncStdin.threadRef = LUA_NOREF;
        g_asyncStdin.initialized = true;
    }

    if (g_asyncStdin.threadRef != LUA_NOREF) {
        luaL_error(L, "another read is already pending");
    }

    g_asyncStdin.rt = rt;
    g_asyncStdin.maxBytes = maxBytes;
    g_asyncStdin.returnBuffer = false;

    // Ref the current thread so it stays alive while yielded
    lua_pushthread(L);
    g_asyncStdin.threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    int startRc = uv_read_start((uv_stream_t*)&g_asyncStdin.pipe, async_alloc_cb, async_read_cb);
    if (startRc != 0) {
        int ref = g_asyncStdin.threadRef;
        g_asyncStdin.threadRef = LUA_NOREF;
        lua_unref(L, ref);
        luaL_error(L, "failed to start stdin read: %s", uv_strerror(startRc));
    }

    return lua_yield(L, 0);
}

// stdio.readBuffer(bytes?: number) -> buffer?  (yields)
static int stdio_readBuffer(lua_State* L) {
    auto rt = eryx_get_runtime(L);
    lua_Integer bytesArg = luaL_optinteger(L, 1, 4096);
    if (bytesArg < 0) luaL_error(L, "read size must be non-negative");
    if (bytesArg == 0) {
        lua_newbuffer(L, 0);
        return 1;
    }
    size_t maxBytes = (size_t)bytesArg;

    if (!g_asyncStdin.initialized) {
        int initRc = uv_pipe_init(rt->loop, &g_asyncStdin.pipe, 0);
        if (initRc != 0) {
            luaL_error(L, "failed to initialize stdin pipe: %s", uv_strerror(initRc));
        }

        int openRc = uv_pipe_open(&g_asyncStdin.pipe, 0);
        if (openRc != 0) {
            luaL_error(L, "failed to open stdin pipe: %s", uv_strerror(openRc));
        }

        g_asyncStdin.pipe.data = &g_asyncStdin;
        g_asyncStdin.threadRef = LUA_NOREF;
        g_asyncStdin.initialized = true;
    }

    if (g_asyncStdin.threadRef != LUA_NOREF) {
        luaL_error(L, "another read is already pending");
    }

    g_asyncStdin.rt = rt;
    g_asyncStdin.maxBytes = maxBytes;
    g_asyncStdin.returnBuffer = true;

    lua_pushthread(L);
    g_asyncStdin.threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    int startRc = uv_read_start((uv_stream_t*)&g_asyncStdin.pipe, async_alloc_cb, async_read_cb);
    if (startRc != 0) {
        int ref = g_asyncStdin.threadRef;
        g_asyncStdin.threadRef = LUA_NOREF;
        lua_unref(L, ref);
        luaL_error(L, "failed to start stdin read: %s", uv_strerror(startRc));
    }

    return lua_yield(L, 0);
}

// stdio.write(data: string) -> number  (yields)
static int stdio_write(lua_State* L) {
    size_t len;
    const char* payload = stdio_check_bytes_arg(L, 1, &len);
    auto rt = eryx_get_runtime(L);

    auto* data = new AsyncWriteData;
    data->rt = rt;
    data->toStderr = false;
    data->isFlush = false;
    data->payload.assign(payload, len);
    data->written = 0;
    data->errNo = 0;

    lua_pushthread(L);
    data->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    data->req.data = data;
    int rc = uv_queue_work(rt->loop, &data->req, async_write_work_cb, async_write_after_cb);
    if (rc != 0) {
        lua_unref(L, data->threadRef);
        delete data;
        luaL_error(L, "failed to queue stdout write: %s", uv_strerror(rc));
    }

    return lua_yield(L, 0);
}

// stdio.writeerr(data: string) -> number  (yields)
static int stdio_writeerr(lua_State* L) {
    size_t len;
    const char* payload = stdio_check_bytes_arg(L, 1, &len);
    auto rt = eryx_get_runtime(L);

    auto* data = new AsyncWriteData;
    data->rt = rt;
    data->toStderr = true;
    data->isFlush = false;
    data->payload.assign(payload, len);
    data->written = 0;
    data->errNo = 0;

    lua_pushthread(L);
    data->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    data->req.data = data;
    int rc = uv_queue_work(rt->loop, &data->req, async_write_work_cb, async_write_after_cb);
    if (rc != 0) {
        lua_unref(L, data->threadRef);
        delete data;
        luaL_error(L, "failed to queue stderr write: %s", uv_strerror(rc));
    }

    return lua_yield(L, 0);
}

// stdio.flush() -> ()  (yields)
static int stdio_flush(lua_State* L) {
    auto rt = eryx_get_runtime(L);

    auto* data = new AsyncWriteData;
    data->rt = rt;
    data->toStderr = false;
    data->isFlush = true;
    data->written = 0;
    data->errNo = 0;

    lua_pushthread(L);
    data->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    data->req.data = data;
    int rc = uv_queue_work(rt->loop, &data->req, async_write_work_cb, async_write_after_cb);
    if (rc != 0) {
        lua_unref(L, data->threadRef);
        delete data;
        luaL_error(L, "failed to queue stdout flush: %s", uv_strerror(rc));
    }

    return lua_yield(L, 0);
}

// stdio.flusherr() -> ()  (yields)
static int stdio_flusherr(lua_State* L) {
    auto rt = eryx_get_runtime(L);

    auto* data = new AsyncWriteData;
    data->rt = rt;
    data->toStderr = true;
    data->isFlush = true;
    data->written = 0;
    data->errNo = 0;

    lua_pushthread(L);
    data->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    data->req.data = data;
    int rc = uv_queue_work(rt->loop, &data->req, async_write_work_cb, async_write_after_cb);
    if (rc != 0) {
        lua_unref(L, data->threadRef);
        delete data;
        luaL_error(L, "failed to queue stderr flush: %s", uv_strerror(rc));
    }

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

static int stdio_stream_cannot_close(lua_State* L) {
    luaL_error(L, "standard stream handle cannot be closed");
    return 0;
}

static void stdio_stream_shift_optional_arg(lua_State* L) {
    if (lua_gettop(L) >= 2 && !lua_isnoneornil(L, 2)) {
        lua_pushvalue(L, 2);
        lua_replace(L, 1);
        lua_settop(L, 1);
    } else if (lua_gettop(L) >= 1 && lua_type(L, 1) != LUA_TTABLE) {
        // dot-call style: handle.read(4096)
        lua_settop(L, 1);
    } else {
        lua_settop(L, 0);
    }
}

static void stdio_stream_shift_required_arg(lua_State* L) {
    if (lua_gettop(L) >= 2) {
        lua_pushvalue(L, 2);
        lua_replace(L, 1);
        lua_settop(L, 1);
        return;
    }
    if (lua_gettop(L) >= 1 && lua_type(L, 1) != LUA_TTABLE) {
        // dot-call style: handle.write("x")
        lua_settop(L, 1);
        return;
    }
    luaL_error(L, "expected data argument");
}

// stdin stream wrappers
static int stdio_stdin_read(lua_State* L) {
    stdio_stream_shift_optional_arg(L);
    return stdio_read(L);
}
static int stdio_stdin_readSync(lua_State* L) {
    stdio_stream_shift_optional_arg(L);
    return stdio_readSync(L);
}
static int stdio_stdin_readBuffer(lua_State* L) {
    stdio_stream_shift_optional_arg(L);
    return stdio_readBuffer(L);
}
static int stdio_stdin_readBufferSync(lua_State* L) {
    stdio_stream_shift_optional_arg(L);
    return stdio_readBufferSync(L);
}

// stdout stream wrappers
static int stdio_stdout_write(lua_State* L) {
    stdio_stream_shift_required_arg(L);
    return stdio_write(L);
}
static int stdio_stdout_writeSync(lua_State* L) {
    stdio_stream_shift_required_arg(L);
    return stdio_writeSync(L);
}

// stderr stream wrappers
static int stdio_stderr_write(lua_State* L) {
    stdio_stream_shift_required_arg(L);
    return stdio_writeerr(L);
}
static int stdio_stderr_writeSync(lua_State* L) {
    stdio_stream_shift_required_arg(L);
    return stdio_writeerrSync(L);
}

// ── Module entry ──────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_stdio(lua_State* L) {
    lua_newtable(L);

    // Async-first API
    lua_pushcfunction(L, stdio_read, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, stdio_write, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, stdio_writeerr, "writeerr");
    lua_setfield(L, -2, "writeerr");
    lua_pushcfunction(L, stdio_flush, "flush");
    lua_setfield(L, -2, "flush");
    lua_pushcfunction(L, stdio_flusherr, "flusherr");
    lua_setfield(L, -2, "flusherr");

    // Sync variants
    lua_pushcfunction(L, stdio_readSync, "readSync");
    lua_setfield(L, -2, "readSync");
    lua_pushcfunction(L, stdio_readBuffer, "readBuffer");
    lua_setfield(L, -2, "readBuffer");
    lua_pushcfunction(L, stdio_readBufferSync, "readBufferSync");
    lua_setfield(L, -2, "readBufferSync");
    lua_pushcfunction(L, stdio_readall, "readall");
    lua_setfield(L, -2, "readall");
    lua_pushcfunction(L, stdio_writeSync, "writeSync");
    lua_setfield(L, -2, "writeSync");
    lua_pushcfunction(L, stdio_writeerrSync, "writeerrSync");
    lua_setfield(L, -2, "writeerrSync");
    lua_pushcfunction(L, stdio_flushSync, "flushSync");
    lua_setfield(L, -2, "flushSync");
    lua_pushcfunction(L, stdio_flusherrSync, "flusherrSync");
    lua_setfield(L, -2, "flusherrSync");
    lua_pushcfunction(L, stdio_readline, "readline");
    lua_setfield(L, -2, "readline");

    // Utility
    lua_pushcfunction(L, stdio_isatty, "isatty");
    lua_setfield(L, -2, "isatty");

    // stdin stream handle
    lua_newtable(L);
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "readable");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "writable");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "closed");
    lua_pushcfunction(L, stdio_stdin_read, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, stdio_stdin_readSync, "readSync");
    lua_setfield(L, -2, "readSync");
    lua_pushcfunction(L, stdio_stdin_readBuffer, "readBuffer");
    lua_setfield(L, -2, "readBuffer");
    lua_pushcfunction(L, stdio_stdin_readBufferSync, "readBufferSync");
    lua_setfield(L, -2, "readBufferSync");
    lua_pushcfunction(L, stdio_stream_cannot_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, stdio_stream_cannot_close, "closeSync");
    lua_setfield(L, -2, "closeSync");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "stdin");

    // stdout stream handle
    lua_newtable(L);
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "readable");
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "writable");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "closed");
    lua_pushcfunction(L, stdio_stdout_write, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, stdio_stdout_writeSync, "writeSync");
    lua_setfield(L, -2, "writeSync");
    lua_pushcfunction(L, stdio_stream_cannot_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, stdio_stream_cannot_close, "closeSync");
    lua_setfield(L, -2, "closeSync");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "stdout");

    // stderr stream handle
    lua_newtable(L);
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "readable");
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "writable");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "closed");
    lua_pushcfunction(L, stdio_stderr_write, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, stdio_stderr_writeSync, "writeSync");
    lua_setfield(L, -2, "writeSync");
    lua_pushcfunction(L, stdio_stream_cannot_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, stdio_stream_cannot_close, "closeSync");
    lua_setfield(L, -2, "closeSync");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "stderr");

    lua_setreadonly(L, -1, true);
    return 1;
}
