#include <cstring>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "zlib.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_zlib",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::vector<Bytef> inflate_all(lua_State* L, const void* src, size_t srcLen, int windowBits) {
    z_stream strm{};
    if (inflateInit2(&strm, windowBits) != Z_OK)
        luaL_error(L, "zlib: inflateInit2 failed");

    strm.next_in  = (Bytef*)src;
    strm.avail_in = (uInt)srcLen;

    std::vector<Bytef> out(srcLen < 16 ? 64 : srcLen * 4);
    int ret = Z_OK;
    while (ret != Z_STREAM_END) {
        size_t used = (size_t)strm.total_out;
        if (used == out.size()) out.resize(out.size() * 2);
        strm.next_out  = out.data() + used;
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
    if (ret != Z_OK)
        luaL_error(L, "zlib: compress failed (%d)", ret);

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
    int level      = (int)luaL_optinteger(L, 2, Z_DEFAULT_COMPRESSION);
    int windowBits = (int)luaL_optinteger(L, 3, MAX_WBITS);
    int memLevel   = (int)luaL_optinteger(L, 4, 8);
    int strategy   = (int)luaL_optinteger(L, 5, Z_DEFAULT_STRATEGY);

    uLong bound = compressBound((uLong)srcLen) + 18; // +18 for possible gzip header
    std::vector<Bytef> tmp(bound);

    z_stream strm{};
    int ret = deflateInit2(&strm, level, Z_DEFLATED, windowBits, memLevel, strategy);
    if (ret != Z_OK)
        luaL_error(L, "zlib: deflateInit2 failed (%d)", ret);

    strm.next_in   = (Bytef*)src;
    strm.avail_in  = (uInt)srcLen;
    strm.next_out  = tmp.data();
    strm.avail_out = (uInt)bound;

    ret = deflate(&strm, Z_FINISH);
    size_t written = (size_t)strm.total_out;
    deflateEnd(&strm);

    if (ret != Z_STREAM_END)
        luaL_error(L, "zlib: deflate failed (%d)", ret);

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
    int windowBits  = (int)luaL_optinteger(L, 2, MAX_WBITS);
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
    uLong init = (uLong)luaL_optinteger(L, 2, 1); // Adler-32 identity = 1
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
    uLong init = (uLong)luaL_optinteger(L, 2, 0); // CRC-32 identity = 0
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

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_zlib(lua_State* L) {
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        {"compress",       l_compress},
        {"compressRaw",   l_compress_raw},
        {"decompress",     l_decompress},
        {"decompressRaw", l_decompress_raw},
        {"adler32",        l_adler32},
        {"crc32",          l_crc32},
        {"compressBound", l_compress_bound},
        {nullptr, nullptr},
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // Compression levels
    lua_pushinteger(L, Z_NO_COMPRESSION);      lua_setfield(L, -2, "NO_COMPRESSION");
    lua_pushinteger(L, Z_BEST_SPEED);          lua_setfield(L, -2, "BEST_SPEED");
    lua_pushinteger(L, Z_BEST_COMPRESSION);    lua_setfield(L, -2, "BEST_COMPRESSION");
    lua_pushinteger(L, Z_DEFAULT_COMPRESSION); lua_setfield(L, -2, "DEFAULT_COMPRESSION");

    // Deflate strategies
    lua_pushinteger(L, Z_DEFAULT_STRATEGY); lua_setfield(L, -2, "STRATEGY_DEFAULT");
    lua_pushinteger(L, Z_FILTERED);         lua_setfield(L, -2, "STRATEGY_FILTERED");
    lua_pushinteger(L, Z_HUFFMAN_ONLY);     lua_setfield(L, -2, "STRATEGY_HUFFMAN_ONLY");
    lua_pushinteger(L, Z_RLE);              lua_setfield(L, -2, "STRATEGY_RLE");
    lua_pushinteger(L, Z_FIXED);            lua_setfield(L, -2, "STRATEGY_FIXED");

    // window_bits helpers for compress_raw / decompress_raw
    lua_pushinteger(L, MAX_WBITS);          lua_setfield(L, -2, "MAX_WBITS");
    lua_pushinteger(L, -MAX_WBITS);         lua_setfield(L, -2, "RAW_WBITS");      // raw deflate
    lua_pushinteger(L, MAX_WBITS + 16);     lua_setfield(L, -2, "GZIP_WBITS");     // gzip wrapper
    lua_pushinteger(L, MAX_WBITS + 32);     lua_setfield(L, -2, "AUTO_WBITS");     // auto-detect zlib/gzip

    return 1;
}
