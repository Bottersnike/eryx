#pragma once

#include <memory>
#include <string>
#include <vector>

#include "../pch.hpp"
#include "lua.h"     // IWYU pragma: export
#include "lualib.h"  // IWYU pragma: export

// Built-in error types
static const char* ETYPE_RUNTIME = "runtime";
static const char* ETYPE_ASSERT = "assert";
static const char* ETYPE_THROWN = "thrown";
static const char* ETYPE_SYNTAX = "syntax";
static const char* ETYPE_REQUIRE = "require";
static const char* ETYPE_USER = "user";
static const char* ETYPE_INTERRUPT = "interrupt";
static const char* ETYPE_SYSTEM_EXIT = "system exit";

static const uint32_t LUA_EXCEPTION_TAG = 0x4C584345;  // "LXCE"

// Chunk name prefixes for virtual module sources
#define CHUNK_PREFIX_VFS "@@vfs/"
#define CHUNK_PREFIX_VFS_LEN 6
#define CHUNK_PREFIX_ERYX "@@eryx/"
#define CHUNK_PREFIX_ERYX_LEN 7

typedef struct _LuaFrame {
    std::string source;
    std::string short_src;
    int line;
    // int col;  // Lua is shit!
    std::string function;
    std::string lineContext;
} LuaFrame;
typedef struct _LuaExceptionSnapshot {
    std::string type;
    std::string message;
    std::vector<LuaFrame> traceback;
    std::unique_ptr<_LuaExceptionSnapshot> parent;
} LuaExceptionSnapshot;
typedef struct _LuaException {
    uint32_t tag = LUA_EXCEPTION_TAG;
    const char* type;
    std::string message;
    std::vector<LuaFrame> traceback;
    const void* extra;
    std::unique_ptr<LuaExceptionSnapshot> parent;
    int pendingTracebackSkip = 0;
    int dataRef = LUA_NOREF;  // Registry ref to the original error value
} LuaException;

LuaException* eryx_get_exception(lua_State* L, int idx);
ERYX_API LuaException* eryx_exception_push_userdata(lua_State* L);
std::unique_ptr<LuaExceptionSnapshot> eryx_copy_exception(const LuaException* exception);

void eryx_exception_push_keyboard_interrupt(lua_State* L);
void eryx_exception_push_exception(lua_State* L, const char* type, const char* message,
                                   const void* extra);
void eryx_exception_populate_tb(lua_State* L, LuaException* exception, int initialLevel = 0);
std::string eryx_format_exception(lua_State* L, int idx, bool useAnsi = false);

// If the value at the top of the stack is not already a LuaException, replaces it
// with one. Traceback is walked from L's current call stack - valid after
// lua_resume fails (frames preserved) or within an error handler.
void eryx_coerce_to_exception(lua_State* L);

void exception_lib_register(lua_State* L);
void exception_lib_unregister(lua_State* L);

std::string getSourceLine(const char* source, int line);
