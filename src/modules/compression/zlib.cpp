#include "zlib.h"

#include <cstring>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_zlib",
};
LUAU_MODULE_INFO()

udataRef* zlibDeflate;
udataRef* zlibInflate;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static constexpr size_t MAX_DECOMPRESS_SIZE = 256 * 1024 * 1024;  // 256 MB
static constexpr size_t STREAM_CHUNK_SIZE = 32 * 1024;            // 32 KB

// ---------------------------------------------------------------------------
// Streaming Deflate
// ---------------------------------------------------------------------------

struct LuaDeflate {
    z_stream strm;
    bool closed;
};

static LuaDeflate* check_deflate(lua_State* L) {
    auto* d = (LuaDeflate*)eryxUdata_checkudata(L, zlibDeflate, 1);
    if (d->closed) luaL_error(L, "zlib: deflate stream is closed");
    return d;
}

// deflate:write(data, flush?) -> buffer
// flush: FLUSH_NO (0), FLUSH_SYNC (2), FLUSH_FULL (3), FLUSH_FINISH (4)
static int l_deflate_write(lua_State* L) {
    auto* d = check_deflate(L);
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);
    int flush = (int)luaL_optinteger(L, 3, Z_NO_FLUSH);

    d->strm.next_in = (Bytef*)src;
    d->strm.avail_in = (uInt)srcLen;

    std::vector<Bytef> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen);

    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        d->strm.next_out = out.data() + used;
        d->strm.avail_out = (uInt)STREAM_CHUNK_SIZE;

        int ret = deflate(&d->strm, flush);
        if (ret == Z_STREAM_ERROR) luaL_error(L, "zlib: deflate stream error");

        size_t produced = STREAM_CHUNK_SIZE - d->strm.avail_out;
        out.resize(used + produced);
    } while (d->strm.avail_out == 0);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// deflate:finish() -> buffer
// Flushes remaining data and finalizes the stream.
static int l_deflate_finish(lua_State* L) {
    auto* d = check_deflate(L);

    d->strm.next_in = nullptr;
    d->strm.avail_in = 0;

    std::vector<Bytef> out;
    int ret;
    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        d->strm.next_out = out.data() + used;
        d->strm.avail_out = (uInt)STREAM_CHUNK_SIZE;

        ret = deflate(&d->strm, Z_FINISH);
        if (ret == Z_STREAM_ERROR) luaL_error(L, "zlib: deflate stream error");

        size_t produced = STREAM_CHUNK_SIZE - d->strm.avail_out;
        out.resize(used + produced);
    } while (ret != Z_STREAM_END);

    deflateEnd(&d->strm);
    d->closed = true;

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// deflate:close()
static void l_deflate_destructor(lua_State* L, void* ud) {
    auto* d = (LuaDeflate*)ud;
    if (!d->closed) {
        deflateEnd(&d->strm);
        d->closed = true;
    }
}

static int l_deflate_close(lua_State* L) {
    auto* d = (LuaDeflate*)eryxUdata_checkudata(L, zlibDeflate, 1);
    l_deflate_destructor(L, d);
    return 0;
}

static int l_deflate_tostring(lua_State* L) {
    auto* d = (LuaDeflate*)eryxUdata_checkudata(L, zlibDeflate, 1);
    lua_pushfstring(L, "zlib.Deflate(%s)", d->closed ? "closed" : "open");
    return 1;
}

// zlib.createDeflate(level?, windowBits?, memLevel?, strategy?) -> Deflate
static int l_create_deflate(lua_State* L) {
    int level = (int)luaL_optinteger(L, 1, Z_DEFAULT_COMPRESSION);
    int windowBits = (int)luaL_optinteger(L, 2, MAX_WBITS);
    int memLevel = (int)luaL_optinteger(L, 3, 8);
    int strategy = (int)luaL_optinteger(L, 4, Z_DEFAULT_STRATEGY);

    auto* d = (LuaDeflate*)eryxUdata_pushudata(L, zlibDeflate);
    memset(&d->strm, 0, sizeof(z_stream));
    d->closed = false;

    int ret = deflateInit2(&d->strm, level, Z_DEFLATED, windowBits, memLevel, strategy);
    if (ret != Z_OK) {
        d->closed = true;
        luaL_error(L, "zlib: deflateInit2 failed (%d)", ret);
    }

    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Inflate
// ---------------------------------------------------------------------------

struct LuaInflate {
    z_stream strm;
    bool closed;
    bool finished;
};

static LuaInflate* check_inflate(lua_State* L) {
    auto* d = (LuaInflate*)eryxUdata_checkudata(L, zlibInflate, 1);
    if (d->closed) luaL_error(L, "zlib: inflate stream is closed");
    return d;
}

// inflate:write(data) -> buffer, finished
// Returns decompressed output and whether the stream has ended.
static int l_inflate_write(lua_State* L) {
    auto* d = check_inflate(L);
    if (d->finished) luaL_error(L, "zlib: inflate stream already finished");

    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);

    d->strm.next_in = (Bytef*)src;
    d->strm.avail_in = (uInt)srcLen;

    std::vector<Bytef> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen * 2);

    int ret = Z_OK;
    do {
        size_t used = out.size();
        if (used + STREAM_CHUNK_SIZE > MAX_DECOMPRESS_SIZE) {
            luaL_error(L, "zlib: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        out.resize(used + STREAM_CHUNK_SIZE);
        d->strm.next_out = out.data() + used;
        d->strm.avail_out = (uInt)STREAM_CHUNK_SIZE;

        ret = inflate(&d->strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_ERROR || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR ||
            ret == Z_NEED_DICT) {
            luaL_error(L, "zlib: inflate error (%d)", ret);
        }

        size_t produced = STREAM_CHUNK_SIZE - d->strm.avail_out;
        out.resize(used + produced);

        if (ret == Z_STREAM_END) {
            d->finished = true;
            break;
        }
    } while (d->strm.avail_out == 0);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    lua_pushboolean(L, d->finished);
    return 2;
}

// inflate:close()
static void l_inflate_destructor(lua_State* L, void* ud) {
    auto* d = (LuaInflate*)ud;
    if (!d->closed) {
        inflateEnd(&d->strm);
        d->closed = true;
    }
}

static int l_inflate_close(lua_State* L) {
    auto* d = (LuaInflate*)eryxUdata_checkudata(L, zlibInflate, 1);
    l_inflate_destructor(L, d);
    return 0;
}

static int l_inflate_tostring(lua_State* L) {
    auto* d = (LuaInflate*)eryxUdata_checkudata(L, zlibInflate, 1);
    const char* state = d->closed ? "closed" : (d->finished ? "finished" : "open");
    lua_pushfstring(L, "zlib.Inflate(%s)", state);
    return 1;
}

// zlib.createInflate(windowBits?) -> Inflate
static int l_create_inflate(lua_State* L) {
    int windowBits = (int)luaL_optinteger(L, 1, MAX_WBITS);

    auto* d = (LuaInflate*)eryxUdata_pushudata(L, zlibInflate);
    memset(&d->strm, 0, sizeof(z_stream));
    d->closed = false;
    d->finished = false;

    int ret = inflateInit2(&d->strm, windowBits);
    if (ret != Z_OK) {
        d->closed = true;
        luaL_error(L, "zlib: inflateInit2 failed (%d)", ret);
    }

    return 1;
}

static std::vector<Bytef> inflate_all(lua_State* L, const void* src, size_t srcLen,
                                      int windowBits) {
    z_stream strm{};
    if (inflateInit2(&strm, windowBits) != Z_OK) luaL_error(L, "zlib: inflateInit2 failed");

    strm.next_in = (Bytef*)src;
    strm.avail_in = (uInt)srcLen;

    std::vector<Bytef> out(srcLen < 16 ? 64 : srcLen * 4);
    int ret = Z_OK;
    while (ret != Z_STREAM_END) {
        size_t used = (size_t)strm.total_out;
        if (used == out.size()) {
            size_t newSize = out.size() * 2;
            if (newSize > MAX_DECOMPRESS_SIZE) {
                inflateEnd(&strm);
                luaL_error(L, "zlib: decompressed size exceeds limit (%d MB)",
                           (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
            }
            out.resize(newSize);
        }
        strm.next_out = out.data() + used;
        strm.avail_out = (uInt)(out.size() - used);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK && ret != Z_BUF_ERROR) {
            inflateEnd(&strm);
            luaL_error(L, "zlib: inflate failed (%d)", ret);
        }
    }
    out.resize((size_t)strm.total_out);
    inflateEnd(&strm);
    return out;
}

// ---------------------------------------------------------------------------
// compress(data, level?) -> buffer
// Standard zlib deflate (zlib header + Adler-32 trailer).
// ---------------------------------------------------------------------------
static int l_compress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int level = (int)luaL_optinteger(L, 2, Z_DEFAULT_COMPRESSION);

    uLong bound = compressBound((uLong)srcLen);
    std::vector<Bytef> tmp(bound);
    uLong destLen = bound;

    int ret = compress2(tmp.data(), &destLen, (const Bytef*)src, (uLong)srcLen, level);
    if (ret != Z_OK) luaL_error(L, "zlib: compress failed (%d)", ret);

    void* out = lua_newbuffer(L, (size_t)destLen);
    memcpy(out, tmp.data(), destLen);
    return 1;
}

// ---------------------------------------------------------------------------
// compress_raw(data, level?, window_bits?, mem_level?, strategy?) -> buffer
// Full access to deflateInit2: use negative window_bits for raw deflate,
// or window_bits+16 for gzip. mem_level controls memory/speed trade-off.
// ---------------------------------------------------------------------------
static int l_compress_raw(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int level = (int)luaL_optinteger(L, 2, Z_DEFAULT_COMPRESSION);
    int windowBits = (int)luaL_optinteger(L, 3, MAX_WBITS);
    int memLevel = (int)luaL_optinteger(L, 4, 8);
    int strategy = (int)luaL_optinteger(L, 5, Z_DEFAULT_STRATEGY);

    uLong bound = compressBound((uLong)srcLen) + 18;  // +18 for possible gzip header
    std::vector<Bytef> tmp(bound);

    z_stream strm{};
    int ret = deflateInit2(&strm, level, Z_DEFLATED, windowBits, memLevel, strategy);
    if (ret != Z_OK) luaL_error(L, "zlib: deflateInit2 failed (%d)", ret);

    strm.next_in = (Bytef*)src;
    strm.avail_in = (uInt)srcLen;
    strm.next_out = tmp.data();
    strm.avail_out = (uInt)bound;

    ret = deflate(&strm, Z_FINISH);
    size_t written = (size_t)strm.total_out;
    deflateEnd(&strm);

    if (ret != Z_STREAM_END) luaL_error(L, "zlib: deflate failed (%d)", ret);

    void* out = lua_newbuffer(L, written);
    memcpy(out, tmp.data(), written);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data) -> buffer
// Standard zlib inflate (expects zlib header).
// ---------------------------------------------------------------------------
static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    auto out = inflate_all(L, src, srcLen, MAX_WBITS);
    void* buf = lua_newbuffer(L, out.size());
    memcpy(buf, out.data(), out.size());
    return 1;
}

// ---------------------------------------------------------------------------
// decompress_raw(data, window_bits?) -> buffer
// Use window_bits=-15 for raw deflate (no header), or +16 for gzip.
// ---------------------------------------------------------------------------
static int l_decompress_raw(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int windowBits = (int)luaL_optinteger(L, 2, MAX_WBITS);
    auto out = inflate_all(L, src, srcLen, windowBits);
    void* buf = lua_newbuffer(L, out.size());
    memcpy(buf, out.data(), out.size());
    return 1;
}

// ---------------------------------------------------------------------------
// adler32(data, initial?) -> number
// Running Adler-32 checksum. Chain calls by passing previous result as initial.
// ---------------------------------------------------------------------------
static int l_adler32(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);
    uLong init = (uLong)luaL_optinteger(L, 2, 1);  // Adler-32 identity = 1
    lua_pushinteger(L, (lua_Integer)adler32(init, (const Bytef*)data, (uInt)len));
    return 1;
}

// ---------------------------------------------------------------------------
// crc32(data, initial?) -> number
// Running CRC-32 checksum. Chain calls by passing previous result as initial.
// ---------------------------------------------------------------------------
static int l_crc32(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);
    uLong init = (uLong)luaL_optinteger(L, 2, 0);  // CRC-32 identity = 0
    lua_pushinteger(L, (lua_Integer)crc32(init, (const Bytef*)data, (uInt)len));
    return 1;
}

// ---------------------------------------------------------------------------
// compress_bound(len) -> number
// Upper bound on compressed output size for an input of `len` bytes.
// ---------------------------------------------------------------------------
static int l_compress_bound(lua_State* L) {
    lua_Integer len = luaL_checkinteger(L, 1);
    lua_pushinteger(L, (lua_Integer)compressBound((uLong)len));
    return 1;
}

luaL_Reg zlibDeflateMethods[] = {
    { "write", l_deflate_write },
    { "finish", l_deflate_finish },
    { "close", l_deflate_close },
    { nullptr, nullptr },
};

luaL_Reg zlibDeflateMetamethods[] = {
    { "__tostring", l_deflate_tostring },
    { nullptr, nullptr },
};

udataDef zlibDeflateDef = {
    .name = "ZlibDeflate",
    .size = sizeof(LuaDeflate),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = zlibDeflateMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = zlibDeflateMethods,
    .bothcallMethods = nullptr,
    .destructor = l_deflate_destructor,
};

luaL_Reg zlibInflateMethods[] = {
    { "write", l_inflate_write },
    { "close", l_inflate_close },
    { nullptr, nullptr },
};

luaL_Reg zlibInflateMetamethods[] = {
    { "__tostring", l_inflate_tostring },
    { nullptr, nullptr },
};

udataDef zlibInflateDef = {
    .name = "ZlibInflate",
    .size = sizeof(LuaInflate),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = zlibInflateMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = zlibInflateMethods,
    .bothcallMethods = nullptr,
    .destructor = l_inflate_destructor,
};

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_zlib(lua_State* L) {
    zlibDeflate = eryxUdata_registerudata(L, &zlibDeflateDef);
    zlibInflate = eryxUdata_registerudata(L, &zlibInflateDef);

    // Module table
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        { "compress", l_compress },
        { "compressRaw", l_compress_raw },
        { "decompress", l_decompress },
        { "decompressRaw", l_decompress_raw },
        { "adler32", l_adler32 },
        { "crc32", l_crc32 },
        { "compressBound", l_compress_bound },
        { "createDeflate", l_create_deflate },
        { "createInflate", l_create_inflate },
        { nullptr, nullptr },
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Compression levels
    lua_pushinteger(L, Z_NO_COMPRESSION);
    lua_setfield(L, -2, "NO_COMPRESSION");
    lua_pushinteger(L, Z_BEST_SPEED);
    lua_setfield(L, -2, "BEST_SPEED");
    lua_pushinteger(L, Z_BEST_COMPRESSION);
    lua_setfield(L, -2, "BEST_COMPRESSION");
    lua_pushinteger(L, Z_DEFAULT_COMPRESSION);
    lua_setfield(L, -2, "DEFAULT_COMPRESSION");

    // Deflate strategies
    lua_pushinteger(L, Z_DEFAULT_STRATEGY);
    lua_setfield(L, -2, "STRATEGY_DEFAULT");
    lua_pushinteger(L, Z_FILTERED);
    lua_setfield(L, -2, "STRATEGY_FILTERED");
    lua_pushinteger(L, Z_HUFFMAN_ONLY);
    lua_setfield(L, -2, "STRATEGY_HUFFMAN_ONLY");
    lua_pushinteger(L, Z_RLE);
    lua_setfield(L, -2, "STRATEGY_RLE");
    lua_pushinteger(L, Z_FIXED);
    lua_setfield(L, -2, "STRATEGY_FIXED");

    // Flush constants for streaming
    lua_pushinteger(L, Z_NO_FLUSH);
    lua_setfield(L, -2, "FLUSH_NO");
    lua_pushinteger(L, Z_SYNC_FLUSH);
    lua_setfield(L, -2, "FLUSH_SYNC");
    lua_pushinteger(L, Z_FULL_FLUSH);
    lua_setfield(L, -2, "FLUSH_FULL");
    lua_pushinteger(L, Z_FINISH);
    lua_setfield(L, -2, "FLUSH_FINISH");

    // window_bits helpers for compress_raw / decompress_raw
    lua_pushinteger(L, MAX_WBITS);
    lua_setfield(L, -2, "MAX_WBITS");
    lua_pushinteger(L, -MAX_WBITS);
    lua_setfield(L, -2, "RAW_WBITS");  // raw deflate
    lua_pushinteger(L, MAX_WBITS + 16);
    lua_setfield(L, -2, "GZIP_WBITS");  // gzip wrapper
    lua_pushinteger(L, MAX_WBITS + 32);
    lua_setfield(L, -2, "AUTO_WBITS");  // auto-detect zlib/gzip

    return 1;
}
