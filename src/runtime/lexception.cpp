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

#include <cstring>
#include <fstream>

#include "../vfs.hpp"

#include "embedded_modules.h"

int exception_tostring(lua_State* L) {
    LuaException* exception = (LuaException*)luaL_checkudata(L, 1, EXCEPTION_METATABLE);
    lua_pushfstring(L, "Exception(%s, %s)", exception->type, exception->message.c_str());
    return 1;
}

int exception_gc(lua_State* L) {
    LuaException* exception = (LuaException*)luaL_checkudata(L, 1, EXCEPTION_METATABLE);
    if (exception) {
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

    // @@vfs/ — read from the virtual filesystem
    if (strncmp(source, CHUNK_PREFIX_VFS, CHUNK_PREFIX_VFS_LEN) == 0) {
        std::string vfsPath = source + CHUNK_PREFIX_VFS_LEN;
        auto data = vfs_read_file(vfsPath);
        if (data.empty()) return std::string("(source unavailable: ") + vfsPath + ")";
        return getLineFromSource(reinterpret_cast<const char*>(data.data()), line);
    }

    // @@eryx/ — read from embedded script modules
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

    // @path — read from the real filesystem
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

    lua_Debug ar;
    for (int level = 0; lua_getinfo(L, level, "sln", &ar); level++) {
        // An =[C] at top level suggests we might have a unique type of error
        if (strcmp(ar.source, "=[C]") == 0) {
            if (level == 0) {
                if (strcmp(ar.name, "error") == 0) {
                    exception->type = ETYPE_THROWN;
                    continue;
                }
                if (strcmp(ar.name, "assert") == 0) {
                    exception->type = ETYPE_ASSERT;
                    continue;
                }
                if (strcmp(ar.name, "require") == 0) {
                    exception->type = ETYPE_REQUIRE;
                    continue;
                }
            }

            // C function, but not an interesting one
            continue;
        }

        // Otherwise, push this as a frame to the traceback
        LuaFrame frame = {
            ar.source ? std::string(ar.source) : "",
            ar.short_src ? std::string(ar.short_src) : "",
            ar.currentline,
            ar.name ? std::string(ar.name) : "<top level>",
            getSourceLine(ar.source, ar.currentline),
        };
        exception->traceback.push_back(frame);
    }
}
void eryx_exception_push_keyboard_interrupt(lua_State* L) {
    eryx_exception_push_exception(L, ETYPE_INTERRUPT, "keyboard interrupt", NULL);
}

void eryx_coerce_to_exception(lua_State* L) {
    if (eryx_get_exception(L, -1)) return;

    const char* raw = lua_tostring(L, -1);
    std::string msg = raw ? raw : "<non-string error>";

    // Strip the "file:line: " prefix Luau prepends to runtime error strings
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

    lua_pop(L, 1);
    eryx_exception_push_exception(L, ETYPE_RUNTIME, msg.c_str(), nullptr);
}

LuaException* eryx_get_exception(lua_State* L, int idx) {
    LuaException* exception = NULL;
    void* p = lua_touserdata(L, idx);
    if (p != NULL) {
        if (((LuaException*)p)->tag == LUA_EXCEPTION_TAG) {
            exception = (LuaException*)p;
        }
    }
    return exception;
}

std::string eryx_format_exception(lua_State* L, int idx) {
    LuaException* exception = eryx_get_exception(L, idx);

    if (exception) {
        std::ostringstream ss;

        ss << exception->type << ": " << exception->message << std::endl;

        if (exception->traceback.size()) {
            // Construct initial error string
            int gutterWidth = std::to_string(exception->traceback[0].line).length();

            ss << "traceback:" << std::endl;

            // Find the maximum width of the "file:line" string
            int maxPathWidth = 0;
            std::vector<std::string> locationStrings;
            for (const auto& f : exception->traceback) {
                std::string loc = std::string(f.short_src) + ":" + std::to_string(f.line);
                locationStrings.push_back(loc);
                if (loc.length() > maxPathWidth) maxPathWidth = loc.length();
            }

            // Construct traceback string
            for (int i = exception->traceback.size() - 1; i >= 0; i--) {
                ss << "  [" << i << "] " << std::left << std::setw(maxPathWidth)
                   << locationStrings[i].c_str();

                if (exception->traceback[i].function.length()) {
                    ss << "  in " << exception->traceback[i].function;
                }

                ss << std::endl;
            }

            ss << " --> " << exception->traceback[0].short_src << ":"
               << exception->traceback[0].line << std::endl;
            if (exception->traceback[0].source[0] == '@') {
                ss << " " << std::string(gutterWidth, ' ') << " |" << std::endl;
                ss << " " << exception->traceback[0].line << " | "
                   << exception->traceback[0].lineContext << std::endl;
                ss << " " << std::string(gutterWidth, ' ') << " |" << std::endl;
            }
        }

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
    } else {
        // Error path – check for uncatchable exceptions
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

    // Replace pcall and xpcall with yieldable variants that rethrow uncatchable exceptions
    lua_pushcclosurek(L, eryx_pcall, "pcall", 0, eryx_pcall_cont);
    lua_setglobal(L, "pcall");
    lua_pushcclosurek(L, eryx_xpcall, "xpcall", 0, eryx_xpcall_cont);
    lua_setglobal(L, "xpcall");
}
