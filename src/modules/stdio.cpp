// stdio.cpp – Standard I/O module for Luau
// Provides synchronous and asynchronous access to stdin, stdout, and stderr.

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

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
    uv_tty_t tty;
    uv_stream_t* stream;
    int threadRef;
    size_t maxBytes;
    bool returnBuffer;
    bool initialized;
    bool isTty;
};

// Module-level async stdin state (one per process)
static AsyncReadData g_asyncStdin = {};

static void stdio_init_async_stdin(lua_State* L, EryxRuntime* rt);

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

struct RawModeState {
    bool initialized;
    bool supported;
    bool enabled;
#ifdef _WIN32
    HANDLE stdinHandle;
    DWORD originalMode;
#else
    struct termios originalTermios;
#endif
};

static RawModeState g_rawMode = {};

static void stdio_init_raw_mode_state() {
    if (g_rawMode.initialized) return;
    g_rawMode.initialized = true;
    g_rawMode.supported = false;
    g_rawMode.enabled = false;

#ifdef _WIN32
    HANDLE handle = GetStdHandle(STD_INPUT_HANDLE);
    if (handle == INVALID_HANDLE_VALUE || handle == nullptr) return;

    DWORD mode = 0;
    if (!GetConsoleMode(handle, &mode)) return;

    g_rawMode.supported = true;
    g_rawMode.stdinHandle = handle;
    g_rawMode.originalMode = mode;
#else
    if (!isatty(STDIN_FILENO)) return;

    struct termios term = {};
    if (tcgetattr(STDIN_FILENO, &term) != 0) return;

    g_rawMode.supported = true;
    g_rawMode.originalTermios = term;
#endif
}

static void stdio_set_raw_mode_impl(lua_State* L, bool enabled) {
    stdio_init_raw_mode_state();
    if (!g_rawMode.supported) {
        if (!enabled) {
            g_rawMode.enabled = false;
            return;
        }
        luaL_error(L, "raw mode is unavailable because stdin is not a TTY");
    }

    auto rt = eryx_get_runtime(L);
    stdio_init_async_stdin(L, rt);
    if (g_asyncStdin.isTty) {
        int modeRc =
            uv_tty_set_mode(&g_asyncStdin.tty, enabled ? UV_TTY_MODE_RAW_VT : UV_TTY_MODE_NORMAL);
        if (modeRc != 0) {
            luaL_error(L, "failed to %s raw mode: %s", enabled ? "enable" : "disable",
                       uv_strerror(modeRc));
        }
        g_rawMode.enabled = enabled;
        return;
    }

    if (enabled) {
        if (g_rawMode.enabled) return;
#ifdef _WIN32
        DWORD mode = g_rawMode.originalMode;
        mode &= ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
        mode |= ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (!SetConsoleMode(g_rawMode.stdinHandle, mode)) {
            luaL_error(L, "failed to enable raw mode");
        }
#else
        struct termios raw = g_rawMode.originalTermios;
        raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
        raw.c_oflag &= ~(OPOST);
        raw.c_cflag |= CS8;
        raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) {
            luaL_error(L, "failed to enable raw mode: %s", strerror(errno));
        }
#endif
        g_rawMode.enabled = true;
        return;
    }

    if (!g_rawMode.enabled) return;
#ifdef _WIN32
    if (!SetConsoleMode(g_rawMode.stdinHandle, g_rawMode.originalMode)) {
        luaL_error(L, "failed to disable raw mode");
    }
#else
    if (tcsetattr(STDIN_FILENO, TCSANOW, &g_rawMode.originalTermios) != 0) {
        luaL_error(L, "failed to disable raw mode: %s", strerror(errno));
    }
#endif
    g_rawMode.enabled = false;
}

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
        if (data->returnBuffer) {
            lua_newbuffer(TL, 0);
        } else {
            lua_pushliteral(TL, "");
        }
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

static int stdio_stdin_fd() {
#ifdef _WIN32
    return _fileno(stdin);
#else
    return fileno(stdin);
#endif
}

static void stdio_init_async_stdin(lua_State* L, EryxRuntime* rt) {
    if (g_asyncStdin.initialized) return;

    int fd = stdio_stdin_fd();
    if (fd < 0) {
        luaL_error(L, "failed to get stdin file descriptor");
    }

    uv_handle_type type = uv_guess_handle(fd);
    if (type == UV_TTY) {
        int initRc = uv_tty_init(rt->loop, &g_asyncStdin.tty, fd, 1);
        if (initRc != 0) {
            luaL_error(L, "failed to initialize stdin tty: %s", uv_strerror(initRc));
        }
        g_asyncStdin.stream = (uv_stream_t*)&g_asyncStdin.tty;
        g_asyncStdin.isTty = true;
    } else if (type == UV_NAMED_PIPE) {
        int initRc = uv_pipe_init(rt->loop, &g_asyncStdin.pipe, 0);
        if (initRc != 0) {
            luaL_error(L, "failed to initialize stdin pipe: %s", uv_strerror(initRc));
        }

        int openRc = uv_pipe_open(&g_asyncStdin.pipe, fd);
        if (openRc != 0) {
            luaL_error(L, "failed to open stdin pipe: %s", uv_strerror(openRc));
        }
        g_asyncStdin.stream = (uv_stream_t*)&g_asyncStdin.pipe;
        g_asyncStdin.isTty = false;
    } else {
        luaL_error(L, "async stdin read is unsupported for this stdin handle type");
    }

    g_asyncStdin.stream->data = &g_asyncStdin;
    g_asyncStdin.threadRef = LUA_NOREF;
    g_asyncStdin.initialized = true;
}

struct ReadLineOptions {
    std::string terminator;
    bool keepTerminator;
};

static ReadLineOptions stdio_readline_options(lua_State* L) {
    ReadLineOptions opts;
    opts.terminator = "\n";
    opts.keepTerminator = false;

    if (lua_gettop(L) < 1 || lua_isnoneornil(L, 1)) return opts;
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "terminator");
    if (!lua_isnil(L, -1)) {
        size_t len = 0;
        const char* term = luaL_checklstring(L, -1, &len);
        if (len == 0) {
            lua_pop(L, 1);
            luaL_error(L, "readline terminator must not be empty");
        }
        opts.terminator.assign(term, len);
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "keepTerminator");
    if (!lua_isnil(L, -1)) {
        opts.keepTerminator = lua_toboolean(L, -1);
    }
    lua_pop(L, 1);

    return opts;
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
        lua_pushliteral(L, "");
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
        lua_newbuffer(L, 0);
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
    ReadLineOptions options = stdio_readline_options(L);
    const std::string& terminator = options.terminator;
    bool keepTerminator = options.keepTerminator;

    std::string line;
    bool matched = false;
    int c;
    while ((c = fgetc(stdin)) != EOF) {
        line += (char)c;
        if (line.size() >= terminator.size()) {
            size_t start = line.size() - terminator.size();
            if (memcmp(line.data() + start, terminator.data(), terminator.size()) == 0) {
                matched = true;
                break;
            }
        }
    }

    if (c == EOF && line.empty()) {
        lua_pushliteral(L, "");
    } else {
        if (matched && !keepTerminator) {
            line.resize(line.size() - terminator.size());
        }
        // Keep backwards-compatible behavior for default newline handling.
        if (!keepTerminator && terminator == "\n" && !line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lua_pushlstring(L, line.data(), line.size());
    }
    return 1;
}

// stdio.setRawMode(enabled: boolean) -> boolean
static int stdio_setRawMode(lua_State* L) {
    luaL_checktype(L, 1, LUA_TBOOLEAN);
    bool enabled = lua_toboolean(L, 1);
    stdio_set_raw_mode_impl(L, enabled);
    lua_pushboolean(L, g_rawMode.enabled);
    return 1;
}

// stdio.isRawMode() -> boolean
static int stdio_isRawMode(lua_State* L) {
    stdio_init_raw_mode_state();
    lua_pushboolean(L, g_rawMode.enabled);
    return 1;
}

static int stdio_set_binary_mode(lua_State* L, const char* streamName, bool enabled) {
#ifdef _WIN32
    FILE* stream = nullptr;
    if (strcmp(streamName, "stdin") == 0) {
        stream = stdin;
    } else if (strcmp(streamName, "stdout") == 0) {
        stream = stdout;
    } else if (strcmp(streamName, "stderr") == 0) {
        stream = stderr;
    } else {
        luaL_error(L, "expected stream to be 'stdin', 'stdout', or 'stderr'");
    }

    if (fflush(stream) != 0) {
        luaL_error(L, "%s flush failed before mode change: %s", streamName, strerror(errno));
    }

    int fd = _fileno(stream);
    if (fd < 0) {
        luaL_error(L, "failed to get %s file descriptor", streamName);
    }

    int mode = enabled ? _O_BINARY : _O_TEXT;
    if (_setmode(fd, mode) == -1) {
        luaL_error(L, "failed to set %s binary mode: %s", streamName, strerror(errno));
    }
#else
    if (strcmp(streamName, "stdin") != 0 && strcmp(streamName, "stdout") != 0 &&
        strcmp(streamName, "stderr") != 0) {
        luaL_error(L, "expected stream to be 'stdin', 'stdout', or 'stderr'");
    }
#endif

    lua_pushboolean(L, enabled);
    return 1;
}

static bool stdio_stream_bool_arg(lua_State* L) {
    if (lua_gettop(L) >= 2 && lua_istable(L, 1)) {
        luaL_checktype(L, 2, LUA_TBOOLEAN);
        return lua_toboolean(L, 2);
    }

    luaL_checktype(L, 1, LUA_TBOOLEAN);
    return lua_toboolean(L, 1);
}

static int stdio_stdin_setBinaryMode(lua_State* L) {
    return stdio_set_binary_mode(L, "stdin", stdio_stream_bool_arg(L));
}

static int stdio_stdout_setBinaryMode(lua_State* L) {
    return stdio_set_binary_mode(L, "stdout", stdio_stream_bool_arg(L));
}

static int stdio_stderr_setBinaryMode(lua_State* L) {
    return stdio_set_binary_mode(L, "stderr", stdio_stream_bool_arg(L));
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

    stdio_init_async_stdin(L, rt);

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

    int startRc = uv_read_start(g_asyncStdin.stream, async_alloc_cb, async_read_cb);
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

    stdio_init_async_stdin(L, rt);

    if (g_asyncStdin.threadRef != LUA_NOREF) {
        luaL_error(L, "another read is already pending");
    }

    g_asyncStdin.rt = rt;
    g_asyncStdin.maxBytes = maxBytes;
    g_asyncStdin.returnBuffer = true;

    lua_pushthread(L);
    g_asyncStdin.threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    int startRc = uv_read_start(g_asyncStdin.stream, async_alloc_cb, async_read_cb);
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

// stdio.terminalSize() -> { columns: number, rows: number }?
static int stdio_terminalSize(lua_State* L) {
    int columns = 0;
    int rows = 0;

#ifdef _WIN32
    HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == INVALID_HANDLE_VALUE || handle == nullptr) {
        lua_pushnil(L);
        return 1;
    }

    CONSOLE_SCREEN_BUFFER_INFO info = {};
    if (!GetConsoleScreenBufferInfo(handle, &info)) {
        lua_pushnil(L);
        return 1;
    }

    columns = (int)(info.srWindow.Right - info.srWindow.Left + 1);
    rows = (int)(info.srWindow.Bottom - info.srWindow.Top + 1);
#else
    struct winsize ws = {};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0 || ws.ws_col == 0 || ws.ws_row == 0) {
        lua_pushnil(L);
        return 1;
    }

    columns = (int)ws.ws_col;
    rows = (int)ws.ws_row;
#endif

    lua_createtable(L, 0, 2);
    lua_pushinteger(L, columns);
    lua_setfield(L, -2, "columns");
    lua_pushinteger(L, rows);
    lua_setfield(L, -2, "rows");
    return 1;
}

static int stdio_stream_cannot_close(lua_State* L) {
    luaL_error(L, "standard stream handle cannot be closed");
    return 0;
}

static void stdio_stream_shift_no_arg(lua_State* L) {
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
    return;
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
static int stdio_stdin_readline(lua_State* L) {
    stdio_stream_shift_optional_arg(L);
    return stdio_readline(L);
}

// stdout stream wrappers
static int stdio_stdout_flush(lua_State* L) {
    stdio_stream_shift_no_arg(L);
    return stdio_flush(L);
}
static int stdio_stdout_write(lua_State* L) {
    stdio_stream_shift_required_arg(L);
    return stdio_write(L);
}
static int stdio_stdout_writeSync(lua_State* L) {
    stdio_stream_shift_required_arg(L);
    return stdio_writeSync(L);
}

// stderr stream wrappers
static int stdio_stderr_flush(lua_State* L) {
    stdio_stream_shift_no_arg(L);
    return stdio_flusherr(L);
}
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
    lua_pushcfunction(L, stdio_setRawMode, "setRawMode");
    lua_setfield(L, -2, "setRawMode");
    lua_pushcfunction(L, stdio_isRawMode, "isRawMode");
    lua_setfield(L, -2, "isRawMode");

    // Utility
    lua_pushcfunction(L, stdio_isatty, "isatty");
    lua_setfield(L, -2, "isatty");
    lua_pushcfunction(L, stdio_terminalSize, "terminalSize");
    lua_setfield(L, -2, "terminalSize");

    // stdin stream handle
    lua_newtable(L);
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "readable");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "writable");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "closed");
    lua_pushcfunction(L, stdio_stdin_setBinaryMode, "setBinaryMode");
    lua_setfield(L, -2, "setBinaryMode");
    lua_pushcfunction(L, stdio_stdin_read, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, stdio_stdin_readSync, "readSync");
    lua_setfield(L, -2, "readSync");
    lua_pushcfunction(L, stdio_stdin_readBuffer, "readBuffer");
    lua_setfield(L, -2, "readBuffer");
    lua_pushcfunction(L, stdio_stdin_readBufferSync, "readBufferSync");
    lua_setfield(L, -2, "readBufferSync");
    lua_pushcfunction(L, stdio_stdin_readline, "readline");
    lua_setfield(L, -2, "readline");
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
    lua_pushcfunction(L, stdio_stdout_flush, "flush");
    lua_setfield(L, -2, "flush");
    lua_pushcfunction(L, stdio_stdout_setBinaryMode, "setBinaryMode");
    lua_setfield(L, -2, "setBinaryMode");
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
    lua_pushcfunction(L, stdio_stderr_flush, "flush");
    lua_setfield(L, -2, "flush");
    lua_pushcfunction(L, stdio_stderr_setBinaryMode, "setBinaryMode");
    lua_setfield(L, -2, "setBinaryMode");
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
