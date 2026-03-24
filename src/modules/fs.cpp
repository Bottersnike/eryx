#include <fcntl.h>

#include <filesystem>


#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_fs",
};
LUAU_MODULE_INFO()

static const char* FILE_METATABLE = "File";

namespace fs = std::filesystem;

#ifndef O_BINARY
#define O_BINARY 0
#endif

// ---------------------------------------------------------------------------
// File userdata
// ---------------------------------------------------------------------------

struct LuaFile {
    uv_file fd;
    bool closed;
    bool canRead;
    bool canWrite;
    char path[1024];
};

static void file_dtor(void* ud) {
    LuaFile* f = (LuaFile*)ud;
    if (!f->closed && f->fd >= 0) {
#ifdef _WIN32
        _close(f->fd);
#else
        ::close(f->fd);
#endif
        f->closed = true;
    }
}

static LuaFile* check_open_file(lua_State* L, int idx = 1) {
    LuaFile* f = (LuaFile*)luaL_checkudata(L, idx, FILE_METATABLE);
    if (!f) luaL_error(L, "expected File");
    if (f->closed) luaL_error(L, "attempt to use a closed file");
    return f;
}

static LuaFile* check_file_any(lua_State* L, int idx = 1) {
    LuaFile* f = (LuaFile*)luaL_checkudata(L, idx, FILE_METATABLE);
    if (!f) luaL_error(L, "expected File");
    return f;
}

// Parse Python-style mode string into open flags.
// "b" suffix is accepted but ignored -- all I/O is binary.
static int parse_open_flags(const char* mode, bool* readable, bool* writable) {
    *readable = false;
    *writable = false;

    // Strip trailing 'b' -- it's meaningless, all I/O is binary
    // Valid primaries: r, w, a, r+, w+, a+  (with optional b anywhere)
    bool hasPlus = strchr(mode, '+') != nullptr;
    char primary = mode[0];

    int flags = O_BINARY;

    switch (primary) {
        case 'r':
            *readable = true;
            if (hasPlus) {
                *writable = true;
                flags |= O_RDWR;
            } else
                flags |= O_RDONLY;
            break;
        case 'w':
            *writable = true;
            flags |= O_CREAT | O_TRUNC;
            if (hasPlus) {
                *readable = true;
                flags |= O_RDWR;
            } else
                flags |= O_WRONLY;
            break;
        case 'a':
            *writable = true;
            flags |= O_CREAT | O_APPEND;
            if (hasPlus) {
                *readable = true;
                flags |= O_RDWR;
            } else
                flags |= O_WRONLY;
            break;
        default:
            return -1;
    }

    return flags;
}

// Seek helper (cross-platform 64-bit)
static int64_t file_lseek(uv_file fd, int64_t offset, int whence) {
#ifdef _WIN32
    return _lseeki64(fd, offset, whence);
#else
    return (int64_t)lseek(fd, (off_t)offset, whence);
#endif
}

// Compute remaining bytes from current position to EOF
static int64_t get_remaining_bytes(lua_State* L, LuaFile* f) {
    EryxRuntime* rt = eryx_get_runtime(L);
    uv_fs_t req;
    uv_fs_fstat(rt->loop, &req, f->fd, nullptr);
    int64_t fileSize = (int64_t)req.statbuf.st_size;
    uv_fs_req_cleanup(&req);

    int64_t pos = file_lseek(f->fd, 0, SEEK_CUR);
    if (pos < 0) pos = 0;

    return (fileSize > pos) ? (fileSize - pos) : 0;
}

// Resolve read size: explicit int argument, or nil -> read remaining
static size_t get_read_size(lua_State* L, LuaFile* f, int argIdx) {
    if (lua_isnoneornil(L, argIdx)) {
        int64_t remaining = get_remaining_bytes(L, f);
        return (size_t)(remaining > 0 ? remaining : 0);
    }
    int n = luaL_checkinteger(L, argIdx);
    if (n < 0) luaL_argerror(L, argIdx, "size must be non-negative");
    return (size_t)n;
}

// ---------------------------------------------------------------------------
// Async operation context
// ---------------------------------------------------------------------------

struct FsAsyncOp {
    lua_State* L;
    int threadRef;
    EryxRuntime* rt;
    uv_buf_t buf;       // heap buffer for read/write data
    bool returnBuffer;  // for reads: true = buffer, false = string
    int fd;             // fd for operations that need it in callbacks
    // open-specific fields:
    bool openReadable;
    bool openWritable;
    char openPath[1024];
};

static FsAsyncOp* begin_async(lua_State* L) {
    FsAsyncOp* op = new FsAsyncOp;
    op->L = L;
    op->rt = eryx_get_runtime(L);
    op->buf = uv_buf_init(nullptr, 0);
    op->returnBuffer = false;
    op->fd = -1;

    lua_pushthread(L);
    op->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    return op;
}

static void end_async(FsAsyncOp* op, uv_fs_t* req, int nresults) {
    uv_fs_req_cleanup(req);
    eryx_push_thread(op->rt, op->threadRef, nresults, false);
    free(op->buf.base);
    delete req;
    delete op;
}

static void end_async_error(FsAsyncOp* op, uv_fs_t* req) {
    lua_pushnil(op->L);
    lua_pushstring(op->L, uv_strerror((int)req->result));
    end_async(op, req, 2);
}

// ---------------------------------------------------------------------------
// Async callbacks
// ---------------------------------------------------------------------------

static void open_async_cb(uv_fs_t* req) {
    FsAsyncOp* op = (FsAsyncOp*)req->data;
    if (req->result < 0) {
        end_async_error(op, req);
        return;
    }

    LuaFile* f = (LuaFile*)lua_newuserdatadtor(op->L, sizeof(LuaFile), file_dtor);
    f->fd = (uv_file)req->result;
    f->closed = false;
    f->canRead = op->openReadable;
    f->canWrite = op->openWritable;
    strncpy(f->path, op->openPath, sizeof(f->path) - 1);
    f->path[sizeof(f->path) - 1] = '\0';
    luaL_getmetatable(op->L, FILE_METATABLE);
    lua_setmetatable(op->L, -2);
    end_async(op, req, 1);
}

static void read_async_cb(uv_fs_t* req) {
    FsAsyncOp* op = (FsAsyncOp*)req->data;
    if (req->result < 0) {
        end_async_error(op, req);
        return;
    }

    size_t nread = (size_t)req->result;
    if (op->returnBuffer) {
        void* out = lua_newbuffer(op->L, nread);
        if (nread > 0) memcpy(out, op->buf.base, nread);
    } else {
        lua_pushlstring(op->L, op->buf.base, nread);
    }
    end_async(op, req, 1);
}

static void write_async_cb(uv_fs_t* req) {
    FsAsyncOp* op = (FsAsyncOp*)req->data;
    if (req->result < 0) {
        end_async_error(op, req);
        return;
    }

    lua_pushinteger(op->L, (int)req->result);
    end_async(op, req, 1);
}

static void close_async_cb(uv_fs_t* req) {
    FsAsyncOp* op = (FsAsyncOp*)req->data;
    if (req->result < 0) {
        end_async_error(op, req);
        return;
    }
    end_async(op, req, 0);
}

static void void_async_cb(uv_fs_t* req) {
    FsAsyncOp* op = (FsAsyncOp*)req->data;
    if (req->result < 0) {
        end_async_error(op, req);
        return;
    }
    end_async(op, req, 0);
}

// ---------------------------------------------------------------------------
// File:read(size?) / File:readSync(size?) -> string
// ---------------------------------------------------------------------------

static int file_readSync(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canRead) luaL_error(L, "file not opened for reading");

    size_t size = get_read_size(L, f, 2);
    if (size == 0) {
        lua_pushlstring(L, "", 0);
        return 1;
    }

    char* buf = (char*)malloc(size);
    if (!buf) luaL_error(L, "out of memory");

    uv_buf_t uvBuf = uv_buf_init(buf, (unsigned int)size);
    uv_fs_t req;
    int result = uv_fs_read(eryx_get_runtime(L)->loop, &req, f->fd, &uvBuf, 1, -1, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        free(buf);
        luaL_error(L, "read failed: %s", uv_strerror(result));
        return 0;
    }

    lua_pushlstring(L, buf, result);
    free(buf);
    return 1;
}

static int file_read(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canRead) luaL_error(L, "file not opened for reading");

    size_t size = get_read_size(L, f, 2);
    if (size == 0) {
        lua_pushlstring(L, "", 0);
        return 1;
    }

    FsAsyncOp* op = begin_async(L);
    op->returnBuffer = false;
    op->buf = uv_buf_init((char*)malloc(size), (unsigned int)size);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_read(op->rt->loop, req, f->fd, &op->buf, 1, -1, read_async_cb);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// File:readBuffer(size?) / File:readBufferSync(size?) -> buffer
// ---------------------------------------------------------------------------

static int file_readBufferSync(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canRead) luaL_error(L, "file not opened for reading");

    size_t size = get_read_size(L, f, 2);
    if (size == 0) {
        lua_newbuffer(L, 0);
        return 1;
    }

    char* buf = (char*)malloc(size);
    if (!buf) luaL_error(L, "out of memory");

    uv_buf_t uvBuf = uv_buf_init(buf, (unsigned int)size);
    uv_fs_t req;
    int result = uv_fs_read(eryx_get_runtime(L)->loop, &req, f->fd, &uvBuf, 1, -1, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        free(buf);
        luaL_error(L, "read failed: %s", uv_strerror(result));
        return 0;
    }

    void* out = lua_newbuffer(L, result);
    if (result > 0) memcpy(out, buf, result);
    free(buf);
    return 1;
}

static int file_readBuffer(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canRead) luaL_error(L, "file not opened for reading");

    size_t size = get_read_size(L, f, 2);
    if (size == 0) {
        lua_newbuffer(L, 0);
        return 1;
    }

    FsAsyncOp* op = begin_async(L);
    op->returnBuffer = true;
    op->buf = uv_buf_init((char*)malloc(size), (unsigned int)size);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_read(op->rt->loop, req, f->fd, &op->buf, 1, -1, read_async_cb);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// File:write(data: string) / File:writeSync(data: string) -> number
// ---------------------------------------------------------------------------

static int file_writeSync(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canWrite) luaL_error(L, "file not opened for writing");

    size_t len;
    const char* data = luaL_checklstring(L, 2, &len);

    uv_buf_t uvBuf = uv_buf_init((char*)data, (unsigned int)len);
    uv_fs_t req;
    int result = uv_fs_write(eryx_get_runtime(L)->loop, &req, f->fd, &uvBuf, 1, -1, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        luaL_error(L, "write failed: %s", uv_strerror(result));
        return 0;
    }

    lua_pushinteger(L, result);
    return 1;
}

static int file_write(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canWrite) luaL_error(L, "file not opened for writing");

    size_t len;
    const char* data = luaL_checklstring(L, 2, &len);

    FsAsyncOp* op = begin_async(L);
    op->buf = uv_buf_init((char*)malloc(len), (unsigned int)len);
    memcpy(op->buf.base, data, len);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_write(op->rt->loop, req, f->fd, &op->buf, 1, -1, write_async_cb);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// File:writeBuffer(data: buffer) / File:writeBufferSync(data: buffer) -> number
// ---------------------------------------------------------------------------

static int file_writeBufferSync(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canWrite) luaL_error(L, "file not opened for writing");

    size_t len;
    const void* data = lua_tobuffer(L, 2, &len);
    if (!data) luaL_typeerror(L, 2, "buffer");

    uv_buf_t uvBuf = uv_buf_init((char*)data, (unsigned int)len);
    uv_fs_t req;
    int result = uv_fs_write(eryx_get_runtime(L)->loop, &req, f->fd, &uvBuf, 1, -1, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        luaL_error(L, "write failed: %s", uv_strerror(result));
        return 0;
    }

    lua_pushinteger(L, result);
    return 1;
}

static int file_writeBuffer(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canWrite) luaL_error(L, "file not opened for writing");

    size_t len;
    const void* data = lua_tobuffer(L, 2, &len);
    if (!data) luaL_typeerror(L, 2, "buffer");

    FsAsyncOp* op = begin_async(L);
    op->buf = uv_buf_init((char*)malloc(len), (unsigned int)len);
    memcpy(op->buf.base, data, len);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_write(op->rt->loop, req, f->fd, &op->buf, 1, -1, write_async_cb);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// File:seek(whence?, offset?) -> number
// File:tell() -> number
// ---------------------------------------------------------------------------

static int file_seek(lua_State* L) {
    LuaFile* f = check_open_file(L);

    int64_t offset = (int64_t)luaL_checknumber(L, 2);
    const char* whenceStr = luaL_optstring(L, 3, "set");

    int whence = SEEK_SET;
    if (strcmp(whenceStr, "set") == 0)
        whence = SEEK_SET;
    else if (strcmp(whenceStr, "cur") == 0)
        whence = SEEK_CUR;
    else if (strcmp(whenceStr, "end") == 0)
        whence = SEEK_END;
    else
        luaL_argerror(L, 2, "expected 'set', 'cur', or 'end'");

    int64_t pos = file_lseek(f->fd, offset, whence);
    if (pos < 0) {
        luaL_error(L, "seek failed");
        return 0;
    }

    lua_pushnumber(L, (double)pos);
    return 1;
}

static int file_tell(lua_State* L) {
    LuaFile* f = check_open_file(L);

    int64_t pos = file_lseek(f->fd, 0, SEEK_CUR);
    if (pos < 0) {
        luaL_error(L, "tell failed");
        return 0;
    }

    lua_pushnumber(L, (double)pos);
    return 1;
}

// ---------------------------------------------------------------------------
// File:truncate(size?) -- truncates at given size, or current position if nil
// ---------------------------------------------------------------------------

static int file_truncate(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canWrite) luaL_error(L, "file not opened for writing");

    int64_t size;
    if (lua_isnoneornil(L, 2)) {
        size = file_lseek(f->fd, 0, SEEK_CUR);
        if (size < 0) {
            luaL_error(L, "failed to get file position");
            return 0;
        }
    } else {
        size = (int64_t)luaL_checknumber(L, 2);
    }

    uv_fs_t req;
    int result = uv_fs_ftruncate(eryx_get_runtime(L)->loop, &req, f->fd, size, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        luaL_error(L, "truncate failed: %s", uv_strerror(result));
        return 0;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// File:flush() / File:flushSync()
// ---------------------------------------------------------------------------

static int file_flushSync(lua_State* L) {
    LuaFile* f = check_open_file(L);

    uv_fs_t req;
    int result = uv_fs_fsync(eryx_get_runtime(L)->loop, &req, f->fd, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        luaL_error(L, "flush failed: %s", uv_strerror(result));
        return 0;
    }

    return 0;
}

static int file_flush(lua_State* L) {
    LuaFile* f = check_open_file(L);

    FsAsyncOp* op = begin_async(L);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_fsync(op->rt->loop, req, f->fd, void_async_cb);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// File:close() / File:closeSync()
// ---------------------------------------------------------------------------

static int file_closeSync(lua_State* L) {
    LuaFile* f = check_open_file(L);

    uv_fs_t req;
    int result = uv_fs_close(eryx_get_runtime(L)->loop, &req, f->fd, nullptr);
    uv_fs_req_cleanup(&req);

    f->closed = true;

    if (result < 0) {
        luaL_error(L, "close failed: %s", uv_strerror(result));
        return 0;
    }

    return 0;
}

static int file_close(lua_State* L) {
    LuaFile* f = check_open_file(L);
    f->closed = true;  // mark immediately to prevent double-close

    FsAsyncOp* op = begin_async(L);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_close(op->rt->loop, req, f->fd, close_async_cb);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// File:size() -> number
// ---------------------------------------------------------------------------

static int file_size(lua_State* L) {
    LuaFile* f = check_open_file(L);

    uv_fs_t req;
    int result = uv_fs_fstat(eryx_get_runtime(L)->loop, &req, f->fd, nullptr);
    if (result < 0) {
        uv_fs_req_cleanup(&req);
        luaL_error(L, "fstat failed: %s", uv_strerror(result));
        return 0;
    }

    lua_pushnumber(L, (double)req.statbuf.st_size);
    uv_fs_req_cleanup(&req);
    return 1;
}

// ---------------------------------------------------------------------------
// File __tostring
// ---------------------------------------------------------------------------

static int file_tostring(lua_State* L) {
    LuaFile* f = check_file_any(L);
    if (f->closed) {
        lua_pushfstring(L, "File(%s, closed)", f->path);
    } else {
        lua_pushfstring(L, "File(%s, fd=%d)", f->path, f->fd);
    }
    return 1;
}

// ---------------------------------------------------------------------------
// File __index: fields (path, fd, isOpen, readable, writable) + method fallback
// ---------------------------------------------------------------------------

// Upvalue 1 = methods table
static int file_index(lua_State* L) {
    LuaFile* f = check_file_any(L);
    const char* key = luaL_checkstring(L, 2);

    // Resolve property fields
    if (strcmp(key, "path") == 0) {
        lua_pushstring(L, f->path);
        return 1;
    }
    if (strcmp(key, "fd") == 0) {
        lua_pushinteger(L, f->fd);
        return 1;
    }
    if (strcmp(key, "isOpen") == 0) {
        lua_pushboolean(L, !f->closed);
        return 1;
    }
    if (strcmp(key, "readable") == 0) {
        lua_pushboolean(L, f->canRead && !f->closed);
        return 1;
    }
    if (strcmp(key, "writable") == 0) {
        lua_pushboolean(L, f->canWrite && !f->closed);
        return 1;
    }

    // Fall back to methods table (upvalue 1)
    lua_pushvalue(L, 2);                 // push key
    lua_rawget(L, lua_upvalueindex(1));  // methods[key]
    return 1;
}

// ---------------------------------------------------------------------------
// fs.open(path, mode?) / fs.openSync(path, mode?)
// ---------------------------------------------------------------------------

static void init_file_ud(lua_State* L, uv_file fd, bool readable, bool writable, const char* path) {
    LuaFile* f = (LuaFile*)lua_newuserdatadtor(L, sizeof(LuaFile), file_dtor);
    f->fd = fd;
    f->closed = false;
    f->canRead = readable;
    f->canWrite = writable;
    strncpy(f->path, path, sizeof(f->path) - 1);
    f->path[sizeof(f->path) - 1] = '\0';
    luaL_getmetatable(L, FILE_METATABLE);
    lua_setmetatable(L, -2);
}

static int fs_openSync(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    const char* mode = luaL_optstring(L, 2, "r");

    bool readable, writable;
    int flags = parse_open_flags(mode, &readable, &writable);
    if (flags < 0) luaL_argerror(L, 2, "invalid mode string");

    uv_fs_t req;
    int result = uv_fs_open(eryx_get_runtime(L)->loop, &req, path, flags, 0644, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        luaL_error(L, "failed to open '%s': %s", path, uv_strerror(result));
        return 0;
    }

    init_file_ud(L, (uv_file)result, readable, writable, path);
    return 1;
}

static int fs_open(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    const char* mode = luaL_optstring(L, 2, "r");

    bool readable, writable;
    int flags = parse_open_flags(mode, &readable, &writable);
    if (flags < 0) luaL_argerror(L, 2, "invalid mode string");

    FsAsyncOp* op = begin_async(L);
    op->openReadable = readable;
    op->openWritable = writable;
    strncpy(op->openPath, path, sizeof(op->openPath) - 1);
    op->openPath[sizeof(op->openPath) - 1] = '\0';

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_open(op->rt->loop, req, path, flags, 0644, open_async_cb);
    return lua_yield(L, 0);
}

// ===========================================================================
// Existing top-level fs functions
// ===========================================================================

// fs.exists(path) -> bool
static int fs_exists(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool exists = fs::exists(path, ec);
    lua_pushboolean(L, exists && !ec);
    return 1;
}

// fs.isFile(path) -> bool
static int fs_isFile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool is_file = fs::is_regular_file(path, ec);
    lua_pushboolean(L, is_file && !ec);
    return 1;
}

// fs.isDirectory(path) -> bool
static int fs_isDirectory(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool is_dir = fs::is_directory(path, ec);
    lua_pushboolean(L, is_dir && !ec);
    return 1;
}

// fs.mkdir(path) -> bool
static int fs_mkdir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    bool success = fs::create_directories(path, ec);
    lua_pushboolean(L, success);
    return 1;
}

// fs.remove(path) -> bool
static int fs_remove(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    // remove_all implements "rm -rf", remove is for empty dirs or files
    uintmax_t count = fs::remove_all(path, ec);
    lua_pushboolean(L, count > 0 && !ec);
    return 1;
}

// fs.listDir(path) -> {string}
static int fs_listDir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    lua_newtable(L);
    int index = 1;

    std::error_code ec;
    if (fs::is_directory(path, ec)) {
        for (const auto& entry : fs::directory_iterator(path, ec)) {
            if (ec) break;

            // We return just the filename, not full path
            std::string filename = entry.path().filename().string();
            lua_pushinteger(L, index++);
            lua_pushstring(L, filename.c_str());
            lua_settable(L, -3);
        }
    }

    return 1;
}

// fs.dirname(path) -> string
static int fs_dirname(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string parent = fs::path(path).parent_path().string();
    lua_pushstring(L, parent.c_str());
    return 1;
}

// fs.basename(path) -> string
static int fs_basename(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string name = fs::path(path).filename().string();
    lua_pushstring(L, name.c_str());
    return 1;
}

// fs.stem(path) -> string (filename without extension)
static int fs_stem(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string stem = fs::path(path).stem().string();
    lua_pushstring(L, stem.c_str());
    return 1;
}

// fs.extension(path) -> string (includes the leading dot)
static int fs_extension(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::string ext = fs::path(path).extension().string();
    lua_pushstring(L, ext.c_str());
    return 1;
}

// fs.canonicalize(path) -> string
static int fs_canonicalize(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    fs::path canon = fs::weakly_canonical(path, ec);
    if (ec) {
        luaL_error(L, "Failed to canonicalize path: %s (%s)", path, ec.message().c_str());
        return 0;
    }
    std::string result = canon.string();
    lua_pushstring(L, result.c_str());
    return 1;
}

// fs.join(path, ...) -> string
static int fs_join(lua_State* L) {
    int n = lua_gettop(L);
    if (n < 1) {
        luaL_error(L, "fs.join requires at least one argument");
        return 0;
    }
    fs::path result(luaL_checkstring(L, 1));
    for (int i = 2; i <= n; i++) {
        result /= luaL_checkstring(L, i);
    }
    std::string str = result.string();
    lua_pushstring(L, str.c_str());
    return 1;
}

// fs.rename(oldPath, newPath)
static int fs_rename(lua_State* L) {
    const char* oldPath = luaL_checkstring(L, 1);
    const char* newPath = luaL_checkstring(L, 2);
    std::error_code ec;
    fs::rename(oldPath, newPath, ec);
    if (ec) {
        luaL_error(L, "rename failed: %s -> %s (%s)", oldPath, newPath, ec.message().c_str());
        return 0;
    }
    return 0;
}

// fs.copy(src, dst)
static int fs_copy(lua_State* L) {
    const char* src = luaL_checkstring(L, 1);
    const char* dst = luaL_checkstring(L, 2);
    std::error_code ec;
    fs::copy(src, dst, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
    if (ec) {
        luaL_error(L, "copy failed: %s -> %s (%s)", src, dst, ec.message().c_str());
        return 0;
    }
    return 0;
}

// fs.symlink(target, link, type?)
// type: "file" (default) or "directory"
// On Windows, the correct symlink type must be used; on Unix this is ignored.
static int fs_symlink(lua_State* L) {
    const char* target = luaL_checkstring(L, 1);
    const char* link = luaL_checkstring(L, 2);
    const char* typeStr = luaL_optstring(L, 3, nullptr);

    // Auto-detect type from target if not specified
    bool isDir = false;
    if (typeStr) {
        if (strcmp(typeStr, "directory") == 0)
            isDir = true;
        else if (strcmp(typeStr, "file") == 0)
            isDir = false;
        else
            luaL_argerror(L, 3, "expected 'file' or 'directory'");
    } else {
        std::error_code ec;
        isDir = fs::is_directory(target, ec);
        // If target doesn't exist, default to file symlink
    }

    std::error_code ec;
    if (isDir) {
        fs::create_directory_symlink(target, link, ec);
    } else {
        fs::create_symlink(target, link, ec);
    }
    if (ec) {
        luaL_error(L, "symlink failed: %s -> %s (%s)", target, link, ec.message().c_str());
        return 0;
    }
    return 0;
}

// fs.readlink(path) -> string
static int fs_readlink(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    fs::path target = fs::read_symlink(path, ec);
    if (ec) {
        luaL_error(L, "readlink failed: %s (%s)", path, ec.message().c_str());
        return 0;
    }
    std::string result = target.string();
    lua_pushstring(L, result.c_str());
    return 1;
}

// fs.isSymlink(path) -> bool
static int fs_isSymlink(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    std::error_code ec;
    // symlink_status does NOT follow symlinks, so is_symlink works correctly
    auto status = fs::symlink_status(path, ec);
    lua_pushboolean(L, !ec && fs::is_symlink(status));
    return 1;
}

// fs.stat(path, followSymlinks?) -> { size, mtime, isFile, isDirectory, isSymlink }
// followSymlinks defaults to true
static int fs_stat(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    bool followSymlinks = lua_isnoneornil(L, 2) ? true : lua_toboolean(L, 2);

    std::error_code ec;
    fs::path p(path);

    // Get status (follow or not)
    auto status = followSymlinks ? fs::status(p, ec) : fs::symlink_status(p, ec);
    if (ec || !fs::exists(status)) {
        lua_newtable(L);
        return 1;  // return empty table for non-existent paths
    }

    lua_newtable(L);

    // size (only meaningful for regular files)
    if (fs::is_regular_file(status)) {
        lua_pushstring(L, "size");
        lua_pushinteger(L, fs::file_size(p, ec));
        lua_settable(L, -3);
    }

    // mtime
    auto ftime = fs::last_write_time(p, ec);
    if (!ec) {
        auto sctp = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
            ftime - fs::file_time_type::clock::now() + std::chrono::system_clock::now());
        lua_pushstring(L, "mtime");
        lua_pushinteger(
            L, std::chrono::duration_cast<std::chrono::seconds>(sctp.time_since_epoch()).count());
        lua_settable(L, -3);
    }

    // isFile
    lua_pushstring(L, "isFile");
    lua_pushboolean(L, fs::is_regular_file(status));
    lua_settable(L, -3);

    // isDirectory
    lua_pushstring(L, "isDirectory");
    lua_pushboolean(L, fs::is_directory(status));
    lua_settable(L, -3);

    // isSymlink (always check via symlink_status, regardless of followSymlinks)
    auto linkStatus = fs::symlink_status(p, ec);
    lua_pushstring(L, "isSymlink");
    lua_pushboolean(L, !ec && fs::is_symlink(linkStatus));
    lua_settable(L, -3);

    return 1;
}

// ===========================================================================
// Module entry point
// ===========================================================================

LUAU_MODULE_EXPORT int luauopen_fs(lua_State* L) {
    // -- File metatable --
    luaL_newmetatable(L, FILE_METATABLE);

    lua_pushcfunction(L, file_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    // Build methods table (used as upvalue for __index)
    lua_newtable(L);  // methods table

    // Yielding methods (default)
    lua_pushcfunction(L, file_read, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, file_readBuffer, "readBuffer");
    lua_setfield(L, -2, "readBuffer");
    lua_pushcfunction(L, file_write, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, file_writeBuffer, "writeBuffer");
    lua_setfield(L, -2, "writeBuffer");
    lua_pushcfunction(L, file_flush, "flush");
    lua_setfield(L, -2, "flush");

    // Sync variants
    lua_pushcfunction(L, file_readSync, "readSync");
    lua_setfield(L, -2, "readSync");
    lua_pushcfunction(L, file_readBufferSync, "readBufferSync");
    lua_setfield(L, -2, "readBufferSync");
    lua_pushcfunction(L, file_writeSync, "writeSync");
    lua_setfield(L, -2, "writeSync");
    lua_pushcfunction(L, file_writeBufferSync, "writeBufferSync");
    lua_setfield(L, -2, "writeBufferSync");
    lua_pushcfunction(L, file_flushSync, "flushSync");
    lua_setfield(L, -2, "flushSync");
    lua_pushcfunction(L, file_closeSync, "closeSync");
    lua_setfield(L, -2, "closeSync");

    // Always-sync methods
    lua_pushcfunction(L, file_seek, "seek");
    lua_setfield(L, -2, "seek");
    lua_pushcfunction(L, file_tell, "tell");
    lua_setfield(L, -2, "tell");
    lua_pushcfunction(L, file_truncate, "truncate");
    lua_setfield(L, -2, "truncate");
    lua_pushcfunction(L, file_size, "size");
    lua_setfield(L, -2, "size");
    lua_pushcfunction(L, file_close, "close");
    lua_setfield(L, -2, "close");

    // __index = file_index with methods table as upvalue
    lua_pushcclosure(L, file_index, "__index", 1);  // pops methods table
    lua_setfield(L, -2, "__index");

    lua_setreadonly(L, -1, true);  // Freeze metatable
    lua_pop(L, 1);  // pop File metatable

    // -- Module table --
    lua_newtable(L);

    // fs.path subtable (pure path manipulation, no I/O)
    lua_newtable(L);
    lua_pushcfunction(L, fs_dirname, "dirname");
    lua_setfield(L, -2, "dirname");
    lua_pushcfunction(L, fs_basename, "basename");
    lua_setfield(L, -2, "basename");
    lua_pushcfunction(L, fs_stem, "stem");
    lua_setfield(L, -2, "stem");
    lua_pushcfunction(L, fs_extension, "extension");
    lua_setfield(L, -2, "extension");
    lua_pushcfunction(L, fs_canonicalize, "canonicalize");
    lua_setfield(L, -2, "canonicalize");
    lua_pushcfunction(L, fs_join, "join");
    lua_setfield(L, -2, "join");
    lua_setreadonly(L, -1, 1);  // freeze fs.path
    lua_setfield(L, -2, "path");

    // File operations
    lua_pushcfunction(L, fs_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, fs_openSync, "openSync");
    lua_setfield(L, -2, "openSync");
    lua_pushcfunction(L, fs_exists, "exists");
    lua_setfield(L, -2, "exists");
    lua_pushcfunction(L, fs_isFile, "isFile");
    lua_setfield(L, -2, "isFile");
    lua_pushcfunction(L, fs_isDirectory, "isDirectory");
    lua_setfield(L, -2, "isDirectory");
    lua_pushcfunction(L, fs_mkdir, "mkdir");
    lua_setfield(L, -2, "mkdir");
    lua_pushcfunction(L, fs_remove, "remove");
    lua_setfield(L, -2, "remove");
    lua_pushcfunction(L, fs_rename, "rename");
    lua_setfield(L, -2, "rename");
    lua_pushcfunction(L, fs_copy, "copy");
    lua_setfield(L, -2, "copy");
    lua_pushcfunction(L, fs_listDir, "listDir");
    lua_setfield(L, -2, "listDir");
    lua_pushcfunction(L, fs_symlink, "symlink");
    lua_setfield(L, -2, "symlink");
    lua_pushcfunction(L, fs_readlink, "readlink");
    lua_setfield(L, -2, "readlink");
    lua_pushcfunction(L, fs_isSymlink, "isSymlink");
    lua_setfield(L, -2, "isSymlink");
    lua_pushcfunction(L, fs_stat, "stat");
    lua_setfield(L, -2, "stat");

    lua_setreadonly(L, -1, true);
    return 1;
}
