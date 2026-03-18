#include <cstring>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "mz.h"
#include "mz_strm.h"
#include "mz_strm_mem.h"
#include "mz_zip.h"
#include "mz_zip_rw.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_zip",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// ZipReader userdata
//
// Holds an mz_zip_reader handle open across multiple calls. The original Lua
// buffer is pinned in the registry (buf_ref) so minizip can reference it with
// copy=0 - no data duplication. The central directory is parsed once on open.
// ---------------------------------------------------------------------------

static const char* ZIPREADER_MT = "ZipReader";

struct ZipReader {
    void* handle;
    int   buf_ref; // LUA_REGISTRYINDEX ref keeping the buffer alive
    bool  closed;
};

static ZipReader* check_reader(lua_State* L, int idx = 1) {
    ZipReader* rd = (ZipReader*)luaL_checkudata(L, idx, ZIPREADER_MT);
    if (rd->closed)
        luaL_error(L, "ZipReader is closed");
    return rd;
}

// Push the standard entry info table for the reader's current entry.
// Caller must have confirmed entry_get_info succeeded.
static void push_entry_info(lua_State* L, mz_zip_file* info) {
    lua_newtable(L);
    lua_pushstring(L, info->filename ? info->filename : "");
    lua_setfield(L, -2, "name");
    lua_pushinteger(L, (lua_Integer)info->uncompressed_size);
    lua_setfield(L, -2, "size");
    lua_pushinteger(L, (lua_Integer)info->compressed_size);
    lua_setfield(L, -2, "compressed_size");
    lua_pushinteger(L, (lua_Integer)info->compression_method);
    lua_setfield(L, -2, "method");
    lua_pushinteger(L, (lua_Integer)info->crc);
    lua_setfield(L, -2, "crc32");
}

// reader:list() -> { EntryInfo }
static int l_reader_list(lua_State* L) {
    ZipReader* rd = check_reader(L);

    lua_newtable(L);
    int idx = 1;

    int32_t err = mz_zip_reader_goto_first_entry(rd->handle);
    while (err == MZ_OK) {
        mz_zip_file* info = nullptr;
        if (mz_zip_reader_entry_get_info(rd->handle, &info) == MZ_OK && info) {
            push_entry_info(L, info);
            lua_rawseti(L, -2, idx++);
        }
        err = mz_zip_reader_goto_next_entry(rd->handle);
    }
    return 1;
}

// reader:read(name) -> buffer?
static int l_reader_read(lua_State* L) {
    ZipReader* rd  = check_reader(L);
    const char* name = luaL_checkstring(L, 2);

    if (mz_zip_reader_locate_entry(rd->handle, name, 0) != MZ_OK) {
        lua_pushnil(L);
        return 1;
    }

    mz_zip_file* info = nullptr;
    mz_zip_reader_entry_get_info(rd->handle, &info);
    int64_t sz = info ? info->uncompressed_size : 0;

    int32_t err = mz_zip_reader_entry_open(rd->handle);
    if (err != MZ_OK)
        luaL_error(L, "ZipReader:read: failed to open entry (%d)", err);

    void* buf = lua_newbuffer(L, (size_t)sz);
    mz_zip_reader_entry_read(rd->handle, buf, (int32_t)sz);
    mz_zip_reader_entry_close(rd->handle);
    return 1;
}

// reader:close()  (also called by __gc)
static int l_reader_close(lua_State* L) {
    ZipReader* rd = (ZipReader*)luaL_checkudata(L, 1, ZIPREADER_MT);
    if (!rd->closed) {
        mz_zip_reader_close(rd->handle);
        mz_zip_reader_delete(&rd->handle);
        lua_unref(L, rd->buf_ref);
        rd->closed = true;
    }
    return 0;
}

static int l_reader_tostring(lua_State* L) {
    ZipReader* rd = (ZipReader*)lua_touserdata(L, 1);
    lua_pushstring(L, rd->closed ? "ZipReader (closed)" : "ZipReader");
    return 1;
}

// zip.open(data: buffer) -> ZipReader
// Parses the central directory once; all subsequent operations reuse it.
static int l_open(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);

    // Pin the buffer so the GC won't collect it while the reader holds a raw
    // pointer into it (copy=0 below). lua_ref takes a stack index directly.
    int buf_ref = lua_ref(L, 1);

    ZipReader* rd = (ZipReader*)lua_newuserdata(L, sizeof(ZipReader));
    rd->handle  = mz_zip_reader_create();
    rd->buf_ref = buf_ref;
    rd->closed  = false;

    // copy=0: minizip points directly into the Lua buffer (no duplication).
    int32_t err = mz_zip_reader_open_buffer(rd->handle, (const uint8_t*)data, (int32_t)len, 0);
    if (err != MZ_OK) {
        mz_zip_reader_delete(&rd->handle);
        lua_unref(L, buf_ref);
        luaL_error(L, "zip.open: failed to open (%d)", err);
    }

    luaL_getmetatable(L, ZIPREADER_MT);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Stateless helpers (single-shot: parse central dir, do work, close)
// ---------------------------------------------------------------------------

static int l_is_zip(lua_State* L) {
    size_t len = 0;
    const uint8_t* data = (const uint8_t*)luaL_checkbuffer(L, 1, &len);
    bool ok = false;
    if (len >= 4 && data[0] == 0x50 && data[1] == 0x4B) {
        uint8_t b2 = data[2], b3 = data[3];
        ok = (b2 == 0x03 && b3 == 0x04) || (b2 == 0x05 && b3 == 0x06);
    }
    lua_pushboolean(L, ok);
    return 1;
}

static int l_list(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);

    void* reader = mz_zip_reader_create();
    int32_t err = mz_zip_reader_open_buffer(reader, (const uint8_t*)data, (int32_t)len, 0);
    if (err != MZ_OK) {
        mz_zip_reader_delete(&reader);
        luaL_error(L, "zip.list: failed to open (%d)", err);
    }

    lua_newtable(L);
    int idx = 1;

    err = mz_zip_reader_goto_first_entry(reader);
    while (err == MZ_OK) {
        mz_zip_file* info = nullptr;
        if (mz_zip_reader_entry_get_info(reader, &info) == MZ_OK && info) {
            push_entry_info(L, info);
            lua_rawseti(L, -2, idx++);
        }
        err = mz_zip_reader_goto_next_entry(reader);
    }

    mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    return 1;
}

static int l_unpack(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);

    void* reader = mz_zip_reader_create();
    int32_t err = mz_zip_reader_open_buffer(reader, (const uint8_t*)data, (int32_t)len, 0);
    if (err != MZ_OK) {
        mz_zip_reader_delete(&reader);
        luaL_error(L, "zip.unpack: failed to open (%d)", err);
    }

    lua_newtable(L);

    err = mz_zip_reader_goto_first_entry(reader);
    while (err == MZ_OK) {
        mz_zip_file* info = nullptr;
        if (mz_zip_reader_entry_get_info(reader, &info) == MZ_OK && info && info->filename) {
            size_t fnlen = strlen(info->filename);
            bool is_dir = fnlen > 0 && info->filename[fnlen - 1] == '/';
            if (!is_dir && mz_zip_reader_entry_open(reader) == MZ_OK) {
                int64_t sz = info->uncompressed_size;
                void* buf = lua_newbuffer(L, (size_t)sz);
                int32_t n = mz_zip_reader_entry_read(reader, buf, (int32_t)sz);
                mz_zip_reader_entry_close(reader);
                if (n >= 0)
                    lua_setfield(L, -2, info->filename);
                else
                    lua_pop(L, 1);
            }
        }
        err = mz_zip_reader_goto_next_entry(reader);
    }

    mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    return 1;
}

static int l_read(lua_State* L) {
    size_t len = 0;
    const void* data = luaL_checkbuffer(L, 1, &len);
    const char* name = luaL_checkstring(L, 2);

    void* reader = mz_zip_reader_create();
    int32_t err = mz_zip_reader_open_buffer(reader, (const uint8_t*)data, (int32_t)len, 0);
    if (err != MZ_OK) {
        mz_zip_reader_delete(&reader);
        luaL_error(L, "zip.read: failed to open (%d)", err);
    }

    err = mz_zip_reader_locate_entry(reader, name, 0);
    if (err != MZ_OK) {
        mz_zip_reader_close(reader);
        mz_zip_reader_delete(&reader);
        lua_pushnil(L);
        return 1;
    }

    mz_zip_file* info = nullptr;
    mz_zip_reader_entry_get_info(reader, &info);
    int64_t sz = info ? info->uncompressed_size : 0;

    err = mz_zip_reader_entry_open(reader);
    if (err != MZ_OK) {
        mz_zip_reader_close(reader);
        mz_zip_reader_delete(&reader);
        luaL_error(L, "zip.read: failed to open entry (%d)", err);
    }

    void* buf = lua_newbuffer(L, (size_t)sz);
    mz_zip_reader_entry_read(reader, buf, (int32_t)sz);
    mz_zip_reader_entry_close(reader);
    mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    return 1;
}

static int l_pack(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    uint16_t method = MZ_COMPRESS_METHOD_DEFLATE;
    int16_t  level  = MZ_COMPRESS_LEVEL_DEFAULT;

    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "method");
        if (lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "store") == 0)
            method = MZ_COMPRESS_METHOD_STORE;
        lua_pop(L, 1);

        lua_getfield(L, 2, "level");
        if (lua_isnumber(L, -1))
            level = (int16_t)lua_tointeger(L, -1);
        lua_pop(L, 1);
    }

    void* mem_stream = mz_stream_mem_create();
    mz_stream_mem_set_grow_size(mem_stream, 128 * 1024);
    mz_stream_open(mem_stream, nullptr, MZ_OPEN_MODE_CREATE);

    void* writer = mz_zip_writer_create();
    mz_zip_writer_set_compress_method(writer, method);
    mz_zip_writer_set_compress_level(writer, level);

    int32_t err = mz_zip_writer_open(writer, mem_stream, 0);
    if (err != MZ_OK) {
        mz_zip_writer_delete(&writer);
        mz_stream_close(mem_stream);
        mz_stream_mem_delete(&mem_stream);
        luaL_error(L, "zip.pack: failed to create writer (%d)", err);
    }

    lua_pushnil(L);
    while (lua_next(L, 1)) {
        if (lua_isstring(L, -2)) {
            size_t data_len = 0;
            const void* file_data = nullptr;
            if (lua_isbuffer(L, -1))
                file_data = lua_tobuffer(L, -1, &data_len);
            else if (lua_isstring(L, -1))
                file_data = lua_tolstring(L, -1, &data_len);

            if (file_data) {
                mz_zip_file file_info{};
                file_info.filename           = lua_tostring(L, -2);
                file_info.compression_method = method;
                file_info.zip64              = MZ_ZIP64_AUTO;
                file_info.flag               = MZ_ZIP_FLAG_UTF8;
                mz_zip_writer_add_buffer(writer, file_data, (int32_t)data_len, &file_info);
            }
        }
        lua_pop(L, 1);
    }

    mz_zip_writer_close(writer);
    mz_zip_writer_delete(&writer);

    const void* out_buf = nullptr;
    int32_t     out_len = 0;
    mz_stream_mem_get_buffer(mem_stream, &out_buf);
    mz_stream_mem_get_buffer_length(mem_stream, &out_len);

    void* result = lua_newbuffer(L, out_len > 0 ? (size_t)out_len : 0);
    if (out_buf && out_len > 0)
        memcpy(result, out_buf, (size_t)out_len);

    mz_stream_close(mem_stream);
    mz_stream_mem_delete(&mem_stream);
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------
LUAU_MODULE_EXPORT int luauopen_zip(lua_State* L) {
    // Register ZipReader metatable
    luaL_newmetatable(L, ZIPREADER_MT);

    static const luaL_Reg reader_methods[] = {
        {"List",  l_reader_list},
        {"Read",  l_reader_read},
        {"Close", l_reader_close},
        {nullptr, nullptr},
    };
    lua_newtable(L);
    for (const luaL_Reg* m = reader_methods; m->name; m++) {
        lua_pushcfunction(L, m->func, m->name);
        lua_setfield(L, -2, m->name);
    }
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, l_reader_close,    "__gc");  // close and __gc are identical
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, l_reader_tostring, "__tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pop(L, 1); // pop metatable

    // Module table
    lua_newtable(L);

    static const luaL_Reg fns[] = {
        {"open",   l_open},
        {"isZip", l_is_zip},
        {"list",   l_list},
        {"unpack", l_unpack},
        {"read",   l_read},
        {"pack",   l_pack},
        {nullptr, nullptr},
    };
    for (const luaL_Reg* f = fns; f->name; f++) {
        lua_pushcfunction(L, f->func, f->name);
        lua_setfield(L, -2, f->name);
    }

    lua_pushinteger(L, MZ_COMPRESS_METHOD_STORE);   lua_setfield(L, -2, "METHOD_STORE");
    lua_pushinteger(L, MZ_COMPRESS_METHOD_DEFLATE); lua_setfield(L, -2, "METHOD_DEFLATE");

    return 1;
}
