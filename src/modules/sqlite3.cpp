// sqlite3.cpp – SQLite3 module for Luau
// Wraps the SQLite amalgamation to provide embedded relational database access.

#include "sqlite3.h"

#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "../LuaUtil.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "module_helpers.hpp"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_sqlite3",
};
LUAU_MODULE_INFO()

// ── Metatable names ───────────────────────────────────────────────────────────

static const char* MT_DATABASE = "SqliteDatabase";
static const char* MT_STATEMENT = "SqliteStatement";

// ── Userdata structs ──────────────────────────────────────────────────────────

struct LuaDatabase {
    sqlite3* db;
    bool busy;
    bool inTransaction;
};

struct LuaStatement {
    sqlite3_stmt* stmt;
    sqlite3* db;  // keep reference to parent db for error messages
    LuaDatabase* owner;
    bool busy;
};

// ── Helpers ───────────────────────────────────────────────────────────────────

static LuaDatabase* check_db(lua_State* L, int idx) {
    return (LuaDatabase*)luaL_checkudata(L, idx, MT_DATABASE);
}

static LuaStatement* check_stmt(lua_State* L, int idx) {
    return (LuaStatement*)luaL_checkudata(L, idx, MT_STATEMENT);
}

// Forward declarations – dtors are defined later but referenced by lua_newuserdatadtor
static void db_dtor(void* ud);
static void stmt_dtor(void* ud);

static void check_db_open(lua_State* L, LuaDatabase* ud) {
    if (!ud->db) luaL_error(L, "attempt to use a closed database");
}

static void check_stmt_valid(lua_State* L, LuaStatement* ud) {
    if (!ud->stmt) luaL_error(L, "attempt to use a finalized statement");
}

static void check_db_available(lua_State* L, LuaDatabase* ud) {
    check_db_open(L, ud);
    if (ud->busy) luaL_error(L, "database is already busy");
}

static void check_stmt_available(lua_State* L, LuaStatement* ud) {
    check_stmt_valid(L, ud);
    if (ud->busy) luaL_error(L, "statement is already busy");
    if (ud->owner && ud->owner->busy) luaL_error(L, "database is already busy");
}

enum class SqlValueKind { Null, Boolean, Number, String, Blob };

struct SqlValue {
    SqlValueKind kind = SqlValueKind::Null;
    bool boolean = false;
    double number = 0.0;
    std::string bytes;
};

struct SqlRow {
    std::vector<std::string> names;
    std::vector<SqlValue> values;
};

static SqlValue copy_lua_bind_value(lua_State* L, int idx) {
    SqlValue value;
    switch (lua_type(L, idx)) {
        case LUA_TNIL:
        case LUA_TNONE:
            value.kind = SqlValueKind::Null;
            break;
        case LUA_TBOOLEAN:
            value.kind = SqlValueKind::Boolean;
            value.boolean = lua_toboolean(L, idx) != 0;
            break;
        case LUA_TNUMBER:
            value.kind = SqlValueKind::Number;
            value.number = lua_tonumber(L, idx);
            break;
        case LUA_TSTRING: {
            size_t len = 0;
            const char* s = lua_tolstring(L, idx, &len);
            value.kind = SqlValueKind::String;
            value.bytes.assign(s, len);
            break;
        }
        case LUA_TBUFFER: {
            size_t len = 0;
            const void* data = lua_tobuffer(L, idx, &len);
            value.kind = SqlValueKind::Blob;
            value.bytes.assign((const char*)data, len);
            break;
        }
        default:
            luaL_error(L, "unsupported type for SQLite parameter: %s", luaL_typename(L, idx));
            break;
    }
    return value;
}

static std::vector<SqlValue> copy_bind_args(lua_State* L, int first) {
    std::vector<SqlValue> values;
    int top = lua_gettop(L);
    if (first > top) return values;

    values.reserve((size_t)(top - first + 1));
    for (int i = first; i <= top; i++) values.push_back(copy_lua_bind_value(L, i));
    return values;
}

static bool bind_copied_value(sqlite3_stmt* stmt, int param, const SqlValue& value,
                              std::string& error) {
    int rc = SQLITE_OK;
    switch (value.kind) {
        case SqlValueKind::Null:
            rc = sqlite3_bind_null(stmt, param);
            break;
        case SqlValueKind::Boolean:
            rc = sqlite3_bind_int(stmt, param, value.boolean ? 1 : 0);
            break;
        case SqlValueKind::Number:
            if (value.number == std::floor(value.number) && value.number >= -9007199254740992.0 &&
                value.number <= 9007199254740992.0) {
                rc = sqlite3_bind_int64(stmt, param, (sqlite3_int64)value.number);
            } else {
                rc = sqlite3_bind_double(stmt, param, value.number);
            }
            break;
        case SqlValueKind::String:
            rc = sqlite3_bind_text(stmt, param, value.bytes.data(), (int)value.bytes.size(),
                                   SQLITE_TRANSIENT);
            break;
        case SqlValueKind::Blob:
            rc = sqlite3_bind_blob(stmt, param, value.bytes.data(), (int)value.bytes.size(),
                                   SQLITE_TRANSIENT);
            break;
    }

    if (rc != SQLITE_OK) {
        error = "sqlite3_bind failed for parameter " + std::to_string(param) + ": " +
                sqlite3_errmsg(sqlite3_db_handle(stmt));
        return false;
    }
    return true;
}

static bool bind_copied_args(sqlite3_stmt* stmt, const std::vector<SqlValue>& values,
                             std::string& error) {
    int nparams = sqlite3_bind_parameter_count(stmt);
    int nargs = (int)values.size();
    if (nargs > nparams) nargs = nparams;
    for (int i = 0; i < nargs; i++) {
        if (!bind_copied_value(stmt, i + 1, values[(size_t)i], error)) return false;
    }
    return true;
}

static SqlValue copy_column(sqlite3_stmt* stmt, int col) {
    SqlValue value;
    switch (sqlite3_column_type(stmt, col)) {
        case SQLITE_INTEGER:
            value.kind = SqlValueKind::Number;
            value.number = (double)sqlite3_column_int64(stmt, col);
            break;
        case SQLITE_FLOAT:
            value.kind = SqlValueKind::Number;
            value.number = sqlite3_column_double(stmt, col);
            break;
        case SQLITE_TEXT:
            value.kind = SqlValueKind::String;
            value.bytes.assign((const char*)sqlite3_column_text(stmt, col),
                               (size_t)sqlite3_column_bytes(stmt, col));
            break;
        case SQLITE_BLOB:
            value.kind = SqlValueKind::Blob;
            value.bytes.assign((const char*)sqlite3_column_blob(stmt, col),
                               (size_t)sqlite3_column_bytes(stmt, col));
            break;
        case SQLITE_NULL:
        default:
            value.kind = SqlValueKind::Null;
            break;
    }
    return value;
}

static SqlRow copy_row(sqlite3_stmt* stmt) {
    int ncols = sqlite3_column_count(stmt);
    SqlRow row;
    row.names.reserve((size_t)ncols);
    row.values.reserve((size_t)ncols);
    for (int i = 0; i < ncols; i++) {
        const char* name = sqlite3_column_name(stmt, i);
        row.names.emplace_back(name ? name : "");
        row.values.push_back(copy_column(stmt, i));
    }
    return row;
}

static void push_sql_value(lua_State* L, const SqlValue& value) {
    switch (value.kind) {
        case SqlValueKind::Null:
            lua_pushnil(L);
            break;
        case SqlValueKind::Boolean:
            lua_pushboolean(L, value.boolean);
            break;
        case SqlValueKind::Number:
            lua_pushnumber(L, value.number);
            break;
        case SqlValueKind::String:
            lua_pushlstring(L, value.bytes.data(), value.bytes.size());
            break;
        case SqlValueKind::Blob: {
            void* buf = lua_newbuffer(L, value.bytes.size());
            if (!value.bytes.empty()) memcpy(buf, value.bytes.data(), value.bytes.size());
            break;
        }
    }
}

static void push_sql_row(lua_State* L, const SqlRow& row) {
    lua_createtable(L, 0, (int)row.values.size());
    for (size_t i = 0; i < row.values.size(); i++) {
        push_sql_value(L, row.values[i]);
        lua_setfield(L, -2, row.names[i].c_str());
    }
}

enum class SqlAsyncKind { Open, CloseDb, Exec, Query, Prepare, Bind, Step, Reset, All, Run };

struct SqlAsyncOp {
    uv_work_t work;
    lua_State* L = nullptr;
    int threadRef = LUA_NOREF;
    int selfRef = LUA_NOREF;
    EryxRuntime* rt = nullptr;
    SqlAsyncKind kind = SqlAsyncKind::Query;
    LuaDatabase* db = nullptr;
    LuaStatement* stmt = nullptr;
    bool markedDbBusy = false;
    bool markedStmtBusy = false;
    std::string path;
    std::string sql;
    std::vector<SqlValue> bindings;
    std::vector<SqlRow> rows;
    SqlRow row;
    bool hasRow = false;
    sqlite3* openedDb = nullptr;
    sqlite3_stmt* preparedStmt = nullptr;
    std::string error;
};

static bool begin_sql_async(lua_State* L, SqlAsyncOp* op, int selfIdx) {
    op->L = L;
    op->rt = eryx_get_runtime(L);
    op->work.data = op;

    lua_pushthread(L);
    op->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    if (selfIdx != 0) {
        lua_pushvalue(L, selfIdx);
        op->selfRef = lua_ref(L, -1);
        lua_pop(L, 1);
    }

    return uv_queue_work(
               op->rt->loop, &op->work,
               [](uv_work_t* req) {
                   SqlAsyncOp* op = (SqlAsyncOp*)req->data;
                   int rc = SQLITE_OK;

                   switch (op->kind) {
                       case SqlAsyncKind::Open:
                           rc = sqlite3_open(op->path.c_str(), &op->openedDb);
                           if (rc != SQLITE_OK) {
                               op->error = "Failed to open database: ";
                               op->error +=
                                   op->openedDb ? sqlite3_errmsg(op->openedDb) : "out of memory";
                               if (op->openedDb) sqlite3_close(op->openedDb);
                               op->openedDb = nullptr;
                           }
                           break;

                       case SqlAsyncKind::CloseDb:
                           rc = sqlite3_close_v2(op->db->db);
                           if (rc != SQLITE_OK)
                               op->error = std::string("sqlite3_close failed: ") +
                                           sqlite3_errmsg(op->db->db);
                           break;

                       case SqlAsyncKind::Exec: {
                           sqlite3_stmt* stmt = nullptr;
                           rc = sqlite3_prepare_v2(op->db->db, op->sql.c_str(), -1, &stmt, nullptr);
                           if (rc != SQLITE_OK) {
                               op->error = std::string("sqlite3 prepare error: ") +
                                           sqlite3_errmsg(op->db->db);
                               break;
                           }
                           if (!bind_copied_args(stmt, op->bindings, op->error)) {
                               sqlite3_finalize(stmt);
                               break;
                           }
                           while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                           }
                           sqlite3_finalize(stmt);
                           if (rc != SQLITE_DONE)
                               op->error =
                                   std::string("sqlite3 step error: ") + sqlite3_errmsg(op->db->db);
                           break;
                       }

                       case SqlAsyncKind::Query: {
                           sqlite3_stmt* stmt = nullptr;
                           rc = sqlite3_prepare_v2(op->db->db, op->sql.c_str(), -1, &stmt, nullptr);
                           if (rc != SQLITE_OK) {
                               op->error = std::string("sqlite3 prepare error: ") +
                                           sqlite3_errmsg(op->db->db);
                               break;
                           }
                           if (!bind_copied_args(stmt, op->bindings, op->error)) {
                               sqlite3_finalize(stmt);
                               break;
                           }
                           while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                               op->rows.push_back(copy_row(stmt));
                           }
                           sqlite3_finalize(stmt);
                           if (rc != SQLITE_DONE)
                               op->error =
                                   std::string("sqlite3 step error: ") + sqlite3_errmsg(op->db->db);
                           break;
                       }

                       case SqlAsyncKind::Prepare:
                           rc = sqlite3_prepare_v2(op->db->db, op->sql.c_str(), -1,
                                                   &op->preparedStmt, nullptr);
                           if (rc != SQLITE_OK)
                               op->error = std::string("sqlite3 prepare error: ") +
                                           sqlite3_errmsg(op->db->db);
                           break;

                       case SqlAsyncKind::Bind:
                           sqlite3_reset(op->stmt->stmt);
                           sqlite3_clear_bindings(op->stmt->stmt);
                           bind_copied_args(op->stmt->stmt, op->bindings, op->error);
                           break;

                       case SqlAsyncKind::Step:
                           rc = sqlite3_step(op->stmt->stmt);
                           if (rc == SQLITE_ROW) {
                               op->hasRow = true;
                               op->row = copy_row(op->stmt->stmt);
                           } else if (rc != SQLITE_DONE) {
                               op->error = std::string("sqlite3 step error: ") +
                                           sqlite3_errmsg(op->stmt->db);
                           }
                           break;

                       case SqlAsyncKind::Reset:
                           rc = sqlite3_reset(op->stmt->stmt);
                           if (rc != SQLITE_OK)
                               op->error = std::string("sqlite3 reset error: ") +
                                           sqlite3_errmsg(op->stmt->db);
                           break;

                       case SqlAsyncKind::All:
                           sqlite3_reset(op->stmt->stmt);
                           sqlite3_clear_bindings(op->stmt->stmt);
                           if (!bind_copied_args(op->stmt->stmt, op->bindings, op->error)) break;
                           while ((rc = sqlite3_step(op->stmt->stmt)) == SQLITE_ROW) {
                               op->rows.push_back(copy_row(op->stmt->stmt));
                           }
                           if (rc != SQLITE_DONE)
                               op->error = std::string("sqlite3 step error: ") +
                                           sqlite3_errmsg(op->stmt->db);
                           break;

                       case SqlAsyncKind::Run:
                           sqlite3_reset(op->stmt->stmt);
                           sqlite3_clear_bindings(op->stmt->stmt);
                           if (!bind_copied_args(op->stmt->stmt, op->bindings, op->error)) break;
                           rc = sqlite3_step(op->stmt->stmt);
                           if (rc != SQLITE_DONE && rc != SQLITE_ROW)
                               op->error = std::string("sqlite3 step error: ") +
                                           sqlite3_errmsg(op->stmt->db);
                           break;
                   }
               },
               [](uv_work_t* req, int) {
                   SqlAsyncOp* op = (SqlAsyncOp*)req->data;
                   lua_State* L = op->L;

                   if (op->markedStmtBusy) op->stmt->busy = false;
                   if (op->markedDbBusy && op->db) op->db->busy = false;

                   int nresults = 0;
                   bool inError = false;

                   if (!op->error.empty()) {
                       lua_pushlstring(L, op->error.data(), op->error.size());
                       nresults = 1;
                       inError = true;
                   } else {
                       switch (op->kind) {
                           case SqlAsyncKind::Open: {
                               LuaDatabase* ud = (LuaDatabase*)lua_newuserdatadtor(
                                   L, sizeof(LuaDatabase), db_dtor);
                               ud->db = op->openedDb;
                               ud->busy = false;
                               ud->inTransaction = false;
                               luaL_getmetatable(L, MT_DATABASE);
                               lua_setmetatable(L, -2);
                               nresults = 1;
                               break;
                           }

                           case SqlAsyncKind::CloseDb:
                               op->db->db = nullptr;
                               nresults = 0;
                               break;

                           case SqlAsyncKind::Query:
                           case SqlAsyncKind::All:
                               lua_createtable(L, (int)op->rows.size(), 0);
                               for (size_t i = 0; i < op->rows.size(); i++) {
                                   push_sql_row(L, op->rows[i]);
                                   lua_rawseti(L, -2, (int)i + 1);
                               }
                               nresults = 1;
                               break;

                           case SqlAsyncKind::Prepare: {
                               LuaStatement* sud = (LuaStatement*)lua_newuserdatadtor(
                                   L, sizeof(LuaStatement), stmt_dtor);
                               sud->stmt = op->preparedStmt;
                               sud->db = op->db->db;
                               sud->owner = op->db;
                               sud->busy = false;
                               luaL_getmetatable(L, MT_STATEMENT);
                               lua_setmetatable(L, -2);
                               nresults = 1;
                               break;
                           }

                           case SqlAsyncKind::Bind:
                           case SqlAsyncKind::Reset:
                               lua_getref(L, op->selfRef);
                               nresults = 1;
                               break;

                           case SqlAsyncKind::Step:
                               if (op->hasRow) {
                                   push_sql_row(L, op->row);
                               } else {
                                   lua_pushnil(L);
                               }
                               nresults = 1;
                               break;

                           case SqlAsyncKind::Exec:
                           case SqlAsyncKind::Run:
                               nresults = 0;
                               break;
                       }
                   }

                   if (op->selfRef != LUA_NOREF) lua_unref(L, op->selfRef);
                   eryx_push_thread(op->rt, op->threadRef, nresults, inError);
                   delete op;
               }) == 0;
}

static void mark_db_busy(SqlAsyncOp* op, LuaDatabase* db) {
    op->db = db;
    db->busy = true;
    op->markedDbBusy = true;
}

static void mark_stmt_busy(SqlAsyncOp* op, LuaStatement* stmt) {
    op->stmt = stmt;
    stmt->busy = true;
    op->markedStmtBusy = true;
    if (stmt->owner) {
        op->db = stmt->owner;
        stmt->owner->busy = true;
        op->markedDbBusy = true;
    }
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
            luaL_error(L, "unsupported type for SQLite parameter %d: %s", param,
                       luaL_typename(L, idx));
            return;
    }
    if (rc != SQLITE_OK) {
        luaL_error(L, "sqlite3_bind failed for parameter %d: %s", param,
                   sqlite3_errmsg(sqlite3_db_handle(stmt)));
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
    std::string path = luaL_checkpathlike(L, 1);

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Open;
    op->path = path;
    if (!begin_sql_async(L, op, 0)) {
        delete op;
        luaL_error(L, "failed to queue sqlite3 open");
    }
    return lua_yield(L, 0);
}

static int sql_version(lua_State* L) {
    lua_pushstring(L, sqlite3_libversion());
    return 1;
}

// ── Database methods ──────────────────────────────────────────────────────────

// Destructor called by Luau GC (lua_newuserdatadtor).
static void db_dtor(void* ud) {
    LuaDatabase* d = (LuaDatabase*)ud;
    if (d->db) {
        sqlite3_close_v2(d->db);
        d->db = nullptr;
    }
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
    if (!ud->db) return 0;
    if (ud->busy) luaL_error(L, "database is already busy");

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::CloseDb;
    mark_db_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 close");
    }
    return lua_yield(L, 0);
}

static int db_isopen(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    lua_pushboolean(L, ud->db != nullptr);
    return 1;
}

// db:exec(sql) - execute one or more SQL statements, no results
static int db_exec(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_available(L, ud);
    const char* sql = luaL_checkstring(L, 2);

    if (ud->inTransaction) {
        sqlite3_stmt* stmt;
        int rc = sqlite3_prepare_v2(ud->db, sql, -1, &stmt, nullptr);
        if (rc != SQLITE_OK) {
            luaL_error(L, "sqlite3 prepare error: %s", sqlite3_errmsg(ud->db));
        }

        bind_args(L, stmt, 3);

        while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        }

        sqlite3_finalize(stmt);

        if (rc != SQLITE_DONE) {
            luaL_error(L, "sqlite3 step error: %s", sqlite3_errmsg(ud->db));
        }

        return 0;
    }

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Exec;
    op->sql = sql;
    op->bindings = copy_bind_args(L, 3);
    mark_db_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 exec");
    }
    return lua_yield(L, 0);
}

// db:query(sql, ...params) - execute and return all rows
static int db_query(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_available(L, ud);
    const char* sql = luaL_checkstring(L, 2);

    if (ud->inTransaction) {
        sqlite3_stmt* stmt;
        int rc = sqlite3_prepare_v2(ud->db, sql, -1, &stmt, nullptr);
        if (rc != SQLITE_OK) {
            luaL_error(L, "sqlite3 prepare error: %s", sqlite3_errmsg(ud->db));
        }

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

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Query;
    op->sql = sql;
    op->bindings = copy_bind_args(L, 3);
    mark_db_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 query");
    }
    return lua_yield(L, 0);
}

// db:prepare(sql) -> Statement
static int db_prepare(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_available(L, ud);
    const char* sql = luaL_checkstring(L, 2);

    if (ud->inTransaction) {
        sqlite3_stmt* stmt;
        int rc = sqlite3_prepare_v2(ud->db, sql, -1, &stmt, nullptr);
        if (rc != SQLITE_OK) {
            luaL_error(L, "sqlite3 prepare error: %s", sqlite3_errmsg(ud->db));
        }

        LuaStatement* sud = (LuaStatement*)lua_newuserdatadtor(L, sizeof(LuaStatement), stmt_dtor);
        sud->stmt = stmt;
        sud->db = ud->db;
        sud->owner = ud;
        sud->busy = false;

        luaL_getmetatable(L, MT_STATEMENT);
        lua_setmetatable(L, -2);
        return 1;
    }

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Prepare;
    op->sql = sql;
    mark_db_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 prepare");
    }
    return lua_yield(L, 0);
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

// db:transaction(fn) -> ...results
// Wraps fn() in BEGIN/COMMIT, rolling back on error.
static int db_transaction(lua_State* L) {
    LuaDatabase* ud = check_db(L, 1);
    check_db_available(L, ud);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // BEGIN
    char* errmsg = nullptr;
    int rc = sqlite3_exec(ud->db, "BEGIN", nullptr, nullptr, &errmsg);
    if (rc != SQLITE_OK) {
        std::string err = "sqlite3 BEGIN failed: ";
        if (errmsg) {
            err += errmsg;
            sqlite3_free(errmsg);
        }
        luaL_error(L, "%s", err.c_str());
    }

    // Call the user function with the database as its argument. Methods invoked
    // from inside the callback use synchronous sqlite3 calls because this C
    // pcall boundary cannot suspend and resume the transaction body.
    ud->inTransaction = true;
    lua_pushvalue(L, 2);                 // push fn
    lua_pushvalue(L, 1);                 // push db (self)
    int top_before = lua_gettop(L) - 2;  // stack top before fn + db
    int status = eryx_pcall(L, 1, LUA_MULTRET, 0);
    ud->inTransaction = false;

    if (status != 0) {
        // ROLLBACK on error
        sqlite3_exec(ud->db, "ROLLBACK", nullptr, nullptr, nullptr);
        lua_error(L);  // re-raise the error from pcall
        return 0;
    }

    // COMMIT on success
    rc = sqlite3_exec(ud->db, "COMMIT", nullptr, nullptr, &errmsg);
    if (rc != SQLITE_OK) {
        sqlite3_exec(ud->db, "ROLLBACK", nullptr, nullptr, nullptr);
        std::string err = "sqlite3 COMMIT failed: ";
        if (errmsg) {
            err += errmsg;
            sqlite3_free(errmsg);
        }
        luaL_error(L, "%s", err.c_str());
    }

    // Return whatever the function returned
    return lua_gettop(L) - top_before;
}

static int db_index(lua_State* L) {
    // Fall through to metatable for methods
    return eryx_metatable_index(L);
}

// ── Statement methods ─────────────────────────────────────────────────────────

// Destructor called by Luau GC (lua_newuserdatadtor).
static void stmt_dtor(void* ud) {
    LuaStatement* s = (LuaStatement*)ud;
    if (s->stmt) {
        sqlite3_finalize(s->stmt);
        s->stmt = nullptr;
    }
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
    check_stmt_available(L, ud);

    if (ud->owner && ud->owner->inTransaction) {
        sqlite3_reset(ud->stmt);
        sqlite3_clear_bindings(ud->stmt);
        bind_args(L, ud->stmt, 2);

        lua_pushvalue(L, 1);
        return 1;
    }

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Bind;
    op->bindings = copy_bind_args(L, 2);
    mark_stmt_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        if (ud->owner) ud->owner->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 bind");
    }
    return lua_yield(L, 0);
}

// stmt:step() -> Row | nil
static int stmt_step(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_available(L, ud);

    if (ud->owner && ud->owner->inTransaction) {
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

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Step;
    mark_stmt_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        if (ud->owner) ud->owner->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 step");
    }
    return lua_yield(L, 0);
}

static int stmt_iter(lua_State* L) {
    check_stmt_valid(L, check_stmt(L, 1));
    lua_pushcfunction(L, stmt_step, "SqliteStatement.next");
    lua_pushvalue(L, 1);
    return 2;
}

// stmt:reset() -> stmt
static int stmt_reset(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_available(L, ud);

    if (ud->owner && ud->owner->inTransaction) {
        sqlite3_reset(ud->stmt);
        lua_pushvalue(L, 1);
        return 1;
    }

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Reset;
    mark_stmt_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        if (ud->owner) ud->owner->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 reset");
    }
    return lua_yield(L, 0);
}

// stmt:all(...params) -> { Row }
static int stmt_all(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_available(L, ud);

    if (ud->owner && ud->owner->inTransaction) {
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

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::All;
    op->bindings = copy_bind_args(L, 2);
    mark_stmt_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        if (ud->owner) ud->owner->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 all");
    }
    return lua_yield(L, 0);
}

// stmt:run(...params) -> ()
static int stmt_run(lua_State* L) {
    LuaStatement* ud = check_stmt(L, 1);
    check_stmt_available(L, ud);

    if (ud->owner && ud->owner->inTransaction) {
        sqlite3_reset(ud->stmt);
        sqlite3_clear_bindings(ud->stmt);
        bind_args(L, ud->stmt, 2);

        int rc = sqlite3_step(ud->stmt);
        if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
            luaL_error(L, "sqlite3 step error: %s", sqlite3_errmsg(ud->db));
        }

        return 0;
    }

    SqlAsyncOp* op = new SqlAsyncOp;
    op->kind = SqlAsyncKind::Run;
    op->bindings = copy_bind_args(L, 2);
    mark_stmt_busy(op, ud);
    if (!begin_sql_async(L, op, 1)) {
        ud->busy = false;
        if (ud->owner) ud->owner->busy = false;
        delete op;
        luaL_error(L, "failed to queue sqlite3 run");
    }
    return lua_yield(L, 0);
}

static int stmt_index(lua_State* L) {
    // Fall through to metatable for methods
    return eryx_metatable_index(L);
}

// ── Module entry ──────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_sqlite3(lua_State* L) {
    // -- SqliteDatabase metatable --
    luaL_newmetatable(L, MT_DATABASE);
    lua_pushcfunction(L, db_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, db_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    // Note: __gc is not supported in Luau; cleanup uses lua_newuserdatadtor

    lua_pushcfunction(L, db_exec, "exec");
    lua_setfield(L, -2, "exec");
    lua_pushcfunction(L, db_query, "query");
    lua_setfield(L, -2, "query");
    lua_pushcfunction(L, db_prepare, "prepare");
    lua_setfield(L, -2, "prepare");
    lua_pushcfunction(L, db_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, db_isopen, "isOpen");
    lua_setfield(L, -2, "isOpen");
    lua_pushcfunction(L, db_lastinsertid, "lastInsertId");
    lua_setfield(L, -2, "lastInsertId");
    lua_pushcfunction(L, db_changes, "changes");
    lua_setfield(L, -2, "changes");
    lua_pushcfunction(L, db_transaction, "transaction");
    lua_setfield(L, -2, "transaction");
    lua_pop(L, 1);

    // -- SqliteStatement metatable --
    luaL_newmetatable(L, MT_STATEMENT);
    lua_pushcfunction(L, stmt_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, stmt_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, stmt_iter, "__iter");
    lua_setfield(L, -2, "__iter");

    // Note: __gc is not supported in Luau; cleanup uses lua_newuserdatadtor

    lua_pushcfunction(L, stmt_bind, "bind");
    lua_setfield(L, -2, "bind");
    lua_pushcfunction(L, stmt_step, "step");
    lua_setfield(L, -2, "step");
    lua_pushcfunction(L, stmt_reset, "reset");
    lua_setfield(L, -2, "reset");
    lua_pushcfunction(L, stmt_all, "all");
    lua_setfield(L, -2, "all");
    lua_pushcfunction(L, stmt_run, "run");
    lua_setfield(L, -2, "run");
    lua_pop(L, 1);

    // -- Module table --
    lua_newtable(L);
    lua_pushcfunction(L, sql_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, sql_version, "version");
    lua_setfield(L, -2, "version");

    lua_setreadonly(L, -1, true);
    return 1;
}
