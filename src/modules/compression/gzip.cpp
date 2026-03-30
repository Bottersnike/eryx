#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "zlib.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_gzip",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// compress(data, level?) -> buffer
// ---------------------------------------------------------------------------
static int l_compress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    int level = (int)luaL_optinteger(L, 2, Z_DEFAULT_COMPRESSION);

    uLong bound = compressBound((uLong)srcLen) + 18;
    std::vector<Bytef> tmp(bound);

    z_stream strm{};
    int ret = deflateInit2(&strm, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) luaL_error(L, "gzip: deflateInit2 failed (%d)", ret);

    strm.next_in = (Bytef*)src;
    strm.avail_in = (uInt)srcLen;
    strm.next_out = tmp.data();
    strm.avail_out = (uInt)bound;

    ret = deflate(&strm, Z_FINISH);
    size_t written = (size_t)strm.total_out;
    deflateEnd(&strm);

    if (ret != Z_STREAM_END) luaL_error(L, "gzip: compress failed (%d)", ret);

    void* out = lua_newbuffer(L, written);
    memcpy(out, tmp.data(), written);
    return 1;
}

// ---------------------------------------------------------------------------
// compress_ex(data, options) -> buffer
// Options table: level?, name?, comment?, mtime?, os?
// Lets you embed a filename, timestamp, and OS tag in the gzip header.
// ---------------------------------------------------------------------------
static int l_compress_ex(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);
    luaL_checktype(L, 2, LUA_TTABLE);

    int level = Z_DEFAULT_COMPRESSION;
    std::string name, comment;
    uLong mtime = 0;
    int os = 255;  // 255 = unknown

    lua_getfield(L, 2, "level");
    if (!lua_isnil(L, -1)) level = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "name");
    if (lua_isstring(L, -1)) name = lua_tostring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "comment");
    if (lua_isstring(L, -1)) comment = lua_tostring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "mtime");
    if (!lua_isnil(L, -1)) mtime = (uLong)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "os");
    if (!lua_isnil(L, -1)) os = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    uLong bound =
        compressBound((uLong)srcLen) + 18 + (uLong)name.size() + 1 + (uLong)comment.size() + 1;
    std::vector<Bytef> tmp(bound);

    z_stream strm{};
    int ret = deflateInit2(&strm, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) luaL_error(L, "gzip: deflateInit2 failed (%d)", ret);

    // gz_header pointers must stay valid until deflateEnd
    gz_header hdr{};
    hdr.time = mtime;
    hdr.os = os;
    hdr.name = name.empty() ? nullptr : (Bytef*)name.c_str();
    hdr.comment = comment.empty() ? nullptr : (Bytef*)comment.c_str();
    deflateSetHeader(&strm, &hdr);

    strm.next_in = (Bytef*)src;
    strm.avail_in = (uInt)srcLen;
    strm.next_out = tmp.data();
    strm.avail_out = (uInt)bound;

    ret = deflate(&strm, Z_FINISH);
    size_t written = (size_t)strm.total_out;
    deflateEnd(&strm);

    if (ret != Z_STREAM_END) luaL_error(L, "gzip: compress_ex failed (%d)", ret);

    void* out = lua_newbuffer(L, written);
    memcpy(out, tmp.data(), written);
    return 1;
}

// ---------------------------------------------------------------------------
// decompress(data) -> buffer
// ---------------------------------------------------------------------------

static constexpr size_t MAX_DECOMPRESS_SIZE = 256 * 1024 * 1024;  // 256 MB

static int l_decompress(lua_State* L) {
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 1, &srcLen);

    z_stream strm{};
    if (inflateInit2(&strm, 15 + 16) != Z_OK) luaL_error(L, "gzip: inflateInit2 failed");

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
                luaL_error(L, "gzip: decompressed size exceeds limit (%d MB)",
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
            luaL_error(L, "gzip: decompress failed (%d)", ret);
        }
    }
    size_t written = (size_t)strm.total_out;
    inflateEnd(&strm);

    void* buf = lua_newbuffer(L, written);
    memcpy(buf, out.data(), written);
    return 1;
}

// ---------------------------------------------------------------------------
// is_gzip(data) -> boolean
// Checks the two-byte magic number 0x1F 0x8B.
// ---------------------------------------------------------------------------
static int l_is_gzip(lua_State* L) {
    size_t len = 0;
    const uint8_t* data = (const uint8_t*)luaL_checkbuffer(L, 1, &len);
    lua_pushboolean(L, len >= 2 && data[0] == 0x1F && data[1] == 0x8B);
    return 1;
}

// ---------------------------------------------------------------------------
// read_header(data) -> table
// Parses the gzip header without decompressing the payload.
// Returns: { method, flags, mtime, xfl, os, name?, comment?, extra?,
//            header_crc16?, data_offset }
// ---------------------------------------------------------------------------
static int l_read_header(lua_State* L) {
    size_t len = 0;
    const uint8_t* d = (const uint8_t*)luaL_checkbuffer(L, 1, &len);

    if (len < 10 || d[0] != 0x1F || d[1] != 0x8B) luaL_error(L, "gzip: not a valid gzip stream");

    uint8_t cm = d[2];
    uint8_t flg = d[3];
    uint32_t mt =
        (uint32_t)d[4] | ((uint32_t)d[5] << 8) | ((uint32_t)d[6] << 16) | ((uint32_t)d[7] << 24);
    uint8_t xfl = d[8];
    uint8_t os = d[9];
    size_t pos = 10;

    lua_newtable(L);
    lua_pushinteger(L, cm);
    lua_setfield(L, -2, "method");  // should be 8 (deflate)
    lua_pushinteger(L, flg);
    lua_setfield(L, -2, "flags");
    lua_pushinteger(L, mt);
    lua_setfield(L, -2, "mtime");
    lua_pushinteger(L, xfl);
    lua_setfield(L, -2, "xfl");
    lua_pushinteger(L, os);
    lua_setfield(L, -2, "os");

    // FEXTRA (bit 2)
    if (flg & 0x04) {
        if (pos + 2 > len) luaL_error(L, "gzip: truncated header (FEXTRA len)");
        uint16_t xlen = (uint16_t)d[pos] | ((uint16_t)d[pos + 1] << 8);
        pos += 2;
        if (pos + xlen > len) luaL_error(L, "gzip: truncated header (FEXTRA data)");
        void* extra = lua_newbuffer(L, xlen);
        memcpy(extra, d + pos, xlen);
        lua_setfield(L, -2, "extra");
        pos += xlen;
    }

    // FNAME (bit 3) – null-terminated
    if (flg & 0x08) {
        const char* start = (const char*)(d + pos);
        while (pos < len && d[pos]) pos++;
        if (pos >= len) luaL_error(L, "gzip: truncated header (FNAME)");
        lua_pushlstring(L, start, (const char*)(d + pos) - start);
        lua_setfield(L, -2, "name");
        pos++;  // skip null
    }

    // FCOMMENT (bit 4) – null-terminated
    if (flg & 0x10) {
        const char* start = (const char*)(d + pos);
        while (pos < len && d[pos]) pos++;
        if (pos >= len) luaL_error(L, "gzip: truncated header (FCOMMENT)");
        lua_pushlstring(L, start, (const char*)(d + pos) - start);
        lua_setfield(L, -2, "comment");
        pos++;
    }

    // FHCRC (bit 1) – CRC-16 of the header bytes
    if (flg & 0x02) {
        if (pos + 2 > len) luaL_error(L, "gzip: truncated header (FHCRC)");
        uint16_t hcrc = (uint16_t)d[pos] | ((uint16_t)d[pos + 1] << 8);
        lua_pushinteger(L, hcrc);
        lua_setfield(L, -2, "header_crc16");
        pos += 2;
    }

    lua_pushinteger(L, (lua_Integer)pos);
    lua_setfield(L, -2, "data_offset");

    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Compress
// ---------------------------------------------------------------------------

static constexpr size_t STREAM_CHUNK_SIZE = 32 * 1024;  // 32 KB

static const char* MT_GZIP_COMPRESS = "gzip.Compressor";
static const char* MT_GZIP_DECOMPRESS = "gzip.Decompressor";

struct LuaGzipCompressor {
    z_stream strm;
    bool closed;
};

static void gzip_compressor_dtor(void* ud) {
    auto* c = (LuaGzipCompressor*)ud;
    if (!c->closed) {
        deflateEnd(&c->strm);
        c->closed = true;
    }
}

static LuaGzipCompressor* check_compressor(lua_State* L) {
    auto* c = (LuaGzipCompressor*)luaL_checkudata(L, 1, MT_GZIP_COMPRESS);
    if (c->closed) luaL_error(L, "gzip: compressor is closed");
    return c;
}

// compressor:write(data, flush?) -> buffer
static int l_compressor_write(lua_State* L) {
    auto* c = check_compressor(L);
    size_t srcLen = 0;
    const void* src = luaL_checkbuffer(L, 2, &srcLen);
    int flush = (int)luaL_optinteger(L, 3, Z_NO_FLUSH);

    c->strm.next_in = (Bytef*)src;
    c->strm.avail_in = (uInt)srcLen;

    std::vector<Bytef> out;
    out.reserve(srcLen < STREAM_CHUNK_SIZE ? STREAM_CHUNK_SIZE : srcLen);

    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        c->strm.next_out = out.data() + used;
        c->strm.avail_out = (uInt)STREAM_CHUNK_SIZE;

        int ret = deflate(&c->strm, flush);
        if (ret == Z_STREAM_ERROR) luaL_error(L, "gzip: deflate stream error");

        size_t produced = STREAM_CHUNK_SIZE - c->strm.avail_out;
        out.resize(used + produced);
    } while (c->strm.avail_out == 0);

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

// compressor:finish() -> buffer
static int l_compressor_finish(lua_State* L) {
    auto* c = check_compressor(L);

    c->strm.next_in = nullptr;
    c->strm.avail_in = 0;

    std::vector<Bytef> out;
    int ret;
    do {
        size_t used = out.size();
        out.resize(used + STREAM_CHUNK_SIZE);
        c->strm.next_out = out.data() + used;
        c->strm.avail_out = (uInt)STREAM_CHUNK_SIZE;

        ret = deflate(&c->strm, Z_FINISH);
        if (ret == Z_STREAM_ERROR) luaL_error(L, "gzip: deflate stream error");

        size_t produced = STREAM_CHUNK_SIZE - c->strm.avail_out;
        out.resize(used + produced);
    } while (ret != Z_STREAM_END);

    deflateEnd(&c->strm);
    c->closed = true;

    void* buf = lua_newbuffer(L, out.size());
    if (!out.empty()) memcpy(buf, out.data(), out.size());
    return 1;
}

static int l_compressor_close(lua_State* L) {
    auto* c = (LuaGzipCompressor*)luaL_checkudata(L, 1, MT_GZIP_COMPRESS);
    if (!c->closed) {
        deflateEnd(&c->strm);
        c->closed = true;
    }
    return 0;
}

static int l_compressor_tostring(lua_State* L) {
    auto* c = (LuaGzipCompressor*)luaL_checkudata(L, 1, MT_GZIP_COMPRESS);
    lua_pushfstring(L, "gzip.Compressor(%s)", c->closed ? "closed" : "open");
    return 1;
}

// gzip.createCompressor(level?) -> Compressor
static int l_create_compressor(lua_State* L) {
    int level = (int)luaL_optinteger(L, 1, Z_DEFAULT_COMPRESSION);

    auto* c =
        (LuaGzipCompressor*)lua_newuserdatadtor(L, sizeof(LuaGzipCompressor), gzip_compressor_dtor);
    memset(&c->strm, 0, sizeof(z_stream));
    c->closed = false;

    int ret = deflateInit2(&c->strm, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) {
        c->closed = true;
        luaL_error(L, "gzip: deflateInit2 failed (%d)", ret);
    }

    luaL_getmetatable(L, MT_GZIP_COMPRESS);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Streaming Decompress
// ---------------------------------------------------------------------------

struct LuaGzipDecompressor {
    z_stream strm;
    bool closed;
    bool finished;
};

static void gzip_decompressor_dtor(void* ud) {
    auto* d = (LuaGzipDecompressor*)ud;
    if (!d->closed) {
        inflateEnd(&d->strm);
        d->closed = true;
    }
}

static LuaGzipDecompressor* check_decompressor(lua_State* L) {
    auto* d = (LuaGzipDecompressor*)luaL_checkudata(L, 1, MT_GZIP_DECOMPRESS);
    if (d->closed) luaL_error(L, "gzip: decompressor is closed");
    return d;
}

// decompressor:write(data) -> buffer, finished
static int l_decompressor_write(lua_State* L) {
    auto* d = check_decompressor(L);
    if (d->finished) luaL_error(L, "gzip: decompressor already finished");

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
            luaL_error(L, "gzip: decompressed size exceeds limit (%d MB)",
                       (int)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
        }
        out.resize(used + STREAM_CHUNK_SIZE);
        d->strm.next_out = out.data() + used;
        d->strm.avail_out = (uInt)STREAM_CHUNK_SIZE;

        ret = inflate(&d->strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_ERROR || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR ||
            ret == Z_NEED_DICT) {
            luaL_error(L, "gzip: inflate error (%d)", ret);
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

static int l_decompressor_close(lua_State* L) {
    auto* d = (LuaGzipDecompressor*)luaL_checkudata(L, 1, MT_GZIP_DECOMPRESS);
    if (!d->closed) {
        inflateEnd(&d->strm);
        d->closed = true;
    }
    return 0;
}

static int l_decompressor_tostring(lua_State* L) {
    auto* d = (LuaGzipDecompressor*)luaL_checkudata(L, 1, MT_GZIP_DECOMPRESS);
    const char* state = d->closed ? "closed" : (d->finished ? "finished" : "open");
    lua_pushfstring(L, "gzip.Decompressor(%s)", state);
    return 1;
}

// gzip.createDecompressor() -> Decompressor
static int l_create_decompressor(lua_State* L) {
    auto* d = (LuaGzipDecompressor*)lua_newuserdatadtor(L, sizeof(LuaGzipDecompressor),
                                                        gzip_decompressor_dtor);
    memset(&d->strm, 0, sizeof(z_stream));
    d->closed = false;
    d->finished = false;

    int ret = inflateInit2(&d->strm, 15 + 16);
    if (ret != Z_OK) {
        d->closed = true;
        luaL_error(L, "gzip: inflateInit2 failed (%d)", ret);
    }

    luaL_getmetatable(L, MT_GZIP_DECOMPRESS);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen_gzip(lua_State* L) {
    // Register Compressor metatable
    luaL_newmetatable(L, MT_GZIP_COMPRESS);
    {
        static const luaL_Reg methods[] = {
            { "write", l_compressor_write },
            { "finish", l_compressor_finish },
            { "close", l_compressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_compressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_compressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);

    // Register Decompressor metatable
    luaL_newmetatable(L, MT_GZIP_DECOMPRESS);
    {
        static const luaL_Reg methods[] = {
            { "write", l_decompressor_write },
            { "close", l_decompressor_close },
            { nullptr, nullptr },
        };
        lua_newtable(L);
        for (const luaL_Reg* m = methods; m->name; m++) {
            lua_pushcfunction(L, m->func, m->name);
            lua_setfield(L, -2, m->name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_decompressor_close, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_decompressor_tostring, "__tostring");
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        { "compress", l_compress },
        { "compressEx", l_compress_ex },
        { "decompress", l_decompress },
        { "isGzip", l_is_gzip },
        { "readHeader", l_read_header },
        { "createCompressor", l_create_compressor },
        { "createDecompressor", l_create_decompressor },
        { nullptr, nullptr },
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    // OS identifier constants (from the gzip spec)
    lua_pushinteger(L, 0);
    lua_setfield(L, -2, "OS_FAT");
    lua_pushinteger(L, 1);
    lua_setfield(L, -2, "OS_AMIGA");
    lua_pushinteger(L, 2);
    lua_setfield(L, -2, "OS_VMS");
    lua_pushinteger(L, 3);
    lua_setfield(L, -2, "OS_UNIX");
    lua_pushinteger(L, 6);
    lua_setfield(L, -2, "OS_HPFS");
    lua_pushinteger(L, 7);
    lua_setfield(L, -2, "OS_MAC");
    lua_pushinteger(L, 11);
    lua_setfield(L, -2, "OS_NTFS");
    lua_pushinteger(L, 255);
    lua_setfield(L, -2, "OS_UNKNOWN");

    // Compression levels (mirrors zlib)
    lua_pushinteger(L, Z_NO_COMPRESSION);
    lua_setfield(L, -2, "NO_COMPRESSION");
    lua_pushinteger(L, Z_BEST_SPEED);
    lua_setfield(L, -2, "BEST_SPEED");
    lua_pushinteger(L, Z_BEST_COMPRESSION);
    lua_setfield(L, -2, "BEST_COMPRESSION");
    lua_pushinteger(L, Z_DEFAULT_COMPRESSION);
    lua_setfield(L, -2, "DEFAULT_COMPRESSION");

    return 1;
}
