#include "zstd.h"

#include <cstring>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "zdict.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_zstd",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static constexpr size_t MAX_DECOMPRESS_SIZE = 256 * 1024 * 1024;  // 256 MB

static void* decompress_known_size(lua_State* L, const void* src, size_t srcLen, size_t outLen) {
    void* out = lua_newbuffer(L, outLen);
    size_t ret = ZSTD_decompress(out, outLen, src, srcLen);
    if (ZSTD_isError(ret)) luaL_error(L, "zstd: decompress failed: %s", ZSTD_getErrorName(ret));
    return out;
}

static void push_decompressed(lua_State* L, const void* src, size_t srcLen) {
    unsigned long long cs = ZSTD_getFrameContentSize(src, srcLen);
    if (cs != ZSTD_CONTENTSIZE_UNKNOWN && cs != ZSTD_CONTENTSIZE_ERROR) {
        if ((size_t)cs > MAX_DECOMPRESS_SIZE) {
            luaL_error(L, "zstd: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        decompress_known_size(L, src, srcLen, (size_t)cs);
        return;
    }
    // Content size not embedded - grow buffer until it fits
    std::vector<char> tmp(srcLen < 16 ? 64 : srcLen * 4);
    while (true) {
        size_t ret = ZSTD_decompress(tmp.data(), tmp.size(), src, srcLen);
        if (!ZSTD_isError(ret)) {
            void* out = lua_newbuffer(L, ret);
            memcpy(out, tmp.data(), ret);
            return;
        } else if (ZSTD_getErrorCode(ret) == ZSTD_error_dstSize_tooSmall) {
            size_t newSize = tmp.size() * 2;
            if (newSize > MAX_DECOMPRESS_SIZE) {
                luaL_error(L, "zstd: decompressed size exceeds limit (%d MB)",
                           (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
            }
            tmp.resize(newSize);
        } else {
            luaL_error(L, "zstd: decompress failed: %s", ZSTD_getErrorName(ret));
        }
    }
}

// ---------------------------------------------------------------------------
// compress(data, level?) -> buffer
// level: CLEVEL_MIN (negative) to CLEVEL_MAX (22). Default CLEVEL_DEFAULT (3).
// ---------------------------------------------------------------------------
static int l_compress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int level = (int)luaL_optinteger(L, 2, ZSTD_CLEVEL_DEFAULT);

    size_t bound = ZSTD_compressBound(srcLen);
    std::vector<char> tmp(bound);

    size_t ret = ZSTD_compress(tmp.data(), bound, src, srcLen, level);
    if (ZSTD_isError(ret)) luaL_error(L, "zstd: compress failed: %s", ZSTD_getErrorName(ret));

    void* out = lua_newbuffer(L, ret);
    memcpy(out, tmp.data(), ret);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data) -> buffer
// Fast path reads the decompressed size from the frame header when available.
// ---------------------------------------------------------------------------
static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    push_decompressed(L, src, srcLen);
    return 1;
}

// ---------------------------------------------------------------------------
// compress_bound(len) -> number
// Upper bound on output size from compress() for input of `len` bytes.
// ---------------------------------------------------------------------------
static int l_compress_bound(lua_State* L) {
    lua_Integer len = luaL_checkinteger(L, 1);
    lua_pushinteger(L, (lua_Integer)ZSTD_compressBound((size_t)len));
    return 1;
}

// ---------------------------------------------------------------------------
// frame_content_size(data) -> number?
// Returns the decompressed size stored in the frame header, or nil if it
// wasn't stored (ZSTD_CONTENTSIZE_UNKNOWN) or the frame is corrupt.
// ---------------------------------------------------------------------------
static int l_frame_content_size(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    unsigned long long cs = ZSTD_getFrameContentSize(src, srcLen);
    if (cs == ZSTD_CONTENTSIZE_UNKNOWN || cs == ZSTD_CONTENTSIZE_ERROR) {
        lua_pushnil(L);
    } else {
        lua_pushinteger(L, (lua_Integer)cs);
    }
    return 1;
}

// ---------------------------------------------------------------------------
// compress_with_dict(data, dict, level?) -> buffer
// Compresses data using a pre-trained dictionary for better ratio on small
// inputs. dict must be the same dictionary used when decompressing.
// ---------------------------------------------------------------------------
static int l_compress_with_dict(lua_State* L) {
    size_t srcLen = 0, dictLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    const void* dict = luaL_checkbuffer(L, 2, &dictLen);
    int level = (int)luaL_optinteger(L, 3, ZSTD_CLEVEL_DEFAULT);

    ZSTD_CDict* cdict = ZSTD_createCDict(dict, dictLen, level);
    if (!cdict) luaL_error(L, "zstd: failed to create CDict");

    ZSTD_CCtx* cctx = ZSTD_createCCtx();
    if (!cctx) {
        ZSTD_freeCDict(cdict);
        luaL_error(L, "zstd: failed to create CCtx");
    }

    size_t bound = ZSTD_compressBound(srcLen);
    std::vector<char> tmp(bound);
    size_t ret = ZSTD_compress_usingCDict(cctx, tmp.data(), bound, src, srcLen, cdict);

    ZSTD_freeCCtx(cctx);
    ZSTD_freeCDict(cdict);

    if (ZSTD_isError(ret))
        luaL_error(L, "zstd: compress_with_dict failed: %s", ZSTD_getErrorName(ret));

    void* out = lua_newbuffer(L, ret);
    memcpy(out, tmp.data(), ret);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress_with_dict(data, dict) -> buffer
// ---------------------------------------------------------------------------
static int l_decompress_with_dict(lua_State* L) {
    size_t srcLen = 0, dictLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    const void* dict = luaL_checkbuffer(L, 2, &dictLen);

    ZSTD_DDict* ddict = ZSTD_createDDict(dict, dictLen);
    if (!ddict) luaL_error(L, "zstd: failed to create DDict");

    ZSTD_DCtx* dctx = ZSTD_createDCtx();
    if (!dctx) {
        ZSTD_freeDDict(ddict);
        luaL_error(L, "zstd: failed to create DCtx");
    }

    unsigned long long cs = ZSTD_getFrameContentSize(src, srcLen);
    std::vector<char> tmp;
    size_t ret;

    if (cs != ZSTD_CONTENTSIZE_UNKNOWN && cs != ZSTD_CONTENTSIZE_ERROR) {
        if ((size_t)cs > MAX_DECOMPRESS_SIZE) {
            ZSTD_freeDCtx(dctx);
            ZSTD_freeDDict(ddict);
            luaL_error(L, "zstd: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        tmp.resize((size_t)cs);
        ret = ZSTD_decompress_usingDDict(dctx, tmp.data(), tmp.size(), src, srcLen, ddict);
    } else {
        tmp.resize(srcLen < 16 ? 64 : srcLen * 4);
        while (true) {
            ret = ZSTD_decompress_usingDDict(dctx, tmp.data(), tmp.size(), src, srcLen, ddict);
            if (!ZSTD_isError(ret)) break;
            if (ZSTD_getErrorCode(ret) == ZSTD_error_dstSize_tooSmall) {
                size_t newSize = tmp.size() * 2;
                if (newSize > MAX_DECOMPRESS_SIZE) {
                    ZSTD_freeDCtx(dctx);
                    ZSTD_freeDDict(ddict);
                    luaL_error(L, "zstd: decompressed size exceeds limit (%d MB)",
                               (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
                }
                tmp.resize(newSize);
            } else {
                break;
            }
        }
    }

    ZSTD_freeDCtx(dctx);
    ZSTD_freeDDict(ddict);

    if (ZSTD_isError(ret))
        luaL_error(L, "zstd: decompress_with_dict failed: %s", ZSTD_getErrorName(ret));

    void* out = lua_newbuffer(L, ret);
    memcpy(out, tmp.data(), ret);
    return 1;
}

// ---------------------------------------------------------------------------
// train_dictionary(samples, capacity) -> buffer
// samples  : array of buffers, each a representative example of your data.
//            More and larger samples produce better dictionaries.
// capacity : desired size of the output dictionary in bytes (e.g. 112640).
// Returns a trained dictionary buffer suitable for compress/decompress_with_dict.
// ---------------------------------------------------------------------------
static int l_train_dictionary(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    size_t capacity = (size_t)luaL_checkinteger(L, 2);

    int n = (int)lua_objlen(L, 1);
    if (n == 0) luaL_error(L, "zstd: train_dictionary requires at least one sample");

    std::vector<size_t> sizes(n);
    std::vector<uint8_t> all;

    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, i);
        size_t len = 0;
        const void* data = luaL_checkbuffer(L, -1, &len);
        sizes[i - 1] = len;
        const uint8_t* bytes = (const uint8_t*)data;
        all.insert(all.end(), bytes, bytes + len);
        lua_pop(L, 1);
    }

    std::vector<char> dict(capacity);
    size_t dictSize =
        ZDICT_trainFromBuffer(dict.data(), capacity, all.data(), sizes.data(), (unsigned)n);

    if (ZDICT_isError(dictSize))
        luaL_error(L, "zstd: train_dictionary failed: %s", ZDICT_getErrorName(dictSize));

    void* out = lua_newbuffer(L, dictSize);
    memcpy(out, dict.data(), dictSize);
    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Compress
// ---------------------------------------------------------------------------

static constexpr size_t STREAM_CHUNK_SIZE = 32 * 1024;  // 32 KB

static const char* MT_ZSTD_CSTREAM = "zstd.Compressor";
static const char* MT_ZSTD_DSTREAM = "zstd.Decompressor";

struct LuaZstdCompressor {
    ZSTD_CStream* cstream;
    bool closed;
};

static void zstd_compressor_dtor(void* ud) {
    auto* c = (LuaZstdCompressor*)ud;
    if (!c->closed && c->cstream) {
        ZSTD_freeCStream(c->cstream);
        c->cstream = nullptr;
        c->closed = true;
    }
}

static LuaZstdCompressor* check_zstd_compressor(lua_State* L) {
    auto* c = (LuaZstdCompressor*)luaL_checkudata(L, 1, MT_ZSTD_CSTREAM);
    if (c->closed) luaL_error(L, "zstd: compressor is closed");
    return c;
}

// compressor:write(data) -> buffer
static int l_zstd_compressor_write(lua_State* L) {
    auto* c = check_zstd_compressor(L);
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    ZSTD_inBuffer input = { src, srcLen, 0 };
    std::vector<char> out;
    out.reserve(ZSTD_CStreamOutSize());

    while (input.pos < input.size) {
        size_t used = out.size();
        out.resize(used + ZSTD_CStreamOutSize());
        ZSTD_outBuffer output = { out.data() + used, ZSTD_CStreamOutSize(), 0 };

        size_t ret = ZSTD_compressStream2(c->cstream, &output, &input, ZSTD_e_continue);
        if (ZSTD_isError(ret))
            luaL_error(L, "zstd: compress stream error: %s", ZSTD_getErrorName(ret));

        out.resize(used + output.pos);
    }

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:flush() -> buffer
static int l_zstd_compressor_flush(lua_State* L) {
    auto* c = check_zstd_compressor(L);

    ZSTD_inBuffer input = { nullptr, 0, 0 };
    std::vector<char> out;

    size_t remaining;
    do {
        size_t used = out.size();
        out.resize(used + ZSTD_CStreamOutSize());
        ZSTD_outBuffer output = { out.data() + used, ZSTD_CStreamOutSize(), 0 };

        remaining = ZSTD_compressStream2(c->cstream, &output, &input, ZSTD_e_flush);
        if (ZSTD_isError(remaining))
            luaL_error(L, "zstd: flush error: %s", ZSTD_getErrorName(remaining));

        out.resize(used + output.pos);
    } while (remaining > 0);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:finish() -> buffer
static int l_zstd_compressor_finish(lua_State* L) {
    auto* c = check_zstd_compressor(L);

    ZSTD_inBuffer input = { nullptr, 0, 0 };
    std::vector<char> out;

    size_t remaining;
    do {
        size_t used = out.size();
        out.resize(used + ZSTD_CStreamOutSize());
        ZSTD_outBuffer output = { out.data() + used, ZSTD_CStreamOutSize(), 0 };

        remaining = ZSTD_compressStream2(c->cstream, &output, &input, ZSTD_e_end);
        if (ZSTD_isError(remaining))
            luaL_error(L, "zstd: finish error: %s", ZSTD_getErrorName(remaining));

        out.resize(used + output.pos);
    } while (remaining > 0);

    ZSTD_freeCStream(c->cstream);
    c->cstream = nullptr;
    c->closed = true;

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

static int l_zstd_compressor_close(lua_State* L) {
    auto* c = (LuaZstdCompressor*)luaL_checkudata(L, 1, MT_ZSTD_CSTREAM);
    if (!c->closed && c->cstream) {
        ZSTD_freeCStream(c->cstream);
        c->cstream = nullptr;
        c->closed = true;
    }
    return 0;
}

static int l_zstd_compressor_tostring(lua_State* L) {
    auto* c = (LuaZstdCompressor*)luaL_checkudata(L, 1, MT_ZSTD_CSTREAM);
    lua_pushfstring(L, "zstd.Compressor(%s)", c->closed ? "closed" : "open");
    return 1;
}

// zstd.createCompressor(level?) -> Compressor
static int l_create_zstd_compressor(lua_State* L) {
    int level = (int)luaL_optinteger(L, 1, ZSTD_CLEVEL_DEFAULT);

    auto* c =
        (LuaZstdCompressor*)lua_newuserdatadtor(L, sizeof(LuaZstdCompressor), zstd_compressor_dtor);
    c->cstream = ZSTD_createCStream();
    c->closed = false;

    if (!c->cstream) {
        c->closed = true;
        luaL_error(L, "zstd: failed to create CStream");
    }

    size_t ret = ZSTD_initCStream(c->cstream, level);
    if (ZSTD_isError(ret)) {
        ZSTD_freeCStream(c->cstream);
        c->cstream = nullptr;
        c->closed = true;
        luaL_error(L, "zstd: initCStream failed: %s", ZSTD_getErrorName(ret));
    }

    luaL_getmetatable(L, MT_ZSTD_CSTREAM);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Decompress
// ---------------------------------------------------------------------------

struct LuaZstdDecompressor {
    ZSTD_DStream* dstream;
    bool closed;
    bool finished;
};

static void zstd_decompressor_dtor(void* ud) {
    auto* d = (LuaZstdDecompressor*)ud;
    if (!d->closed && d->dstream) {
        ZSTD_freeDStream(d->dstream);
        d->dstream = nullptr;
        d->closed = true;
    }
}

static LuaZstdDecompressor* check_zstd_decompressor(lua_State* L) {
    auto* d = (LuaZstdDecompressor*)luaL_checkudata(L, 1, MT_ZSTD_DSTREAM);
    if (d->closed) luaL_error(L, "zstd: decompressor is closed");
    return d;
}

// decompressor:write(data) -> buffer, finished
static int l_zstd_decompressor_write(lua_State* L) {
    auto* d = check_zstd_decompressor(L);
    if (d->finished) luaL_error(L, "zstd: decompressor already finished");

    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    ZSTD_inBuffer input = { src, srcLen, 0 };
    std::vector<char> out;
    out.reserve(ZSTD_DStreamOutSize());

    while (input.pos < input.size) {
        size_t used = out.size();
        if (used + ZSTD_DStreamOutSize() > MAX_DECOMPRESS_SIZE) {
            luaL_error(L, "zstd: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        out.resize(used + ZSTD_DStreamOutSize());
        ZSTD_outBuffer output = { out.data() + used, ZSTD_DStreamOutSize(), 0 };

        size_t ret = ZSTD_decompressStream(d->dstream, &output, &input);
        if (ZSTD_isError(ret))
            luaL_error(L, "zstd: decompress stream error: %s", ZSTD_getErrorName(ret));

        out.resize(used + output.pos);

        if (ret == 0) {
            d->finished = true;
            break;
        }
    }

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    lua_pushboolean(L, d->finished);
    return 2;
}

static int l_zstd_decompressor_close(lua_State* L) {
    auto* d = (LuaZstdDecompressor*)luaL_checkudata(L, 1, MT_ZSTD_DSTREAM);
    if (!d->closed && d->dstream) {
        ZSTD_freeDStream(d->dstream);
        d->dstream = nullptr;
        d->closed = true;
    }
    return 0;
}

static int l_zstd_decompressor_tostring(lua_State* L) {
    auto* d = (LuaZstdDecompressor*)luaL_checkudata(L, 1, MT_ZSTD_DSTREAM);
    const char* state = d->closed ? "closed" : (d->finished ? "finished" : "open");
    lua_pushfstring(L, "zstd.Decompressor(%s)", state);
    return 1;
}

// zstd.createDecompressor() -> Decompressor
static int l_create_zstd_decompressor(lua_State* L) {
    auto* d = (LuaZstdDecompressor*)lua_newuserdatadtor(L, sizeof(LuaZstdDecompressor),
                                                        zstd_decompressor_dtor);
    d->dstream = ZSTD_createDStream();
    d->closed = false;
    d->finished = false;

    if (!d->dstream) {
        d->closed = true;
        luaL_error(L, "zstd: failed to create DStream");
    }

    size_t ret = ZSTD_initDStream(d->dstream);
    if (ZSTD_isError(ret)) {
        ZSTD_freeDStream(d->dstream);
        d->dstream = nullptr;
        d->closed = true;
        luaL_error(L, "zstd: initDStream failed: %s", ZSTD_getErrorName(ret));
    }

    luaL_getmetatable(L, MT_ZSTD_DSTREAM);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_zstd(lua_State* L) {
    // Register Compressor metatable
    luaL_newmetatable(L, MT_ZSTD_CSTREAM);
    {
        static const luaL_Reg methods[] = {
            { "write", l_zstd_compressor_write },
            { "flush", l_zstd_compressor_flush },
            { "finish", l_zstd_compressor_finish },
            { "close", l_zstd_compressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_zstd_compressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_zstd_compressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);

    // Register Decompressor metatable
    luaL_newmetatable(L, MT_ZSTD_DSTREAM);
    {
        static const luaL_Reg methods[] = {
            { "write", l_zstd_decompressor_write },
            { "close", l_zstd_decompressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_zstd_decompressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_zstd_decompressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        { "compress", l_compress },
        { "decompress", l_decompress },
        { "compressBound", l_compress_bound },
        { "frameContentSize", l_frame_content_size },
        { "compressWithDict", l_compress_with_dict },
        { "decompressWithDict", l_decompress_with_dict },
        { "trainDictionary", l_train_dictionary },
        { "createCompressor", l_create_zstd_compressor },
        { "createDecompressor", l_create_zstd_decompressor },
        { nullptr, nullptr },
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Compression level constants
    lua_pushinteger(L, ZSTD_minCLevel());
    lua_setfield(L, -2, "CLEVEL_MIN");
    lua_pushinteger(L, ZSTD_maxCLevel());
    lua_setfield(L, -2, "CLEVEL_MAX");
    lua_pushinteger(L, ZSTD_CLEVEL_DEFAULT);
    lua_setfield(L, -2, "CLEVEL_DEFAULT");

    return 1;
}
