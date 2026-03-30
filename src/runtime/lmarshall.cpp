#include "lmarshall.hpp"

#include "../pch.hpp"

// ---------------------------------------------------------------------------
// Encoder helpers
// ---------------------------------------------------------------------------

static void encode_varint(std::vector<uint8_t>& data, unsigned int val) {
    if (!val) {
        data.push_back(0);
        return;
    }
    while (val) {
        uint8_t byte = val & 0x7F;
        val >>= 7;
        if (val) byte |= 0x80;
        data.push_back(byte);
    }
}

static int already_seen(lua_State* L, int t, int visited) {
    lua_pushvalue(L, t);
    lua_rawget(L, visited);
    int seen = !lua_isnil(L, -1);
    lua_pop(L, 1);
    return seen;
}

static void mark_seen(lua_State* L, int t, int visited) {
    lua_pushvalue(L, t);
    lua_pushboolean(L, 1);
    lua_rawset(L, visited);
}

static void encode_lua_table(lua_State* L, int idx, std::vector<uint8_t>& data, int visited);
static void encode_lua_value(lua_State* L, int idx, std::vector<uint8_t>& data, int visited) {
    switch ((lua_Type)lua_type(L, idx)) {
        case LUA_TNIL:
            data.push_back(ETYPE_NULL);
            break;
        case LUA_TBOOLEAN:
            if (lua_toboolean(L, idx))
                data.push_back(ETYPE_TRUE);
            else
                data.push_back(ETYPE_FALSE);
            break;
        case LUA_TNUMBER: {
            lua_Number k = lua_tonumber(L, idx);
            data.push_back(ETYPE_DOUBLE);
            auto ptr = reinterpret_cast<const uint8_t*>(&k);
            data.insert(data.end(), ptr, ptr + sizeof(lua_Number));
            break;
        }
        case LUA_TSTRING: {
            size_t slen;
            const char* s = lua_tolstring(L, idx, &slen);
            data.push_back(ETYPE_STRING);
            encode_varint(data, slen);
            if (slen) data.insert(data.end(), s, s + slen);
            break;
        }
        case LUA_TBUFFER: {
            size_t nBuffer;
            const void* buf = lua_tobuffer(L, idx, &nBuffer);
            data.push_back(ETYPE_BUFFER);
            encode_varint(data, nBuffer);
            if (nBuffer) data.insert(data.end(), (uint8_t*)buf, (uint8_t*)buf + nBuffer);
            break;
        }
        case LUA_TVECTOR: {
            const float* v = lua_tovector(L, idx);
            data.push_back(ETYPE_VECTOR);
            auto ptr = reinterpret_cast<const uint8_t*>(v);
            data.insert(data.end(), ptr, ptr + sizeof(float) * LUA_VECTOR_SIZE);
            break;
        }
        case LUA_TTABLE:
            encode_lua_table(L, idx, data, visited);
            break;

        // Unmarshallable types: these can't be serialized in a meaningful way.
        // Userdata could theoretically support opt-in serialization via a
        // __marshall/__unmarshall metamethod protocol in the future.
        case LUA_TUSERDATA:
        case LUA_TLIGHTUSERDATA:
            luaL_error(L, "Cannot marshall userdata");
            break;
        case LUA_TFUNCTION:
            luaL_error(L, "Cannot marshall functions");
            break;
        case LUA_TTHREAD:
            luaL_error(L, "Cannot marshall threads");
            break;

        // Internal VM types — should never appear as stack values
        case LUA_TPROTO:
        case LUA_TUPVAL:
        case LUA_TDEADKEY:
            luaL_error(L, "Something has gone fatally wrong with your Luau runtime.");
            break;
    }
}

static void encode_lua_table(lua_State* L, int idx, std::vector<uint8_t>& data, int visited) {
    if (lua_getmetatable(L, idx)) {
        lua_pop(L, 1);
        luaL_error(L, "Cannot marshall tables with metatables");
        return;
    }

    if (already_seen(L, idx, visited)) {
        luaL_error(L, "Cannot marshall recursive tables");
        return;
    }
    mark_seen(L, idx, visited);

    data.push_back(ETYPE_TABLE);

    // Array part
    lua_Integer n = lua_objlen(L, idx);
    encode_varint(data, n);
    for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, idx, i);
        encode_lua_value(L, -1, data, visited);
        lua_pop(L, 1);
    }

    // Hash part
    data.push_back(ETYPE_TABLE_HASH_DELIM);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        // Skip array keys we already encoded
        if (lua_type(L, -2) == LUA_TNUMBER) {
            lua_Number k = lua_tonumber(L, -2);
            if (k >= 1 && k <= n && (lua_Integer)k == k) {
                lua_pop(L, 1);
                continue;
            }
        }

        encode_lua_value(L, -2, data, visited);
        encode_lua_value(L, -1, data, visited);
        lua_pop(L, 1);
    }
    data.push_back(ETYPE_TABLE_HASH_DELIM);
}

// ---------------------------------------------------------------------------
// Public encoder entry point
// ---------------------------------------------------------------------------

void eryx_marshall(lua_State* L, int idx, std::vector<uint8_t>& out) {
    // Normalize negative indices before we push the visited table
    if (idx < 0 && idx > LUA_REGISTRYINDEX) idx = lua_gettop(L) + idx + 1;

    lua_newtable(L);
    int visited = lua_gettop(L);
    encode_lua_value(L, idx, out, visited);
    lua_pop(L, 1);  // pop visited table
}

// ---------------------------------------------------------------------------
// Decoder helpers
// ---------------------------------------------------------------------------

static size_t decode_varint(lua_State* L, const uint8_t* data, size_t len, unsigned int* out) {
    *out = 0;
    size_t pos = 0;
    unsigned int shift = 0;
    do {
        if (pos >= len) luaL_error(L, "Truncated varint in unmarshall");
        *out |= (unsigned int)(data[pos] & 0x7F) << shift;
        shift += 7;
    } while (data[pos++] & 0x80);
    return pos;
}

static size_t decode_lua_value(lua_State* L, const uint8_t* data, size_t len);

static size_t decode_lua_table(lua_State* L, const uint8_t* data, size_t len) {
    size_t pos = 0;

    // Read array length
    unsigned int n;
    size_t vlen = decode_varint(L, data + pos, len - pos, &n);
    pos += vlen;

    luaL_checkstack(L, 4, "unmarshall table");
    lua_createtable(L, n, 0);
    int tbl = lua_gettop(L);

    // Decode array part
    for (unsigned int i = 1; i <= n; i++) {
        size_t consumed = decode_lua_value(L, data + pos, len - pos);
        pos += consumed;
        lua_rawseti(L, tbl, i);
    }

    // Expect hash delimiter
    if (pos >= len || data[pos] != ETYPE_TABLE_HASH_DELIM)
        luaL_error(L, "Expected hash delimiter in unmarshall");
    pos++;

    // Decode hash part until closing delimiter
    while (pos < len && data[pos] != ETYPE_TABLE_HASH_DELIM) {
        // Decode key
        size_t consumed = decode_lua_value(L, data + pos, len - pos);
        pos += consumed;
        // Decode value
        consumed = decode_lua_value(L, data + pos, len - pos);
        pos += consumed;
        lua_rawset(L, tbl);
    }

    if (pos >= len || data[pos] != ETYPE_TABLE_HASH_DELIM)
        luaL_error(L, "Expected closing hash delimiter in unmarshall");
    pos++;

    // Table is already on top of the stack
    return pos;
}

static size_t decode_lua_value(lua_State* L, const uint8_t* data, size_t len) {
    if (len == 0) luaL_error(L, "Truncated data in unmarshall");

    uint8_t tag = data[0];
    size_t pos = 1;

    switch (tag) {
        case ETYPE_NULL:
            lua_pushnil(L);
            break;
        case ETYPE_TRUE:
            lua_pushboolean(L, 1);
            break;
        case ETYPE_FALSE:
            lua_pushboolean(L, 0);
            break;
        case ETYPE_DOUBLE: {
            if (len - pos < sizeof(lua_Number)) luaL_error(L, "Truncated double in unmarshall");
            lua_Number k;
            memcpy(&k, data + pos, sizeof(lua_Number));
            pos += sizeof(lua_Number);
            lua_pushnumber(L, k);
            break;
        }
        case ETYPE_STRING: {
            unsigned int slen;
            size_t vlen = decode_varint(L, data + pos, len - pos, &slen);
            pos += vlen;
            if (len - pos < slen) luaL_error(L, "Truncated string in unmarshall");
            lua_pushlstring(L, reinterpret_cast<const char*>(data + pos), slen);
            pos += slen;
            break;
        }
        case ETYPE_BUFFER: {
            unsigned int blen;
            size_t vlen = decode_varint(L, data + pos, len - pos, &blen);
            pos += vlen;
            if (len - pos < blen) luaL_error(L, "Truncated buffer in unmarshall");
            void* buf = lua_newbuffer(L, blen);
            if (blen) memcpy(buf, data + pos, blen);
            pos += blen;
            break;
        }
        case ETYPE_VECTOR: {
            const size_t vsize = sizeof(float) * LUA_VECTOR_SIZE;
            if (len - pos < vsize) luaL_error(L, "Truncated vector in unmarshall");
            float v[LUA_VECTOR_SIZE];
            memcpy(v, data + pos, vsize);
            pos += vsize;
#if LUA_VECTOR_SIZE == 4
            lua_pushvector(L, v[0], v[1], v[2], v[3]);
#else
            lua_pushvector(L, v[0], v[1], v[2]);
#endif
            break;
        }
        case ETYPE_TABLE: {
            size_t consumed = decode_lua_table(L, data + pos, len - pos);
            pos += consumed;
            break;
        }
        default:
            luaL_error(L, "Unknown type tag 0x%02X in unmarshall", tag);
            break;
    }

    return pos;
}

// ---------------------------------------------------------------------------
// Public decoder entry point
// ---------------------------------------------------------------------------

size_t eryx_unmarshall(lua_State* L, const uint8_t* data, size_t len) {
    return decode_lua_value(L, data, len);
}
