#pragma once

#include <cstdint>
#include <vector>

#include "lua.h"
#include "lualib.h"

enum EryxMarshallType : uint8_t {
    ETYPE_NULL = 0x00,
    ETYPE_TRUE = 0x01,
    ETYPE_FALSE = 0x02,
    ETYPE_DOUBLE = 0x03,
    ETYPE_STRING = 0x04,
    ETYPE_BUFFER = 0x05,
    ETYPE_VECTOR = 0x06,

    ETYPE_TABLE = 0x11,
    ETYPE_TABLE_HASH_DELIM = 0x12,
};

// Encode the Lua value at stack index `idx` into `out`.
// Handles visited-table tracking internally.
void eryx_marshall(lua_State* L, int idx, std::vector<uint8_t>& out);

// Decode one value from `data` (of `len` bytes), pushing it onto L's stack.
// Returns the number of bytes consumed. Calls luaL_error on malformed input.
size_t eryx_unmarshall(lua_State* L, const uint8_t* data, size_t len);
