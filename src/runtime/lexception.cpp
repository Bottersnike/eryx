#include "lexception.hpp"

// VM internals needed for yieldable pcall/xpcall
// Both of these are Luau/VM/src/*
#include "lstate.h"
#ifndef ERYX_EMBED
extern "C" {
#endif
#include "ldo.h"
#ifndef ERYX_EMBED
}
#endif

#include <cctype>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <memory>

#include "../vfs.hpp"
#include "embedded_modules.h"

constexpr int RETHROW_MAGIC = -3558;
static const char* ERYX_PENDING_ERROR_SKIP = "_ERYX_PENDING_ERROR_SKIP";

struct ExceptionFormatStyle {
    bool ansi = false;

    const char* reset() const { return ansi ? "\x1b[0m" : ""; }
    const char* bold() const { return ansi ? "\x1b[1m" : ""; }
    const char* dim() const { return ansi ? "\x1b[2m" : ""; }
    const char* red() const { return ansi ? "\x1b[31m" : ""; }
    const char* yellow() const { return ansi ? "\x1b[33m" : ""; }
    const char* cyan() const { return ansi ? "\x1b[36m" : ""; }
};

static std::unique_ptr<LuaExceptionSnapshot> copy_exception_snapshot(
    const LuaExceptionSnapshot* snapshot) {
    if (!snapshot) return nullptr;

    auto copy = std::make_unique<LuaExceptionSnapshot>();
    copy->type = snapshot->type;
    copy->message = snapshot->message;
    copy->traceback = snapshot->traceback;
    copy->parent = copy_exception_snapshot(snapshot->parent.get());
    return copy;
}

std::unique_ptr<LuaExceptionSnapshot> eryx_copy_exception(const LuaException* exception) {
    if (!exception) return nullptr;

    auto copy = std::make_unique<LuaExceptionSnapshot>();
    copy->type = exception->type ? exception->type : "";
    copy->message = exception->message;
    copy->traceback = exception->traceback;
    copy->parent = copy_exception_snapshot(exception->parent.get());
    return copy;
}

static void push_exception_snapshot(lua_State* L, const LuaExceptionSnapshot* snapshot) {
    if (!snapshot) {
        lua_pushnil(L);
        return;
    }

    lua_createtable(L, 0, 4);

    lua_pushlstring(L, snapshot->message.c_str(), snapshot->message.size());
    lua_setfield(L, -2, "message");

    lua_pushlstring(L, snapshot->type.c_str(), snapshot->type.size());
    lua_setfield(L, -2, "type");

    lua_createtable(L, snapshot->traceback.size(), 0);
    for (size_t i = 0; i < snapshot->traceback.size(); i++) {
        const LuaFrame& f = snapshot->traceback[i];

        lua_createtable(L, 0, 5);
        lua_pushlstring(L, f.source.c_str(), f.source.size());
        lua_setfield(L, -2, "source");
        lua_pushlstring(L, f.short_src.c_str(), f.short_src.size());
        lua_setfield(L, -2, "short_src");
        lua_pushinteger(L, f.line);
        lua_setfield(L, -2, "line");
        lua_pushlstring(L, f.function.c_str(), f.function.size());
        lua_setfield(L, -2, "functionName");
        lua_pushlstring(L, f.lineContext.c_str(), f.lineContext.size());
        lua_setfield(L, -2, "lineContext");

        lua_rawseti(L, -2, (lua_Integer)i + 1);
    }
    lua_setfield(L, -2, "traceback");

    push_exception_snapshot(L, snapshot->parent.get());
    lua_setfield(L, -2, "parent");
}

static void set_pending_error_skip(lua_State* L, int skip) {
    lua_getfield(L, LUA_REGISTRYINDEX, ERYX_PENDING_ERROR_SKIP);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushthread(L);
        lua_pushinteger(L, skip);
        lua_rawset(L, -3);
        lua_setfield(L, LUA_REGISTRYINDEX, ERYX_PENDING_ERROR_SKIP);
        return;
    }

    lua_pushthread(L);
    lua_pushinteger(L, skip);
    lua_rawset(L, -3);
    lua_pop(L, 1);
}

static int take_pending_error_skip(lua_State* L) {
    int skip = 0;

    lua_getfield(L, LUA_REGISTRYINDEX, ERYX_PENDING_ERROR_SKIP);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    lua_pushthread(L);
    lua_rawget(L, -2);
    if (lua_isnumber(L, -1)) {
        skip = static_cast<int>(lua_tointeger(L, -1));
    }
    lua_pop(L, 1);

    lua_pushthread(L);
    lua_pushnil(L);
    lua_rawset(L, -3);
    lua_pop(L, 1);

    return skip;
}

static void format_exception_into(std::ostringstream& ss, const char* type,
                                  const std::string& message,
                                  const std::vector<LuaFrame>& traceback,
                                  const LuaExceptionSnapshot* parent,
                                  const ExceptionFormatStyle& style) {
    if (parent) {
        format_exception_into(ss, parent->type.c_str(), parent->message, parent->traceback,
                              parent->parent.get(), style);
        ss << style.dim() << " --> " << style.reset() << style.bold() << "rethrown as"
           << style.reset() << std::endl;
    }

    ss << style.red() << style.bold() << type << style.reset() << ": " << style.bold() << message
       << style.reset() << std::endl;

    if (traceback.empty()) {
        return;
    }

    int gutterWidth = std::to_string(traceback[0].line).length();

    ss << style.yellow() << style.bold() << "Traceback (most recent call last):" << style.reset()
       << std::endl;

    int maxLocationWidth = 0;
    std::vector<std::string> pathStrings;
    std::vector<std::string> lineStrings;
    for (const auto& f : traceback) {
        std::string path = std::string(f.short_src);
        std::string line = std::to_string(f.line);
        pathStrings.push_back(path);
        lineStrings.push_back(line);

        int locationWidth = static_cast<int>(path.length() + 1 + line.length());
        if (locationWidth > maxLocationWidth) maxLocationWidth = locationWidth;
    }

    int numberingBase = static_cast<int>(traceback.size());
    for (int i = static_cast<int>(traceback.size()) - 1; i >= 0; i--) {
        if (traceback[i].line == RETHROW_MAGIC) {
            ss << style.dim() << " --> " << style.reset() << style.cyan()
               << traceback[i + 1].short_src << style.reset() << ":" << style.yellow()
               << traceback[i + 1].line << style.reset() << std::endl;
            if (!traceback[i + 1].source.empty() && traceback[i + 1].source[0] == '@') {
                ss << style.dim() << " " << std::string(gutterWidth, ' ') << " |" << style.reset()
                   << std::endl;
                ss << " " << style.yellow() << traceback[i + 1].line << style.reset() << " "
                   << style.dim() << "|" << style.reset() << " " << traceback[i + 1].lineContext
                   << std::endl;
                ss << style.dim() << " " << std::string(gutterWidth, ' ') << " |" << style.reset()
                   << std::endl;
            }

            ss << style.dim() << "  --> propagated through" << style.reset();
            numberingBase = i;
        } else {
            std::string location = pathStrings[i] + ":";
            ss << style.dim() << "  [" << -(i - numberingBase + 1) << "] " << style.reset()
               << style.cyan() << std::left << std::setw(maxLocationWidth - lineStrings[i].length())
               << location.c_str() << style.reset() << style.yellow() << lineStrings[i]
               << style.reset();

            if (traceback[i].function.length()) {
                ss << "  " << style.dim() << "in" << style.reset() << " " << traceback[i].function;
            }
        }

        ss << std::endl;
    }

    ss << style.dim() << " --> " << style.reset() << style.cyan() << traceback[0].short_src
       << style.reset() << ":" << style.yellow() << traceback[0].line << style.reset() << std::endl;
    if (!traceback[0].source.empty() && traceback[0].source[0] == '@') {
        ss << style.dim() << " " << std::string(gutterWidth, ' ') << " |" << style.reset()
           << std::endl;
        ss << " " << style.yellow() << traceback[0].line << style.reset() << " " << style.dim()
           << "|" << style.reset() << " " << traceback[0].lineContext << std::endl;
        ss << style.dim() << " " << std::string(gutterWidth, ' ') << " |" << style.reset()
           << std::endl;
    }
}

int exception_tostring(lua_State* L) {
    LuaException* exception = (LuaException*)luaL_checkudata(L, 1, EXCEPTION_METATABLE);
    lua_pushfstring(L, "Exception(%s, %s)", exception->type, exception->message.c_str());
    return 1;
}

int exception_gc(lua_State* L) {
    LuaException* exception = (LuaException*)luaL_checkudata(L, 1, EXCEPTION_METATABLE);
    if (exception) {
        if (exception->dataRef != LUA_NOREF) {
            lua_unref(L, exception->dataRef);
            exception->dataRef = LUA_NOREF;
        }
        exception->~LuaException();
    }
    return 0;
}

int exception_index(lua_State* L) {
    LuaException* exception = (LuaException*)luaL_checkudata(L, 1, EXCEPTION_METATABLE);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "message") == 0) {
        lua_pushstring(L, exception->message.c_str());
        return 1;
    }
    if (strcmp(key, "type") == 0) {
        lua_pushstring(L, exception->type);
        return 1;
    }
    if (strcmp(key, "data") == 0) {
        if (exception->dataRef != LUA_NOREF) {
            lua_getref(L, exception->dataRef);
        } else {
            lua_pushnil(L);
        }
        return 1;
    }
    if (strcmp(key, "parent") == 0) {
        push_exception_snapshot(L, exception->parent.get());
        return 1;
    }
    if (strcmp(key, "traceback") == 0) {
        lua_createtable(L, exception->traceback.size(), 0);

        for (size_t i = 0; i < exception->traceback.size(); i++) {
            const LuaFrame& f = exception->traceback[i];

            // frame table
            lua_createtable(L, 0, 5);

            // source
            lua_pushlstring(L, f.source.c_str(), f.source.size());
            lua_setfield(L, -2, "source");

            // short_src
            lua_pushlstring(L, f.short_src.c_str(), f.short_src.size());
            lua_setfield(L, -2, "short_src");

            // line
            lua_pushinteger(L, f.line);
            lua_setfield(L, -2, "line");

            // function
            lua_pushlstring(L, f.function.c_str(), f.function.size());
            lua_setfield(L, -2, "functionName");

            // lineContext
            lua_pushlstring(L, f.lineContext.c_str(), f.lineContext.size());
            lua_setfield(L, -2, "lineContext");

            // traceback[i+1] = frame
            lua_rawseti(L, -2, (lua_Integer)i + 1);
        }

        return 1;
    }

    // Key not found
    lua_pushnil(L);
    return 1;
}

static std::string lstrip(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) ++i;
    return s.substr(i);
}

// Extract line N from a raw source string (1-indexed).
static std::string getLineFromSource(const char* src, int line) {
    int cur = 1;
    const char* p = src;
    while (*p) {
        const char* eol = p;
        while (*eol && *eol != '\n' && *eol != '\r') ++eol;

        if (cur == line) return lstrip(std::string(p, eol));

        // Skip newline(s)
        if (*eol == '\r' && *(eol + 1) == '\n')
            p = eol + 2;
        else if (*eol)
            p = eol + 1;
        else
            break;
        ++cur;
    }
    return std::string("(line ") + std::to_string(line) + " unavailable)";
}

std::string getSourceLine(const char* source, int line) {
    if (!source || line <= 0) return std::string("Cooked!");  // not a source-backed chunk

    // @@vfs/ - read from the virtual filesystem
    if (strncmp(source, CHUNK_PREFIX_VFS, CHUNK_PREFIX_VFS_LEN) == 0) {
        std::string vfsPath = source + CHUNK_PREFIX_VFS_LEN;
        auto data = vfs_read_file(vfsPath);
        if (data.empty()) return std::string("(source unavailable: ") + vfsPath + ")";
        return getLineFromSource(reinterpret_cast<const char*>(data.data()), line);
    }

    // @@eryx/ - read from embedded script modules
    if (strncmp(source, CHUNK_PREFIX_ERYX, CHUNK_PREFIX_ERYX_LEN) == 0) {
        const char* key = source + CHUNK_PREFIX_ERYX_LEN;
        auto* scripts = eryx_get_embedded_script_modules();
        if (scripts) {
            for (const EmbeddedScriptModule* m = scripts; m->modulePath; ++m) {
                if (strcmp(m->modulePath, key) == 0) {
                    return getLineFromSource(m->source, line);
                }
            }
        }
        return std::string("(source unavailable: ") + key + ")";
    }

    // @path - read from the real filesystem
    if (source[0] != '@') return std::string("Cooked!");

    std::string path = source + 1;

    std::ifstream file(path);
    if (!file.is_open()) {
        return std::string("(source unavailable: ") + path + ")";
    }

    std::string text;
    for (int i = 1; i <= line; ++i) {
        if (!std::getline(file, text)) {
            return std::string("(line ") + std::to_string(line) + " unavailable)";
        }
    }

    return lstrip(text);
}

void eryx_exception_populate_tb(lua_State* L, LuaException* exception, int initialLevel) {
    lua_Debug ar;
    std::vector<LuaFrame> newFrames;
    int remainingSkip = exception->pendingTracebackSkip;
    exception->pendingTracebackSkip = 0;

    for (int level = initialLevel; unsigned(level) < unsigned(L->ci - L->base_ci); level++) {
        CallInfo* ci = L->ci - level;
        if (!ttisfunction(ci->func)) continue;
        if (!lua_getinfo(L, level, "sln", &ar)) continue;

        const char* arSource = ar.source ? ar.source : "";
        const char* arShortSource = ar.short_src ? ar.short_src : "";
        const char* arName = ar.name ? ar.name : nullptr;

        // An =[C] at top level suggests we might have a unique type of error
        if (strcmp(arSource, "=[C]") == 0) {
            if (level == initialLevel) {
                if (arName && strcmp(arName, "error") == 0) {
                    exception->type = ETYPE_THROWN;
                    continue;
                }
                if (arName && strcmp(arName, "assert") == 0) {
                    exception->type = ETYPE_ASSERT;
                    continue;
                }
                if (arName && strcmp(arName, "require") == 0) {
                    exception->type = ETYPE_REQUIRE;
                    continue;
                }
            }

            // C function, but not an interesting one
            continue;
        }

        if (remainingSkip > 0) {
            remainingSkip--;
            continue;
        }

        // Otherwise, push this as a frame to the traceback
        LuaFrame frame = {
            std::string(arSource),
            std::string(arShortSource),
            ar.currentline,
            arName ? std::string(arName) : "<top level>",
            getSourceLine(arSource, ar.currentline),
        };
        newFrames.push_back(frame);
    }

    if (!exception->traceback.empty()) {
        // RETHROW: prepend
        LuaFrame rethrowFrame = { "", "", RETHROW_MAGIC, "", "" };
        newFrames.push_back(rethrowFrame);
        exception->traceback.insert(exception->traceback.begin(), newFrames.begin(),
                                    newFrames.end());

    } else {
        // FIRST THROW: just assign
        exception->traceback = std::move(newFrames);
    }
}

void eryx_exception_push_exception(lua_State* L, const char* type, const char* message,
                                   const void* extra) {
    lua_checkstack(L, 3);  // need space for userdata + metatable + getfield
    LuaException* exception = (LuaException*)lua_newuserdata(L, sizeof(LuaException));
    new (exception) LuaException();
    luaL_getmetatable(L, EXCEPTION_METATABLE);
    lua_setmetatable(L, -2);
    exception->type = type;
    exception->message = message;
    exception->extra = extra;

    eryx_exception_populate_tb(L, exception, 0);
}
void eryx_exception_push_keyboard_interrupt(lua_State* L) {
    eryx_exception_push_exception(L, ETYPE_INTERRUPT, "keyboard interrupt", NULL);
}

void eryx_coerce_to_exception(lua_State* L) {
    if (lua_gettop(L) < 1) {
        eryx_exception_push_exception(L, ETYPE_RUNTIME, "<missing error object>", nullptr);

        LuaException* exception = eryx_get_exception(L, -1);
        if (exception) {
            exception->pendingTracebackSkip = take_pending_error_skip(L);
            exception->traceback.clear();
            eryx_exception_populate_tb(L, exception, 0);
        }
        return;
    }

    LuaException* e = eryx_get_exception(L, -1);
    if (e) {
        eryx_exception_populate_tb(L, e, 0);
        return;
    }

    // Need stack space for getfield, pushvalue, ref, and push_exception
    lua_checkstack(L, 4);

    std::string msg;
    bool isTable = lua_istable(L, -1);
    bool isString = lua_isstring(L, -1);

    if (isTable) {
        // Table errors: extract "message" field if present.
        // This supports structured error tables like { message = "...", line = 5, ... }
        lua_getfield(L, -1, "message");
        const char* tableMsg = lua_tostring(L, -1);
        if (tableMsg) {
            msg = tableMsg;
        } else {
            msg = "<non-string error>";
        }
        lua_pop(L, 1);  // pop the message field
    } else if (isString) {
        const char* raw = lua_tostring(L, -1);
        msg = raw ? raw : "<non-string error>";
    } else {
        msg = "<non-string error>";
    }

    // For string errors, strip the "file:line: " prefix that Luau prepends
    // (it's redundant with the traceback). For table errors, the message was
    // extracted from .message and has no Luau prefix, so leave it alone.
    if (isString) {
        size_t colon2 = msg.find(": ");
        if (colon2 != std::string::npos && colon2 > 0) {
            size_t colon1 = msg.rfind(':', colon2 - 1);
            if (colon1 != std::string::npos) {
                std::string lineStr = msg.substr(colon1 + 1, colon2 - colon1 - 1);
                bool isNum = !lineStr.empty();
                for (char c : lineStr) {
                    if (!std::isdigit((unsigned char)c)) {
                        isNum = false;
                        break;
                    }
                }
                if (isNum) msg = msg.substr(colon2 + 2);
            }
        }
    }

    // Store a registry ref to the original error value.
    // lua_ref pops the value, so we push a copy first.
    lua_pushvalue(L, -1);
    int dataRef = lua_ref(L, -1);  // pops the copy

    lua_pop(L, 1);  // pop the original

    const char* etype = isTable ? ETYPE_THROWN : ETYPE_RUNTIME;
    eryx_exception_push_exception(L, etype, msg.c_str(), nullptr);

    // Attach the original error data to the Exception
    LuaException* exception = eryx_get_exception(L, -1);
    if (exception) {
        exception->dataRef = dataRef;
        exception->pendingTracebackSkip = take_pending_error_skip(L);
        exception->traceback.clear();
        eryx_exception_populate_tb(L, exception, 0);
    }
}

LuaException* eryx_get_exception(lua_State* L, int idx) {
    LuaException* exception = NULL;
    // Guard against lightuserdata
    if (lua_tolightuserdata(L, idx) != NULL) {
        return NULL;
    }
    void* p = lua_touserdata(L, idx);
    if (p != NULL) {
        if (((LuaException*)p)->tag == LUA_EXCEPTION_TAG) {
            exception = (LuaException*)p;
        }
    }
    return exception;
}

std::string eryx_format_exception(lua_State* L, int idx, bool useAnsi) {
    LuaException* exception = eryx_get_exception(L, idx);

    if (exception) {
        std::ostringstream ss;
        ExceptionFormatStyle style{ useAnsi };
        format_exception_into(ss, exception->type, exception->message, exception->traceback,
                              exception->parent.get(), style);

        return ss.str();
        fprintf(stderr, "%s\n", ss.str().c_str());

    } else {
        const char* errStr = lua_tostring(L, idx);
        if (errStr) return std::string(errStr);

        // TODO: Make this a bit nicer? :D
        return std::string("<non-string error>");
    }
}

static bool is_uncatchable_exception(lua_State* L, int idx) {
    LuaException* exception = eryx_get_exception(L, idx);
    if (!exception) return false;

    if (strcmp(exception->type, ETYPE_SYSTEM_EXIT) == 0) {
        return true;
    }

    return false;
}
// ---------------------------------------------------------------------------
// Yieldable pcall / xpcall that also rethrow uncatchable exceptions.
// Mirrors luaB_pcally / luaB_xpcally from lbaselib.cpp but adds the
// uncatchable-exception check in the continuation path.
// ---------------------------------------------------------------------------

static void eryx_pcallrun(lua_State* L, void* ud) {
    StkId func = (StkId)ud;
    luaD_callint(L, func, LUA_MULTRET, lua_isyieldable(L) != 0);
}

static int eryx_pcall_cont(lua_State* L, int status) {
    if (status == 0) {
        lua_rawcheckstack(L, 1);
        lua_pushboolean(L, true);
        lua_insert(L, 1);
        return lua_gettop(L);
    }

    if (is_uncatchable_exception(L, -1)) {
        lua_error(L);  // rethrow past this pcall
        return 0;
    }

    eryx_coerce_to_exception(L);
    lua_rawcheckstack(L, 1);
    lua_pushboolean(L, false);
    lua_insert(L, -2);
    return 2;
}

static int eryx_pcall(lua_State* L) {
    luaL_checkany(L, 1);

    StkId func = L->base;
    L->ci->flags |= LUA_CALLINFO_HANDLE;

    int status = luaD_pcall(L, eryx_pcallrun, func, savestack(L, func), 0);
    expandstacklimit(L, L->top);

    if (status == 0 && isyielded(L)) return C_CALL_YIELD;

    // Immediate return (no yield)
    if (status != LUA_OK && is_uncatchable_exception(L, -1)) {
        lua_error(L);
        return 0;
    }

    if (status != LUA_OK) eryx_coerce_to_exception(L);

    lua_rawcheckstack(L, 1);
    lua_pushboolean(L, status == 0);
    lua_insert(L, 1);
    return lua_gettop(L);
}

static void eryx_xpcallerr(lua_State* L, void* ud) {
    StkId func = (StkId)ud;
    luaD_callny(L, func, 1);
}

static int eryx_xpcall_cont(lua_State* L, int status) {
    if (status == 0) {
        lua_rawcheckstack(L, 1);
        lua_pushboolean(L, true);
        lua_replace(L, 1);
        return lua_gettop(L);
    } else {
        if (is_uncatchable_exception(L, -1)) {
            lua_error(L);
            return 0;
        }
        lua_rawcheckstack(L, 3);
        lua_pushboolean(L, false);
        lua_pushvalue(L, 1);   // push error function
        lua_pushvalue(L, -3);  // push error object

        StkId errf = L->top - 2;
        ptrdiff_t oldtopoffset = savestack(L, errf);

        int err = luaD_pcall(L, eryx_xpcallerr, errf, oldtopoffset, 0);

        if (err != 0) {
            int errstatus;
            if (status == LUA_ERRMEM && err == LUA_ERRMEM)
                errstatus = LUA_ERRMEM;
            else
                errstatus = LUA_ERRERR;
            StkId oldtop = restorestack(L, oldtopoffset);
            luaD_seterrorobj(L, errstatus, oldtop);
        }

        return 2;
    }
}

static int eryx_xpcall(lua_State* L) {
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // swap function & error function so stack is: err, f, args
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_replace(L, 1);
    lua_replace(L, 2);

    L->ci->flags |= LUA_CALLINFO_HANDLE;

    StkId errf = L->base;
    StkId func = L->base + 1;

    int status = luaD_pcall(L, eryx_pcallrun, func, savestack(L, func), savestack(L, errf));
    expandstacklimit(L, L->top);

    if (status == 0 && isyielded(L)) return C_CALL_YIELD;

    // Immediate return
    if (status != LUA_OK && is_uncatchable_exception(L, -1)) {
        lua_error(L);
        return 0;
    }

    lua_rawcheckstack(L, 1);
    lua_pushboolean(L, status == 0);
    lua_replace(L, 1);
    return lua_gettop(L);
}

static int eryx_error(lua_State* L) {
    int level = luaL_optinteger(L, 2, 1);
    lua_settop(L, 1);

    if (LuaException* exception = eryx_get_exception(L, 1)) {
        exception->pendingTracebackSkip = level > 1 ? level - 1 : 0;
    } else if (lua_isstring(L, 1) && level > 0) {
        set_pending_error_skip(L, level > 1 ? level - 1 : 0);
        luaL_where(L, level);
        lua_pushvalue(L, 1);
        lua_concat(L, 2);
    } else {
        set_pending_error_skip(L, level > 1 ? level - 1 : 0);
    }

    lua_error(L);
}

void exception_lib_register(lua_State* L) {
    luaL_newmetatable(L, EXCEPTION_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, exception_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, exception_gc, "gc");
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, exception_index, "index");
    lua_setfield(L, -2, "__index");

    lua_pushstring(L, "Exception");
    lua_setfield(L, -2, "__type");

    lua_pop(L, 1);

    lua_pushcfunction(L, eryx_error, "error");
    lua_setglobal(L, "error");

    // Replace pcall and xpcall with yieldable variants that rethrow uncatchable exceptions
    lua_pushcclosurek(L, eryx_pcall, "pcall", 0, eryx_pcall_cont);
    lua_setglobal(L, "pcall");
    lua_pushcclosurek(L, eryx_xpcall, "xpcall", 0, eryx_xpcall_cont);
    lua_setglobal(L, "xpcall");
}
