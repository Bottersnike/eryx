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
#include <string>
#include <vector>

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
        push_name(L, t->name);
        lua_setfield(L, -2, "name");
        if (t->prefix) {
            push_name(L, *t->prefix);
            lua_setfield(L, -2, "prefix");
        }
        if (t->parameters.size > 0) {
            lua_createtable(L, (int)t->parameters.size, 0);
            for (size_t i = 0; i < t->parameters.size; i++) {
                auto& p = t->parameters.data[i];
                if (p.type)
                    push_type(L, p.type);
                else if (p.typePack)
                    push_typepack(L, p.typePack);
                else
                    lua_pushnil(L);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "parameters");
        }
    } else if (auto* t = type->as<AstTypeTable>()) {
        begin_node(L, "TypeTable", t->location);
        lua_createtable(L, (int)t->props.size, 0);
        for (size_t i = 0; i < t->props.size; i++) {
            lua_createtable(L, 0, 3);
            push_name(L, t->props.data[i].name);
            lua_setfield(L, -2, "name");
            push_type(L, t->props.data[i].type);
            lua_setfield(L, -2, "type");
            push_location(L, t->props.data[i].location);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "props");
        if (t->indexer) {
            lua_createtable(L, 0, 2);
            push_type(L, t->indexer->indexType);
            lua_setfield(L, -2, "indexType");
            push_type(L, t->indexer->resultType);
            lua_setfield(L, -2, "resultType");
            lua_setfield(L, -2, "indexer");
        }
    } else if (auto* t = type->as<AstTypeFunction>()) {
        begin_node(L, "TypeFunction", t->location);
        // arg types
        lua_createtable(L, (int)t->argTypes.types.size, 0);
        for (size_t i = 0; i < t->argTypes.types.size; i++) {
            push_type(L, t->argTypes.types.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "argTypes");
        // arg names (optional per-arg)
        lua_createtable(L, (int)t->argNames.size, 0);
        for (size_t i = 0; i < t->argNames.size; i++) {
            if (t->argNames.data[i].has_value()) {
                push_name(L, t->argNames.data[i]->first);
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
        begin_node(L, "TypeError", type->location);
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
    lua_createtable(L, 0, 3);
    push_name(L, local->name);
    lua_setfield(L, -2, "name");
    push_location(L, local->location);
    lua_setfield(L, -2, "location");
    if (local->annotation) {
        push_type(L, local->annotation);
        lua_setfield(L, -2, "annotation");
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
    } else if (auto* e = expr->as<AstExprConstantString>()) {
        begin_node(L, "ExprConstantString", e->location);
        lua_pushlstring(L, e->value.data, e->value.size);
        lua_setfield(L, -2, "value");
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
        push_array<AstExpr>(L, e->args, push_expr);
        lua_setfield(L, -2, "args");
        lua_pushboolean(L, e->self);
        lua_setfield(L, -2, "self");
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
        push_name(L, e->debugname);
        lua_setfield(L, -2, "debugname");
        // args
        lua_createtable(L, (int)e->args.size, 0);
        for (size_t i = 0; i < e->args.size; i++) {
            push_local(L, e->args.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "args");
        lua_pushboolean(L, e->vararg);
        lua_setfield(L, -2, "vararg");
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
        push_expr(L, e->trueExpr);
        lua_setfield(L, -2, "trueExpr");
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
    } else if (auto* e = expr->as<AstExprError>()) {
        begin_node(L, "ExprError", e->location);
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
        push_array<AstStat>(L, s->body, push_stat);
        lua_setfield(L, -2, "body");
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
            push_expr(L, node->condition);
            lua_setfield(L, -2, "condition");
            push_stat(L, node->thenbody);
            lua_setfield(L, -2, "thenBody");
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
        push_expr(L, s->condition);
        lua_setfield(L, -2, "condition");
        push_stat(L, s->body);
        lua_setfield(L, -2, "body");
    } else if (auto* s = stat->as<AstStatRepeat>()) {
        begin_node(L, "StatRepeat", s->location);
        push_expr(L, s->condition);
        lua_setfield(L, -2, "condition");
        push_stat(L, s->body);
        lua_setfield(L, -2, "body");
    } else if (stat->as<AstStatBreak>()) {
        begin_node(L, "StatBreak", stat->location);
    } else if (stat->as<AstStatContinue>()) {
        begin_node(L, "StatContinue", stat->location);
    } else if (auto* s = stat->as<AstStatReturn>()) {
        begin_node(L, "StatReturn", s->location);
        push_array<AstExpr>(L, s->list, push_expr);
        lua_setfield(L, -2, "list");
    } else if (auto* s = stat->as<AstStatExpr>()) {
        begin_node(L, "StatExpr", s->location);
        push_expr(L, s->expr);
        lua_setfield(L, -2, "expr");
    } else if (auto* s = stat->as<AstStatLocal>()) {
        begin_node(L, "StatLocal", s->location);
        // vars
        lua_createtable(L, (int)s->vars.size, 0);
        for (size_t i = 0; i < s->vars.size; i++) {
            push_local(L, s->vars.data[i]);
            lua_rawseti(L, -2, (int)(i + 1));
        }
        lua_setfield(L, -2, "vars");
        push_array<AstExpr>(L, s->values, push_expr);
        lua_setfield(L, -2, "values");
    } else if (auto* s = stat->as<AstStatFor>()) {
        begin_node(L, "StatFor", s->location);
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
    } else if (auto* s = stat->as<AstStatForIn>()) {
        begin_node(L, "StatForIn", s->location);
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
    } else if (auto* s = stat->as<AstStatAssign>()) {
        begin_node(L, "StatAssign", s->location);
        push_array<AstExpr>(L, s->vars, push_expr);
        lua_setfield(L, -2, "vars");
        push_array<AstExpr>(L, s->values, push_expr);
        lua_setfield(L, -2, "values");
    } else if (auto* s = stat->as<AstStatCompoundAssign>()) {
        begin_node(L, "StatCompoundAssign", s->location);
        std::string opStr = toString(s->op);
        lua_pushstring(L, opStr.c_str());
        lua_setfield(L, -2, "op");
        push_expr(L, s->var);
        lua_setfield(L, -2, "var");
        push_expr(L, s->value);
        lua_setfield(L, -2, "value");
    } else if (auto* s = stat->as<AstStatFunction>()) {
        begin_node(L, "StatFunction", s->location);
        push_expr(L, s->name);
        lua_setfield(L, -2, "name");
        push_expr(L, s->func);
        lua_setfield(L, -2, "func");
    } else if (auto* s = stat->as<AstStatLocalFunction>()) {
        begin_node(L, "StatLocalFunction", s->location);
        push_local(L, s->name);
        lua_setfield(L, -2, "name");
        push_expr(L, s->func);
        lua_setfield(L, -2, "func");
    } else if (auto* s = stat->as<AstStatTypeAlias>()) {
        begin_node(L, "StatTypeAlias", s->location);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, s->exported);
        lua_setfield(L, -2, "exported");
        push_type(L, s->type);
        lua_setfield(L, -2, "aliasedType");
        if (s->generics.size > 0) {
            lua_createtable(L, (int)s->generics.size, 0);
            for (size_t i = 0; i < s->generics.size; i++) {
                push_name(L, s->generics.data[i]->name);
                lua_rawseti(L, -2, (int)(i + 1));
            }
            lua_setfield(L, -2, "generics");
        }
    } else if (auto* s = stat->as<AstStatDeclareGlobal>()) {
        begin_node(L, "StatDeclareGlobal", s->location);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
        push_type(L, s->type);
        lua_setfield(L, -2, "declaredType");
    } else if (auto* s = stat->as<AstStatDeclareFunction>()) {
        begin_node(L, "StatDeclareFunction", s->location);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
    } else if (auto* s = stat->as<AstStatDeclareExternType>()) {
        begin_node(L, "StatDeclareExternType", s->location);
        push_name(L, s->name);
        lua_setfield(L, -2, "name");
    } else if (stat->as<AstStatError>()) {
        begin_node(L, "StatError", stat->location);
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
    const char* path = luaL_checkstring(L, 1);
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
    auto ctx = eryx_get_require_context(L);
    std::filesystem::path configSearchStart;
    std::string vfsConfigDir;
    if (!ctx.callerDir.empty()) {
        configSearchStart = ctx.callerDir;
    } else if (ctx.isVFS) {
        vfsConfigDir = ctx.vfsCallerDir;
    } else {
        configSearchStart = ctx.root;
    }
    auto config = eryx_locate_config(L, configSearchStart, std::nullopt, vfsConfigDir);

    // TODO: THIS!

    // const char* path = luaL_checkstring(L, 1);
    // auto resolved = resolve_module(L, path);

    // if (resolved) {
    //     lua_pushnumber(L, resolved->type);
    //     lua_pushstring(L, resolved->path.c_str());
    // } else {
    //     lua_pushnil(L);
    //     lua_pushnil(L);
    // }
    return 0;
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
    return 1;
}
