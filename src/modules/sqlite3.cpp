// sqlite3.cpp – SQLite3 module for Luau
// Wraps the SQLite amalgamation to provide embedded relational database access.

#include <cmath>
#include <cstring>
#include <string>

#include "sqlite3.h"

#include "lua.h"
#include "lualib.h"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_sqlite3",
};
LUAU_MODULE_INFO()

// ── Metatable names ───────────────────────────────────────────────────────────

static const char* MT_DATABASE  = "SqliteDatabase";
static const char* MT_STATEMENT = "SqliteStatement";

// ── Userdata structs ──────────────────────────────────────────────────────────

struct LuaDatabase {
    sqlite3* db;
};

struct LuaStatement {
    sqlite3_stmt* stmt;
    sqlite3* db; // keep reference to parent db for error messages
};

// ── Helpers ───────────────────────────────────────────────────────────────────

static LuaDatabase* check_db(lua_State* L, int idx) {
    return (LuaDatabase*)luaL_checkudata(L, idx, MT_DATABASE);
}

static LuaStatement* check_stmt(lua_State* L, int idx) {
    return (LuaStatement*)luaL_checkudata(L, idx, MT_STATEMENT);
}

static void check_db_open(lua_State* L, LuaDatabase* ud) {
    if (!ud->db) luaL_error(L, "attempt to use a closed database");
}

static void check_stmt_valid(lua_State* L, LuaStatement* ud) {
    if (!ud->stmt) luaL_error(L, "attempt to use a finalized statement");
}

// Bind a single Lua value at stack index `idx` to SQLite parameter `param` (1-based).
static void bind_value(lua_State* L, sqlite3_stmt* stmt, int param, int idx) {
    int rc;
    switch (lua_type(L, idx)) {
        case LUA_TNIL:
        case LUA_TNONE:
            rc = sqlite3_bind_null(stmt, param);
            break;
        case LUA_TBOOLEAN:
            rc = sqlite3_bind_int(stmt, param, lua_toboolean(L, idx) ? 1 : 0);
            break;
        case LUA_TNUMBER: {
            double v = lua_tonumber(L, idx);
            if (v == std::floor(v) && v >= -9007199254740992.0 && v <= 9007199254740992.0) {
                rc = sqlite3_bind_int64(stmt, param, (sqlite3_int64)v);
            } else {
                rc = sqlite3_bind_double(stmt, param, v);
            }
            break;
        }
        case LUA_TSTRING: {
            size_t len;
            const char* s = lua_tolstring(L, idx, &len);
            rc = sqlite3_bind_text(stmt, param, s, (int)len, SQLITE_TRANSIENT);
            break;
        }
        case LUA_TBUFFER: {
            size_t len;
            const void* p = lua_tobuffer(L, idx, &len);
            rc = sqlite3_bind_blob(stmt, param, p, (int)len, SQLITE_TRANSIENT);
            break;
        }
        default:
            luaL_error(L, "unsupported type for SQLite parameter %d: %s",
                       param, luaL_typename(L, idx));
            return;
    }
    if (rc != SQLITE_OK) {
        luaL_error(L, "sqlite3_bind failed for parameter %d: %s",
                   param, sqlite3_errmsg(sqlite3_db_handle(stmt)));
    }
}

// Bind variadic args starting at stack position `first` to statement parameters.
static void bind_args(lua_State* L, sqlite3_stmt* stmt, int first) {
    int nargs = lua_gettop(L) - first + 1;
    int nparams = sqlite3_bind_parameter_count(stmt);
    if (nargs > nparams) nargs = nparams;
    for (int i = 0; i < nargs; i++) {
        bind_value(L, stmt, i + 1, first + i);
    }
}

// Push one column value from a stepped statement onto the Lua stack.
static void push_column(lua_State* L, sqlite3_stmt* stmt, int col) {
    switch (sqlite3_column_type(stmt, col)) {
        case SQLITE_INTEGER:
            lua_pushnumber(L, (double)sqlite3_column_int64(stmt, col));
            break;
        case SQLITE_FLOAT:
            lua_pushnumber(L, sqlite3_column_double(stmt, col));
            break;
        case SQLITE_TEXT:
            lua_pushlstring(L, (const char*)sqlite3_column_text(stmt, col),
                           (size_t)sqlite3_column_bytes(stmt, col));
            break;
        case SQLITE_BLOB: {
            int len = sqlite3_column_bytes(stmt, col);
            void* buf = lua_newbuffer(L, len);
            memcpy(buf, sqlite3_column_blob(stmt, col), len);
            break;
        }
        case SQLITE_NULL:
        default:
            lua_pushnil(L);
            break;
    }
}

// Push current row as a { [col_name] = value } table.
static void push_row(lua_State* L, sqlite3_stmt* stmt) {
    int ncols = sqlite3_column_count(stmt);
    lua_createtable(L, 0, ncols);
    for (int i = 0; i < ncols; i++) {
        push_column(L, stmt, i);
        lua_setfield(L, -2, sqlite3_column_name(stmt, i));
    }
}

// ── Module functions ──────────────────────────────────────────────────────────

static int sql_open(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    LuaDatabase* ud = (LuaDatabase*)lua_newuserdata(L, sizeof(LuaDatabase));
    ud->db = nullptr;

    int rc = sqlite3_open(path, &ud->db);
    if (rc != SQLITE_OK) {
        std::string err = "Failed to open database: ";
        if (ud->db) {
            err += sqlite3_errmsg(ud->db);
            sqlite3_close(ud->db);
        } else {
            err += "out of memory";
        }
        ud->db = nullptr;
        luaL_error(L, "%s", err.c_str());
    }

    luaL_getmetatable(L, MT_DATABASE);
    lua_setmetatable(L, -2);
    return 1;
}

static int sql_version(lua_State* L) {
    lua_pushstring(L, sqlite3_libversion());
    return 1;
}

// ── Database methods ──────────────────────────────────────────────────────────

static int db_gc(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    if (ud->db) {
        sqlite3_close_v2(ud->db);
        ud->db = nullptr;
    }
    return 0;
}

static int db_tostring(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    if (ud->db) {
        const char* name = sqlite3_db_filename(ud->db, "main");
        if (name && name[0])
            lua_pushfstring(L, "SqliteDatabase(%s)", name);
        else
            lua_pushstring(L, "SqliteDatabase(:memory:)");
    } else {
        lua_pushstring(L, "SqliteDatabase(closed)");
    }
    return 1;
}

static int db_close(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    if (ud->db) {
        int rc = sqlite3_close_v2(ud->db);
        if (rc != SQLITE_OK) {
            luaL_error(L, "sqlite3_close failed: %s", sqlite3_errmsg(ud->db));
        }
        ud->db = nullptr;
    }
    return 0;
}

static int db_isopen(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    lua_pushboolean(L, ud->db != nullptr);
    return 1;
}

// db:exec(sql) — execute one or more SQL statements, no results
static int db_exec(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_open(L, ud);
    const char* sql = luaL_checkstring(L, 2);

    char* errmsg = nullptr;
    int rc = sqlite3_exec(ud->db, sql, nullptr, nullptr, &errmsg);
    if (rc != SQLITE_OK) {
        std::string err = errmsg ? errmsg : "unknown error";
        sqlite3_free(errmsg);
        luaL_error(L, "sqlite3 exec error: %s", err.c_str());
    }
    return 0;
}

// db:query(sql, ...params) — execute and return all rows
static int db_query(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_open(L, ud);
    const char* sql = luaL_checkstring(L, 2);

    sqlite3_stmt* stmt;
    int rc = sqlite3_prepare_v2(ud->db, sql, -1, &stmt, nullptr);
    if (rc != SQLITE_OK) {
        luaL_error(L, "sqlite3 prepare error: %s", sqlite3_errmsg(ud->db));
    }

    // Bind parameters from arg 3 onwards
    bind_args(L, stmt, 3);

    lua_newtable(L);
    int row_idx = 1;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        push_row(L, stmt);
        lua_rawseti(L, -2, row_idx++);
    }

    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        luaL_error(L, "sqlite3 step error: %s", sqlite3_errmsg(ud->db));
    }

    return 1;
}

// db:prepare(sql) -> Statement
static int db_prepare(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_open(L, ud);
    const char* sql = luaL_checkstring(L, 2);

    sqlite3_stmt* stmt;
    int rc = sqlite3_prepare_v2(ud->db, sql, -1, &stmt, nullptr);
    if (rc != SQLITE_OK) {
        luaL_error(L, "sqlite3 prepare error: %s", sqlite3_errmsg(ud->db));
    }

    LuaStatement* sud = (LuaStatement*)lua_newuserdata(L, sizeof(LuaStatement));
    sud->stmt = stmt;
    sud->db = ud->db;

    luaL_getmetatable(L, MT_STATEMENT);
    lua_setmetatable(L, -2);
    return 1;
}

static int db_lastinsertid(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_open(L, ud);
    lua_pushnumber(L, (double)sqlite3_last_insert_rowid(ud->db));
    return 1;
}

static int db_changes(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_open(L, ud);
    lua_pushinteger(L, sqlite3_changes(ud->db));
    return 1;
}

static int db_index(lua_State* L) {
    // Fall through to metatable for methods
    lua_getmetatable(L, 1);
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
}

// ── Statement methods ─────────────────────────────────────────────────────────

static int stmt_gc(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    if (ud->stmt) {
        sqlite3_finalize(ud->stmt);
        ud->stmt = nullptr;
    }
    return 0;
}

static int stmt_tostring(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    if (ud->stmt) {
        const char* sql = sqlite3_sql(ud->stmt);
        if (sql)
            lua_pushfstring(L, "SqliteStatement(%s)", sql);
        else
            lua_pushstring(L, "SqliteStatement");
    } else {
        lua_pushstring(L, "SqliteStatement(finalized)");
    }
    return 1;
}

// stmt:bind(...params) -> stmt
static int stmt_bind(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_valid(L, ud);

    sqlite3_reset(ud->stmt);
    sqlite3_clear_bindings(ud->stmt);
    bind_args(L, ud->stmt, 2);

    lua_pushvalue(L, 1); // return self
    return 1;
}

// stmt:step() -> Row | nil
static int stmt_step(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_valid(L, ud);

    int rc = sqlite3_step(ud->stmt);
    if (rc == SQLITE_ROW) {
        push_row(L, ud->stmt);
        return 1;
    }
    if (rc == SQLITE_DONE) {
        lua_pushnil(L);
        return 1;
    }
    luaL_error(L, "sqlite3 step error: %s", sqlite3_errmsg(ud->db));
    return 0;
}

// stmt:reset() -> stmt
static int stmt_reset(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_valid(L, ud);

    sqlite3_reset(ud->stmt);
    lua_pushvalue(L, 1);
    return 1;
}

// stmt:all(...params) -> { Row }
static int stmt_all(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_valid(L, ud);

    sqlite3_reset(ud->stmt);
    sqlite3_clear_bindings(ud->stmt);
    bind_args(L, ud->stmt, 2);

    lua_newtable(L);
    int row_idx = 1;
    int rc;
    while ((rc = sqlite3_step(ud->stmt)) == SQLITE_ROW) {
        push_row(L, ud->stmt);
        lua_rawseti(L, -2, row_idx++);
    }

    if (rc != SQLITE_DONE) {
        luaL_error(L, "sqlite3 step error: %s", sqlite3_errmsg(ud->db));
    }

    return 1;
}

// stmt:run(...params) -> ()
static int stmt_run(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_valid(L, ud);

    sqlite3_reset(ud->stmt);
    sqlite3_clear_bindings(ud->stmt);
    bind_args(L, ud->stmt, 2);

    int rc = sqlite3_step(ud->stmt);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        luaL_error(L, "sqlite3 step error: %s", sqlite3_errmsg(ud->db));
    }

    return 0;
}

static int stmt_index(lua_State* L) {
    // Fall through to metatable for methods
    lua_getmetatable(L, 1);
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
}

// ── Module entry ──────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_sqlite3(lua_State* L) {
    // -- SqliteDatabase metatable --
    luaL_newmetatable(L, MT_DATABASE);
    lua_pushcfunction(L, db_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, db_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, db_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, db_exec, "Exec");
    lua_setfield(L, -2, "Exec");
    lua_pushcfunction(L, db_query, "Query");
    lua_setfield(L, -2, "Query");
    lua_pushcfunction(L, db_prepare, "Prepare");
    lua_setfield(L, -2, "Prepare");
    lua_pushcfunction(L, db_close, "Close");
    lua_setfield(L, -2, "Close");
    lua_pushcfunction(L, db_isopen, "IsOpen");
    lua_setfield(L, -2, "IsOpen");
    lua_pushcfunction(L, db_lastinsertid, "LastInsertId");
    lua_setfield(L, -2, "LastInsertId");
    lua_pushcfunction(L, db_changes, "Changes");
    lua_setfield(L, -2, "Changes");
    lua_pop(L, 1);

    // -- SqliteStatement metatable --
    luaL_newmetatable(L, MT_STATEMENT);
    lua_pushcfunction(L, stmt_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, stmt_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, stmt_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, stmt_bind, "Bind");
    lua_setfield(L, -2, "Bind");
    lua_pushcfunction(L, stmt_step, "Step");
    lua_setfield(L, -2, "Step");
    lua_pushcfunction(L, stmt_reset, "Reset");
    lua_setfield(L, -2, "Reset");
    lua_pushcfunction(L, stmt_all, "All");
    lua_setfield(L, -2, "All");
    lua_pushcfunction(L, stmt_run, "Run");
    lua_setfield(L, -2, "Run");
    lua_pop(L, 1);

    // -- Module table --
    lua_newtable(L);
    lua_pushcfunction(L, sql_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, sql_version, "version");
    lua_setfield(L, -2, "version");
    return 1;
}
