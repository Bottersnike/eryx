#include <fcntl.h>

#include <cstring>
#include <filesystem>
#include <map>
#include <new>
#include <string>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <aclapi.h>
#include <io.h>
#include <sddl.h>
#include <sys/stat.h>
#include <windows.h>
#else
#include <grp.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#include "../LuaUtil.hpp"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_fs",
};
LUAU_MODULE_INFO()

static const char* FILE_METATABLE = "File";
static const char* FILE_LINE_ITER_METATABLE = "FileLineIterator";
static const char* WALK_ITER_METATABLE = "FsWalkIterator";

namespace fs = std::filesystem;

#ifndef O_BINARY
#define O_BINARY 0
#endif

static bool parse_permission_token(const char* token, uint32_t* outMask) {
    if (strcmp(token, "read") == 0) {
#ifdef _WIN32
        *outMask = FILE_GENERIC_READ;
#else
        *outMask = 1;
#endif
        return true;
    }
    if (strcmp(token, "write") == 0) {
#ifdef _WIN32
        *outMask = FILE_GENERIC_WRITE;
#else
        *outMask = 2;
#endif
        return true;
    }
    if (strcmp(token, "execute") == 0) {
#ifdef _WIN32
        *outMask = FILE_GENERIC_EXECUTE;
#else
        *outMask = 4;
#endif
        return true;
    }
    if (strcmp(token, "delete") == 0) {
#ifdef _WIN32
        *outMask = DELETE;
#else
        *outMask = 8;
#endif
        return true;
    }
    if (strcmp(token, "readAcl") == 0) {
#ifdef _WIN32
        *outMask = READ_CONTROL;
#else
        *outMask = 16;
#endif
        return true;
    }
    if (strcmp(token, "writeAcl") == 0) {
#ifdef _WIN32
        *outMask = WRITE_DAC;
#else
        *outMask = 32;
#endif
        return true;
    }
    if (strcmp(token, "writeOwner") == 0) {
#ifdef _WIN32
        *outMask = WRITE_OWNER;
#else
        *outMask = 64;
#endif
        return true;
    }
    return false;
}

#ifdef _WIN32
static bool win_sid_to_string(PSID sid, std::string& out) {
    LPSTR sidStr = nullptr;
    if (!ConvertSidToStringSidA(sid, &sidStr) || sidStr == nullptr) return false;
    out.assign(sidStr);
    LocalFree(sidStr);
    return true;
}

static bool win_parse_sid_string(const char* value, PSID* sidOut) {
    return ConvertStringSidToSidA(value, sidOut) == TRUE;
}

static DWORD win_rights_from_list(lua_State* L, int idx) {
    DWORD mask = 0;
    if (!lua_istable(L, idx)) {
        luaL_error(L, "rights must be an array");
    }
    int n = lua_objlen(L, idx);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, idx, i);
        const char* token = luaL_checkstring(L, -1);
        uint32_t part = 0;
        if (!parse_permission_token(token, &part)) {
            lua_pop(L, 1);
            luaL_error(L, "unknown permission token '%s'", token);
        }
        mask |= (DWORD)part;
        lua_pop(L, 1);
    }
    return mask;
}

static void win_push_rights_list(lua_State* L, DWORD mask) {
    lua_newtable(L);
    int index = 1;
    const char* tokens[] = { "read",    "write",    "execute",   "delete",
                             "readAcl", "writeAcl", "writeOwner" };
    for (const char* token : tokens) {
        uint32_t part = 0;
        parse_permission_token(token, &part);
        if ((mask & part) == part) {
            lua_pushstring(L, token);
            lua_rawseti(L, -2, index++);
        }
    }
}

static DWORD win_inheritance_flags(lua_State* L, int idx, bool* inheritsOut) {
    bool inherits = false;
    DWORD flags = 0;

    lua_getfield(L, idx, "inherits");
    if (!lua_isnil(L, -1)) inherits = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "appliesTo");
    const char* appliesTo = lua_isstring(L, -1) ? lua_tostring(L, -1) : "this";
    lua_pop(L, 1);

    if (strcmp(appliesTo, "children") == 0) {
        flags |= INHERIT_ONLY_ACE | OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
        inherits = true;
    } else if (strcmp(appliesTo, "this_and_children") == 0) {
        flags |= OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
        inherits = true;
    } else if (strcmp(appliesTo, "this") == 0) {
        if (inherits) flags |= OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
    } else {
        luaL_error(L, "appliesTo must be 'this', 'children', or 'this_and_children'");
    }

    *inheritsOut = inherits;
    return flags;
}
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

struct FileLineIterator {
    std::string buffered;
    int lineNumber = 0;
    bool eof = false;
};

struct WalkIterator {
    fs::path root;
    bool recursive = false;
    bool followSymlinks = false;
    std::vector<fs::directory_iterator> stack;
};

static void file_line_iter_dtor(void* ud) { ((FileLineIterator*)ud)->~FileLineIterator(); }

static void walk_iter_dtor(void* ud) { ((WalkIterator*)ud)->~WalkIterator(); }

static FileLineIterator* check_line_iter(lua_State* L, int idx) {
    return (FileLineIterator*)luaL_checkudata(L, idx, FILE_LINE_ITER_METATABLE);
}

static WalkIterator* check_walk_iter(lua_State* L, int idx) {
    return (WalkIterator*)luaL_checkudata(L, idx, WALK_ITER_METATABLE);
}

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
    int statResult = uv_fs_fstat(rt->loop, &req, f->fd, nullptr);
    if (statResult < 0) {
        uv_fs_req_cleanup(&req);
        return 0;
    }
    int64_t fileSize = (int64_t)req.statbuf.st_size;
    uv_fs_req_cleanup(&req);

#ifdef _WIN32
    // uv_fs_open descriptors can come from a different CRT than this module in
    // some build/link setups. Calling _lseeki64 on those descriptors can trip
    // a debug CRT assertion (_osfile(fh) & FOPEN). For default-size reads we
    // only need an upper bound; returning file size is sufficient.
    return fileSize > 0 ? fileSize : 0;
#else
    int64_t pos = file_lseek(f->fd, 0, SEEK_CUR);
    if (pos < 0) pos = 0;

    return (fileSize > pos) ? (fileSize - pos) : 0;
#endif
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

static int file_readAllSync(lua_State* L, LuaFile* f, bool asBuffer) {
    constexpr size_t chunkSize = 64 * 1024;
    std::vector<char> chunk(chunkSize);
    std::string out;

    while (true) {
        uv_buf_t uvBuf = uv_buf_init(chunk.data(), (unsigned int)chunk.size());
        uv_fs_t req;
        int result = uv_fs_read(eryx_get_runtime(L)->loop, &req, f->fd, &uvBuf, 1, -1, nullptr);
        uv_fs_req_cleanup(&req);

        if (result < 0) {
            luaL_error(L, "read failed: %s", uv_strerror(result));
            return 0;
        }

        if (result == 0) break;
        out.append(chunk.data(), (size_t)result);
    }

    if (asBuffer) {
        void* buf = lua_newbuffer(L, out.size());
        if (!out.empty()) memcpy(buf, out.data(), out.size());
    } else {
        lua_pushlstring(L, out.data(), out.size());
    }
    return 1;
}

static int file_readSync(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canRead) luaL_error(L, "file not opened for reading");

    if (lua_isnoneornil(L, 2)) return file_readAllSync(L, f, false);

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

    if (lua_isnoneornil(L, 2)) return file_readAllSync(L, f, true);

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

static const char* check_bytes_arg(lua_State* L, int idx, size_t* len) {
    const void* bufData = lua_tobuffer(L, idx, len);
    if (bufData) return (const char*)bufData;
    return luaL_checklstring(L, idx, len);
}

static int file_writeSync(lua_State* L) {
    LuaFile* f = check_open_file(L);
    if (!f->canWrite) luaL_error(L, "file not opened for writing");

    size_t len;
    const char* data = check_bytes_arg(L, 2, &len);

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
    const char* data = check_bytes_arg(L, 2, &len);

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
// File line iterator
// ---------------------------------------------------------------------------

static bool file_line_try_push(lua_State* L, FileLineIterator* it) {
    std::string& s = it->buffered;

    for (size_t i = 0; i < s.size(); i++) {
        char ch = s[i];
        if (ch == '\n') {
            std::string line = s.substr(0, i);
            s.erase(0, i + 1);
            lua_pushinteger(L, ++it->lineNumber);
            lua_pushlstring(L, line.data(), line.size());
            lua_pushliteral(L, "\n");
            return true;
        }

        if (ch == '\r') {
            if (i + 1 >= s.size() && !it->eof) return false;

            size_t endingLen = (i + 1 < s.size() && s[i + 1] == '\n') ? 2 : 1;
            std::string line = s.substr(0, i);
            s.erase(0, i + endingLen);
            lua_pushinteger(L, ++it->lineNumber);
            lua_pushlstring(L, line.data(), line.size());
            lua_pushlstring(L, endingLen == 2 ? "\r\n" : "\r", endingLen);
            return true;
        }
    }

    if (it->eof && !s.empty()) {
        lua_pushinteger(L, ++it->lineNumber);
        lua_pushlstring(L, s.data(), s.size());
        lua_pushliteral(L, "");
        s.clear();
        return true;
    }

    return false;
}

struct FileLineAsyncOp {
    lua_State* L;
    int threadRef;
    EryxRuntime* rt;
    FileLineIterator* iter;
    uv_file fd;
    uv_buf_t buf;
};

static void end_line_async(FileLineAsyncOp* op, uv_fs_t* req, int nresults, bool inError) {
    uv_fs_req_cleanup(req);
    eryx_push_thread(op->rt, op->threadRef, nresults, inError);
    free(op->buf.base);
    delete req;
    delete op;
}

static void file_line_read_cb(uv_fs_t* req) {
    FileLineAsyncOp* op = (FileLineAsyncOp*)req->data;
    if (req->result < 0) {
        lua_pushfstring(op->L, "read failed: %s", uv_strerror((int)req->result));
        end_line_async(op, req, 1, true);
        return;
    }

    if (req->result == 0) {
        op->iter->eof = true;
    } else {
        op->iter->buffered.append(op->buf.base, (size_t)req->result);
    }

    if (file_line_try_push(op->L, op->iter)) {
        end_line_async(op, req, 3, false);
        return;
    }

    if (op->iter->eof) {
        end_line_async(op, req, 0, false);
        return;
    }

    uv_fs_req_cleanup(req);
    req->data = op;
    uv_fs_read(op->rt->loop, req, op->fd, &op->buf, 1, -1, file_line_read_cb);
}

static int file_line_next(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "_file");
    LuaFile* f = check_open_file(L, -1);
    if (!f->canRead) luaL_error(L, "file not opened for reading");
    lua_pop(L, 1);

    lua_getfield(L, 1, "_iter");
    FileLineIterator* it = check_line_iter(L, -1);
    lua_pop(L, 1);

    if (file_line_try_push(L, it)) return 3;
    if (it->eof) return 0;

    FileLineAsyncOp* op = new FileLineAsyncOp;
    op->L = L;
    op->rt = eryx_get_runtime(L);
    op->iter = it;
    op->fd = f->fd;
    op->buf = uv_buf_init((char*)malloc(64 * 1024), 64 * 1024);

    lua_pushthread(L);
    op->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_read(op->rt->loop, req, f->fd, &op->buf, 1, -1, file_line_read_cb);
    return lua_yield(L, 0);
}

static int file_iter(lua_State* L) {
    check_open_file(L, 1);

    lua_pushcfunction(L, file_line_next, "File.lines.next");
    lua_createtable(L, 0, 2);

    lua_pushvalue(L, 1);
    lua_setfield(L, -2, "_file");

    void* ud = lua_newuserdatadtor(L, sizeof(FileLineIterator), file_line_iter_dtor);
    new (ud) FileLineIterator();
    luaL_getmetatable(L, FILE_LINE_ITER_METATABLE);
    lua_setmetatable(L, -2);
    lua_setfield(L, -2, "_iter");

    return 2;
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
    std::string path = luaL_checkpathlike(L, 1);
    const char* mode = luaL_optstring(L, 2, "r");

    bool readable, writable;
    int flags = parse_open_flags(mode, &readable, &writable);
    if (flags < 0) luaL_argerror(L, 2, "invalid mode string");

    uv_fs_t req;
    int result = uv_fs_open(eryx_get_runtime(L)->loop, &req, path.c_str(), flags, 0644, nullptr);
    uv_fs_req_cleanup(&req);

    if (result < 0) {
        luaL_error(L, "failed to open '%s': %s", path.c_str(), uv_strerror(result));
        return 0;
    }

    init_file_ud(L, (uv_file)result, readable, writable, path.c_str());
    return 1;
}

static int fs_open(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    const char* mode = luaL_optstring(L, 2, "r");

    bool readable, writable;
    int flags = parse_open_flags(mode, &readable, &writable);
    if (flags < 0) luaL_argerror(L, 2, "invalid mode string");

    FsAsyncOp* op = begin_async(L);
    op->openReadable = readable;
    op->openWritable = writable;
    strncpy(op->openPath, path.c_str(), sizeof(op->openPath) - 1);
    op->openPath[sizeof(op->openPath) - 1] = '\0';

    uv_fs_t* req = new uv_fs_t;
    req->data = op;
    uv_fs_open(op->rt->loop, req, path.c_str(), flags, 0644, open_async_cb);
    return lua_yield(L, 0);
}

// ===========================================================================
// Existing top-level fs functions
// ===========================================================================

// fs.exists(path) -> bool
static int fs_exists(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    bool exists = fs::exists(path, ec);
    lua_pushboolean(L, exists && !ec);
    return 1;
}

// fs.isFile(path) -> bool
static int fs_isFile(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    bool is_file = fs::is_regular_file(path, ec);
    lua_pushboolean(L, is_file && !ec);
    return 1;
}

// fs.isDirectory(path) -> bool
static int fs_isDirectory(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    bool is_dir = fs::is_directory(path, ec);
    lua_pushboolean(L, is_dir && !ec);
    return 1;
}

// fs.mkdir(path) -> bool
static int fs_mkdir(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    bool success = fs::create_directories(path, ec);
    lua_pushboolean(L, success);
    return 1;
}

// Depth-first recursive delete. On Windows we use the Win32 API directly
// with the \\?\ extended-length prefix so that paths longer than MAX_PATH
// (260 chars) are handled correctly. std::filesystem silently fails on long
// paths without this prefix.
#ifdef _WIN32
static void forceRemoveAll(const std::wstring& path, std::error_code& ec) {
    ec.clear();

    // Build the \\?\ prefixed version for all API calls.
    std::wstring lp = L"\\\\?\\" + path;

    DWORD attrs = GetFileAttributesW(lp.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) return;  // doesn't exist — nothing to do

    if (attrs & FILE_ATTRIBUTE_DIRECTORY) {
        // Ensure we can list the directory.
        SetFileAttributesW(lp.c_str(), attrs & ~FILE_ATTRIBUTE_READONLY);

        WIN32_FIND_DATAW fd;
        HANDLE hFind = FindFirstFileW((lp + L"\\*").c_str(), &fd);
        if (hFind != INVALID_HANDLE_VALUE) {
            do {
                if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
                forceRemoveAll(path + L"\\" + fd.cFileName, ec);
                if (ec) break;
            } while (FindNextFileW(hFind, &fd));
            FindClose(hFind);
        }

        SetFileAttributesW(lp.c_str(), FILE_ATTRIBUTE_NORMAL);
        if (!RemoveDirectoryW(lp.c_str()))
            ec = std::error_code(static_cast<int>(GetLastError()), std::system_category());
    } else {
        SetFileAttributesW(lp.c_str(), FILE_ATTRIBUTE_NORMAL);
        if (!DeleteFileW(lp.c_str()))
            ec = std::error_code(static_cast<int>(GetLastError()), std::system_category());
    }
#else
static void forceRemoveAll(const fs::path& p, std::error_code& ec) {
    ec.clear();

    std::error_code ignore;

    if (!fs::exists(p, ignore)) return;

    if (fs::is_directory(p, ignore)) {
        fs::permissions(p, fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec,
                        fs::perm_options::add, ignore);
        for (auto& entry : fs::directory_iterator(p, ec)) {
            if (ec) return;
            forceRemoveAll(entry.path(), ec);
            if (ec) return;
        }
    }

    fs::permissions(p, fs::perms::owner_write, fs::perm_options::add, ignore);
    fs::remove(p, ec);
#endif
}

// fs.remove(path) -> bool
static int fs_remove(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
#ifdef _WIN32
    forceRemoveAll(fs::absolute(fs::path(path)).wstring(), ec);
#else
    forceRemoveAll(fs::absolute(fs::path(path)), ec);
#endif
    std::error_code ignore;
    lua_pushboolean(L, !ec && !fs::exists(path, ignore));
    return 1;
}

// fs.listDir(path) -> {string}
static int fs_listDir(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);

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

static void push_walk_entry(lua_State* L, const fs::directory_entry& entry) {
    fs::path p = entry.path();
    lua_createtable(L, 0, 3);

    std::string name = p.filename().string();
    lua_pushlstring(L, name.data(), name.size());
    lua_setfield(L, -2, "name");

    std::string directory = p.parent_path().string();
    lua_pushlstring(L, directory.data(), directory.size());
    lua_setfield(L, -2, "directory");

    std::string path = p.string();
    lua_pushlstring(L, path.data(), path.size());
    lua_setfield(L, -2, "path");
}

static fs::directory_options walk_options(bool followSymlinks) {
    fs::directory_options opts = fs::directory_options::skip_permission_denied;
    if (followSymlinks) opts |= fs::directory_options::follow_directory_symlink;
    return opts;
}

static int walk_next(lua_State* L) {
    WalkIterator* it = check_walk_iter(L, 1);

    while (!it->stack.empty()) {
        fs::directory_iterator& current = it->stack.back();
        if (current == fs::directory_iterator()) {
            it->stack.pop_back();
            continue;
        }

        fs::directory_entry entry = *current;
        std::error_code ec;
        current.increment(ec);
        if (ec) {
            it->stack.pop_back();
            continue;
        }

        if (it->recursive) {
            std::error_code statusEc;
            fs::file_status status =
                it->followSymlinks ? entry.status(statusEc) : entry.symlink_status(statusEc);
            if (!statusEc && fs::is_directory(status)) {
                fs::directory_iterator child(entry.path(), walk_options(it->followSymlinks), ec);
                if (!ec) it->stack.push_back(child);
            }
        }

        push_walk_entry(L, entry);
        return 1;
    }

    return 0;
}

static int walk_iter(lua_State* L) {
    check_walk_iter(L, 1);
    lua_pushcfunction(L, walk_next, "fs.walk.next");
    lua_pushvalue(L, 1);
    return 2;
}

// fs.walk(root, options?) -> walk iterator
static int fs_walk(lua_State* L) {
    std::string root = luaL_checkpathlike(L, 1);
    bool recursive = false;
    bool followSymlinks = false;

    if (!lua_isnoneornil(L, 2)) {
        luaL_checktype(L, 2, LUA_TTABLE);

        lua_getfield(L, 2, "recursive");
        recursive = lua_toboolean(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "followSymlinks");
        followSymlinks = lua_toboolean(L, -1);
        lua_pop(L, 1);
    }

    void* ud = lua_newuserdatadtor(L, sizeof(WalkIterator), walk_iter_dtor);
    WalkIterator* it = new (ud) WalkIterator();
    it->root = fs::path(root);
    it->recursive = recursive;
    it->followSymlinks = followSymlinks;

    std::error_code ec;
    fs::directory_iterator first(it->root, walk_options(followSymlinks), ec);
    if (!ec) it->stack.push_back(first);

    luaL_getmetatable(L, WALK_ITER_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// fs.dirname(path) -> string
static int fs_dirname(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::string parent = fs::path(path).parent_path().string();
    lua_pushstring(L, parent.c_str());
    return 1;
}

// fs.basename(path) -> string
static int fs_basename(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::string name = fs::path(path).filename().string();
    lua_pushstring(L, name.c_str());
    return 1;
}

// fs.stem(path) -> string (filename without extension)
static int fs_stem(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::string stem = fs::path(path).stem().string();
    lua_pushstring(L, stem.c_str());
    return 1;
}

// fs.extension(path) -> string (includes the leading dot)
static int fs_extension(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::string ext = fs::path(path).extension().string();
    lua_pushstring(L, ext.c_str());
    return 1;
}

// fs.canonicalize(path) -> string
static int fs_canonicalize(lua_State* L) {
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

// fs.join(path, ...) -> string
static int fs_join(lua_State* L) {
    int n = lua_gettop(L);
    if (n < 1) {
        luaL_error(L, "fs.join requires at least one argument");
        return 0;
    }
    fs::path result(luaL_checkpathlike(L, 1));
    for (int i = 2; i <= n; i++) {
        result /= luaL_checkpathlike(L, i);
    }
    std::string str = result.string();
    lua_pushstring(L, str.c_str());
    return 1;
}

// fs.rename(oldPath, newPath)
static int fs_rename(lua_State* L) {
    std::string oldPath = luaL_checkpathlike(L, 1);
    std::string newPath = luaL_checkpathlike(L, 2);
    std::error_code ec;
    fs::rename(oldPath, newPath, ec);
    if (ec) {
        luaL_error(L, "rename failed: %s -> %s (%s)", oldPath.c_str(), newPath.c_str(),
                   ec.message().c_str());
        return 0;
    }
    return 0;
}

// fs.copy(src, dst)
static int fs_copy(lua_State* L) {
    std::string src = luaL_checkpathlike(L, 1);
    std::string dst = luaL_checkpathlike(L, 2);
    std::error_code ec;
    fs::copy(src, dst, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
    if (ec) {
        luaL_error(L, "copy failed: %s -> %s (%s)", src.c_str(), dst.c_str(), ec.message().c_str());
        return 0;
    }
    return 0;
}

// fs.symlink(target, link, type?)
// type: "file" (default) or "directory"
// On Windows, the correct symlink type must be used; on Unix this is ignored.
static int fs_symlink(lua_State* L) {
    std::string target = luaL_checkpathlike(L, 1);
    std::string link = luaL_checkpathlike(L, 2);
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
        luaL_error(L, "symlink failed: %s -> %s (%s)", target.c_str(), link.c_str(),
                   ec.message().c_str());
        return 0;
    }
    return 0;
}

// fs.readlink(path) -> string
static int fs_readlink(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    fs::path target = fs::read_symlink(path, ec);
    if (ec) {
        luaL_error(L, "readlink failed: %s (%s)", path.c_str(), ec.message().c_str());
        return 0;
    }
    std::string result = target.string();
    lua_pushstring(L, result.c_str());
    return 1;
}

// fs.isSymlink(path) -> bool
static int fs_isSymlink(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    std::error_code ec;
    // symlink_status does NOT follow symlinks, so is_symlink works correctly
    auto status = fs::symlink_status(path, ec);
    lua_pushboolean(L, !ec && fs::is_symlink(status));
    return 1;
}

// fs.stat(path, followSymlinks?) -> { size, mtime, isFile, isDirectory, isSymlink }
// followSymlinks defaults to true
static int fs_stat(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
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

    // readonly (cross-platform)
    lua_pushstring(L, "readonly");
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    lua_pushboolean(L,
                    attrs != INVALID_FILE_ATTRIBUTES && ((attrs & FILE_ATTRIBUTE_READONLY) != 0));
#else
    struct stat st;
    if (::stat(path.c_str(), &st) == 0) {
        lua_pushboolean(L, (st.st_mode & S_IWUSR) == 0);
    } else {
        lua_pushnil(L);
    }
#endif
    lua_settable(L, -3);

    return 1;
}

static int fs_hasPermission(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    const char* permission = luaL_checkstring(L, 2);
    uint32_t requested = 0;
    if (!parse_permission_token(permission, &requested)) {
        luaL_error(L, "unknown permission token '%s'", permission);
    }

#ifdef _WIN32
    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "principal");
        bool hasPrincipal = !lua_isnil(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 3, "groups");
        bool hasGroups = !lua_isnil(L, -1);
        lua_pop(L, 1);
        if (hasPrincipal || hasGroups) {
            luaL_error(L,
                       "hasPermission principal/groups override is not supported on Windows yet");
        }
    }

    PSECURITY_DESCRIPTOR sd = nullptr;
    PACL dacl = nullptr;
    DWORD secErr =
        GetNamedSecurityInfoA((LPSTR)path.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                              nullptr, nullptr, &dacl, nullptr, &sd);
    if (secErr != ERROR_SUCCESS) {
        lua_pushboolean(L, false);
        return 1;
    }

    HANDLE token = nullptr;
    HANDLE impToken = nullptr;
    BOOL allowed = FALSE;
    DWORD granted = 0;
    PRIVILEGE_SET ps = {};
    DWORD psLen = sizeof(ps);
    GENERIC_MAPPING mapping = { FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_GENERIC_EXECUTE,
                                FILE_ALL_ACCESS };

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &token)) {
        LocalFree(sd);
        lua_pushboolean(L, false);
        return 1;
    }
    if (!DuplicateToken(token, SecurityImpersonation, &impToken)) {
        CloseHandle(token);
        LocalFree(sd);
        lua_pushboolean(L, false);
        return 1;
    }
    MapGenericMask((PDWORD)&requested, &mapping);
    AccessCheck(sd, impToken, requested, &mapping, &ps, &psLen, &granted, &allowed);
    CloseHandle(impToken);
    CloseHandle(token);
    LocalFree(sd);
    lua_pushboolean(L, allowed == TRUE);
    return 1;
#else
    uid_t checkUid = geteuid();
    std::vector<gid_t> checkGroups;
    checkGroups.push_back(getegid());

    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "principal");
        if (!lua_isnil(L, -1)) {
            if (lua_isnumber(L, -1)) {
                checkUid = (uid_t)lua_tointeger(L, -1);
            } else {
                luaL_error(L, "principal must be a uid number on POSIX");
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 3, "groups");
        if (!lua_isnil(L, -1)) {
            if (!lua_istable(L, -1)) luaL_error(L, "groups must be an array");
            checkGroups.clear();
            int n = lua_objlen(L, -1);
            for (int i = 1; i <= n; i++) {
                lua_rawgeti(L, -1, i);
                checkGroups.push_back((gid_t)luaL_checkinteger(L, -1));
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
    }

    struct stat st;
    if (::stat(path.c_str(), &st) != 0) {
        lua_pushboolean(L, false);
        return 1;
    }

    auto inGroups = [&](gid_t gid) {
        for (gid_t g : checkGroups) {
            if (g == gid) return true;
        }
        return false;
    };

    bool allowed = false;
    if (requested == 16) {
        allowed = true;
    } else if (requested == 32 || requested == 64) {
        allowed = (checkUid == 0 || checkUid == st.st_uid);
    } else if (requested == 8) {
        // delete permission is controlled by parent directory permissions
        fs::path parent = fs::path(path).parent_path();
        struct stat pst;
        if (::stat(parent.empty() ? "." : parent.string().c_str(), &pst) == 0) {
            mode_t writeBit = 0;
            mode_t execBit = 0;
            if (checkUid == pst.st_uid) {
                writeBit = S_IWUSR;
                execBit = S_IXUSR;
            } else if (inGroups(pst.st_gid)) {
                writeBit = S_IWGRP;
                execBit = S_IXGRP;
            } else {
                writeBit = S_IWOTH;
                execBit = S_IXOTH;
            }
            allowed = ((pst.st_mode & writeBit) != 0) && ((pst.st_mode & execBit) != 0);
        }
    } else {
        mode_t bit = 0;
        if (requested == 1) {
            if (checkUid == st.st_uid)
                bit = S_IRUSR;
            else if (inGroups(st.st_gid))
                bit = S_IRGRP;
            else
                bit = S_IROTH;
        } else if (requested == 2) {
            if (checkUid == st.st_uid)
                bit = S_IWUSR;
            else if (inGroups(st.st_gid))
                bit = S_IWGRP;
            else
                bit = S_IWOTH;
        } else if (requested == 4) {
            if (checkUid == st.st_uid)
                bit = S_IXUSR;
            else if (inGroups(st.st_gid))
                bit = S_IXGRP;
            else
                bit = S_IXOTH;
        }
        allowed = (st.st_mode & bit) != 0;
        if (checkUid == 0 && requested != 4) {
            allowed = true;
        }
    }

    lua_pushboolean(L, allowed);
    return 1;
#endif
}

static int fs_getReadonly(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    lua_pushboolean(L,
                    attrs != INVALID_FILE_ATTRIBUTES && ((attrs & FILE_ATTRIBUTE_READONLY) != 0));
#else
    struct stat st;
    if (::stat(path.c_str(), &st) == 0)
        lua_pushboolean(L, (st.st_mode & S_IWUSR) == 0);
    else
        lua_pushboolean(L, false);
#endif
    return 1;
}

static int fs_setReadonly(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    bool readonly = lua_toboolean(L, 2);
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) luaL_error(L, "path does not exist");
    if (readonly)
        attrs |= FILE_ATTRIBUTE_READONLY;
    else
        attrs &= ~FILE_ATTRIBUTE_READONLY;
    if (!SetFileAttributesA(path.c_str(), attrs)) luaL_error(L, "failed to set readonly attribute");
#else
    struct stat st;
    if (::stat(path.c_str(), &st) != 0) luaL_error(L, "path does not exist");
    mode_t mode = st.st_mode;
    if (readonly)
        mode &= ~(S_IWUSR | S_IWGRP | S_IWOTH);
    else
        mode |= S_IWUSR;
    if (::chmod(path.c_str(), mode) != 0) luaL_error(L, "failed to set readonly state");
#endif
    return 0;
}

static int fs_getHidden(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    lua_pushboolean(L, attrs != INVALID_FILE_ATTRIBUTES && ((attrs & FILE_ATTRIBUTE_HIDDEN) != 0));
#else
    luaL_error(L, "hidden attribute is only supported on Windows");
#endif
    return 1;
}

static int fs_setHidden(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    bool hidden = lua_toboolean(L, 2);
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) luaL_error(L, "path does not exist");
    if (hidden)
        attrs |= FILE_ATTRIBUTE_HIDDEN;
    else
        attrs &= ~FILE_ATTRIBUTE_HIDDEN;
    if (!SetFileAttributesA(path.c_str(), attrs)) luaL_error(L, "failed to set hidden attribute");
#else
    luaL_error(L, "hidden attribute is only supported on Windows");
#endif
    return 0;
}

static int fs_getSystem(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    lua_pushboolean(L, attrs != INVALID_FILE_ATTRIBUTES && ((attrs & FILE_ATTRIBUTE_SYSTEM) != 0));
#else
    luaL_error(L, "system attribute is only supported on Windows");
#endif
    return 1;
}

static int fs_setSystem(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    bool systemBit = lua_toboolean(L, 2);
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) luaL_error(L, "path does not exist");
    if (systemBit)
        attrs |= FILE_ATTRIBUTE_SYSTEM;
    else
        attrs &= ~FILE_ATTRIBUTE_SYSTEM;
    if (!SetFileAttributesA(path.c_str(), attrs)) luaL_error(L, "failed to set system attribute");
#else
    luaL_error(L, "system attribute is only supported on Windows");
#endif
    return 0;
}

static int fs_chmod(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    (void)path;
    luaL_error(L, "fs.chmod is not supported on Windows; use fs.setReadonly/fs.setAcl");
#else
    lua_Integer mode = luaL_checkinteger(L, 2);
    if (::chmod(path.c_str(), (mode_t)mode) != 0) {
        luaL_error(L, "failed to chmod '%s'", path.c_str());
    }
#endif
    return 0;
}

static int fs_chown(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    const char* sidString = luaL_checkstring(L, 2);
    PSID sid = nullptr;
    if (!win_parse_sid_string(sidString, &sid)) {
        luaL_error(L, "owner must be a SID string on Windows");
    }
    DWORD err = SetNamedSecurityInfoA((LPSTR)path.c_str(), SE_FILE_OBJECT,
                                      OWNER_SECURITY_INFORMATION, sid, nullptr, nullptr, nullptr);
    LocalFree(sid);
    if (err != ERROR_SUCCESS) {
        luaL_error(L, "failed to set owner SID");
    }
#else
    uid_t uid = (uid_t)luaL_checkinteger(L, 2);
    if (::chown(path.c_str(), uid, (gid_t)-1) != 0) {
        luaL_error(L, "failed to chown '%s'", path.c_str());
    }
#endif
    return 0;
}

static int fs_chgrp(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    (void)path;
    luaL_error(L, "fs.chgrp is not supported on Windows");
#else
    gid_t gid = (gid_t)luaL_checkinteger(L, 2);
    if (::chown(path.c_str(), (uid_t)-1, gid) != 0) {
        luaL_error(L, "failed to chgrp '%s'", path.c_str());
    }
#endif
    return 0;
}

static int fs_getAcl(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
#ifdef _WIN32
    PSECURITY_DESCRIPTOR sd = nullptr;
    PACL dacl = nullptr;
    DWORD err =
        GetNamedSecurityInfoA((LPSTR)path.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                              nullptr, nullptr, &dacl, nullptr, &sd);
    if (err != ERROR_SUCCESS || dacl == nullptr) {
        if (sd) LocalFree(sd);
        lua_newtable(L);
        return 1;
    }

    ACL_SIZE_INFORMATION info = {};
    if (!GetAclInformation(dacl, &info, sizeof(info), AclSizeInformation)) {
        LocalFree(sd);
        lua_newtable(L);
        return 1;
    }

    lua_newtable(L);
    int outIndex = 1;
    for (DWORD i = 0; i < info.AceCount; i++) {
        void* aceRaw = nullptr;
        if (!GetAce(dacl, i, &aceRaw)) continue;
        ACE_HEADER* hdr = (ACE_HEADER*)aceRaw;
        DWORD mask = 0;
        PSID sid = nullptr;
        const char* aceType = nullptr;
        if (hdr->AceType == ACCESS_ALLOWED_ACE_TYPE) {
            auto* ace = (ACCESS_ALLOWED_ACE*)aceRaw;
            mask = ace->Mask;
            sid = &ace->SidStart;
            aceType = "allow";
        } else if (hdr->AceType == ACCESS_DENIED_ACE_TYPE) {
            auto* ace = (ACCESS_DENIED_ACE*)aceRaw;
            mask = ace->Mask;
            sid = &ace->SidStart;
            aceType = "deny";
        } else {
            continue;
        }

        std::string sidString;
        if (!win_sid_to_string(sid, sidString)) continue;

        lua_newtable(L);
        lua_pushstring(L, aceType);
        lua_setfield(L, -2, "type");
        lua_pushlstring(L, sidString.data(), sidString.size());
        lua_setfield(L, -2, "principal");
        win_push_rights_list(L, mask);
        lua_setfield(L, -2, "rights");
        lua_pushboolean(L, (hdr->AceFlags & (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)) != 0);
        lua_setfield(L, -2, "inherits");
        lua_pushboolean(L, (hdr->AceFlags & INHERITED_ACE) != 0);
        lua_setfield(L, -2, "inherited");

        if ((hdr->AceFlags & INHERIT_ONLY_ACE) != 0) {
            lua_pushliteral(L, "children");
        } else if ((hdr->AceFlags & (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)) != 0) {
            lua_pushliteral(L, "this_and_children");
        } else {
            lua_pushliteral(L, "this");
        }
        lua_setfield(L, -2, "appliesTo");
        lua_rawseti(L, -2, outIndex++);
    }
    LocalFree(sd);
    return 1;
#else
    luaL_error(L, "ACL APIs are only supported on Windows in this release");
#endif
    return 1;
}

static int fs_setAcl(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
#ifdef _WIN32
    std::vector<EXPLICIT_ACCESSA> entries;
    std::vector<PSID> sidPointers;

    int n = lua_objlen(L, 2);
    entries.reserve((size_t)n);
    sidPointers.reserve((size_t)n);

    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_getfield(L, -1, "type");
        const char* type = luaL_checkstring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "principal");
        const char* principal = luaL_checkstring(L, -1);
        PSID sid = nullptr;
        if (!win_parse_sid_string(principal, &sid)) {
            lua_pop(L, 1);
            luaL_error(L, "principal must be SID string on Windows");
        }
        sidPointers.push_back(sid);
        lua_pop(L, 1);

        lua_getfield(L, -1, "rights");
        DWORD rights = win_rights_from_list(L, lua_gettop(L));
        lua_pop(L, 1);

        bool inherits = false;
        DWORD inheritFlags = win_inheritance_flags(L, lua_gettop(L), &inherits);

        EXPLICIT_ACCESSA ea = {};
        ea.grfAccessPermissions = rights;
        ea.grfAccessMode = (strcmp(type, "deny") == 0) ? DENY_ACCESS : GRANT_ACCESS;
        ea.grfInheritance = inheritFlags;
        ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
        ea.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN;
        entries.push_back(ea);
        lua_pop(L, 1);
    }

    for (size_t i = 0; i < entries.size(); i++) {
        entries[i].Trustee.ptstrName = (LPSTR)sidPointers[i];
    }

    PACL acl = nullptr;
    DWORD err = SetEntriesInAclA((ULONG)entries.size(), entries.data(), nullptr, &acl);
    if (err != ERROR_SUCCESS) {
        for (PSID sid : sidPointers) {
            if (sid) LocalFree(sid);
        }
        luaL_error(L, "failed to build ACL");
    }
    err = SetNamedSecurityInfoA((LPSTR)path.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                                nullptr, nullptr, acl, nullptr);
    LocalFree(acl);
    for (PSID sid : sidPointers) {
        if (sid) LocalFree(sid);
    }
    if (err != ERROR_SUCCESS) {
        luaL_error(L, "failed to apply ACL");
    }
#else
    (void)path;
    luaL_error(L, "ACL APIs are only supported on Windows in this release");
#endif
    return 0;
}

// ===========================================================================
// Module entry point
// ===========================================================================

LUAU_MODULE_EXPORT int luauopen_fs(lua_State* L) {
    luaL_newmetatable(L, FILE_LINE_ITER_METATABLE);
    lua_setreadonly(L, -1, true);
    lua_pop(L, 1);

    luaL_newmetatable(L, WALK_ITER_METATABLE);
    lua_pushcfunction(L, walk_iter, "__iter");
    lua_setfield(L, -2, "__iter");
    lua_setreadonly(L, -1, true);
    lua_pop(L, 1);

    // -- File metatable --
    luaL_newmetatable(L, FILE_METATABLE);

    lua_pushcfunction(L, file_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, file_iter, "__iter");
    lua_setfield(L, -2, "__iter");

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
    lua_pop(L, 1);                 // pop File metatable

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
    lua_pushcfunction(L, fs_walk, "walk");
    lua_setfield(L, -2, "walk");
    lua_pushcfunction(L, fs_symlink, "symlink");
    lua_setfield(L, -2, "symlink");
    lua_pushcfunction(L, fs_readlink, "readlink");
    lua_setfield(L, -2, "readlink");
    lua_pushcfunction(L, fs_isSymlink, "isSymlink");
    lua_setfield(L, -2, "isSymlink");
    lua_pushcfunction(L, fs_stat, "stat");
    lua_setfield(L, -2, "stat");
    lua_pushcfunction(L, fs_hasPermission, "hasPermission");
    lua_setfield(L, -2, "hasPermission");
    lua_pushcfunction(L, fs_chmod, "chmod");
    lua_setfield(L, -2, "chmod");
    lua_pushcfunction(L, fs_chown, "chown");
    lua_setfield(L, -2, "chown");
    lua_pushcfunction(L, fs_chgrp, "chgrp");
    lua_setfield(L, -2, "chgrp");
    lua_pushcfunction(L, fs_getReadonly, "getReadonly");
    lua_setfield(L, -2, "getReadonly");
    lua_pushcfunction(L, fs_setReadonly, "setReadonly");
    lua_setfield(L, -2, "setReadonly");
    lua_pushcfunction(L, fs_getHidden, "getHidden");
    lua_setfield(L, -2, "getHidden");
    lua_pushcfunction(L, fs_setHidden, "setHidden");
    lua_setfield(L, -2, "setHidden");
    lua_pushcfunction(L, fs_getSystem, "getSystem");
    lua_setfield(L, -2, "getSystem");
    lua_pushcfunction(L, fs_setSystem, "setSystem");
    lua_setfield(L, -2, "setSystem");
    lua_pushcfunction(L, fs_getAcl, "getAcl");
    lua_setfield(L, -2, "getAcl");
    lua_pushcfunction(L, fs_setAcl, "setAcl");
    lua_setfield(L, -2, "setAcl");

    lua_setreadonly(L, -1, true);
    return 1;
}
