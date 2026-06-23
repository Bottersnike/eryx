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
//   location : userdata with beginline/begincolumn/endline/endcolumn
// plus node-specific fields described below.
// ---------------------------------------------------------------------------

#include "native.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../../LuaLocation.hpp"
#include "../../LuaUtil.hpp"
#include "../../runtime/lconfig.hpp"
#include "../../runtime/lresolve.hpp"
#include "Luau/Allocator.h"
#include "Luau/Ast.h"
#include "Luau/Bytecode.h"
#include "Luau/BytecodeBuilder.h"
#include "Luau/Compiler.h"
#include "Luau/Config.h"  // We just want the luaurc parsing side of things, so it's safe to use this in a shared module
#include "Luau/Cst.h"
#include "Luau/Lexer.h"
#include "Luau/Location.h"
#include "Luau/ParseOptions.h"
#include "Luau/ParseResult.h"
#include "Luau/Parser.h"
#include "Luau/PrettyPrinter.h"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"

// using namespace Luau;

// ---------------------------------------------------------------------------
// Helpers – push a Location / Position onto the Lua stack
// ---------------------------------------------------------------------------
static void push_position(lua_State* L, const Luau::Position& pos) {
    if (!lua_checkstack(L, 4))
        luaL_error(L, "luau.parse: stack overflow while serialising AST position");

    lua_createtable(L, 0, 2);
    lua_pushinteger(L, pos.line + 1);  // 1-based for Luau users
    lua_setfield(L, -2, "line");
    lua_pushinteger(L, pos.column + 1);  // 1-based
    lua_setfield(L, -2, "column");
}

static void push_location(lua_State* L, const Luau::Location& loc) {
    if (!lua_checkstack(L, 8))
        luaL_error(L, "luau.parse: stack overflow while serialising AST location");

    eryx_lua_push_location(L, loc);
}

static const char* quote_style_to_string(Luau::AstExprConstantString::QuoteStyle quoteStyle) {
    switch (quoteStyle) {
        case Luau::AstExprConstantString::QuotedSimple:
            return "simple";
        case Luau::AstExprConstantString::QuotedSingle:
            return "single";
        case Luau::AstExprConstantString::QuotedRaw:
            return "raw";
        case Luau::AstExprConstantString::Unquoted:
            return "unquoted";
        default:
            return "unknown";
    }
}

static const char* comment_type_to_string(Luau::Lexeme::Type type) {
    switch (type) {
        case Luau::Lexeme::Comment:
            return "line";
        case Luau::Lexeme::BlockComment:
            return "block";
        case Luau::Lexeme::BrokenComment:
            return "broken";
        default:
            return "unknown";
    }
}

static const char* getNodeTypeName(Luau::AstNode* node) {
    if (node->is<Luau::AstAttr>()) return "AstAttr";
    if (node->is<Luau::AstGenericType>()) return "AstGenericType";
    if (node->is<Luau::AstGenericTypePack>()) return "AstGenericTypePack";
    if (node->is<Luau::AstExprGroup>()) return "AstExprGroup";
    if (node->is<Luau::AstExprConstantNil>()) return "AstExprConstantNil";
    if (node->is<Luau::AstExprConstantBool>()) return "AstExprConstantBool";
    if (node->is<Luau::AstExprConstantNumber>()) return "AstExprConstantNumber";
    if (node->is<Luau::AstExprConstantInteger>()) return "AstExprConstantInteger";
    if (node->is<Luau::AstExprConstantString>()) return "AstExprConstantString";
    if (node->is<Luau::AstExprLocal>()) return "AstExprLocal";
    if (node->is<Luau::AstExprGlobal>()) return "AstExprGlobal";
    if (node->is<Luau::AstExprVarargs>()) return "AstExprVarargs";
    if (node->is<Luau::AstExprCall>()) return "AstExprCall";
    if (node->is<Luau::AstExprIndexName>()) return "AstExprIndexName";
    if (node->is<Luau::AstExprIndexExpr>()) return "AstExprIndexExpr";
    if (node->is<Luau::AstExprFunction>()) return "AstExprFunction";
    if (node->is<Luau::AstExprTable>()) return "AstExprTable";
    if (node->is<Luau::AstExprUnary>()) return "AstExprUnary";
    if (node->is<Luau::AstExprBinary>()) return "AstExprBinary";
    if (node->is<Luau::AstExprTypeAssertion>()) return "AstExprTypeAssertion";
    if (node->is<Luau::AstExprIfElse>()) return "AstExprIfElse";
    if (node->is<Luau::AstExprInterpString>()) return "AstExprInterpString";
    if (node->is<Luau::AstExprInstantiate>()) return "AstExprInstantiate";
    if (node->is<Luau::AstExprError>()) return "AstExprError";
    if (node->is<Luau::AstStatBlock>()) return "AstStatBlock";
    if (node->is<Luau::AstStatIf>()) return "AstStatIf";
    if (node->is<Luau::AstStatWhile>()) return "AstStatWhile";
    if (node->is<Luau::AstStatRepeat>()) return "AstStatRepeat";
    if (node->is<Luau::AstStatBreak>()) return "AstStatBreak";
    if (node->is<Luau::AstStatContinue>()) return "AstStatContinue";
    if (node->is<Luau::AstStatReturn>()) return "AstStatReturn";
    if (node->is<Luau::AstStatExpr>()) return "AstStatExpr";
    if (node->is<Luau::AstStatLocal>()) return "AstStatLocal";
    if (node->is<Luau::AstStatFor>()) return "AstStatFor";
    if (node->is<Luau::AstStatForIn>()) return "AstStatForIn";
    if (node->is<Luau::AstStatAssign>()) return "AstStatAssign";
    if (node->is<Luau::AstStatCompoundAssign>()) return "AstStatCompoundAssign";
    if (node->is<Luau::AstStatFunction>()) return "AstStatFunction";
    if (node->is<Luau::AstStatLocalFunction>()) return "AstStatLocalFunction";
    if (node->is<Luau::AstStatTypeAlias>()) return "AstStatTypeAlias";
    if (node->is<Luau::AstStatTypeFunction>()) return "AstStatTypeFunction";
    if (node->is<Luau::AstStatDeclareFunction>()) return "AstStatDeclareFunction";
    if (node->is<Luau::AstStatDeclareGlobal>()) return "AstStatDeclareGlobal";
    if (node->is<Luau::AstStatClass>()) return "AstStatClass";
    if (node->is<Luau::AstStatDeclareExternType>()) return "AstStatDeclareExternType";
    if (node->is<Luau::AstStatError>()) return "AstStatError";
    if (node->is<Luau::AstTypeReference>()) return "AstTypeReference";
    if (node->is<Luau::AstTypeTable>()) return "AstTypeTable";
    if (node->is<Luau::AstTypeFunction>()) return "AstTypeFunction";
    if (node->is<Luau::AstTypeTypeof>()) return "AstTypeTypeof";
    if (node->is<Luau::AstTypeOptional>()) return "AstTypeOptional";
    if (node->is<Luau::AstTypeUnion>()) return "AstTypeUnion";
    if (node->is<Luau::AstTypeIntersection>()) return "AstTypeIntersection";
    if (node->is<Luau::AstTypeSingletonBool>()) return "AstTypeSingletonBool";
    if (node->is<Luau::AstTypeSingletonString>()) return "AstTypeSingletonString";
    if (node->is<Luau::AstTypeGroup>()) return "AstTypeGroup";
    if (node->is<Luau::AstTypeError>()) return "AstTypeError";
    if (node->is<Luau::AstTypePackExplicit>()) return "AstTypePackExplicit";
    if (node->is<Luau::AstTypePackVariadic>()) return "AstTypePackVariadic";
    if (node->is<Luau::AstTypePackGeneric>()) return "AstTypePackGeneric";
    return "Unknown node";
}

static std::vector<size_t> computeLineOffsets(const char* content) {
    std::vector<size_t> result;
    result.push_back(0);

    size_t i = 0;
    char ch;
    while ((ch = content[i])) {
        if (ch == '\r') {
            if (content[i + 1] == '\n')
                i += 2;
            else
                i += 1;

            result.push_back(i);
        } else if (ch == '\n') {
            i += 1;
            result.push_back(i);
        } else {
            i += 1;
        }
    }

    return result;
}

struct AstSerialiser : public Luau::AstVisitor {
    lua_State* L;
    const char* source;
    size_t sourceSize;
    Luau::CstNodeMap cstNodeMap;
    std::vector<size_t> lineOffsets;

    Luau::Position cursor{ 0, 0 };
    struct TriviaOwner {
        int tokenId = 0;
    };
    TriviaOwner previousOwner;
    int nodeTableIndex = 0;
    int localTableIndex = 0;
    int tokenTableIndex = 0;
    int nextNodeId = 0;
    int nextLocalId = 0;
    int nextTokenId = 0;
    std::unordered_map<Luau::AstLocal*, int> localIds;
    std::unordered_set<Luau::AstExprFunction*> claimedFunctionKeywords;
    std::unordered_set<Luau::AstExprIfElse*> claimedElseifExprKeywords;
    std::unordered_set<Luau::AstStatIf*> claimedElseifKeywords;

    AstSerialiser(lua_State* L, const char* source, size_t sourceSize, Luau::CstNodeMap cstNodeMap)
        : L(L),
          source(source),
          sourceSize(sourceSize),
          cstNodeMap(std::move(cstNodeMap)),
          lineOffsets(computeLineOffsets(source)) {
        lua_createtable(L, 0, 0);
        nodeTableIndex = lua_absindex(L, -1);

        lua_createtable(L, 0, 0);
        localTableIndex = lua_absindex(L, -1);

        lua_createtable(L, 0, 0);
        tokenTableIndex = lua_absindex(L, -1);
    }

    ~AstSerialiser() {
        lua_remove(L, tokenTableIndex);
        lua_remove(L, localTableIndex);
        lua_remove(L, nodeTableIndex);
    }

   private:
    template <typename T>
    T locateCst(Luau::AstNode* astNode) {
        const auto cstNode = cstNodeMap.find(astNode);
        if (!cstNode)
            luaL_error(L, "Parsing failed: missing CST data for %s", getNodeTypeName(astNode));

        T result = (*cstNode)->as<typename std::remove_pointer<T>::type>();
        if (!result)
            luaL_error(L, "Parsing failed: CST data had unexpected shape for %s",
                       getNodeTypeName(astNode));

        return result;
    }

    template <typename T>
    T maybeCst(Luau::AstNode* astNode) {
        const auto cstNode = cstNodeMap.find(astNode);
        if (!cstNode) return nullptr;

        return (*cstNode)->as<typename std::remove_pointer<T>::type>();
    }

    size_t offsetFromPosition(Luau::Position position) const {
        if (!position.hasValue()) return sourceSize;
        if (position.line >= lineOffsets.size()) return sourceSize;
        return std::min(lineOffsets[position.line] + position.column, sourceSize);
    }

    Luau::Position positionFromOffset(size_t offset) const {
        offset = std::min(offset, sourceSize);
        auto it = std::upper_bound(lineOffsets.begin(), lineOffsets.end(), offset);
        size_t line = it == lineOffsets.begin() ? 0 : size_t((it - lineOffsets.begin()) - 1);
        return Luau::Position{ unsigned(line), unsigned(offset - lineOffsets[line]) };
    }

    static std::string tokenFieldName(const char* key) {
        if (std::strcmp(key, "token") == 0) return "token";

        return std::string(key) + "Token";
    }

    void appendTokenText(int tokenId, const char* field, std::string_view text) {
        if (tokenId == 0 || text.empty()) return;

        lua_rawgeti(L, tokenTableIndex, tokenId);
        int tokenIndex = lua_absindex(L, -1);
        lua_getfield(L, tokenIndex, field);
        size_t oldSize = 0;
        const char* oldText = lua_isstring(L, -1) ? lua_tolstring(L, -1, &oldSize) : nullptr;

        if (oldText && oldSize > 0) {
            std::string combined(oldText, oldSize);
            combined.append(text.data(), text.size());
            lua_pop(L, 1);
            lua_pushlstring(L, combined.data(), combined.size());
        } else {
            lua_pop(L, 1);
            lua_pushlstring(L, text.data(), text.size());
        }

        lua_setfield(L, tokenIndex, field);
        lua_pop(L, 1);
    }

    int createToken(int ownerRef, const char* key, Luau::Position position, size_t width) {
        if (!lua_checkstack(L, 16))
            luaL_error(L, "luau.parse: stack overflow while serialising CST token");

        lua_rawgeti(L, nodeTableIndex, ownerRef);
        int ownerIndex = lua_absindex(L, -1);

        size_t startOffset = offsetFromPosition(position);
        size_t endOffset = std::min(startOffset + width, sourceSize);
        std::string_view text = sourceSlice(startOffset, endOffset);

        lua_createtable(L, 0, 5);
        int tokenIndex = lua_absindex(L, -1);

        lua_pushstring(L, "token");
        lua_setfield(L, tokenIndex, "type");
        lua_pushlstring(L, text.data(), text.size());
        lua_setfield(L, tokenIndex, "text");
        push_location(L, Luau::Location{ position, positionFromOffset(endOffset) });
        lua_setfield(L, tokenIndex, "location");
        lua_pushliteral(L, "");
        lua_setfield(L, tokenIndex, "leadingText");
        lua_pushliteral(L, "");
        lua_setfield(L, tokenIndex, "trailingText");

        int tokenId = ++nextTokenId;
        lua_pushvalue(L, tokenIndex);
        lua_rawseti(L, tokenTableIndex, tokenId);

        std::string fieldName = tokenFieldName(key);
        lua_setfield(L, ownerIndex, fieldName.c_str());
        lua_pop(L, 1);
        return tokenId;
    }

    int refCurrentNode() {
        int nodeId = ++nextNodeId;
        lua_pushvalue(L, -1);
        lua_rawseti(L, nodeTableIndex, nodeId);
        return nodeId;
    }

    void setField(int tableIndex, const char* name) { lua_setfield(L, tableIndex, name); }

    void rawSetI(int tableIndex, int index) { lua_rawseti(L, tableIndex, index); }

    static std::string numberedKey(const char* prefix, size_t index) {
        return std::string(prefix) + std::to_string(index + 1);
    }

    static const char* tableAccessToString(Luau::AstTableAccess access) {
        switch (access) {
            case Luau::AstTableAccess::Read:
                return "Read";
            case Luau::AstTableAccess::Write:
                return "Write";
            case Luau::AstTableAccess::ReadWrite:
            default:
                return "ReadWrite";
        }
    }

    static const char* attrTypeToString(Luau::AstAttr::Type type) {
        switch (type) {
            case Luau::AstAttr::Checked:
                return "Checked";
            case Luau::AstAttr::Native:
                return "Native";
            case Luau::AstAttr::Deprecated:
                return "Deprecated";
            case Luau::AstAttr::DebugNoinline:
                return "DebugNoinline";
            case Luau::AstAttr::Unknown:
            default:
                return "Unknown";
        }
    }

    void attachGap(int currentTokenId, std::string_view gap) {
        if (gap.empty()) return;

        size_t newline = gap.find('\n');
        if (previousOwner.tokenId == 0) {
            appendTokenText(currentTokenId, "leadingText", gap);
        } else if (newline == std::string_view::npos) {
            appendTokenText(previousOwner.tokenId, "trailingText", gap);
        } else {
            appendTokenText(previousOwner.tokenId, "trailingText", gap.substr(0, newline + 1));
            appendTokenText(currentTokenId, "leadingText", gap.substr(newline + 1));
        }
    }

    std::string_view sourceSlice(size_t start, size_t end) const {
        start = std::min(start, sourceSize);
        end = std::min(end, sourceSize);
        if (end < start) end = start;
        return std::string_view(source + start, end - start);
    }

    void consumeSyntax(int ownerRef, const char* key, Luau::Position position, size_t width) {
        if (!position.hasValue()) return;

        size_t cursorOffset = offsetFromPosition(cursor);
        size_t syntaxOffset = offsetFromPosition(position);
        if (syntaxOffset < cursorOffset)
            luaL_error(L, "Parsing failed: syntax cursor moved backwards at %s (%d:%d -> %d:%d)",
                       key, cursor.line + 1, cursor.column + 1, position.line + 1,
                       position.column + 1);

        int tokenId = createToken(ownerRef, key, position, width);
        attachGap(tokenId, sourceSlice(cursorOffset, syntaxOffset));

        size_t endOffset = std::min(syntaxOffset + width, sourceSize);
        cursor = positionFromOffset(endOffset);
        previousOwner = TriviaOwner{ tokenId };
    }

    void consumeSyntax(int ownerRef, const char* key, Luau::Position position, const char* text) {
        consumeSyntax(ownerRef, key, position, std::strlen(text));
    }

    void consumeSyntax(int ownerRef, const char* key, Luau::Location location) {
        consumeSyntax(ownerRef, key, location.begin,
                      offsetFromPosition(location.end) - offsetFromPosition(location.begin));
    }

    void consumeIdentifier(int ownerRef, const char* key, Luau::Location location) {
        consumeSyntax(ownerRef, key, location);
    }

    void consumeSemicolonIfPresent(int ownerRef, Luau::AstStat* node) {
        if (!node->hasSemicolon) return;

        size_t start = offsetFromPosition(cursor);
        size_t end = offsetFromPosition(node->location.end);
        for (size_t i = start; i < end; ++i) {
            if (source[i] == ';') {
                consumeSyntax(ownerRef, "semicolon", positionFromOffset(i), 1);
                return;
            }
        }
    }

    void consumeEof(int ownerRef) {
        int tokenId = createToken(ownerRef, "eof", positionFromOffset(sourceSize), 0);
        attachGap(tokenId, sourceSlice(offsetFromPosition(cursor), sourceSize));
        cursor = positionFromOffset(sourceSize);
    }

    // Consumes a synthetic "span" token for an error node. Unlike consumeSyntax,
    // the span may overlap source already consumed by the error node's children
    // (which are visited first and have advanced the cursor past the error's
    // begin). Clamp the token's start to the current cursor so it covers only
    // the remaining unconsumed range instead of moving the cursor backwards.
    void consumeSpan(int ownerRef, const char* key, Luau::Location location) {
        size_t cursorOffset = offsetFromPosition(cursor);
        size_t beginOffset = offsetFromPosition(location.begin);
        size_t endOffset = offsetFromPosition(location.end);
        size_t startOffset = std::max(cursorOffset, beginOffset);
        if (endOffset < startOffset) endOffset = startOffset;

        int tokenId =
            createToken(ownerRef, key, positionFromOffset(startOffset), endOffset - startOffset);
        attachGap(tokenId, sourceSlice(cursorOffset, startOffset));
        cursor = positionFromOffset(endOffset);
        previousOwner = TriviaOwner{ tokenId };
    }

    std::optional<Luau::Position> findCharPosition(size_t startOffset, size_t endOffset,
                                                   char ch) const {
        startOffset = std::min(startOffset, sourceSize);
        endOffset = std::min(endOffset, sourceSize);
        for (size_t i = startOffset; i < endOffset; ++i) {
            if (source[i] == ch) return positionFromOffset(i);
        }
        return std::nullopt;
    }

    void serialiseTypeOrPack(const Luau::AstTypeOrPack& value) {
        if (!lua_checkstack(L, 16))
            luaL_error(L, "luau.parse: stack overflow while serialising AST type argument");

        lua_createtable(L, 0, 2);
        if (value.type) {
            lua_pushstring(L, "Type");
            lua_setfield(L, -2, "kind");
            value.type->visit(this);
            lua_setfield(L, -2, "value");
        } else if (value.typePack) {
            lua_pushstring(L, "TypePack");
            lua_setfield(L, -2, "kind");
            value.typePack->visit(this);
            lua_setfield(L, -2, "value");
        } else {
            lua_pushstring(L, "None");
            lua_setfield(L, -2, "kind");
        }
    }

    void serialiseTypeList(const Luau::AstTypeList& list, int commaOwnerRef = 0,
                           const Luau::AstArray<Luau::Position>* commaPositions = nullptr,
                           const char* commaPrefix = "comma") {
        if (!lua_checkstack(L, 16))
            luaL_error(L, "luau.parse: stack overflow while serialising AST type list");

        lua_createtable(L, 0, 2);
        int listIndex = lua_absindex(L, -1);
        lua_createtable(L, list.types.size, 0);
        int typesIndex = lua_absindex(L, -1);
        for (size_t i = 0; i < list.types.size; ++i) {
            list.types.data[i]->visit(this);
            lua_rawseti(L, typesIndex, int(i + 1));
            if (commaOwnerRef != 0 && commaPositions && i < commaPositions->size)
                consumeSyntax(commaOwnerRef, numberedKey(commaPrefix, i).c_str(),
                              commaPositions->data[i], ",");
        }
        lua_setfield(L, listIndex, "types");

        if (list.tailType) {
            list.tailType->visit(this);
            lua_setfield(L, listIndex, "tail");
        }
    }

    void serialiseTypeFunctionArgs(const Luau::AstTypeList& types,
                                   Luau::AstArray<std::optional<Luau::AstArgumentName>> names,
                                   const Luau::AstArray<Luau::Position>* nameColonPositions,
                                   const Luau::AstArray<Luau::Position>* commaPositions,
                                   int ownerRef) {
        if (!lua_checkstack(L, 24))
            luaL_error(L, "luau.parse: stack overflow while serialising function type args");

        int parentIndex = lua_absindex(L, -1);
        lua_createtable(L, 0, 2);
        int typeListIndex = lua_absindex(L, -1);
        lua_createtable(L, types.types.size, 0);
        int typeArrayIndex = lua_absindex(L, -1);

        lua_createtable(L, names.size, 0);
        int nameArrayIndex = lua_absindex(L, -1);

        for (size_t i = 0; i < types.types.size; ++i) {
            if (i < names.size && names.data[i].has_value()) {
                const auto& name = *names.data[i];
                lua_createtable(L, 0, 2);
                lua_pushstring(L, name.first.value);
                lua_setfield(L, -2, "name");
                consumeSyntax(ownerRef, numberedKey("argName", i).c_str(), name.second);
                push_location(L, name.second);
                lua_setfield(L, -2, "location");
                lua_rawseti(L, nameArrayIndex, int(i + 1));
            } else if (i < names.size) {
                lua_pushnil(L);
                lua_rawseti(L, nameArrayIndex, int(i + 1));
            }

            if (nameColonPositions && i < nameColonPositions->size &&
                nameColonPositions->data[i].hasValue())
                consumeSyntax(ownerRef, numberedKey("argNameColon", i).c_str(),
                              nameColonPositions->data[i], ":");

            types.types.data[i]->visit(this);
            lua_rawseti(L, typeArrayIndex, int(i + 1));

            if (commaPositions && i < commaPositions->size)
                consumeSyntax(ownerRef, numberedKey("argComma", i).c_str(), commaPositions->data[i],
                              ",");
        }

        lua_pushvalue(L, typeArrayIndex);
        lua_setfield(L, typeListIndex, "types");
        lua_remove(L, typeArrayIndex);

        if (types.tailType) {
            types.tailType->visit(this);
            lua_setfield(L, typeListIndex, "tail");
        }

        lua_setfield(L, parentIndex, "argNames");
        lua_setfield(L, parentIndex, "argTypes");
    }

    void serialiseOptionalArgNames(Luau::AstArray<std::optional<Luau::AstArgumentName>> argNames) {
        lua_createtable(L, argNames.size, 0);
        for (size_t i = 0; i < argNames.size; ++i) {
            if (argNames.data[i].has_value()) {
                lua_createtable(L, 0, 2);
                lua_pushstring(L, argNames.data[i]->first.value);
                lua_setfield(L, -2, "name");
                push_location(L, argNames.data[i]->second);
                lua_setfield(L, -2, "location");
            } else {
                lua_pushnil(L);
            }
            lua_rawseti(L, -2, int(i + 1));
        }
    }

    void serialiseArgNames(Luau::AstArray<Luau::AstArgumentName> argNames) {
        lua_createtable(L, argNames.size, 0);
        for (size_t i = 0; i < argNames.size; ++i) {
            lua_createtable(L, 0, 2);
            lua_pushstring(L, argNames.data[i].first.value);
            lua_setfield(L, -2, "name");
            push_location(L, argNames.data[i].second);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, int(i + 1));
        }
    }

    void serialiseTableIndexer(Luau::AstTableIndexer* indexer) {
        if (!indexer) {
            lua_pushnil(L);
            return;
        }

        lua_createtable(L, 0, 5);
        indexer->indexType->visit(this);
        lua_setfield(L, -2, "indexType");
        indexer->resultType->visit(this);
        lua_setfield(L, -2, "resultType");
        push_location(L, indexer->location);
        lua_setfield(L, -2, "location");
        lua_pushstring(L, tableAccessToString(indexer->access));
        lua_setfield(L, -2, "access");
        if (indexer->accessLocation) {
            push_location(L, *indexer->accessLocation);
            lua_setfield(L, -2, "accessLocation");
        }
    }

    void serialiseSyntheticArrayIndexType(Luau::AstType* node) {
        if (auto refNode = node->as<Luau::AstTypeReference>()) {
            serialiseNode(refNode, "type", "reference");
            lua_pushboolean(L, refNode->hasParameterList);
            lua_setfield(L, -2, "hasParameterList");
            lua_pushstring(L, refNode->name.value);
            lua_setfield(L, -2, "name");
            push_location(L, refNode->nameLocation);
            lua_setfield(L, -2, "nameLocation");
        } else {
            serialiseNode(node, "type", "unknown");
        }
    }

    int serialiseNode(Luau::AstNode* node, const char* category, const char* name) {
        if (!lua_checkstack(L, 16))
            luaL_error(L, "luau.parse: stack overflow while serialising AST node");

        lua_createtable(L, 0, 3 + 2);
        lua_pushstring(L, category);
        lua_setfield(L, -2, "category");
        lua_pushstring(L, name);
        lua_setfield(L, -2, "type");
        push_location(L, node->location);
        lua_setfield(L, -2, "location");
        return refCurrentNode();
    }

    int serialiseExprNode(Luau::AstExpr* node, const char* name) {
        return serialiseNode(node, "expr", name);
    }
    int serialiseStatNode(Luau::AstStat* node, const char* name) {
        int ref = serialiseNode(node, "stat", name);
        lua_pushboolean(L, node->hasSemicolon);
        lua_setfield(L, -2, "hasSemicolon");
        return ref;
    }

    void serialiseLocal(Luau::AstLocal* node) {
        if (!lua_checkstack(L, 16))
            luaL_error(L, "luau.parse: stack overflow while serialising AST local");

        // TODO: Trivia?
        auto cached = localIds.find(node);
        if (cached != localIds.end()) {
            lua_rawgeti(L, localTableIndex, cached->second);
            return;
        }

        lua_createtable(L, 0, 10 + 2);
        int localId = ++nextLocalId;
        lua_pushvalue(L, -1);
        lua_rawseti(L, localTableIndex, localId);
        localIds[node] = localId;

        lua_pushstring(L, "");
        lua_setfield(L, -2, "category");
        lua_pushstring(L, "local");
        lua_setfield(L, -2, "type");
        push_location(L, node->location);
        lua_setfield(L, -2, "location");

        // node->location references the original local!
        // attachLeadingTrivia(node->location.begin);

        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        if (node->shadow) {
            serialiseLocal(node->shadow);
            lua_setfield(L, -2, "shadows");
        }
        lua_pushnumber(L, node->functionDepth);
        lua_setfield(L, -2, "functionDepth");
        lua_pushnumber(L, node->loopDepth);
        lua_setfield(L, -2, "loopDepth");
        lua_pushboolean(L, node->isConst);
        lua_setfield(L, -2, "isConst");
        lua_pushboolean(L, node->isExported);
        lua_setfield(L, -2, "isExported");
    }

    template <typename T>
    void attachVisitArray(Luau::AstArray<T*> arr, const char* name) {
        if (!lua_checkstack(L, 16))
            luaL_error(L, "luau.parse: stack overflow while serialising AST array");

        lua_createtable(L, arr.size, 0);
        auto idx = 1;
        for (auto i : arr) {
            i->visit(this);
            lua_rawseti(L, -2, idx++);
        }
        lua_setfield(L, -2, name);
    }

   public:
    /// AstExpr
    virtual bool visit(Luau::AstExprGroup* node) {
        int ref = serialiseExprNode(node, "group");
        consumeSyntax(ref, "openParen", node->location.begin, "(");
        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        if (auto cst = locateCst<Luau::CstExprGroup*>(node))
            consumeSyntax(ref, "closeParen", cst->closePosition, ")");
        else
            consumeSyntax(ref, "closeParen",
                          positionFromOffset(offsetFromPosition(node->location.end) - 1), ")");
        return false;
    }
    virtual bool visit(Luau::AstExprConstantNil* node) {
        int ref = serialiseExprNode(node, "constantNil");
        consumeSyntax(ref, "token", node->location.begin, "nil");
        return false;
    }
    virtual bool visit(Luau::AstExprConstantBool* node) {
        int ref = serialiseExprNode(node, "constantBool");
        lua_pushboolean(L, node->value);
        lua_setfield(L, -2, "value");
        consumeSyntax(ref, "token", node->location.begin, node->value ? "true" : "false");
        return false;
    }
    virtual bool visit(Luau::AstExprConstantNumber* node) {
        int ref = serialiseExprNode(node, "constantNumber");
        lua_pushnumber(L, node->value);
        lua_setfield(L, -2, "value");
        auto cst = locateCst<Luau::CstExprConstantNumber*>(node);
        consumeSyntax(ref, "token", node->location.begin, cst->value.size);
        return false;
    }
    virtual bool visit(Luau::AstExprConstantInteger* node) {
        int ref = serialiseExprNode(node, "constantInteger");
        lua_pushinteger64(L, node->value);
        lua_setfield(L, -2, "value");
        auto cst = locateCst<Luau::CstExprConstantInteger*>(node);
        consumeSyntax(ref, "token", node->location.begin, cst->value.size);
        return false;
    }
    virtual bool visit(Luau::AstExprConstantString* node) {
        int ref = serialiseExprNode(node, "constantString");
        lua_pushlstring(L, node->value.data, node->value.size);
        lua_setfield(L, -2, "value");
        lua_pushstring(L, quote_style_to_string(node->quoteStyle));
        lua_setfield(L, -2, "quoteStyle");
        lua_pushboolean(L, node->isQuoted());
        lua_setfield(L, -2, "isQuoted");
        consumeSyntax(ref, "token", node->location);
        return false;
    }
    virtual bool visit(Luau::AstExprLocal* node) {
        int ref = serialiseExprNode(node, "local");
        consumeIdentifier(ref, "name", node->location);
        serialiseLocal(node->local);
        lua_setfield(L, -2, "local");
        lua_pushboolean(L, node->upvalue);
        lua_setfield(L, -2, "upvalue");
        return false;
    }
    virtual bool visit(Luau::AstExprGlobal* node) {
        int ref = serialiseExprNode(node, "global");
        consumeIdentifier(ref, "name", node->location);
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        return false;
    }
    virtual bool visit(Luau::AstExprVarargs* node) {
        int ref = serialiseExprNode(node, "varargs");
        consumeSyntax(ref, "token", node->location.begin, "...");
        return false;
    }
    virtual bool visit(Luau::AstExprCall* node) {
        int ref = serialiseExprNode(node, "call");
        auto cst = locateCst<Luau::CstExprCall*>(node);

        node->func->visit(this);
        lua_setfield(L, -2, "func");

        if (cst->explicitTypes) {
            consumeSyntax(ref, "leftArrow1", cst->explicitTypes->leftArrow1Position, "<");
            consumeSyntax(ref, "leftArrow2", cst->explicitTypes->leftArrow2Position, "<");
        }

        lua_createtable(L, node->typeArguments.size, 0);
        auto idx = 1;
        for (size_t typeIdx = 0; typeIdx < node->typeArguments.size; ++typeIdx) {
            const auto& i = node->typeArguments.data[typeIdx];
            if (i.type)
                i.type->visit(this);
            else
                i.typePack->visit(this);
            lua_rawseti(L, -2, idx++);
            if (cst->explicitTypes && typeIdx < cst->explicitTypes->commaPositions.size)
                consumeSyntax(ref, numberedKey("typeComma", typeIdx).c_str(),
                              cst->explicitTypes->commaPositions.data[typeIdx], ",");
        }
        lua_setfield(L, -2, "typeArguments");

        if (cst->explicitTypes) {
            consumeSyntax(ref, "rightArrow1", cst->explicitTypes->rightArrow1Position, ">");
            consumeSyntax(ref, "rightArrow2", cst->explicitTypes->rightArrow2Position, ">");
        }

        consumeSyntax(ref, "openParen", cst->openParens, "(");

        lua_createtable(L, node->args.size, 0);
        for (size_t argIdx = 0; argIdx < node->args.size; ++argIdx) {
            node->args.data[argIdx]->visit(this);
            lua_rawseti(L, -2, int(argIdx + 1));
            if (argIdx < cst->commaPositions.size)
                consumeSyntax(ref, numberedKey("argComma", argIdx).c_str(),
                              cst->commaPositions.data[argIdx], ",");
        }
        lua_setfield(L, -2, "args");

        lua_pushboolean(L, node->self);
        lua_setfield(L, -2, "self");

        push_location(L, node->argLocation);
        lua_setfield(L, -2, "argLocation");

        consumeSyntax(ref, "closeParen", cst->closeParens, ")");
        return false;
    }
    virtual bool visit(Luau::AstExprIndexName* node) {
        int ref = serialiseExprNode(node, "indexName");

        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        char opText[2] = { node->op, '\0' };
        consumeSyntax(ref, "op", node->opPosition, opText);
        lua_pushstring(L, node->index.value);
        lua_setfield(L, -2, "index");
        consumeSyntax(ref, "index", node->indexLocation);
        push_location(L, node->indexLocation);
        lua_setfield(L, -2, "indexLocation");
        push_position(L, node->opPosition);
        lua_setfield(L, -2, "opPosition");

        return false;
    }
    virtual bool visit(Luau::AstExprIndexExpr* node) {
        int ref = serialiseExprNode(node, "indexExpr");
        auto cst = locateCst<Luau::CstExprIndexExpr*>(node);

        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        consumeSyntax(ref, "openBracket", cst->openBracketPosition, "[");
        node->index->visit(this);
        lua_setfield(L, -2, "index");
        consumeSyntax(ref, "closeBracket", cst->closeBracketPosition, "]");

        return false;
    }
    virtual bool visit(Luau::AstExprFunction* node) {
        int ref = serialiseExprNode(node, "function");
        auto cst = locateCst<Luau::CstExprFunction*>(node);

        attachVisitArray(node->attributes, "attributes");
        if (cst->functionKeywordPosition.hasValue() && claimedFunctionKeywords.erase(node) == 0)
            consumeSyntax(ref, "functionKeyword", cst->functionKeywordPosition, "function");

        if (node->generics.size > 0 || node->genericPacks.size > 0)
            consumeSyntax(ref, "openGenerics", cst->openGenericsPosition, "<");
        attachVisitArray(node->generics, "generics");
        attachVisitArray(node->genericPacks, "genericPacks");
        if (node->generics.size > 0 || node->genericPacks.size > 0)
            consumeSyntax(ref, "closeGenerics", cst->closeGenericsPosition, ">");

        if (node->self) {
            serialiseLocal(node->self);
            lua_setfield(L, -2, "self");
        }

        if (auto val = node->argLocation) consumeSyntax(ref, "openParen", val->begin, "(");

        lua_createtable(L, node->args.size, 0);
        auto idx = 1;
        for (size_t argIdx = 0; argIdx < node->args.size; ++argIdx) {
            auto local = node->args.data[argIdx];
            consumeIdentifier(ref, numberedKey("arg", argIdx).c_str(), local->location);
            serialiseLocal(local);
            int localIndex = lua_absindex(L, -1);
            if (argIdx < cst->argsAnnotationColonPositions.size)
                consumeSyntax(ref, numberedKey("argColon", argIdx).c_str(),
                              cst->argsAnnotationColonPositions.data[argIdx], ":");
            if (local->annotation) {
                local->annotation->visit(this);
                lua_setfield(L, localIndex, "annotation");
            }
            lua_rawseti(L, -2, idx++);
            if (argIdx < cst->argsCommaPositions.size)
                consumeSyntax(ref, numberedKey("argComma", argIdx).c_str(),
                              cst->argsCommaPositions.data[argIdx], ",");
        }
        lua_setfield(L, -2, "args");

        lua_pushboolean(L, node->vararg);
        lua_setfield(L, -2, "vararg");
        push_location(L, node->varargLocation);
        lua_setfield(L, -2, "varargLocation");
        if (node->vararg) consumeSyntax(ref, "vararg", node->varargLocation.begin, "...");
        if (node->varargAnnotation)
            consumeSyntax(ref, "varargColon", cst->varargAnnotationColonPosition, ":");
        if (node->varargAnnotation) {
            node->varargAnnotation->visit(this);
            lua_setfield(L, -2, "varargAnnotation");
        }
        if (auto val = node->argLocation)
            consumeSyntax(ref, "closeParen", positionFromOffset(offsetFromPosition(val->end) - 1),
                          ")");

        if (node->returnAnnotation)
            consumeSyntax(ref, "returnColon", cst->returnSpecifierPosition, ":");
        if (node->returnAnnotation) {
            node->returnAnnotation->visit(this);
            lua_setfield(L, -2, "returnAnnotation");
        }

        node->body->visit(this);
        lua_setfield(L, -2, "body");
        consumeSyntax(ref, "endKeyword", node->body->location.end, "end");

        lua_pushnumber(L, node->functionDepth);
        lua_setfield(L, -2, "functionDepth");

        lua_pushstring(L, node->debugname.value);
        lua_setfield(L, -2, "debugname");

        if (auto val = node->argLocation) {
            push_location(L, *val);
            lua_setfield(L, -2, "argLocation");
        }

        return false;
    }
    virtual bool visit(Luau::AstExprTable* node) {
        int ref = serialiseExprNode(node, "table");
        auto cst = locateCst<Luau::CstExprTable*>(node);
        consumeSyntax(ref, "openBrace", node->location.begin, "{");

        lua_createtable(L, node->items.size, 0);
        for (size_t itemIdx = 0; itemIdx < node->items.size; ++itemIdx) {
            auto i = node->items.data[itemIdx];
            auto cstItem = cst->items.data[itemIdx];
            //
            lua_createtable(L, 0, 3);
            lua_pushstring(L, i.kind == Luau::AstExprTable::Item::List     ? "list"
                              : i.kind == Luau::AstExprTable::Item::Record ? "record"
                                                                           : "general");
            lua_setfield(L, -2, "kind");

            if (i.key) {
                if (i.kind == Luau::AstExprTable::Item::General)
                    consumeSyntax(ref, numberedKey("itemOpenBracket", itemIdx).c_str(),
                                  cstItem.indexerOpenPosition, "[");
                i.key->visit(this);
                lua_setfield(L, -2, "key");
                if (i.kind == Luau::AstExprTable::Item::General)
                    consumeSyntax(ref, numberedKey("itemCloseBracket", itemIdx).c_str(),
                                  cstItem.indexerClosePosition, "]");
                if (i.kind != Luau::AstExprTable::Item::List)
                    consumeSyntax(ref, numberedKey("itemEquals", itemIdx).c_str(),
                                  cstItem.equalsPosition, "=");
            }
            i.value->visit(this);
            lua_setfield(L, -2, "value");
            if (cstItem.separator != Luau::CstExprTable::Missing)
                consumeSyntax(ref, numberedKey("itemSeparator", itemIdx).c_str(),
                              cstItem.separatorPosition,
                              cstItem.separator == Luau::CstExprTable::Comma ? "," : ";");

            lua_rawseti(L, -2, int(itemIdx + 1));
        }
        lua_setfield(L, -2, "items");

        consumeSyntax(ref, "closeBrace",
                      positionFromOffset(offsetFromPosition(node->location.end) - 1), "}");
        return false;
    }
    virtual bool visit(Luau::AstExprUnary* node) {
        int ref = serialiseExprNode(node, "unary");

        auto op = toString(node->op);
        op[0] = tolower(op[0]);
        lua_pushstring(L, op.c_str());
        lua_setfield(L, -2, "op");

        auto cst = locateCst<Luau::CstExprOp*>(node);
        consumeSyntax(ref, "op", cst->opPosition, toString(node->op).data());
        node->expr->visit(this);
        lua_setfield(L, -2, "expr");

        return false;
    }
    virtual bool visit(Luau::AstExprBinary* node) {
        int ref = serialiseExprNode(node, "binary");

        auto op = toString(node->op);
        op[0] = tolower(op[0]);
        lua_pushstring(L, op.c_str());
        lua_setfield(L, -2, "op");

        node->left->visit(this);
        lua_setfield(L, -2, "left");
        auto cst = locateCst<Luau::CstExprOp*>(node);
        consumeSyntax(ref, "op", cst->opPosition, toString(node->op).data());
        node->right->visit(this);
        lua_setfield(L, -2, "right");

        return false;
    }
    virtual bool visit(Luau::AstExprTypeAssertion* node) {
        int ref = serialiseExprNode(node, "typeAssertion");

        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        auto cst = locateCst<Luau::CstExprTypeAssertion*>(node);
        consumeSyntax(ref, "op", cst->opPosition, "::");
        node->annotation->visit(this);
        lua_setfield(L, -2, "annotation");

        return false;
    }
    virtual bool visit(Luau::AstExprIfElse* node) {
        int ref = serialiseExprNode(node, "ifElse");
        auto cst = locateCst<Luau::CstExprIfElse*>(node);

        // CstExprIfElse::isElseIf describes whether *this* node's else-branch is
        // spelled `elseif` (chaining into another if-else expression), not
        // whether this node is itself an elseif. A node that is an elseif is
        // flagged by its parent claiming it below; the parent's `elseKeyword`
        // owns the `elseif` token, so a claimed node skips its own leading
        // keyword. Every other node leads with a plain `if`.
        bool isClaimedElseif = claimedElseifExprKeywords.erase(node) != 0;
        if (!isClaimedElseif) consumeSyntax(ref, "ifKeyword", node->location.begin, "if");
        node->condition->visit(this);
        lua_setfield(L, -2, "condition");
        if (node->hasThen) {
            consumeSyntax(ref, "thenKeyword", cst->thenPosition, "then");
            node->trueExpr->visit(this);
            lua_setfield(L, -2, "thenExpr");
        }
        if (node->hasElse) {
            consumeSyntax(ref, "elseKeyword", cst->elsePosition, cst->isElseIf ? "elseif" : "else");
            if (cst->isElseIf) {
                if (auto elseifExpr =
                        node->falseExpr ? node->falseExpr->as<Luau::AstExprIfElse>() : nullptr)
                    claimedElseifExprKeywords.insert(elseifExpr);
            }
            node->falseExpr->visit(this);
            lua_setfield(L, -2, "elseExpr");
        }

        return false;
    }
    virtual bool visit(Luau::AstExprInterpString* node) {
        int ref = serialiseExprNode(node, "interpString");
        auto cst = locateCst<Luau::CstExprInterpString*>(node);

        lua_createtable(L, node->strings.size, 0);
        auto idx = 1;
        for (auto i : node->strings) {
            lua_pushlstring(L, i.data, i.size);
            lua_rawseti(L, -2, idx++);
        }
        lua_setfield(L, -2, "strings");
        lua_createtable(L, node->expressions.size, 0);
        int expressionsIndex = lua_absindex(L, -1);
        for (size_t i = 0; i < cst->sourceStrings.size; ++i) {
            consumeSyntax(ref, numberedKey("stringPart", i).c_str(), cst->stringPositions.data[i],
                          cst->sourceStrings.data[i].size);
            if (i < node->expressions.size) {
                node->expressions.data[i]->visit(this);
                lua_rawseti(L, expressionsIndex, int(i + 1));
            }
        }
        lua_setfield(L, -2, "expressions");

        return false;
    }
    virtual bool visit(Luau::AstExprInstantiate* node) {
        int ref = serialiseExprNode(node, "instantiate");
        const auto& cst = locateCst<Luau::CstExprExplicitTypeInstantiation*>(node)->instantiation;

        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        consumeSyntax(ref, "leftArrow1", cst.leftArrow1Position, "<");
        consumeSyntax(ref, "leftArrow2", cst.leftArrow2Position, "<");

        lua_createtable(L, node->typeArguments.size, 0);
        for (size_t i = 0; i < node->typeArguments.size; ++i) {
            auto typeArg = node->typeArguments.data[i];
            if (typeArg.type)
                typeArg.type->visit(this);
            else
                typeArg.typePack->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst.commaPositions.size)
                consumeSyntax(ref, numberedKey("typeComma", i).c_str(), cst.commaPositions.data[i],
                              ",");
        }
        lua_setfield(L, -2, "typeArguments");
        consumeSyntax(ref, "rightArrow1", cst.rightArrow1Position, ">");
        consumeSyntax(ref, "rightArrow2", cst.rightArrow2Position, ">");

        return false;
    }

    /// AstStat
    virtual bool visit(Luau::AstStatBlock* node) {
        int ref = serialiseStatNode(node, "block");
        attachVisitArray(node->body, "body");
        if (node->location.begin == Luau::Position{ 0, 0 }) consumeEof(ref);
        return false;
    }
    virtual bool visit(Luau::AstStatIf* node) {
        int ref = serialiseStatNode(node, "if");
        bool isElseif = claimedElseifKeywords.erase(node) != 0;
        if (!isElseif) consumeSyntax(ref, "ifKeyword", node->location.begin, "if");
        node->condition->visit(this);
        lua_setfield(L, -2, "condition");
        if (auto i = node->thenLocation) consumeSyntax(ref, "thenKeyword", i->begin, "then");
        node->thenbody->visit(this);
        lua_setfield(L, -2, "thenBody");
        if (node->elsebody) {
            bool hasElseif = node->elsebody->is<Luau::AstStatIf>();
            if (auto i = node->elseLocation)
                consumeSyntax(ref, "elseKeyword", i->begin, hasElseif ? "elseif" : "else");
            if (hasElseif) claimedElseifKeywords.insert(node->elsebody->as<Luau::AstStatIf>());
            node->elsebody->visit(this);
            lua_setfield(L, -2, "elseBody");
        }
        if (auto i = node->thenLocation) {
            push_location(L, *i);
            lua_setfield(L, -2, "thenLocation");
        }
        if (auto i = node->elseLocation) {
            push_location(L, *i);
            lua_setfield(L, -2, "elseLocation");
        }
        if (!node->elsebody || !node->elsebody->is<Luau::AstStatIf>())
            consumeSyntax(ref, "endKeyword",
                          positionFromOffset(offsetFromPosition(node->location.end) - 3), "end");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatWhile* node) {
        int ref = serialiseStatNode(node, "while");
        consumeSyntax(ref, "whileKeyword", node->location.begin, "while");
        node->condition->visit(this);
        lua_setfield(L, -2, "condition");
        if (node->hasDo) consumeSyntax(ref, "doKeyword", node->doLocation.begin, "do");
        node->body->visit(this);
        lua_setfield(L, -2, "body");

        if (node->hasDo) {
            push_location(L, node->doLocation);
            lua_setfield(L, -2, "doLocation");
        }

        consumeSyntax(ref, "endKeyword",
                      positionFromOffset(offsetFromPosition(node->location.end) - 3), "end");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatRepeat* node) {
        int ref = serialiseStatNode(node, "repeat");
        auto cst = locateCst<Luau::CstStatRepeat*>(node);
        consumeSyntax(ref, "repeatKeyword", node->location.begin, "repeat");
        node->body->visit(this);
        lua_setfield(L, -2, "body");
        consumeSyntax(ref, "untilKeyword", cst->untilPosition, "until");
        node->condition->visit(this);
        lua_setfield(L, -2, "condition");

        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatBreak* node) {
        int ref = serialiseStatNode(node, "break");
        consumeSyntax(ref, "breakKeyword", node->location.begin, "break");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatContinue* node) {
        int ref = serialiseStatNode(node, "continue");
        consumeSyntax(ref, "continueKeyword", node->location.begin, "continue");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatReturn* node) {
        int ref = serialiseStatNode(node, "return");
        auto cst = locateCst<Luau::CstStatReturn*>(node);
        consumeSyntax(ref, "returnKeyword", node->location.begin, "return");
        lua_createtable(L, node->list.size, 0);
        for (size_t i = 0; i < node->list.size; ++i) {
            node->list.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->commaPositions.size)
                consumeSyntax(ref, numberedKey("valueComma", i).c_str(),
                              cst->commaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "list");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatExpr* node) {
        int ref = serialiseStatNode(node, "expr");
        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatLocal* node) {
        int ref = serialiseStatNode(node, "local");
        auto cst = locateCst<Luau::CstStatLocal*>(node);
        consumeSyntax(ref, "localKeyword",
                      cst->declarationKeywordPosition.hasValue() ? cst->declarationKeywordPosition
                                                                 : node->location.begin,
                      node->isConst ? "const" : "local");

        lua_createtable(L, node->vars.size, 0);
        for (size_t i = 0; i < node->vars.size; ++i) {
            auto local = node->vars.data[i];
            consumeIdentifier(ref, numberedKey("var", i).c_str(), local->location);
            serialiseLocal(local);
            int localIndex = lua_absindex(L, -1);
            if (i < cst->varsAnnotationColonPositions.size)
                consumeSyntax(ref, numberedKey("varColon", i).c_str(),
                              cst->varsAnnotationColonPositions.data[i], ":");
            if (local->annotation) {
                local->annotation->visit(this);
                lua_setfield(L, localIndex, "annotation");
            }
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->varsCommaPositions.size)
                consumeSyntax(ref, numberedKey("varComma", i).c_str(),
                              cst->varsCommaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "vars");

        if (auto i = node->equalsSignLocation) consumeSyntax(ref, "equals", i->begin, "=");

        lua_createtable(L, node->values.size, 0);
        for (size_t i = 0; i < node->values.size; ++i) {
            node->values.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->valuesCommaPositions.size)
                consumeSyntax(ref, numberedKey("valueComma", i).c_str(),
                              cst->valuesCommaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "values");
        lua_pushboolean(L, node->isConst);
        lua_setfield(L, -2, "isConst");

        if (auto i = node->equalsSignLocation) {
            push_location(L, *i);
            lua_setfield(L, -2, "equalsSignLocation");
        }
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatFor* node) {
        int ref = serialiseStatNode(node, "for");
        auto cst = locateCst<Luau::CstStatFor*>(node);
        consumeSyntax(ref, "forKeyword", node->location.begin, "for");

        consumeIdentifier(ref, "var", node->var->location);
        serialiseLocal(node->var);
        int varIndex = lua_absindex(L, -1);
        if (cst->annotationColonPosition.hasValue())
            consumeSyntax(ref, "varColon", cst->annotationColonPosition, ":");
        if (node->var->annotation) {
            node->var->annotation->visit(this);
            lua_setfield(L, varIndex, "annotation");
        }
        lua_setfield(L, -2, "var");
        consumeSyntax(ref, "equals", cst->equalsPosition, "=");
        node->from->visit(this);
        lua_setfield(L, -2, "from");
        consumeSyntax(ref, "endComma", cst->endCommaPosition, ",");
        node->to->visit(this);
        lua_setfield(L, -2, "to");
        if (node->step) {
            consumeSyntax(ref, "stepComma", cst->stepCommaPosition, ",");
            node->step->visit(this);
            lua_setfield(L, -2, "step");
        }
        if (node->hasDo) consumeSyntax(ref, "doKeyword", node->doLocation.begin, "do");
        node->body->visit(this);
        lua_setfield(L, -2, "body");
        if (node->hasDo) {
            push_location(L, node->doLocation);
            lua_setfield(L, -2, "doLocation");
        }

        consumeSyntax(ref, "endKeyword",
                      positionFromOffset(offsetFromPosition(node->location.end) - 3), "end");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatForIn* node) {
        int ref = serialiseStatNode(node, "forIn");
        auto cst = locateCst<Luau::CstStatForIn*>(node);
        consumeSyntax(ref, "forKeyword", node->location.begin, "for");

        lua_createtable(L, node->vars.size, 0);
        for (size_t i = 0; i < node->vars.size; ++i) {
            auto local = node->vars.data[i];
            consumeIdentifier(ref, numberedKey("var", i).c_str(), local->location);
            serialiseLocal(local);
            int localIndex = lua_absindex(L, -1);
            if (i < cst->varsAnnotationColonPositions.size)
                consumeSyntax(ref, numberedKey("varColon", i).c_str(),
                              cst->varsAnnotationColonPositions.data[i], ":");
            if (local->annotation) {
                local->annotation->visit(this);
                lua_setfield(L, localIndex, "annotation");
            }
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->varsCommaPositions.size)
                consumeSyntax(ref, numberedKey("varComma", i).c_str(),
                              cst->varsCommaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "vars");

        if (node->hasIn) consumeSyntax(ref, "inKeyword", node->inLocation.begin, "in");
        lua_createtable(L, node->values.size, 0);
        for (size_t i = 0; i < node->values.size; ++i) {
            node->values.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->valuesCommaPositions.size)
                consumeSyntax(ref, numberedKey("valueComma", i).c_str(),
                              cst->valuesCommaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "values");
        if (node->hasDo) consumeSyntax(ref, "doKeyword", node->doLocation.begin, "do");
        node->body->visit(this);
        lua_setfield(L, -2, "body");

        if (node->hasIn) {
            push_location(L, node->inLocation);
            lua_setfield(L, -2, "inLocation");
        }
        if (node->hasDo) {
            push_location(L, node->doLocation);
            lua_setfield(L, -2, "doLocation");
        }

        consumeSyntax(ref, "endKeyword",
                      positionFromOffset(offsetFromPosition(node->location.end) - 3), "end");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatAssign* node) {
        int ref = serialiseStatNode(node, "assign");
        auto cst = locateCst<Luau::CstStatAssign*>(node);
        lua_createtable(L, node->vars.size, 0);
        for (size_t i = 0; i < node->vars.size; ++i) {
            node->vars.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->varsCommaPositions.size)
                consumeSyntax(ref, numberedKey("varComma", i).c_str(),
                              cst->varsCommaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "vars");
        consumeSyntax(ref, "equals", cst->equalsPosition, "=");
        lua_createtable(L, node->values.size, 0);
        for (size_t i = 0; i < node->values.size; ++i) {
            node->values.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (i < cst->valuesCommaPositions.size)
                consumeSyntax(ref, numberedKey("valueComma", i).c_str(),
                              cst->valuesCommaPositions.data[i], ",");
        }
        lua_setfield(L, -2, "values");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatCompoundAssign* node) {
        int ref = serialiseStatNode(node, "compoundAssign");
        auto cst = locateCst<Luau::CstStatCompoundAssign*>(node);

        auto op = toString(node->op);
        op[0] = tolower(op[0]);
        lua_pushstring(L, op.c_str());
        lua_setfield(L, -2, "op");

        node->var->visit(this);
        lua_setfield(L, -2, "var");
        std::string opText = std::string(toString(node->op)) + "=";
        consumeSyntax(ref, "op", cst->opPosition, opText.size());
        node->value->visit(this);
        lua_setfield(L, -2, "value");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatFunction* node) {
        int ref = serialiseStatNode(node, "function");
        auto cst = locateCst<Luau::CstStatFunction*>(node);
        consumeSyntax(ref, "functionKeyword", cst->functionKeywordPosition, "function");
        claimedFunctionKeywords.insert(node->func);

        node->name->visit(this);
        lua_setfield(L, -2, "name");
        node->func->visit(this);
        lua_setfield(L, -2, "func");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatLocalFunction* node) {
        int ref = serialiseStatNode(node, "localFunction");
        auto cst = locateCst<Luau::CstStatLocalFunction*>(node);
        consumeSyntax(ref, "localKeyword", cst->localKeywordPosition, "local");
        consumeSyntax(ref, "functionKeyword", cst->functionKeywordPosition, "function");
        claimedFunctionKeywords.insert(node->func);

        consumeIdentifier(ref, "name", node->name->location);
        serialiseLocal(node->name);
        lua_setfield(L, -2, "name");
        node->func->visit(this);
        lua_setfield(L, -2, "func");
        lua_pushboolean(L, node->isConst);
        lua_setfield(L, -2, "isConst");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatTypeAlias* node) {
        int ref = serialiseStatNode(node, "typeAlias");
        auto cst = locateCst<Luau::CstStatTypeAlias*>(node);
        if (node->exported) consumeSyntax(ref, "exportKeyword", node->location.begin, "export");
        consumeSyntax(ref, "typeKeyword", cst->typeKeywordPosition, "type");

        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name", node->nameLocation);

        push_location(L, node->nameLocation);
        lua_setfield(L, -2, "nameLocation");

        if (node->generics.size > 0 || node->genericPacks.size > 0)
            consumeSyntax(ref, "openGenerics", cst->genericsOpenPosition, "<");
        attachVisitArray(node->generics, "generics");
        attachVisitArray(node->genericPacks, "genericPacks");
        if (node->generics.size > 0 || node->genericPacks.size > 0)
            consumeSyntax(ref, "closeGenerics", cst->genericsClosePosition, ">");

        consumeSyntax(ref, "equals", cst->equalsPosition, "=");
        node->type->visit(this);
        lua_setfield(L, -2, "aliasedType");

        lua_pushboolean(L, node->exported);
        lua_setfield(L, -2, "exported");

        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatTypeFunction* node) {
        int ref = serialiseStatNode(node, "typeFunction");
        auto cst = locateCst<Luau::CstStatTypeFunction*>(node);
        if (node->exported) consumeSyntax(ref, "exportKeyword", node->location.begin, "export");
        consumeSyntax(ref, "typeKeyword", cst->typeKeywordPosition, "type");
        consumeSyntax(ref, "functionKeyword", cst->functionKeywordPosition, "function");

        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name", node->nameLocation);

        push_location(L, node->nameLocation);
        lua_setfield(L, -2, "nameLocation");

        if (node->body) {
            claimedFunctionKeywords.insert(node->body);
            node->body->visit(this);
            lua_setfield(L, -2, "body");
        }

        lua_pushboolean(L, node->exported);
        lua_setfield(L, -2, "exported");
        lua_pushboolean(L, node->hasErrors);
        lua_setfield(L, -2, "hasErrors");

        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatClass* node) {
        int ref = serialiseStatNode(node, "class");
        if (node->exported) consumeSyntax(ref, "exportKeyword", node->location.begin, "export");

        size_t classSearchStart = node->exported ? offsetFromPosition(node->location.begin) + 6
                                                 : offsetFromPosition(node->location.begin);
        if (auto classPos = findCharPosition(classSearchStart,
                                             offsetFromPosition(node->name->location.begin), 'c'))
            consumeSyntax(ref, "classKeyword", *classPos, "class");

        consumeIdentifier(ref, "name", node->name->location);
        serialiseLocal(node->name);
        lua_setfield(L, -2, "name");

        lua_createtable(L, node->members.size, 0);
        for (size_t i = 0; i < node->members.size; ++i) {
            lua_createtable(L, 0, 8);
            if (auto prop = node->members.data[i].get_if<Luau::AstClassProperty>()) {
                lua_pushstring(L, "property");
                lua_setfield(L, -2, "kind");
                if (prop->qualifierLocation.begin.hasValue()) {
                    consumeSyntax(ref, numberedKey("memberQualifier", i).c_str(),
                                  prop->qualifierLocation.begin,
                                  sourceSlice(offsetFromPosition(prop->qualifierLocation.begin),
                                              offsetFromPosition(prop->qualifierLocation.end))
                                      .size());
                    push_location(L, prop->qualifierLocation);
                    lua_setfield(L, -2, "qualifierLocation");
                }
                lua_pushstring(L, prop->name.value);
                lua_setfield(L, -2, "name");
                consumeSyntax(ref, numberedKey("memberName", i).c_str(), prop->nameLocation);
                push_location(L, prop->nameLocation);
                lua_setfield(L, -2, "nameLocation");
                if (prop->typeColonLocation) {
                    consumeSyntax(ref, numberedKey("memberColon", i).c_str(),
                                  prop->typeColonLocation->begin, ":");
                    push_location(L, *prop->typeColonLocation);
                    lua_setfield(L, -2, "typeColonLocation");
                }
                if (prop->ty) {
                    prop->ty->visit(this);
                    lua_setfield(L, -2, "type");
                }
            } else if (auto method = node->members.data[i].get_if<Luau::AstClassMethod>()) {
                lua_pushstring(L, "method");
                lua_setfield(L, -2, "kind");
                if (method->qualifierLocation) {
                    consumeSyntax(ref, numberedKey("memberQualifier", i).c_str(),
                                  method->qualifierLocation->begin,
                                  sourceSlice(offsetFromPosition(method->qualifierLocation->begin),
                                              offsetFromPosition(method->qualifierLocation->end))
                                      .size());
                    push_location(L, *method->qualifierLocation);
                    lua_setfield(L, -2, "qualifierLocation");
                }
                consumeSyntax(ref, numberedKey("memberFunctionKeyword", i).c_str(),
                              method->keywordLocation.begin, "function");
                push_location(L, method->keywordLocation);
                lua_setfield(L, -2, "keywordLocation");
                lua_pushstring(L, method->functionName.value);
                lua_setfield(L, -2, "name");
                consumeSyntax(ref, numberedKey("memberName", i).c_str(), method->nameLocation);
                push_location(L, method->nameLocation);
                lua_setfield(L, -2, "nameLocation");
                claimedFunctionKeywords.insert(method->function);
                method->function->visit(this);
                lua_setfield(L, -2, "function");
            }
            lua_rawseti(L, -2, int(i + 1));
        }
        lua_setfield(L, -2, "members");
        lua_pushboolean(L, node->exported);
        lua_setfield(L, -2, "exported");
        consumeSyntax(ref, "endKeyword",
                      positionFromOffset(offsetFromPosition(node->location.end) - 3), "end");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }

    /// AstType
    virtual bool visit(Luau::AstType* node) {
        int ref = serialiseNode(node, "type", "unknown");
        consumeSyntax(ref, "token", node->location);
        return false;
    }
    virtual bool visit(Luau::AstTypeReference* node) {
        int ref = serialiseNode(node, "type", "reference");
        auto cst = maybeCst<Luau::CstTypeReference*>(node);

        lua_pushboolean(L, node->hasParameterList);
        lua_setfield(L, -2, "hasParameterList");
        if (node->prefix) {
            lua_pushstring(L, node->prefix->value);
            lua_setfield(L, -2, "prefix");
            if (node->prefixLocation) consumeSyntax(ref, "prefix", *node->prefixLocation);
            if (cst) consumeSyntax(ref, "prefixDot", cst->prefixPointPosition, ".");
            if (node->prefixLocation) {
                push_location(L, *node->prefixLocation);
                lua_setfield(L, -2, "prefixLocation");
            }
        }

        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name", node->nameLocation);
        push_location(L, node->nameLocation);
        lua_setfield(L, -2, "nameLocation");

        if (node->parameters.size > 0 || node->hasParameterList) {
            if (cst) consumeSyntax(ref, "openParameters", cst->openParametersPosition, "<");
            lua_createtable(L, node->parameters.size, 0);
            for (size_t i = 0; i < node->parameters.size; ++i) {
                serialiseTypeOrPack(node->parameters.data[i]);
                lua_rawseti(L, -2, int(i + 1));
                if (cst && i < cst->parametersCommaPositions.size)
                    consumeSyntax(ref, numberedKey("parameterComma", i).c_str(),
                                  cst->parametersCommaPositions.data[i], ",");
            }
            lua_setfield(L, -2, "parameters");
            if (cst) consumeSyntax(ref, "closeParameters", cst->closeParametersPosition, ">");
        }
        return false;
    }
    virtual bool visit(Luau::AstTypeTable* node) {
        int ref = serialiseNode(node, "type", "table");
        auto cst = maybeCst<Luau::CstTypeTable*>(node);
        consumeSyntax(ref, "openBrace", node->location.begin, "{");

        lua_createtable(L, node->props.size, 0);
        int propsIndex = lua_absindex(L, -1);
        int parentIndex = lua_absindex(L, -2);

        size_t propIndex = 0;
        if (cst && cst->isArray && node->indexer) {
            lua_createtable(L, 0, 5);
            node->indexer->resultType->visit(this);
            lua_setfield(L, -2, "resultType");
            serialiseSyntheticArrayIndexType(node->indexer->indexType);
            lua_setfield(L, -2, "indexType");
            push_location(L, node->indexer->location);
            lua_setfield(L, -2, "location");
            lua_pushstring(L, tableAccessToString(node->indexer->access));
            lua_setfield(L, -2, "access");
            if (node->indexer->accessLocation) {
                push_location(L, *node->indexer->accessLocation);
                lua_setfield(L, -2, "accessLocation");
            }
            lua_setfield(L, parentIndex, "indexer");
        } else if (cst && !cst->isArray) {
            for (size_t i = 0; i < cst->items.size; ++i) {
                const auto& item = cst->items.data[i];
                if (item.kind == Luau::CstTypeTable::Item::Kind::Indexer && node->indexer) {
                    lua_createtable(L, 0, 5);
                    if (node->indexer->accessLocation) {
                        consumeSyntax(ref, numberedKey("indexerAccess", i).c_str(),
                                      *node->indexer->accessLocation);
                        push_location(L, *node->indexer->accessLocation);
                        lua_setfield(L, -2, "accessLocation");
                    }
                    consumeSyntax(ref, numberedKey("indexerOpen", i).c_str(),
                                  item.indexerOpenPosition, "[");
                    node->indexer->indexType->visit(this);
                    lua_setfield(L, -2, "indexType");
                    consumeSyntax(ref, numberedKey("indexerClose", i).c_str(),
                                  item.indexerClosePosition, "]");
                    consumeSyntax(ref, numberedKey("indexerColon", i).c_str(), item.colonPosition,
                                  ":");
                    node->indexer->resultType->visit(this);
                    lua_setfield(L, -2, "resultType");
                    push_location(L, node->indexer->location);
                    lua_setfield(L, -2, "location");
                    lua_pushstring(L, tableAccessToString(node->indexer->access));
                    lua_setfield(L, -2, "access");
                    lua_setfield(L, parentIndex, "indexer");
                } else if (propIndex < node->props.size) {
                    auto& prop = node->props.data[propIndex];
                    lua_createtable(L, 0, 5);
                    lua_pushstring(L, prop.name.value);
                    lua_setfield(L, -2, "name");
                    if (prop.accessLocation) {
                        consumeSyntax(ref, numberedKey("propAccess", propIndex).c_str(),
                                      *prop.accessLocation);
                        push_location(L, *prop.accessLocation);
                        lua_setfield(L, -2, "accessLocation");
                    }
                    if (item.kind == Luau::CstTypeTable::Item::Kind::StringProperty) {
                        consumeSyntax(ref, numberedKey("propOpenBracket", propIndex).c_str(),
                                      item.indexerOpenPosition, "[");
                        if (item.stringInfo)
                            consumeSyntax(ref, numberedKey("propString", propIndex).c_str(),
                                          item.stringPosition, item.stringInfo->sourceString.size);
                        consumeSyntax(ref, numberedKey("propCloseBracket", propIndex).c_str(),
                                      item.indexerClosePosition, "]");
                    } else {
                        consumeSyntax(ref, numberedKey("propName", propIndex).c_str(),
                                      prop.location);
                    }
                    consumeSyntax(ref, numberedKey("propColon", propIndex).c_str(),
                                  item.colonPosition, ":");
                    prop.type->visit(this);
                    lua_setfield(L, -2, "type");
                    push_location(L, prop.location);
                    lua_setfield(L, -2, "location");
                    lua_pushstring(L, tableAccessToString(prop.access));
                    lua_setfield(L, -2, "access");
                    lua_rawseti(L, propsIndex, int(propIndex + 1));
                    ++propIndex;
                }
                if (item.separator != Luau::CstExprTable::Missing)
                    consumeSyntax(ref, numberedKey("itemSeparator", i).c_str(),
                                  item.separatorPosition,
                                  item.separator == Luau::CstExprTable::Comma ? "," : ";");
            }
        } else {
            for (size_t i = 0; i < node->props.size; ++i) {
                auto& prop = node->props.data[i];
                lua_createtable(L, 0, 5);
                lua_pushstring(L, prop.name.value);
                lua_setfield(L, -2, "name");
                if (prop.accessLocation) {
                    consumeSyntax(ref, numberedKey("propAccess", i).c_str(), *prop.accessLocation);
                    push_location(L, *prop.accessLocation);
                    lua_setfield(L, -2, "accessLocation");
                }
                consumeSyntax(ref, numberedKey("propName", i).c_str(), prop.location);
                prop.type->visit(this);
                lua_setfield(L, -2, "type");
                push_location(L, prop.location);
                lua_setfield(L, -2, "location");
                lua_pushstring(L, tableAccessToString(prop.access));
                lua_setfield(L, -2, "access");
                lua_rawseti(L, propsIndex, int(i + 1));
            }
            if (node->indexer) {
                serialiseTableIndexer(node->indexer);
                lua_setfield(L, parentIndex, "indexer");
            }
        }
        lua_setfield(L, parentIndex, "props");
        consumeSyntax(ref, "closeBrace",
                      positionFromOffset(offsetFromPosition(node->location.end) - 1), "}");
        return false;
    }
    virtual bool visit(Luau::AstTypeFunction* node) {
        int ref = serialiseNode(node, "type", "function");
        auto cst = maybeCst<Luau::CstTypeFunction*>(node);

        attachVisitArray(node->attributes, "attributes");
        if (node->generics.size > 0 || node->genericPacks.size > 0) {
            if (cst) consumeSyntax(ref, "openGenerics", cst->openGenericsPosition, "<");
            attachVisitArray(node->generics, "generics");
            attachVisitArray(node->genericPacks, "genericPacks");
            if (cst) consumeSyntax(ref, "closeGenerics", cst->closeGenericsPosition, ">");
        }

        if (cst) consumeSyntax(ref, "openArgs", cst->openArgsPosition, "(");
        serialiseTypeFunctionArgs(node->argTypes, node->argNames,
                                  cst ? &cst->argumentNameColonPositions : nullptr,
                                  cst ? &cst->argumentsCommaPositions : nullptr, ref);
        if (cst) consumeSyntax(ref, "closeArgs", cst->closeArgsPosition, ")");
        if (cst) consumeSyntax(ref, "returnArrow", cst->returnArrowPosition, "->");
        if (node->returnTypes) {
            node->returnTypes->visit(this);
            lua_setfield(L, -2, "returnTypes");
        }
        return false;
    }
    virtual bool visit(Luau::AstTypeTypeof* node) {
        int ref = serialiseNode(node, "type", "typeof");
        auto cst = maybeCst<Luau::CstTypeTypeof*>(node);
        consumeSyntax(ref, "typeofKeyword", node->location.begin, "typeof");
        if (cst) consumeSyntax(ref, "openParen", cst->openPosition, "(");
        node->expr->visit(this);
        lua_setfield(L, -2, "expr");
        if (cst) consumeSyntax(ref, "closeParen", cst->closePosition, ")");
        return false;
    }
    virtual bool visit(Luau::AstTypeOptional* node) {
        int ref = serialiseNode(node, "type", "optional");
        consumeSyntax(ref, "token", node->location.begin, "?");
        return false;
    }
    virtual bool visit(Luau::AstTypeUnion* node) {
        int ref = serialiseNode(node, "type", "union");
        auto cst = maybeCst<Luau::CstTypeUnion*>(node);
        if (cst && cst->leadingPosition.hasValue())
            consumeSyntax(ref, "leadingSeparator", cst->leadingPosition, "|");
        lua_createtable(L, node->types.size, 0);
        // A postfix `?` becomes an AstTypeOptional member of the union with no
        // `|` of its own, so separators do not line up one-to-one with members.
        // The `|` tokens are recorded in order, each preceding a non-optional
        // member after the first; consume them on that basis instead.
        size_t separatorIdx = 0;
        for (size_t i = 0; i < node->types.size; ++i) {
            if (i > 0 && !node->types.data[i]->is<Luau::AstTypeOptional>() && cst &&
                separatorIdx < cst->separatorPositions.size) {
                consumeSyntax(ref, numberedKey("separator", separatorIdx).c_str(),
                              cst->separatorPositions.data[separatorIdx], "|");
                ++separatorIdx;
            }
            node->types.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
        }
        lua_setfield(L, -2, "types");
        return false;
    }
    virtual bool visit(Luau::AstTypeIntersection* node) {
        int ref = serialiseNode(node, "type", "intersection");
        auto cst = maybeCst<Luau::CstTypeIntersection*>(node);
        if (cst && cst->leadingPosition.hasValue())
            consumeSyntax(ref, "leadingSeparator", cst->leadingPosition, "&");
        lua_createtable(L, node->types.size, 0);
        for (size_t i = 0; i < node->types.size; ++i) {
            node->types.data[i]->visit(this);
            lua_rawseti(L, -2, int(i + 1));
            if (cst && i < cst->separatorPositions.size)
                consumeSyntax(ref, numberedKey("separator", i).c_str(),
                              cst->separatorPositions.data[i], "&");
        }
        lua_setfield(L, -2, "types");
        return false;
    }
    virtual bool visit(Luau::AstExprError* node) {
        int ref = serialiseExprNode(node, "error");
        attachVisitArray(node->expressions, "expressions");
        lua_pushinteger(L, node->messageIndex);
        lua_setfield(L, -2, "messageIndex");
        consumeSpan(ref, "span", node->location);
        return false;
    }
    virtual bool visit(Luau::AstStatError* node) {
        int ref = serialiseStatNode(node, "error");
        attachVisitArray(node->expressions, "expressions");
        attachVisitArray(node->statements, "statements");
        lua_pushinteger(L, node->messageIndex);
        lua_setfield(L, -2, "messageIndex");
        consumeSpan(ref, "span", node->location);
        return false;
    }
    virtual bool visit(Luau::AstTypeError* node) {
        int ref = serialiseNode(node, "type", "error");
        attachVisitArray(node->types, "types");
        lua_pushboolean(L, node->isMissing);
        lua_setfield(L, -2, "isMissing");
        lua_pushinteger(L, node->messageIndex);
        lua_setfield(L, -2, "messageIndex");
        consumeSpan(ref, "span", node->location);
        return false;
    }
    virtual bool visit(Luau::AstTypeSingletonBool* node) {
        int ref = serialiseNode(node, "type", "singletonBool");
        lua_pushboolean(L, node->value);
        lua_setfield(L, -2, "value");
        consumeSyntax(ref, "token", node->location.begin, node->value ? "true" : "false");
        return false;
    }
    virtual bool visit(Luau::AstTypeSingletonString* node) {
        int ref = serialiseNode(node, "type", "singletonString");
        auto cst = maybeCst<Luau::CstTypeSingletonString*>(node);
        lua_pushlstring(L, node->value.data, node->value.size);
        lua_setfield(L, -2, "value");
        consumeSyntax(ref, "token", node->location.begin,
                      cst ? cst->sourceString.size
                          : offsetFromPosition(node->location.end) -
                                offsetFromPosition(node->location.begin));
        return false;
    }
    virtual bool visit(Luau::AstTypeGroup* node) {
        int ref = serialiseNode(node, "type", "group");
        consumeSyntax(ref, "openParen", node->location.begin, "(");
        node->type->visit(this);
        lua_setfield(L, -2, "innerType");
        if (auto cst = maybeCst<Luau::CstTypeGroup*>(node))
            consumeSyntax(ref, "closeParen", cst->closePosition, ")");
        else
            consumeSyntax(ref, "closeParen",
                          positionFromOffset(offsetFromPosition(node->location.end) - 1), ")");
        return false;
    }
    virtual bool visit(Luau::AstTypePack* node) {
        int ref = serialiseNode(node, "typePack", "unknown");
        consumeSyntax(ref, "token", node->location);
        return false;
    }
    virtual bool visit(Luau::AstTypePackExplicit* node) {
        int ref = serialiseNode(node, "typePack", "explicit");
        auto cst = maybeCst<Luau::CstTypePackExplicit*>(node);
        if (cst && cst->openParenthesesPosition.hasValue())
            consumeSyntax(ref, "openParen", cst->openParenthesesPosition, "(");
        serialiseTypeList(node->typeList, ref, cst ? &cst->commaPositions : nullptr, "comma");
        lua_setfield(L, -2, "typeList");
        if (cst && cst->closeParenthesesPosition.hasValue())
            consumeSyntax(ref, "closeParen", cst->closeParenthesesPosition, ")");
        return false;
    }
    virtual bool visit(Luau::AstTypePackVariadic* node) {
        int ref = serialiseNode(node, "typePack", "variadic");
        // A variadic pack from `...T` in a type list bakes the `...` into its
        // location, so its begin sits before the type. The variant synthesised
        // for a function's vararg annotation (`function f(...: T)`) has no `...`
        // of its own - its location is just the type `T`, while the `...` and
        // `:` are owned by the enclosing function. Only consume the ellipsis
        // when it is genuinely present in front of the type.
        if (node->location.begin != node->variadicType->location.begin)
            consumeSyntax(ref, "ellipsis", node->location.begin, "...");
        node->variadicType->visit(this);
        lua_setfield(L, -2, "variadicType");
        return false;
    }
    virtual bool visit(Luau::AstTypePackGeneric* node) {
        int ref = serialiseNode(node, "typePack", "generic");
        auto cst = maybeCst<Luau::CstTypePackGeneric*>(node);
        lua_pushstring(L, node->genericName.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name",
                      Luau::Location{ node->location.begin, cst && cst->ellipsisPosition.hasValue()
                                                                ? cst->ellipsisPosition
                                                                : node->location.end });
        if (cst) consumeSyntax(ref, "ellipsis", cst->ellipsisPosition, "...");
        return false;
    }

    /// Weird misc
    virtual bool visit(Luau::AstGenericTypePack* node) {
        int ref = serialiseNode(node, "generic", "typePack");
        auto cst = maybeCst<Luau::CstGenericTypePack*>(node);
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name",
                      Luau::Location{ node->location.begin, cst && cst->ellipsisPosition.hasValue()
                                                                ? cst->ellipsisPosition
                                                                : node->location.end });
        if (cst) consumeSyntax(ref, "ellipsis", cst->ellipsisPosition, "...");
        if (node->defaultValue) {
            if (cst) consumeSyntax(ref, "defaultEquals", cst->defaultEqualsPosition, "=");
            node->defaultValue->visit(this);
            lua_setfield(L, -2, "default");
        }
        return false;
    }
    virtual bool visit(Luau::AstGenericType* node) {
        int ref = serialiseNode(node, "generic", "type");
        auto cst = maybeCst<Luau::CstGenericType*>(node);
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name",
                      node->defaultValue && cst
                          ? Luau::Location{ node->location.begin, cst->defaultEqualsPosition }
                          : node->location);
        if (node->defaultValue) {
            if (cst) consumeSyntax(ref, "defaultEquals", cst->defaultEqualsPosition, "=");
            node->defaultValue->visit(this);
            lua_setfield(L, -2, "default");
        }
        return false;
    }

    /// Declaration syntax
    virtual bool visit(Luau::AstStatDeclareGlobal* node) {
        int ref = serialiseStatNode(node, "declareGlobal");
        consumeSyntax(ref, "declareKeyword", node->location.begin, "declare");
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name", node->nameLocation);
        push_location(L, node->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        if (auto colon = findCharPosition(offsetFromPosition(node->nameLocation.end),
                                          offsetFromPosition(node->type->location.begin), ':'))
            consumeSyntax(ref, "colon", *colon, ":");
        node->type->visit(this);
        lua_setfield(L, -2, "declaredType");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatDeclareFunction* node) {
        int ref = serialiseStatNode(node, "declareFunction");
        consumeSyntax(ref, "declareKeyword", node->location.begin, "declare");
        attachVisitArray(node->attributes, "attributes");
        if (auto functionPos = findCharPosition(offsetFromPosition(node->location.begin),
                                                offsetFromPosition(node->nameLocation.begin), 'f'))
            consumeSyntax(ref, "functionKeyword", *functionPos, "function");
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        consumeSyntax(ref, "name", node->nameLocation);
        push_location(L, node->nameLocation);
        lua_setfield(L, -2, "nameLocation");
        attachVisitArray(node->generics, "generics");
        attachVisitArray(node->genericPacks, "genericPacks");
        serialiseTypeList(node->params);
        lua_setfield(L, -2, "params");
        serialiseArgNames(node->paramNames);
        lua_setfield(L, -2, "paramNames");
        lua_pushboolean(L, node->vararg);
        lua_setfield(L, -2, "vararg");
        push_location(L, node->varargLocation);
        lua_setfield(L, -2, "varargLocation");
        if (node->retTypes) {
            node->retTypes->visit(this);
            lua_setfield(L, -2, "returnTypes");
        }
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstStatDeclareExternType* node) {
        int ref = serialiseStatNode(node, "declareExternType");
        // Luau sets this node's location to begin at the class *name*, not the
        // `declare` keyword (see Parser::parseDeclaration). Consuming "declare"
        // at location.begin would stamp it over the name and overshoot the end
        // of an empty class body, so locate the real keyword from the cursor.
        if (auto declarePos = findCharPosition(offsetFromPosition(cursor),
                                               offsetFromPosition(node->location.begin), 'd'))
            consumeSyntax(ref, "declareKeyword", *declarePos, "declare");
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        if (node->superName) {
            lua_pushstring(L, node->superName->value);
            lua_setfield(L, -2, "superName");
        }
        lua_createtable(L, node->props.size, 0);
        for (size_t i = 0; i < node->props.size; ++i) {
            const auto& prop = node->props.data[i];
            lua_createtable(L, 0, 7);
            lua_pushstring(L, prop.name.value);
            lua_setfield(L, -2, "name");
            push_location(L, prop.nameLocation);
            lua_setfield(L, -2, "nameLocation");
            if (prop.ty) {
                prop.ty->visit(this);
                lua_setfield(L, -2, "type");
            }
            lua_pushboolean(L, prop.isMethod);
            lua_setfield(L, -2, "isMethod");
            lua_pushstring(L, tableAccessToString(prop.access));
            lua_setfield(L, -2, "access");
            push_location(L, prop.location);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, int(i + 1));
        }
        lua_setfield(L, -2, "props");
        if (node->indexer) {
            serialiseTableIndexer(node->indexer);
            lua_setfield(L, -2, "indexer");
        }
        consumeSyntax(ref, "endKeyword",
                      positionFromOffset(offsetFromPosition(node->location.end) - 3), "end");
        consumeSemicolonIfPresent(ref, node);
        return false;
    }
    virtual bool visit(Luau::AstAttr* node) {
        int ref = serialiseNode(node, "attr", "attribute");
        consumeSyntax(ref, "name", node->location.begin, 1 + std::strlen(node->name.value));
        lua_pushstring(L, attrTypeToString(node->type));
        lua_setfield(L, -2, "attrType");
        lua_pushstring(L, node->name.value);
        lua_setfield(L, -2, "name");
        attachVisitArray(node->args, "args");
        if (node->type == Luau::AstAttr::Deprecated) {
            auto info = node->deprecatedInfo();
            lua_createtable(L, 0, 3);
            lua_pushboolean(L, info.deprecated);
            lua_setfield(L, -2, "deprecated");
            if (info.use) {
                lua_pushstring(L, info.use->c_str());
                lua_setfield(L, -2, "use");
            }
            if (info.reason) {
                lua_pushstring(L, info.reason->c_str());
                lua_setfield(L, -2, "reason");
            }
            lua_setfield(L, -2, "deprecatedInfo");
        }
        return false;
    }

    /// Fallback
    virtual bool visit(Luau::AstNode* node) {
        luaL_errorL(L, "Unimplemented node in AST serialiser: %s", getNodeTypeName(node));
    }
};

// ---------------------------------------------------------------------------
// luau.parse(source [, options]) -> ParseResult
// ---------------------------------------------------------------------------
static bool read_collect_comments_option(lua_State* L, int index) {
    bool collectComments = false;
    if (lua_istable(L, index)) {
        lua_getfield(L, index, "collectComments");
        if (lua_isboolean(L, -1)) collectComments = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);

        lua_getfield(L, index, "captureComments");
        if (lua_isboolean(L, -1)) collectComments = collectComments || lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
    }

    return collectComments;
}

template <typename Result>
static void attach_parse_result_fields(lua_State* L, int resultIndex, const Result& result,
                                       const char* src, size_t srcLen, bool collectComments) {
    lua_createtable(L, int(result.errors.size()), 0);
    for (size_t i = 0; i < result.errors.size(); i++) {
        lua_createtable(L, 0, 2);
        lua_pushstring(L, result.errors[i].getMessage().c_str());
        lua_setfield(L, -2, "message");
        push_location(L, result.errors[i].getLocation());
        lua_setfield(L, -2, "location");
        lua_rawseti(L, -2, int(i + 1));
    }
    lua_setfield(L, resultIndex, "errors");

    if (collectComments) {
        lua_createtable(L, int(result.commentLocations.size()), 0);
        for (size_t i = 0; i < result.commentLocations.size(); i++) {
            lua_createtable(L, 0, 2);
            lua_pushstring(L, comment_type_to_string(result.commentLocations[i].type));
            lua_setfield(L, -2, "type");
            push_location(L, result.commentLocations[i].location);
            lua_setfield(L, -2, "location");
            lua_rawseti(L, -2, int(i + 1));
        }
        lua_setfield(L, resultIndex, "comments");
    }
}

static int l_parse(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    eryx_enable_all_luau_flags();
    eryx_apply_user_flags_opt(L, 2);

    bool collectComments = read_collect_comments_option(L, 2);

    Luau::Allocator allocator;
    Luau::AstNameTable names(allocator);
    Luau::ParseOptions opts;
    opts.allowDeclarationSyntax = true;
    opts.captureComments = collectComments;
    opts.storeCstData = true;

    Luau::ParseResult result = Luau::Parser::parse(src, srcLen, names, allocator, opts);

    AstSerialiser serialiser{ L, src, srcLen, result.cstNodeMap };

    lua_createtable(L, 0, 6);
    int resultIndex = lua_absindex(L, -1);

    if (result.root) {
        result.root->visit(&serialiser);
        lua_setfield(L, resultIndex, "root");
    } else {
        lua_pushnil(L);
        lua_setfield(L, resultIndex, "root");
    }

    attach_parse_result_fields(L, resultIndex, result, src, srcLen, collectComments);

    return 1;
}

// ---------------------------------------------------------------------------
// luau.parseExpr(source [, options]) -> ParseExprResult
// ---------------------------------------------------------------------------
static int l_parseExpr(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    eryx_enable_all_luau_flags();
    eryx_apply_user_flags_opt(L, 2);

    bool collectComments = read_collect_comments_option(L, 2);

    Luau::Allocator allocator;
    Luau::AstNameTable names(allocator);
    Luau::ParseOptions opts;
    opts.allowDeclarationSyntax = true;
    opts.captureComments = collectComments;
    opts.storeCstData = true;

    Luau::ParseNodeResult<Luau::AstExpr> result =
        Luau::Parser::parseExpr(src, srcLen, names, allocator, opts);

    AstSerialiser serialiser{ L, src, srcLen, result.cstNodeMap };

    lua_createtable(L, 0, 6);
    int resultIndex = lua_absindex(L, -1);

    if (result.root) {
        result.root->visit(&serialiser);
        lua_setfield(L, resultIndex, "root");
    } else {
        lua_pushnil(L);
        lua_setfield(L, resultIndex, "root");
    }

    attach_parse_result_fields(L, resultIndex, result, src, srcLen, collectComments);

    return 1;
}

// ---------------------------------------------------------------------------
// luau.prettyPrint(source) -> string
// ---------------------------------------------------------------------------
static int l_prettyPrint(lua_State* L) {
    size_t srcLen = 0;
    const char* src = luaL_checklstring(L, 1, &srcLen);

    std::string_view sv(src, srcLen);
    Luau::PrettyPrintResult ppr = Luau::prettyPrint(sv);

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

    eryx_enable_all_luau_flags();
    eryx_apply_user_flags_opt(L, 2);

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
    // Accepts (source, chunkname?, options?) or (source, options?) if arg 2 is a table.
    int optIdx = lua_istable(L, 2) ? 2 : 3;
    const char* chunkname = lua_istable(L, 2) ? "=load" : luaL_optstring(L, 2, "=load");

    eryx_enable_all_luau_flags();
    eryx_apply_user_flags_opt(L, optIdx);

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

    eryx_enable_all_luau_flags();
    eryx_apply_user_flags_opt(L, 2);

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

static int l_parseLuaurc(lua_State* L) {
    size_t configSize;
    const char* source = luaL_checklstring(L, 1, &configSize);

    const char* path = luaL_checkstring(L, 2);
    const bool overwriteAliases = luaL_optboolean(L, 3, true);
    const bool compat = luaL_optboolean(L, 4, false);

    Luau::ConfigOptions opts;
    opts.aliasOptions = Luau::ConfigOptions::AliasOptions{
        .configLocation = path,
        .overwriteAliases = overwriteAliases,
    };
    opts.compat = compat;

    Luau::Config cfg;
    auto err = Luau::parseConfig(source, cfg, opts);
    if (err) {
        luaL_error(L, "Error parsing config: %s", (*err).c_str());
    }

    lua_createtable(L, 0, 8);

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

    lua_pushstring(L, mode_to_string(cfg.mode));
    lua_setfield(L, -2, "mode");

    lua_createtable(L, 0, 0);
    for (int code = Luau::LintWarning::Code_Unknown; code < Luau::LintWarning::Code__Count;
         ++code) {
        if (cfg.enabledLint.isEnabled(Luau::LintWarning::Code(code))) {
            lua_pushboolean(L, true);
            lua_setfield(L, -2, Luau::LintWarning::getName(Luau::LintWarning::Code(code)));
        }
    }
    lua_setfield(L, -2, "enabledLint");

    lua_createtable(L, 0, 0);
    for (int code = Luau::LintWarning::Code_Unknown; code < Luau::LintWarning::Code__Count;
         ++code) {
        if (cfg.fatalLint.isEnabled(Luau::LintWarning::Code(code))) {
            lua_pushboolean(L, true);
            lua_setfield(L, -2, Luau::LintWarning::getName(Luau::LintWarning::Code(code)));
        }
    }
    lua_setfield(L, -2, "fatalLint");

    lua_pushboolean(L, cfg.lintErrors);
    lua_setfield(L, -2, "lintErrors");
    lua_pushboolean(L, cfg.typeErrors);
    lua_setfield(L, -2, "typeErrors");

    lua_createtable(L, (int)cfg.globals.size(), 0);
    for (size_t i = 0; i < cfg.globals.size(); ++i) {
        lua_pushstring(L, cfg.globals[i].c_str());
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "globals");

    lua_createtable(L, 0, (int)cfg.aliases.size());
    for (const auto& [key, alias] : cfg.aliases) {
        lua_createtable(L, 0, 3);

        lua_pushstring(L, std::string(alias.configLocation).c_str());
        lua_setfield(L, -2, "configLocation");

        lua_pushstring(L, alias.originalCase.c_str());
        lua_setfield(L, -2, "originalCase");

        lua_pushstring(L, alias.value.c_str());
        lua_setfield(L, -2, "value");

        lua_setfield(L, -2, key.c_str());
    }
    lua_setfield(L, -2, "aliases");

    lua_pushnil(L);
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry point
//
// check / typeAt / autocomplete / typeofModule are implemented in LuauShared (_wrapper_lib)
// because they depend on Luau.Analysis which requires the VM.
// ---------------------------------------------------------------------------
static void register_module(lua_State* L, const luaL_Reg* funcs) {
    lua_createtable(L, 0, 8);
    for (const luaL_Reg* reg = funcs; reg && reg->name; ++reg) {
        lua_pushcfunction(L, reg->func, reg->name);
        lua_setfield(L, -2, reg->name);
    }
    lua_setreadonly(L, -1, true);
}

static const luaL_Reg parse_funcs[] = {
    { "parse", l_parse },
    { "parseExpr", l_parseExpr },
    { "prettyPrint", l_prettyPrint },
    { nullptr, nullptr },
};

static const luaL_Reg vm_funcs[] = {
    { "compile", l_compile },
    { "load", l_load },
    { "disassemble", l_disassemble },
    { nullptr, nullptr },
};

static const luaL_Reg analysis_funcs[] = {
    { "check", eryx_luau_check },
    { "typeAt", eryx_luau_typeAt },
    { "autocomplete", eryx_luau_autocomplete },
    { "typeofModule", eryx_luau_typeofModule },
    { "resolve", l_resolve },
    { "getconfig", l_config },
    { "parseLuaurc", l_parseLuaurc },
    { nullptr, nullptr },
};

int eryx_luau_open_parse_native(lua_State* L) {
    register_module(L, parse_funcs);
    return 1;
}

int eryx_luau_open_vm_native(lua_State* L) {
    register_module(L, vm_funcs);
    return 1;
}

int eryx_luau_open_analysis_native(lua_State* L) {
    register_module(L, analysis_funcs);
    return 1;
}
