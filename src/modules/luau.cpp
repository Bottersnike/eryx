// _luau.cpp  –  Luau parser / AST module
//
// Exposes the Luau parser to Luau scripts, returning the AST as a nested
// table structure that can be inspected, transformed, or pretty-printed.
//
// API:
//
//   luau.parse(source [, options])  -> ParseResult
//
//     source  : string         – Luau source code to parse
//     options : { captureComments: boolean? }?
//
//     Returns:
//       {
//         root     : AstNode,            -- the top-level Block node
//         errors   : { { message: string, location: Location }... },
//         comments : { { type: string, location: Location }... }?,
//         lines    : number,
//       }
//
//   luau.prettyPrint(source)  -> string
//
//     Round-trips source through the parser and pretty-printer.
//
// Every AST node is a table with at least:
//   type     : string    -- e.g. "Block", "StatLocal", "ExprCall", ...
//   location : { start: {line,column}, ["end"]: {line,column} }
// plus node-specific fields described below.
// ---------------------------------------------------------------------------

#include <cstdio>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "../LuaUtil.hpp"
#include "../runtime/lconfig.hpp"
#include "../runtime/lresolve.hpp"
#include "Luau/Allocator.h"
#include "Luau/Ast.h"
#include "Luau/Bytecode.h"
#include "Luau/BytecodeBuilder.h"
#include "Luau/Compiler.h"
#include "Luau/Lexer.h"
#include "Luau/Location.h"
#include "Luau/ParseOptions.h"
#include "Luau/ParseResult.h"
#include "Luau/Parser.h"
#include "Luau/PrettyPrinter.h"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"

using namespace Luau;

// ---------------------------------------------------------------------------
// Module metadata
// ---------------------------------------------------------------------------
static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_luau",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Helpers – push a Location / Position onto the Lua stack
// ---------------------------------------------------------------------------
static void push_position(lua_State* L, const Position& pos) {
    lua_createtable(L, 0, 2);
    lua_pushinteger(L, pos.line + 1);  // 1-based for Luau users
    lua_setfield(L, -2, "line");
    lua_pushinteger(L, pos.column + 1);  // 1-based
    lua_setfield(L, -2, "column");
}

static void push_location(lua_State* L, const Location& loc) {
    lua_createtable(L, 0, 2);
    push_position(L, loc.begin);
    lua_setfield(L, -2, "start");
    push_position(L, loc.end);
    lua_setfield(L, -2, "end");
}

// Start a new node table with `type` and `location` pre-filled.
static void begin_node(lua_State* L, const char* type, const Location& loc) {
    lua_createtable(L, 0, 8);
    lua_pushstring(L, type);
    lua_setfield(L, -2, "type");
    push_location(L, loc);
    lua_setfield(L, -2, "location");
}

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static void push_node(lua_State* L, AstNode* node);
static void push_expr(lua_State* L, AstExpr* expr);
static void push_stat(lua_State* L, AstStat* stat);
static void push_type(lua_State* L, AstType* type);
static void push_typepack(lua_State* L, AstTypePack* tp);
static void push_local(lua_State* L, AstLocal* local);

// Stack safety: ensure room for at least `n` extra Lua-stack slots.
// Raises a clean Lua error if the stack cannot grow (tree too deep).
static void ensure_stack(lua_State* L, int n) {
    if (!lua_checkstack(L, n))
        luaL_error(L, "luau.parse: stack overflow during AST serialization (tree too deep)");
}

// Push an AstArray of pointers as a Lua array.
template <typename T>
static void push_array(lua_State* L, const AstArray<T*>& arr, void (*push_fn)(lua_State*, T*)) {
    lua_createtable(L, (int)arr.size, 0);
    for (size_t i = 0; i < arr.size; i++) {
        push_fn(L, arr.data[i]);
        lua_rawseti(L, -2, (int)(i + 1));
    }
}

// Push an AstName (nullable).
static void push_name(lua_State* L, const AstName& name) {
    if (name.value)
        lua_pushstring(L, name.value);
    else
        lua_pushnil(L);
}

static void push_optional_name(lua_State* L, const std::optional<AstName>& name) {
    if (name)
        push_name(L, *name);
    else
        lua_pushnil(L);
}

static void push_optional_location(lua_State* L, const std::optional<Location>& loc) {
    if (loc)
        push_location(L, *loc);
    else
        lua_pushnil(L);
}

static const char* table_access_to_string(AstTableAccess access) {
    switch (access) {
        case AstTableAccess::Read:
            return "Read";
        case AstTableAccess::Write:
            return "Write";
        case AstTableAccess::ReadWrite:
        default:
            return "ReadWrite";
    }
}

static const char* attr_type_to_string(AstAttr::Type type) {
    switch (type) {
        case AstAttr::Checked:
            return "Checked";
        case AstAttr::Native:
            return "Native";
        case AstAttr::Deprecated:
            return "Deprecated";
        case AstAttr::Unknown:
        default:
            return "Unknown";
    }
}

static const char* number_parse_result_to_string(ConstantNumberParseResult result) {
    switch (result) {
        case ConstantNumberParseResult::Ok:
            return "Ok";
        case ConstantNumberParseResult::Imprecise:
            return "Imprecise";
        case ConstantNumberParseResult::Malformed:
            return "Malformed";
        case ConstantNumberParseResult::BinOverflow:
            return "BinOverflow";
        case ConstantNumberParseResult::HexOverflow:
            return "HexOverflow";
        default:
            return "Unknown";
    }
}

static const char* quote_style_to_string(AstExprConstantString::QuoteStyle quoteStyle) {
    switch (quoteStyle) {
        case AstExprConstantString::QuotedSimple:
            return "QuotedSimple";
        case AstExprConstantString::QuotedSingle:
            return "QuotedSingle";
        case AstExprConstantString::QuotedRaw:
            return "QuotedRaw";
        case AstExprConstantString::Unquoted:
            return "Unquoted";
        default:
            return "Unknown";
    }
}

static void push_type_or_pack(lua_State* L, const AstTypeOrPack& v) {
    lua_createtable(L, 0, 2);
    if (v.type) {
        lua_pushstring(L, "Type");
        lua_setfield(L, -2, "kind");
        push_type(L, v.type);
        lua_setfield(L, -2, "value");
    } else if (v.typePack) {
        lua_pushstring(L, "TypePack");
        lua_setfield(L, -2, "kind");
        push_typepack(L, v.typePack);
        lua_setfield(L, -2, "value");
    } else {
        lua_pushstring(L, "Unknown");
        lua_setfield(L, -2, "kind");
        lua_pushnil(L);
        lua_setfield(L, -2, "value");
    }
}

static void push_ast_attr(lua_State* L, AstAttr* attr) {
    if (!attr) {
        lua_pushnil(L);
        return;
    }
    lua_createtable(L, 0, 6);
    lua_pushstring(L, attr_type_to_string(attr->type));
    lua_setfield(L, -2, "type");
    push_location(L, attr->location);
    lua_setfield(L, -2, "location");
    push_name(L, attr->name);
    lua_setfield(L, -2, "name");
    push_array<AstExpr>(L, attr->args, push_expr);
    lua_setfield(L, -2, "args");

    if (attr->type == AstAttr::Deprecated) {
        AstAttr::DeprecatedInfo info = attr->deprecatedInfo();
        lua_createtable(L, 0, 3);
        lua_pushboolean(L, info.deprecated);
        lua_setfield(L, -2, "deprecated");
        if (info.use.has_value()) {
            lua_pushlstring(L, info.use->data(), info.use->size());
            lua_setfield(L, -2, "use");
        }
        if (info.reason.has_value()) {
            lua_pushlstring(L, info.reason->data(), info.reason->size());
            lua_setfield(L, -2, "reason");
        }
        lua_setfield(L, -2, "deprecatedInfo");
    }
}

static void push_generic_type(lua_State* L, AstGenericType* generic) {
    if (!generic) {
        lua_pushnil(L);
        return;
    }
    lua_createtable(L, 0, 3);
    push_name(L, generic->name);
    lua_setfield(L, -2, "name");
    push_location(L, generic->location);
    lua_setfield(L, -2, "location");
    if (generic->defaultValue) {
        push_type(L, generic->defaultValue);
        lua_setfield(L, -2, "default");
    }
}

static void push_generic_typepack(lua_State* L, AstGenericTypePack* generic) {
    if (!generic) {
        lua_pushnil(L);
        return;
    }
    lua_createtable(L, 0, 3);
    push_name(L, generic->name);
    lua_setfield(L, -2, "name");
    push_location(L, generic->location);
    lua_setfield(L, -2, "location");
    if (generic->defaultValue) {
        push_typepack(L, generic->defaultValue);
        lua_setfield(L, -2, "default");
    }
}

static void push_type_list(lua_State* L, const AstTypeList& list) {
    lua_createtable(L, 0, 2);
    lua_createtable(L, (int)list.types.size, 0);
    for (size_t i = 0; i < list.types.size; i++) {
        push_type(L, list.types.data[i]);
        lua_rawseti(L, -2, (int)(i + 1));
    }
    lua_setfield(L, -2, "types");
    if (list.tailType) {
        push_typepack(L, list.tailType);
        lua_setfield(L, -2, "tail");
    }
}

static void set_stat_common(lua_State* L, AstStat* stat) {
    lua_pushboolean(L, stat->hasSemicolon);
    lua_setfield(L, -2, "hasSemicolon");
}

// ---------------------------------------------------------------------------
// Type serialisation
// ---------------------------------------------------------------------------
static void push_type(lua_State* L, AstType* type) {
    if (!type) {
        lua_pushnil(L);
        return;
    }
    ensure_stack(L, 20);

    if (auto* t = type->as<AstTypeReference>()) {
        begin_node(L, "TypeReference", t->location);
        lua_pushboolean(L, t->hasParameterList);
        lua_setfield(L, -2, "hasParameterList");
        push_name(L, t->name);
        lua_setfield(L, -2, "name");
        push_location(L, t->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        if (t->prefix) {
            push_name(L, *t->prefix);
            lua_setfield(L, -2, "prefix");
        }
        if (t->prefixLocation) {
            push_location(L, *t->prefixLocation);
            lua_setfield(L, -2, "prefixLocation");
        }
        if (t->parameters.size > 0) {
            lua_createtable(L, (int)t->parameters.size, 0);
            for (size_t i = 0; i < t->parameters.size; i++) {
                push_type_or_pack(L, t->parameters.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "parameters");
        }
    } else if (auto* t = type->as<AstTypeTable>()) {
        begin_node(L, "TypeTable", t->location);
        lua_createtable(L, (int)t->props.size, 0);
        for (size_t i = 0; i < t->props.size; i++) {
            lua_createtable(L, 0, 5);
            push_name(L, t->props.data[i].name);
            lua_setfield(L, -2, "name");
            push_type(L, t->props.data[i].type);
            lua_setfield(L, -2, "type");
            push_location(L, t->props.data[i].location);
            lua_setfield(L, -2, "location");
            lua_pushstring(L, table_access_to_string(t->props.data[i].access));
            lua_setfield(L, -2, "access");
            if (t->props.data[i].accessLocation) {
                push_location(L, *t->props.data[i].accessLocation);
                lua_setfield(L, -2, "accessLocation");
            }
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "props");
        if (t->indexer) {
            lua_createtable(L, 0, 5);
            push_type(L, t->indexer->indexType);
            lua_setfield(L, -2, "indexType");
            push_type(L, t->indexer->resultType);
            lua_setfield(L, -2, "resultType");
            push_location(L, t->indexer->location);
            lua_setfield(L, -2, "location");
            lua_pushstring(L, table_access_to_string(t->indexer->access));
            lua_setfield(L, -2, "access");
            if (t->indexer->accessLocation) {
                push_location(L, *t->indexer->accessLocation);
                lua_setfield(L, -2, "accessLocation");
            }
            lua_setfield(L, -2, "indexer");
        }
    } else if (auto* t = type->as<AstTypeFunction>()) {
        begin_node(L, "TypeFunction", t->location);
        if (t->attributes.size > 0) {
            lua_createtable(L, (int)t->attributes.size, 0);
            for (size_t i = 0; i < t->attributes.size; i++) {
                push_ast_attr(L, t->attributes.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "attributes");
        }
        if (t->generics.size > 0) {
            lua_createtable(L, (int)t->generics.size, 0);
            for (size_t i = 0; i < t->generics.size; i++) {
                push_generic_type(L, t->generics.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "generics");
        }
        if (t->genericPacks.size > 0) {
            lua_createtable(L, (int)t->genericPacks.size, 0);
            for (size_t i = 0; i < t->genericPacks.size; i++) {
                push_generic_typepack(L, t->genericPacks.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "genericPacks");
        }
        push_type_list(L, t->argTypes);
        lua_setfield(L, -2, "argTypes");
        // arg names (optional per-arg)
        lua_createtable(L, (int)t->argNames.size, 0);
        for (size_t i = 0; i < t->argNames.size; i++) {
            if (t->argNames.data[i].has_value()) {
                lua_createtable(L, 0, 2);
                push_name(L, t->argNames.data[i]->first);
                lua_setfield(L, -2, "name");
                push_location(L, t->argNames.data[i]->second);
                lua_setfield(L, -2, "location");
            } else {
                lua_pushnil(L);
            }
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "argNames");
        // return types
        if (t->returnTypes) {
            push_typepack(L, t->returnTypes);
            lua_setfield(L, -2, "returnTypes");
        }
    } else if (auto* t = type->as<AstTypeTypeof>()) {
        begin_node(L, "TypeTypeof", t->location);
        push_expr(L, t->expr);
        lua_setfield(L, -2, "expr");
    } else if (type->as<AstTypeOptional>()) {
        begin_node(L, "TypeOptional", type->location);
    } else if (auto* t = type->as<AstTypeUnion>()) {
        begin_node(L, "TypeUnion", t->location);
        lua_createtable(L, (int)t->types.size, 0);
        for (size_t i = 0; i < t->types.size; i++) {
            push_type(L, t->types.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "types");
    } else if (auto* t = type->as<AstTypeIntersection>()) {
        begin_node(L, "TypeIntersection", t->location);
        lua_createtable(L, (int)t->types.size, 0);
        for (size_t i = 0; i < t->types.size; i++) {
            push_type(L, t->types.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "types");
    } else if (auto* t = type->as<AstTypeSingletonBool>()) {
        begin_node(L, "TypeSingletonBool", t->location);
        lua_pushboolean(L, t->value);
        lua_setfield(L, -2, "value");
    } else if (auto* t = type->as<AstTypeSingletonString>()) {
        begin_node(L, "TypeSingletonString", t->location);
        lua_pushlstring(L, t->value.data, t->value.size);
        lua_setfield(L, -2, "value");
    } else if (auto* t = type->as<AstTypeGroup>()) {
        begin_node(L, "TypeGroup", t->location);
        push_type(L, t->type);
        lua_setfield(L, -2, "inner");
    } else if (type->as<AstTypeError>()) {
        auto* t = type->as<AstTypeError>();
        begin_node(L, "TypeError", type->location);
        lua_createtable(L, (int)t->types.size, 0);
        for (size_t i = 0; i < t->types.size; i++) {
            push_type(L, t->types.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "types");
        lua_pushboolean(L, t->isMissing);
        lua_setfield(L, -2, "isMissing");
        lua_pushinteger(L, (lua_Integer)t->messageIndex);
        lua_setfield(L, -2, "messageIndex");
    } else {
        begin_node(L, "TypeUnknown", type->location);
    }
}

// ---------------------------------------------------------------------------
// TypePack serialisation
// ---------------------------------------------------------------------------
static void push_typepack(lua_State* L, AstTypePack* tp) {
    if (!tp) {
        lua_pushnil(L);
        return;
    }
    ensure_stack(L, 20);

    if (auto* t = tp->as<AstTypePackExplicit>()) {
        begin_node(L, "TypePackExplicit", t->location);
        lua_createtable(L, (int)t->typeList.types.size, 0);
        for (size_t i = 0; i < t->typeList.types.size; i++) {
            push_type(L, t->typeList.types.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "types");
        if (t->typeList.tailType) {
            push_typepack(L, t->typeList.tailType);
            lua_setfield(L, -2, "tail");
        }
    } else if (auto* t = tp->as<AstTypePackVariadic>()) {
        begin_node(L, "TypePackVariadic", t->location);
        push_type(L, t->variadicType);
        lua_setfield(L, -2, "variadicType");
    } else if (auto* t = tp->as<AstTypePackGeneric>()) {
        begin_node(L, "TypePackGeneric", t->location);
        push_name(L, t->genericName);
        lua_setfield(L, -2, "name");
    } else {
        begin_node(L, "TypePackUnknown", tp->location);
    }
}

// ---------------------------------------------------------------------------
// AstLocal helper
// ---------------------------------------------------------------------------
static void push_local(lua_State* L, AstLocal* local) {
    if (!local) {
        lua_pushnil(L);
        return;
    }
    lua_createtable(L, 0, 7);
    push_name(L, local->name);
    lua_setfield(L, -2, "name");
    push_location(L, local->location);
    lua_setfield(L, -2, "location");
    lua_pushinteger(L, (lua_Integer)local->functionDepth);
    lua_setfield(L, -2, "functionDepth");
    lua_pushinteger(L, (lua_Integer)local->loopDepth);
    lua_setfield(L, -2, "loopDepth");
    lua_pushboolean(L, local->isConst);
    lua_setfield(L, -2, "isConst");
    if (local->annotation) {
        push_type(L, local->annotation);
        lua_setfield(L, -2, "annotation");
    }
    if (local->shadow) {
        lua_createtable(L, 0, 2);
        push_name(L, local->shadow->name);
        lua_setfield(L, -2, "name");
        push_location(L, local->shadow->location);
        lua_setfield(L, -2, "location");
        lua_setfield(L, -2, "shadow");
    }
}

// ---------------------------------------------------------------------------
// Expression serialisation
// ---------------------------------------------------------------------------
static void push_expr(lua_State* L, AstExpr* expr) {
    if (!expr) {
        lua_pushnil(L);
        return;
    }
    ensure_stack(L, 20);

    if (auto* e = expr->as<AstExprGroup>()) {
        begin_node(L, "ExprGroup", e->location);
        push_expr(L, e->expr);
        lua_setfield(L, -2, "expr");
    } else if (expr->as<AstExprConstantNil>()) {
        begin_node(L, "ExprConstantNil", expr->location);
    } else if (auto* e = expr->as<AstExprConstantBool>()) {
        begin_node(L, "ExprConstantBool", e->location);
        lua_pushboolean(L, e->value);
        lua_setfield(L, -2, "value");
    } else if (auto* e = expr->as<AstExprConstantNumber>()) {
        begin_node(L, "ExprConstantNumber", e->location);
        lua_pushnumber(L, e->value);
        lua_setfield(L, -2, "value");
        lua_pushstring(L, number_parse_result_to_string(e->parseResult));
        lua_setfield(L, -2, "parseResult");
    } else if (auto* e = expr->as<AstExprConstantString>()) {
        begin_node(L, "ExprConstantString", e->location);
        lua_pushlstring(L, e->value.data, e->value.size);
        lua_setfield(L, -2, "value");
        lua_pushstring(L, quote_style_to_string(e->quoteStyle));
        lua_setfield(L, -2, "quoteStyle");
        lua_pushboolean(L, e->isQuoted());
        lua_setfield(L, -2, "isQuoted");
    } else if (auto* e = expr->as<AstExprLocal>()) {
        begin_node(L, "ExprLocal", e->location);
        push_local(L, e->local);
        lua_setfield(L, -2, "local");
        lua_pushboolean(L, e->upvalue);
        lua_setfield(L, -2, "upvalue");
    } else if (auto* e = expr->as<AstExprGlobal>()) {
        begin_node(L, "ExprGlobal", e->location);
        push_name(L, e->name);
        lua_setfield(L, -2, "name");
    } else if (expr->as<AstExprVarargs>()) {
        begin_node(L, "ExprVarargs", expr->location);
    } else if (auto* e = expr->as<AstExprCall>()) {
        begin_node(L, "ExprCall", e->location);
        push_expr(L, e->func);
        lua_setfield(L, -2, "func");
        if (e->typeArguments.size > 0) {
            lua_createtable(L, (int)e->typeArguments.size, 0);
            for (size_t i = 0; i < e->typeArguments.size; i++) {
                push_type_or_pack(L, e->typeArguments.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "typeArguments");
        }
        push_array<AstExpr>(L, e->args, push_expr);
        lua_setfield(L, -2, "args");
        lua_pushboolean(L, e->self);
        lua_setfield(L, -2, "self");
        push_location(L, e->argLocation);
        lua_setfield(L, -2, "argLocation");
    } else if (auto* e = expr->as<AstExprIndexName>()) {
        // ---- Iterative index-name chain (a.b.c.d) ----
        std::vector<AstExprIndexName*> idxChain;
        AstExpr* leftmost = expr;
        while (auto* idx = leftmost->as<AstExprIndexName>()) {
            idxChain.push_back(idx);
            leftmost = idx->expr;
        }
        // leftmost is the non-IndexName root; serialise it first.
        push_expr(L, leftmost);
        // Build from innermost to outermost.
        for (int i = (int)idxChain.size() - 1; i >= 0; i--) {
            ensure_stack(L, 20);
            auto* idx = idxChain[i];
            begin_node(L, "ExprIndexName", idx->location);
            // Stack: [..., leftVal, idxTable]
            lua_pushvalue(L, -2);         // copy leftVal
            lua_setfield(L, -2, "expr");  // idxTable.expr = leftVal
            lua_remove(L, -2);            // pop original leftVal
            push_name(L, idx->index);
            lua_setfield(L, -2, "index");
            push_location(L, idx->indexLocation);
            lua_setfield(L, -2, "indexLocation");
            push_position(L, idx->opPosition);
            lua_setfield(L, -2, "opPosition");
            lua_pushlstring(L, &idx->op, 1);
            lua_setfield(L, -2, "op");
            // Stack: [..., idxTable] - becomes leftVal for next level
        }
    } else if (auto* e = expr->as<AstExprIndexExpr>()) {
        begin_node(L, "ExprIndexExpr", e->location);
        push_expr(L, e->expr);
        lua_setfield(L, -2, "expr");
        push_expr(L, e->index);
        lua_setfield(L, -2, "index");
    } else if (auto* e = expr->as<AstExprFunction>()) {
        begin_node(L, "ExprFunction", e->location);
        if (e->attributes.size > 0) {
            lua_createtable(L, (int)e->attributes.size, 0);
            for (size_t i = 0; i < e->attributes.size; i++) {
                push_ast_attr(L, e->attributes.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "attributes");
        }
        push_name(L, e->debugname);
        lua_setfield(L, -2, "debugname");
        // generics
        if (e->generics.size > 0) {
            lua_createtable(L, (int)e->generics.size, 0);
            for (size_t i = 0; i < e->generics.size; i++) {
                push_generic_type(L, e->generics.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "generics");
        }
        if (e->genericPacks.size > 0) {
            lua_createtable(L, (int)e->genericPacks.size, 0);
            for (size_t i = 0; i < e->genericPacks.size; i++) {
                push_generic_typepack(L, e->genericPacks.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "genericPacks");
        }
        // args
        lua_createtable(L, (int)e->args.size, 0);
        for (size_t i = 0; i < e->args.size; i++) {
            push_local(L, e->args.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "args");
        lua_pushboolean(L, e->vararg);
        lua_setfield(L, -2, "vararg");
        push_location(L, e->varargLocation);
        lua_setfield(L, -2, "varargLocation");
        if (e->varargAnnotation) {
            push_typepack(L, e->varargAnnotation);
            lua_setfield(L, -2, "varargAnnotation");
        }
        if (e->returnAnnotation) {
            push_typepack(L, e->returnAnnotation);
            lua_setfield(L, -2, "returnAnnotation");
        }
        if (e->self) {
            push_local(L, e->self);
            lua_setfield(L, -2, "self");
        }
        if (e->argLocation) {
            push_location(L, *e->argLocation);
            lua_setfield(L, -2, "argLocation");
        }
        lua_pushinteger(L, (lua_Integer)e->functionDepth);
        lua_setfield(L, -2, "functionDepth");
        // body
        push_stat(L, e->body);
        lua_setfield(L, -2, "body");
    } else if (auto* e = expr->as<AstExprTable>()) {
        begin_node(L, "ExprTable", e->location);
        lua_createtable(L, (int)e->items.size, 0);
        for (size_t i = 0; i < e->items.size; i++) {
            lua_createtable(L, 0, 3);
            switch (e->items.data[i].kind) {
                case AstExprTable::Item::List:
                    lua_pushstring(L, "List");
                    break;
                case AstExprTable::Item::Record:
                    lua_pushstring(L, "Record");
                    break;
                case AstExprTable::Item::General:
                    lua_pushstring(L, "General");
                    break;
            }
            lua_setfield(L, -2, "kind");
            if (e->items.data[i].key) {
                push_expr(L, e->items.data[i].key);
                lua_setfield(L, -2, "key");
            }
            push_expr(L, e->items.data[i].value);
            lua_setfield(L, -2, "value");
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "items");
    } else if (auto* e = expr->as<AstExprUnary>()) {
        begin_node(L, "ExprUnary", e->location);
        std::string opStr = toString(e->op);
        lua_pushstring(L, opStr.c_str());
        lua_setfield(L, -2, "op");
        push_expr(L, e->expr);
        lua_setfield(L, -2, "expr");
    } else if (auto* e = expr->as<AstExprBinary>()) {
        // ---- Iterative left-spine of binary expr chain ----
        // `a + b + c + d` parses left-leaning; flatten to avoid
        // O(n) recursion depth.
        std::vector<AstExprBinary*> binChain;
        AstExpr* leftmost = expr;
        while (auto* bin = leftmost->as<AstExprBinary>()) {
            binChain.push_back(bin);
            leftmost = bin->left;
        }
        // leftmost is the non-binary leaf; serialise it first.
        push_expr(L, leftmost);
        // Build from innermost to outermost.
        for (int i = (int)binChain.size() - 1; i >= 0; i--) {
            ensure_stack(L, 20);
            auto* bin = binChain[i];
            begin_node(L, "ExprBinary", bin->location);
            std::string opStr = toString(bin->op);
            lua_pushstring(L, opStr.c_str());
            lua_setfield(L, -2, "op");
            // Stack: [..., leftVal, binTable]
            lua_pushvalue(L, -2);         // copy leftVal
            lua_setfield(L, -2, "left");  // binTable.left = leftVal
            lua_remove(L, -2);            // pop original leftVal
            push_expr(L, bin->right);     // right side (recurse normally)
            lua_setfield(L, -2, "right");
            // Stack: [..., binTable] - becomes leftVal for next level
        }
    } else if (auto* e = expr->as<AstExprTypeAssertion>()) {
        begin_node(L, "ExprTypeAssertion", e->location);
        push_expr(L, e->expr);
        lua_setfield(L, -2, "expr");
        push_type(L, e->annotation);
        lua_setfield(L, -2, "annotation");
    } else if (auto* e = expr->as<AstExprIfElse>()) {
        begin_node(L, "ExprIfElse", e->location);
        push_expr(L, e->condition);
        lua_setfield(L, -2, "condition");
        lua_pushboolean(L, e->hasThen);
        lua_setfield(L, -2, "hasThen");
        push_expr(L, e->trueExpr);
        lua_setfield(L, -2, "trueExpr");
        lua_pushboolean(L, e->hasElse);
        lua_setfield(L, -2, "hasElse");
        push_expr(L, e->falseExpr);
        lua_setfield(L, -2, "falseExpr");
    } else if (auto* e = expr->as<AstExprInterpString>()) {
        begin_node(L, "ExprInterpString", e->location);
        // strings
        lua_createtable(L, (int)e->strings.size, 0);
        for (size_t i = 0; i < e->strings.size; i++) {
            lua_pushlstring(L, e->strings.data[i].data, e->strings.data[i].size);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "strings");
        push_array<AstExpr>(L, e->expressions, push_expr);
        lua_setfield(L, -2, "expressions");
    } else if (auto* e = expr->as<AstExprInstantiate>()) {
        begin_node(L, "ExprInstantiate", e->location);
        push_expr(L, e->expr);
        lua_setfield(L, -2, "expr");
        lua_createtable(L, (int)e->typeArguments.size, 0);
        for (size_t i = 0; i < e->typeArguments.size; i++) {
            push_type_or_pack(L, e->typeArguments.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "typeArguments");
    } else if (auto* e = expr->as<AstExprError>()) {
        begin_node(L, "ExprError", e->location);
        push_array<AstExpr>(L, e->expressions, push_expr);
        lua_setfield(L, -2, "expressions");
        lua_pushinteger(L, (lua_Integer)e->messageIndex);
        lua_setfield(L, -2, "messageIndex");
    } else {
        begin_node(L, "ExprUnknown", expr->location);
    }
}

// ---------------------------------------------------------------------------
// Statement serialisation
// ---------------------------------------------------------------------------
static void push_stat(lua_State* L, AstStat* stat) {
    if (!stat) {
        lua_pushnil(L);
        return;
    }
    ensure_stack(L, 20);

    if (auto* s = stat->as<AstStatBlock>()) {
        begin_node(L, "Block", s->location);
        set_stat_common(L, s);
        push_array<AstStat>(L, s->body, push_stat);
        lua_setfield(L, -2, "body");
        lua_pushboolean(L, s->hasEnd);
        lua_setfield(L, -2, "hasEnd");
    } else if (auto* s = stat->as<AstStatIf>()) {
        // ---- Iterative if / elseif chain ----
        // Each elseif is a nested AstStatIf in the else branch.  Rather
        // than recursing (depth == number of elseifs), we collect the
        // chain, build all tables on the Lua stack, then collapse them.
        std::vector<AstStatIf*> ifChain;
        AstStatIf* cur = s;
        while (cur) {
            ifChain.push_back(cur);
            cur = cur->elsebody ? cur->elsebody->as<AstStatIf>() : nullptr;
        }

        for (auto* node : ifChain) {
            ensure_stack(L, 20);
            begin_node(L, "StatIf", node->location);
            set_stat_common(L, node);
            push_expr(L, node->condition);
            lua_setfield(L, -2, "condition");
            push_stat(L, node->thenbody);
            lua_setfield(L, -2, "thenBody");
            if (node->thenLocation) {
                push_location(L, *node->thenLocation);
                lua_setfield(L, -2, "thenLocation");
            }
            if (node->elseLocation) {
                push_location(L, *node->elseLocation);
                lua_setfield(L, -2, "elseLocation");
            }
        }

        // Handle final else body (non-if) on the last node
        AstStatIf* last = ifChain.back();
        if (last->elsebody && !last->elsebody->as<AstStatIf>()) {
            push_stat(L, last->elsebody);
            lua_setfield(L, -2, "elseBody");
        }

        // Collapse: set each table as elseBody of the one below it
        for (int i = (int)ifChain.size() - 1; i > 0; i--) {
            lua_setfield(L, -2, "elseBody");
        }
        // Top of stack is the outermost StatIf table.
    } else if (auto* s = stat->as<AstStatWhile>()) {
        begin_node(L, "StatWhile", s->location);
        set_stat_common(L, s);
        push_expr(L, s->condition);
        lua_setfield(L, -2, "condition");
        push_stat(L, s->body);
        lua_setfield(L, -2, "body");
        lua_pushboolean(L, s->hasDo);
        lua_setfield(L, -2, "hasDo");
        push_location(L, s->doLocation);
        lua_setfield(L, -2, "doLocation");
    } else if (auto* s = stat->as<AstStatRepeat>()) {
        begin_node(L, "StatRepeat", s->location);
        set_stat_common(L, s);
        push_expr(L, s->condition);
        lua_setfield(L, -2, "condition");
        push_stat(L, s->body);
        lua_setfield(L, -2, "body");
        lua_pushboolean(L, s->DEPRECATED_hasUntil);
        lua_setfield(L, -2, "hasUntil");
    } else if (stat->as<AstStatBreak>()) {
        begin_node(L, "StatBreak", stat->location);
        set_stat_common(L, stat);
    } else if (stat->as<AstStatContinue>()) {
        begin_node(L, "StatContinue", stat->location);
        set_stat_common(L, stat);
    } else if (auto* s = stat->as<AstStatReturn>()) {
        begin_node(L, "StatReturn", s->location);
        set_stat_common(L, s);
        push_array<AstExpr>(L, s->list, push_expr);
        lua_setfield(L, -2, "list");
    } else if (auto* s = stat->as<AstStatExpr>()) {
        begin_node(L, "StatExpr", s->location);
        set_stat_common(L, s);
        push_expr(L, s->expr);
        lua_setfield(L, -2, "expr");
    } else if (auto* s = stat->as<AstStatLocal>()) {
        begin_node(L, "StatLocal", s->location);
        set_stat_common(L, s);
        // vars
        lua_createtable(L, (int)s->vars.size, 0);
        for (size_t i = 0; i < s->vars.size; i++) {
            push_local(L, s->vars.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "vars");
        push_array<AstExpr>(L, s->values, push_expr);
        lua_setfield(L, -2, "values");
        if (s->equalsSignLocation) {
            push_location(L, *s->equalsSignLocation);
            lua_setfield(L, -2, "equalsSignLocation");
        }
    } else if (auto* s = stat->as<AstStatFor>()) {
        begin_node(L, "StatFor", s->location);
        set_stat_common(L, s);
        push_local(L, s->var);
        lua_setfield(L, -2, "var");
        push_expr(L, s->from);
        lua_setfield(L, -2, "from");
        push_expr(L, s->to);
        lua_setfield(L, -2, "to");
        if (s->step) {
            push_expr(L, s->step);
            lua_setfield(L, -2, "step");
        }
        push_stat(L, s->body);
        lua_setfield(L, -2, "body");
        lua_pushboolean(L, s->hasDo);
        lua_setfield(L, -2, "hasDo");
        push_location(L, s->doLocation);
        lua_setfield(L, -2, "doLocation");
    } else if (auto* s = stat->as<AstStatForIn>()) {
        begin_node(L, "StatForIn", s->location);
        set_stat_common(L, s);
        lua_createtable(L, (int)s->vars.size, 0);
        for (size_t i = 0; i < s->vars.size; i++) {
            push_local(L, s->vars.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "vars");
        push_array<AstExpr>(L, s->values, push_expr);
        lua_setfield(L, -2, "values");
        push_stat(L, s->body);
        lua_setfield(L, -2, "body");
        lua_pushboolean(L, s->hasIn);
        lua_setfield(L, -2, "hasIn");
        push_location(L, s->inLocation);
        lua_setfield(L, -2, "inLocation");
        lua_pushboolean(L, s->hasDo);
        lua_setfield(L, -2, "hasDo");
        push_location(L, s->doLocation);
        lua_setfield(L, -2, "doLocation");
    } else if (auto* s = stat->as<AstStatAssign>()) {
        begin_node(L, "StatAssign", s->location);
        set_stat_common(L, s);
        push_array<AstExpr>(L, s->vars, push_expr);
        lua_setfield(L, -2, "vars");
        push_array<AstExpr>(L, s->values, push_expr);
        lua_setfield(L, -2, "values");
    } else if (auto* s = stat->as<AstStatCompoundAssign>()) {
        begin_node(L, "StatCompoundAssign", s->location);
        set_stat_common(L, s);
        std::string opStr = toString(s->op);
        lua_pushstring(L, opStr.c_str());
        lua_setfield(L, -2, "op");
        push_expr(L, s->var);
        lua_setfield(L, -2, "var");
        push_expr(L, s->value);
        lua_setfield(L, -2, "value");
    } else if (auto* s = stat->as<AstStatFunction>()) {
        begin_node(L, "StatFunction", s->location);
        set_stat_common(L, s);
        push_expr(L, s->name);
        lua_setfield(L, -2, "name");
        push_expr(L, s->func);
        lua_setfield(L, -2, "func");
    } else if (auto* s = stat->as<AstStatLocalFunction>()) {
        begin_node(L, "StatLocalFunction", s->location);
        set_stat_common(L, s);
        push_local(L, s->name);
        lua_setfield(L, -2, "name");
        push_expr(L, s->func);
        lua_setfield(L, -2, "func");
    } else if (auto* s = stat->as<AstStatTypeAlias>()) {
        begin_node(L, "StatTypeAlias", s->location);
        set_stat_common(L, s);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        push_location(L, s->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        lua_pushboolean(L, s->exported);
        lua_setfield(L, -2, "exported");
        push_type(L, s->type);
        lua_setfield(L, -2, "aliasedType");
        if (s->generics.size > 0) {
            lua_createtable(L, (int)s->generics.size, 0);
            for (size_t i = 0; i < s->generics.size; i++) {
                push_generic_type(L, s->generics.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "generics");
        }
        if (s->genericPacks.size > 0) {
            lua_createtable(L, (int)s->genericPacks.size, 0);
            for (size_t i = 0; i < s->genericPacks.size; i++) {
                push_generic_typepack(L, s->genericPacks.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "genericPacks");
        }
    } else if (auto* s = stat->as<AstStatTypeFunction>()) {
        begin_node(L, "StatTypeFunction", s->location);
        set_stat_common(L, s);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        push_location(L, s->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        push_expr(L, s->body);
        lua_setfield(L, -2, "body");
        lua_pushboolean(L, s->exported);
        lua_setfield(L, -2, "exported");
        lua_pushboolean(L, s->hasErrors);
        lua_setfield(L, -2, "hasErrors");
    } else if (auto* s = stat->as<AstStatDeclareGlobal>()) {
        begin_node(L, "StatDeclareGlobal", s->location);
        set_stat_common(L, s);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        push_location(L, s->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        push_type(L, s->type);
        lua_setfield(L, -2, "declaredType");
    } else if (auto* s = stat->as<AstStatDeclareFunction>()) {
        begin_node(L, "StatDeclareFunction", s->location);
        set_stat_common(L, s);
        if (s->attributes.size > 0) {
            lua_createtable(L, (int)s->attributes.size, 0);
            for (size_t i = 0; i < s->attributes.size; i++) {
                push_ast_attr(L, s->attributes.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "attributes");
        }
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        push_location(L, s->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        if (s->generics.size > 0) {
            lua_createtable(L, (int)s->generics.size, 0);
            for (size_t i = 0; i < s->generics.size; i++) {
                push_generic_type(L, s->generics.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "generics");
        }
        if (s->genericPacks.size > 0) {
            lua_createtable(L, (int)s->genericPacks.size, 0);
            for (size_t i = 0; i < s->genericPacks.size; i++) {
                push_generic_typepack(L, s->genericPacks.data[i]);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "genericPacks");
        }
        push_type_list(L, s->params);
        lua_setfield(L, -2, "params");
        lua_createtable(L, (int)s->paramNames.size, 0);
        for (size_t i = 0; i < s->paramNames.size; i++) {
            lua_createtable(L, 0, 2);
            push_name(L, s->paramNames.data[i].first);
            lua_setfield(L, -2, "name");
            push_location(L, s->paramNames.data[i].second);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "paramNames");
        lua_pushboolean(L, s->vararg);
        lua_setfield(L, -2, "vararg");
        push_location(L, s->varargLocation);
        lua_setfield(L, -2, "varargLocation");
        push_typepack(L, s->retTypes);
        lua_setfield(L, -2, "returnTypes");
    } else if (auto* s = stat->as<AstStatDeclareExternType>()) {
        begin_node(L, "StatDeclareExternType", s->location);
        set_stat_common(L, s);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        push_optional_name(L, s->superName);
        lua_setfield(L, -2, "superName");
        lua_createtable(L, (int)s->props.size, 0);
        for (size_t i = 0; i < s->props.size; i++) {
            lua_createtable(L, 0, 6);
            push_name(L, s->props.data[i].name);
            lua_setfield(L, -2, "name");
            push_location(L, s->props.data[i].nameLocation);
            lua_setfield(L, -2, "nameLocation");
            push_type(L, s->props.data[i].ty);
            lua_setfield(L, -2, "type");
            lua_pushboolean(L, s->props.data[i].isMethod);
            lua_setfield(L, -2, "isMethod");
            push_location(L, s->props.data[i].location);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "props");
        if (s->indexer) {
            lua_createtable(L, 0, 5);
            push_type(L, s->indexer->indexType);
            lua_setfield(L, -2, "indexType");
            push_type(L, s->indexer->resultType);
            lua_setfield(L, -2, "resultType");
            push_location(L, s->indexer->location);
            lua_setfield(L, -2, "location");
            lua_pushstring(L, table_access_to_string(s->indexer->access));
            lua_setfield(L, -2, "access");
            if (s->indexer->accessLocation) {
                push_location(L, *s->indexer->accessLocation);
                lua_setfield(L, -2, "accessLocation");
            }
            lua_setfield(L, -2, "indexer");
        }
    } else if (stat->as<AstStatError>()) {
        auto* s = stat->as<AstStatError>();
        begin_node(L, "StatError", stat->location);
        set_stat_common(L, s);
        push_array<AstExpr>(L, s->expressions, push_expr);
        lua_setfield(L, -2, "expressions");
        push_array<AstStat>(L, s->statements, push_stat);
        lua_setfield(L, -2, "statements");
        lua_pushinteger(L, (lua_Integer)s->messageIndex);
        lua_setfield(L, -2, "messageIndex");
    } else {
        begin_node(L, "StatUnknown", stat->location);
    }
}

// ---------------------------------------------------------------------------
// Generic node dispatcher
// ---------------------------------------------------------------------------
static void push_node(lua_State* L, AstNode* node) {
    if (!node) {
        lua_pushnil(L);
        return;
    }
    if (node->asExpr())
        push_expr(L, node->asExpr());
    else if (node->asStat())
        push_stat(L, node->asStat());
    else if (node->asType())
        push_type(L, node->asType());
    else {
        begin_node(L, "Unknown", node->location);
    }
}

// ---------------------------------------------------------------------------
// Protected AST serialisation -- runs inside lua_pcall so longjmp from a
// stack-overflow error won't skip RAII cleanup of Allocator / ParseResult.
// ---------------------------------------------------------------------------
struct ParseSerializeCtx {
    const ParseResult* result;
    bool captureComments;
};

static int l_serialize_ast(lua_State* L) {
    auto* ctx = static_cast<ParseSerializeCtx*>(lua_touserdata(L, 1));
    const ParseResult& result = *ctx->result;
    ensure_stack(L, 40);

    // Build result table: { root, errors, comments?, lines }
    lua_createtable(L, 0, 4);

    // root
    push_stat(L, result.root);
    lua_setfield(L, -2, "root");

    // lines
    lua_pushinteger(L, (int)result.lines);
    lua_setfield(L, -2, "lines");

    // errors
    lua_createtable(L, (int)result.errors.size(), 0);
    for (size_t i = 0; i < result.errors.size(); i++) {
        lua_createtable(L, 0, 2);
        lua_pushstring(L, result.errors[i].getMessage().c_str());
        lua_setfield(L, -2, "message");
        push_location(L, result.errors[i].getLocation());
        lua_setfield(L, -2, "location");
        lua_rawseti(L, -2, (int)(i + 1));
    }
    lua_setfield(L, -2, "errors");

    // comments (only if captureComments was set)
    if (ctx->captureComments) {
        lua_createtable(L, (int)result.commentLocations.size(), 0);
        for (size_t i = 0; i < result.commentLocations.size(); i++) {
            lua_createtable(L, 0, 2);
            switch (result.commentLocations[i].type) {
                case Lexeme::Comment:
                    lua_pushstring(L, "Comment");
                    break;
                case Lexeme::BlockComment:
                    lua_pushstring(L, "BlockComment");
                    break;
                case Lexeme::BrokenComment:
                    lua_pushstring(L, "BrokenComment");
                    break;
                default:
                    lua_pushstring(L, "Unknown");
                    break;
            }
            lua_setfield(L, -2, "type");
            push_location(L, result.commentLocations[i].location);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "comments");
    }

    return 1;
}

// ---------------------------------------------------------------------------
// luau.parse(source [, options]) -> ParseResult
// ---------------------------------------------------------------------------
static int l_parse(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    // Optional options table
    bool captureComments = false;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "captureComments");
        if (lua_isboolean(L, -1)) captureComments = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
    }

    int status;
    {
        // RAII scope -- Allocator, AstNameTable, and ParseResult are destroyed
        // at the end of this block, even if serialisation raises an error.
        Allocator allocator;
        AstNameTable names(allocator);
        ParseOptions opts;
        opts.captureComments = captureComments;

        ParseResult result = Parser::parse(src, srcLen, names, allocator, opts);

        // Serialise inside lua_pcall so a longjmp doesn't skip destructors.
        ParseSerializeCtx ctx{ &result, captureComments };
        lua_pushcfunction(L, l_serialize_ast, "serialize_ast");
        lua_pushlightuserdata(L, &ctx);
        status = lua_pcall(L, 1, 1, 0);
    }
    // Allocator, names, result all cleanly destroyed here.

    if (status != 0) lua_error(L);  // re-raise; safe to longjmp now

    return 1;
}

// ---------------------------------------------------------------------------
// luau.prettyPrint(source) -> string
// ---------------------------------------------------------------------------
static int l_prettyPrint(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    std::string_view sv(src, srcLen);
    PrettyPrintResult ppr = prettyPrint(sv);

    if (!ppr.parseError.empty()) {
        luaL_error(L, "parse error: %s", ppr.parseError.c_str());
    }

    lua_pushlstring(L, ppr.code.data(), ppr.code.size());
    return 1;
}

// ---------------------------------------------------------------------------
// luau.compile(source [, options]) -> string (bytecode)
//
//   options : {
//       optimizationLevel : number?,  -- 0..2, default 1
//       debugLevel        : number?,  -- 0..2, default 1
//       coverageLevel     : number?,  -- 0..2, default 0
//       typeInfoLevel     : number?,  -- 0..1, default 0
//   }?
// ---------------------------------------------------------------------------
static int l_compile(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    Luau::CompileOptions opts;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "optimizationLevel");
        if (lua_isnumber(L, -1)) opts.optimizationLevel = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "debugLevel");
        if (lua_isnumber(L, -1)) opts.debugLevel = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "coverageLevel");
        if (lua_isnumber(L, -1)) opts.coverageLevel = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "typeInfoLevel");
        if (lua_isnumber(L, -1)) opts.typeInfoLevel = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);
    }

    std::string bytecode = Luau::compile(std::string(src, srcLen), opts);
    lua_pushlstring(L, bytecode.data(), bytecode.size());
    return 1;
}

// ---------------------------------------------------------------------------
// luau.load(sourceOrBytecode [, chunkname]) -> function
//
// Accepts either Luau source code or pre-compiled bytecode.  Source is
// detected by checking the first byte:  bytecode blobs start with a
// small version number (0..LBC_VERSION_MAX) which is never a valid
// first character of Luau source.
// ---------------------------------------------------------------------------
static int l_load(lua_State* L) {
    size_t dataLen = 0;
    const char* data = luaL_checklstring(L, 1, &dataLen);
    const char* chunkname = luaL_optstring(L, 2, "=load");

    eryx_enable_all_luau_flags();

    std::string bytecode;
    bool isBytecode = (dataLen > 0 && (unsigned char)data[0] <= LBC_VERSION_MAX);

    if (isBytecode) {
        bytecode.assign(data, dataLen);
    } else {
        // Compile source to bytecode.
        Luau::CompileOptions opts;
        opts.optimizationLevel = 1;
        opts.debugLevel = 1;
        bytecode = Luau::compile(std::string(data, dataLen), opts);
    }

    int status = luau_load(L, chunkname, bytecode.data(), bytecode.size(), 0);
    if (status != 0) {
        // luau_load pushed an error string
        lua_error(L);
    }

    // Attempt native codegen if we can
    if (lua_codegen_isSupported()) {
        Luau::CodeGen::CompilationStats stats = {};
        Luau::CodeGen::CodeGenCompilationResult res =
            lua_codegen_compile(L, -1, Luau::CodeGen::CodeGen_ColdFunctions, &stats);
    }

    // Populate _DIR and _FILE
    std::string dirStr;
    std::string fileStr;
    if (chunkname[0] == '@') {
        std::string p = std::string(chunkname).substr(1);
        try {
            std::filesystem::path sp = std::filesystem::path(p);
            dirStr = sp.parent_path().generic_string();
            fileStr = sp.generic_string();
        } catch (...) {
        }
    }

    if (!dirStr.empty() || !fileStr.empty()) {
        lua_newtable(L);  // env

        // env.__index = _G
        lua_getglobal(L, "_G");
        lua_setfield(L, -2, "__index");

        lua_newtable(L);                 // metatable
        lua_getglobal(L, "_G");          // fallback
        lua_setfield(L, -2, "__index");  // mt.__index = _G
        lua_setmetatable(L, -2);         // setmetatable(env, mt)

        if (!fileStr.empty()) {
            lua_pushstring(L, fileStr.c_str());
            lua_setfield(L, -2, "_FILE");
        }
        if (!dirStr.empty()) {
            lua_pushstring(L, dirStr.c_str());
            lua_setfield(L, -2, "_DIR");
        }

        // set as environment for chunk
        lua_setfenv(L, -2);
    }

    return 1;  // the loaded function
}

// ---------------------------------------------------------------------------
// luau.disassemble(source [, options]) -> string
//
// Compiles source and returns a human-readable bytecode listing.
//
//   options : {
//       optimizationLevel : number?,   -- default 1
//       debugLevel        : number?,   -- default 2 (full for disassembly)
//       showLocals        : boolean?,  -- include local variable info
//       showRemarks       : boolean?,  -- include compiler remarks
//       showTypes         : boolean?,  -- include type info
//   }?
// ---------------------------------------------------------------------------
static int l_disassemble(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    uint32_t dumpFlags = Luau::BytecodeBuilder::Dump_Code | Luau::BytecodeBuilder::Dump_Source |
                         Luau::BytecodeBuilder::Dump_Lines;

    Luau::CompileOptions compileOpts;
    compileOpts.optimizationLevel = 1;
    compileOpts.debugLevel = 2;  // full debug info for disassembly

    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "optimizationLevel");
        if (lua_isnumber(L, -1)) compileOpts.optimizationLevel = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "debugLevel");
        if (lua_isnumber(L, -1)) compileOpts.debugLevel = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "showLocals");
        if (lua_isboolean(L, -1) && lua_toboolean(L, -1))
            dumpFlags |= Luau::BytecodeBuilder::Dump_Locals;
        lua_pop(L, 1);

        lua_getfield(L, 2, "showRemarks");
        if (lua_isboolean(L, -1) && lua_toboolean(L, -1))
            dumpFlags |= Luau::BytecodeBuilder::Dump_Remarks;
        lua_pop(L, 1);

        lua_getfield(L, 2, "showTypes");
        if (lua_isboolean(L, -1) && lua_toboolean(L, -1))
            dumpFlags |= Luau::BytecodeBuilder::Dump_Types;
        lua_pop(L, 1);
    }

    Luau::BytecodeBuilder bcb;
    bcb.setDumpFlags(dumpFlags);
    bcb.setDumpSource(std::string(src, srcLen));

    try {
        Luau::compileOrThrow(bcb, std::string(src, srcLen), compileOpts);
    } catch (Luau::CompileError& e) {
        luaL_error(L, "compile error: %s", e.what());
    }

    std::string listing = bcb.dumpEverything();
    lua_pushlstring(L, listing.data(), listing.size());
    return 1;
}

static int l_resolve(lua_State* L) {
    std::string path = luaL_checkpathlike(L, 1);
    auto resolved = eryx_resolve_module(L, path);

    if (resolved) {
        switch (resolved->type) {
            case LocatedModule::TYPE_FILE:
                lua_pushstring(L, "file");
                break;
            case LocatedModule::TYPE_EMBEDDED_NATIVE:
                lua_pushstring(L, "embedded dll");
                break;
            case LocatedModule::TYPE_EMBEDDED_SCRIPT:
                lua_pushstring(L, "embedded script");
                break;
            case LocatedModule::TYPE_VFS:
                lua_pushstring(L, "virtual file");
                break;
        }
        lua_pushstring(L, resolved->path.c_str());
    } else {
        lua_pushnil(L);
        lua_pushnil(L);
    }
    return 2;
}
static int l_config(lua_State* L) {
    auto mode_to_string = [](Luau::Mode mode) -> const char* {
        switch (mode) {
            case Luau::Mode::Strict:
                return "strict";
            case Luau::Mode::Nonstrict:
                return "nonstrict";
            case Luau::Mode::NoCheck:
                return "nocheck";
            default:
                return "nonstrict";
        }
    };

    std::filesystem::path configSearchStart;
    std::string vfsConfigDir;

    if (!lua_isnoneornil(L, 1)) {
        std::string folderPath = luaL_checkpathlike(L, 1);
        std::error_code ec;
        std::filesystem::path inputPath(folderPath);
        std::filesystem::path resolvedPath = std::filesystem::weakly_canonical(inputPath, ec);
        if (ec) {
            ec.clear();
            resolvedPath = std::filesystem::absolute(inputPath, ec);
            if (ec) resolvedPath = inputPath;
        }

        ec.clear();
        if (std::filesystem::is_regular_file(resolvedPath, ec)) {
            configSearchStart = resolvedPath.parent_path();
        } else {
            configSearchStart = resolvedPath;
        }
    } else {
        auto ctx = eryx_get_require_context(L);
        if (!ctx.callerDir.empty()) {
            configSearchStart = ctx.callerDir;
        } else if (ctx.isVFS) {
            vfsConfigDir = ctx.vfsCallerDir;
        } else {
            configSearchStart = ctx.root;
        }
    }
    auto config = eryx_locate_config(L, configSearchStart, std::nullopt, vfsConfigDir);

    lua_createtable(L, 0, 8);

    lua_pushboolean(L, config->found);
    lua_setfield(L, -2, "found");

    lua_pushstring(L, config->configDir.string().c_str());
    lua_setfield(L, -2, "configDir");

    lua_pushstring(L, mode_to_string(config->languageMode));
    lua_setfield(L, -2, "languageMode");

    lua_pushnumber(L, static_cast<lua_Number>(config->enabledLints));
    lua_setfield(L, -2, "enabledLints");
    lua_pushnumber(L, static_cast<lua_Number>(config->fatalLints));
    lua_setfield(L, -2, "fatalLints");

    lua_pushboolean(L, config->lintErrors);
    lua_setfield(L, -2, "lintErrors");
    lua_pushboolean(L, config->typeErrors);
    lua_setfield(L, -2, "typeErrors");

    lua_createtable(L, (int)config->globals.size(), 0);
    for (size_t i = 0; i < config->globals.size(); ++i) {
        lua_pushstring(L, config->globals[i].c_str());
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "globals");

    lua_createtable(L, 0, (int)config->aliases.size());
    for (const auto& [key, alias] : config->aliases) {
        lua_createtable(L, 0, 3);

        lua_pushstring(L, alias.qualified.c_str());
        lua_setfield(L, -2, "qualified");

        lua_pushstring(L, alias.configPath.c_str());
        lua_setfield(L, -2, "configPath");

        lua_pushstring(L, alias.path.c_str());
        lua_setfield(L, -2, "path");

        lua_setfield(L, -2, key.c_str());
    }
    lua_setfield(L, -2, "aliases");

    return 1;
}

// ---------------------------------------------------------------------------
// Module entry point
//
// check / typeAt / autocomplete are implemented in LuauShared (_wrapper_lib)
// because they depend on Luau.Analysis which requires the VM.
// ---------------------------------------------------------------------------
static const luaL_Reg funcs[] = {
    { "parse", l_parse },
    { "prettyPrint", l_prettyPrint },
    { "compile", l_compile },
    { "load", l_load },
    { "disassemble", l_disassemble },
    { "check", eryx_luau_check },
    { "typeAt", eryx_luau_typeAt },
    { "autocomplete", eryx_luau_autocomplete },
    { "resolve", l_resolve },
    { "getconfig", l_config },
    { nullptr, nullptr },
};

LUAU_MODULE_EXPORT int luauopen_luau(lua_State* L) {
    luaL_register(L, "luau", funcs);
    lua_setreadonly(L, -1, true);
    return 1;
}
