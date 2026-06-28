#include "lprint.hpp"

#include <cinttypes>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <unordered_set>

namespace {

struct StackGuard {
    lua_State* L;
    int top;

    explicit StackGuard(lua_State* L) : L(L), top(lua_gettop(L)) {}

    ~StackGuard() { lua_settop(L, top); }
};

struct FormatContext {
    bool colorsEnabled = false;
    std::unordered_set<const void*> activeTables;
};

struct TableEntry {
    int keyRef = LUA_NOREF;
    int valueRef = LUA_NOREF;
    int keyType = LUA_TNIL;
    int category = 2;
    double numberKey = 0;
    std::string stringKey;
    const void* pointerKey = nullptr;
    size_t order = 0;
};

static void ensure_stack(lua_State* L, int slots) {
    luaL_checkstack(L, slots, "print formatting too deeply nested");
}

enum class Style {
    Dim,
    Green,
    Yellow,
    Magenta,
    Cyan,
    Red,
};

static bool should_use_color() {
    if (std::getenv("NO_COLOR")) return false;
    if (std::getenv("FORCE_COLOR")) return true;
    return uv_guess_handle(1) == UV_TTY;
}

static const char* style_code(Style style) {
    switch (style) {
        case Style::Dim:
            return "2";
        case Style::Green:
            return "32";
        case Style::Yellow:
            return "33";
        case Style::Magenta:
            return "35";
        case Style::Cyan:
            return "36";
        case Style::Red:
            return "31";
    }
    return "0";
}

static std::string apply_style(FormatContext& ctx, Style style, std::string text) {
    if (!ctx.colorsEnabled) return text;

    std::string out;
    out.reserve(text.size() + 16);
    out += "\x1b[";
    out += style_code(style);
    out += "m";
    out += text;
    out += "\x1b[0m";
    return out;
}

static std::string indent(int depth) { return std::string(static_cast<size_t>(depth) * 4, ' '); }

static bool is_plain_string_key(const std::string& key) {
    if (key.empty()) return false;

    static const std::unordered_set<std::string> keywords = {
        "and",      "break",  "do",   "else", "elseif", "end",   "false", "for",
        "function", "goto",   "if",   "in",   "local",  "nil",   "not",   "or",
        "repeat",   "return", "then", "true", "until",  "while",
    };

    if (keywords.contains(key)) return false;

    unsigned char first = static_cast<unsigned char>(key[0]);
    if (!std::isalpha(first) && first != '_') return false;

    for (unsigned char ch : key) {
        if (std::isalnum(ch) || ch == '_') continue;
        return false;
    }

    return true;
}

static std::string escaped_string_contents(const char* s, size_t len) {
    std::string out;

    for (size_t i = 0; i < len; i++) {
        unsigned char ch = static_cast<unsigned char>(s[i]);

        switch (ch) {
            case '\a':
                out += "\\a";
                break;
            case '\b':
                out += "\\b";
                break;
            case '\f':
                out += "\\f";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\t':
                out += "\\t";
                break;
            case '\v':
                out += "\\v";
                break;
            case '\\':
                out += "\\\\";
                break;
            case '"':
                out += "\\\"";
                break;
            case '\0':
                out += "\\0";
                break;
            default:
                if (ch < 0x20) {
                    char buf[5];
                    snprintf(buf, sizeof(buf), "\\x%02x", ch);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(ch));
                }
                break;
        }
    }

    return out;
}

static std::string format_quoted_string(FormatContext& ctx, const char* s, size_t len) {
    return apply_style(ctx, Style::Green, "\"" + escaped_string_contents(s, len) + "\"");
}

static std::string format_lua_tostring(lua_State* L, int index) {
    StackGuard guard(L);

    size_t len = 0;
    const char* s = luaL_tolstring(L, index, &len);
    return std::string(s, len);
}

static std::optional<std::string> get_metafield_string(lua_State* L, int index, const char* field) {
    StackGuard guard(L);
    index = lua_absindex(L, index);

    ensure_stack(L, 2);
    if (!lua_getmetatable(L, index)) return std::nullopt;

    lua_getfield(L, -1, field);
    if (!lua_isstring(L, -1)) return std::nullopt;

    size_t len = 0;
    const char* s = lua_tolstring(L, -1, &len);
    return std::string(s, len);
}

static std::optional<std::string> call_tostring_metamethod(lua_State* L, int index) {
    StackGuard guard(L);
    index = lua_absindex(L, index);

    ensure_stack(L, 3);
    if (!lua_getmetatable(L, index)) return std::nullopt;

    lua_getfield(L, -1, "__tostring");

    if (lua_isstring(L, -1)) {
        size_t len = 0;
        const char* s = lua_tolstring(L, -1, &len);
        return std::string(s, len);
    }

    if (!lua_isfunction(L, -1)) return std::nullopt;

    lua_pushvalue(L, index);
    if (lua_pcall(L, 1, 1, 0) != 0) return std::nullopt;
    if (!lua_isstring(L, -1)) return std::nullopt;

    size_t len = 0;
    const char* s = lua_tolstring(L, -1, &len);
    return std::string(s, len);
}

static std::optional<std::string> format_typename_and_tostring(lua_State* L, int index) {
    std::optional<std::string> typeName = get_metafield_string(L, index, "__type");
    std::optional<std::string> tostringed = call_tostring_metamethod(L, index);

    if (typeName && tostringed) return "<" + *typeName + "(" + *tostringed + ")>";
    if (typeName) return "<" + *typeName + ">";
    if (tostringed) return *tostringed;

    return std::nullopt;
}

static std::string format_value(lua_State* L, int index, FormatContext& ctx, int depth,
                                bool preferPlainString);

static std::string format_key(lua_State* L, int index, FormatContext& ctx, int depth) {
    if (lua_type(L, index) == LUA_TSTRING) {
        size_t len = 0;
        const char* s = lua_tolstring(L, index, &len);
        std::string key(s, len);

        if (is_plain_string_key(key)) return key;

        return apply_style(ctx, Style::Dim, "[") + format_quoted_string(ctx, s, len) +
               apply_style(ctx, Style::Dim, "]");
    }

    return apply_style(ctx, Style::Dim, "[") + format_value(L, index, ctx, depth, false) +
           apply_style(ctx, Style::Dim, "]");
}

static void fill_sort_key(lua_State* L, int keyIndex, TableEntry& entry) {
    entry.keyType = lua_type(L, keyIndex);

    if (entry.keyType == LUA_TNUMBER) {
        entry.category = 0;
        entry.numberKey = lua_tonumber(L, keyIndex);
        return;
    }

    if (entry.keyType == LUA_TSTRING) {
        entry.category = 1;
        size_t len = 0;
        const char* s = lua_tolstring(L, keyIndex, &len);
        entry.stringKey.assign(s, len);
        return;
    }

    entry.category = 2;
    entry.pointerKey = lua_topointer(L, keyIndex);
}

static bool table_entry_less(const TableEntry& a, const TableEntry& b) {
    if (a.category != b.category) return a.category < b.category;

    if (a.category == 0 && a.numberKey != b.numberKey) return a.numberKey < b.numberKey;
    if (a.category == 1 && a.stringKey != b.stringKey) return a.stringKey < b.stringKey;

    if (a.keyType != b.keyType) return a.keyType < b.keyType;
    if (a.pointerKey != b.pointerKey) return a.pointerKey < b.pointerKey;

    return a.order < b.order;
}

static std::vector<TableEntry> collect_table_entries(lua_State* L, int tableIndex) {
    StackGuard guard(L);
    tableIndex = lua_absindex(L, tableIndex);

    std::vector<TableEntry> entries;

    ensure_stack(L, 2);
    lua_pushnil(L);
    size_t order = 0;
    while (lua_next(L, tableIndex) != 0) {
        ensure_stack(L, 2);
        TableEntry entry;
        entry.order = order++;
        fill_sort_key(L, -2, entry);
        entry.keyRef = lua_ref(L, -2);
        entry.valueRef = lua_ref(L, -1);
        entries.push_back(entry);
        lua_pop(L, 1);
    }

    std::sort(entries.begin(), entries.end(), table_entry_less);
    return entries;
}

static bool is_positive_integral_number(double value) {
    return value >= 1 && std::isfinite(value) && std::floor(value) == value;
}

static bool is_array_entries(const std::vector<TableEntry>& entries) {
    if (entries.empty()) return true;

    for (size_t i = 0; i < entries.size(); i++) {
        const TableEntry& entry = entries[i];
        if (entry.keyType != LUA_TNUMBER || !is_positive_integral_number(entry.numberKey))
            return false;
        if (static_cast<size_t>(entry.numberKey) != i + 1) return false;
    }

    return true;
}

static void release_entries(lua_State* L, std::vector<TableEntry>& entries) {
    for (TableEntry& entry : entries) {
        lua_unref(L, entry.keyRef);
        lua_unref(L, entry.valueRef);
        entry.keyRef = LUA_NOREF;
        entry.valueRef = LUA_NOREF;
    }
}

static std::string format_table(lua_State* L, int index, FormatContext& ctx, int depth) {
    StackGuard guard(L);
    index = lua_absindex(L, index);

    if (std::optional<std::string> formatted = format_typename_and_tostring(L, index))
        return *formatted;

    const void* id = lua_topointer(L, index);
    if (ctx.activeTables.contains(id)) return apply_style(ctx, Style::Dim, "{ ... }");

    ctx.activeTables.insert(id);

    std::vector<TableEntry> entries = collect_table_entries(L, index);
    bool isArray = is_array_entries(entries);

    int metatableRef = LUA_NOREF;
    bool metatableLocked = false;
    ensure_stack(L, 3);
    if (lua_getmetatable(L, index)) {
        lua_getfield(L, -1, "__metatable");
        metatableLocked = !lua_isnil(L, -1);
        lua_pop(L, 1);

        metatableRef = lua_ref(L, -1);
    }

    if (entries.empty() && metatableRef == LUA_NOREF) {
        ctx.activeTables.erase(id);
        release_entries(L, entries);
        return apply_style(ctx, Style::Dim, "{ }");
    }

    std::string out = apply_style(ctx, Style::Dim, "{");
    out += "\n";

    for (const TableEntry& entry : entries) {
        out += indent(depth + 1);

        if (isArray) {
            ensure_stack(L, 1);
            lua_getref(L, entry.valueRef);
            out += format_value(L, -1, ctx, depth + 1, false);
            lua_pop(L, 1);
        } else {
            ensure_stack(L, 1);
            lua_getref(L, entry.keyRef);
            out += format_key(L, -1, ctx, depth + 1);
            lua_pop(L, 1);

            out += " ";
            out += apply_style(ctx, Style::Dim, "=");
            out += " ";

            ensure_stack(L, 1);
            lua_getref(L, entry.valueRef);
            out += format_value(L, -1, ctx, depth + 1, false);
            lua_pop(L, 1);
        }

        out += apply_style(ctx, Style::Dim, ",");
        out += "\n";
    }

    if (metatableRef != LUA_NOREF) {
        out += indent(depth + 1);
        out += apply_style(ctx, Style::Red, metatableLocked ? "@metatable<locked>" : "@metatable");
        out += " ";
        out += apply_style(ctx, Style::Dim, "=");
        out += " ";

        ensure_stack(L, 1);
        lua_getref(L, metatableRef);
        out += format_value(L, -1, ctx, depth + 1, false);
        lua_pop(L, 1);

        out += apply_style(ctx, Style::Dim, ",");
        out += "\n";
    }

    out += indent(depth);
    out += apply_style(ctx, Style::Dim, "}");

    ctx.activeTables.erase(id);
    lua_unref(L, metatableRef);
    release_entries(L, entries);
    return out;
}

static std::string format_opaque_value(lua_State* L, int index, FormatContext& ctx,
                                       const char* fallback) {
    if (std::optional<std::string> formatted = format_typename_and_tostring(L, index))
        return apply_style(ctx, Style::Magenta, *formatted);

    std::string text = format_lua_tostring(L, index);
    if (text.empty()) text = fallback;
    return apply_style(ctx, Style::Magenta, text);
}

static std::string format_pointer(const void* pointer) {
    char buffer[2 + sizeof(uintptr_t) * 2 + 1];
    snprintf(buffer, sizeof(buffer), "0x%" PRIxPTR, reinterpret_cast<uintptr_t>(pointer));
    return buffer;
}

static std::string format_type_pointer(const char* type, const void* pointer) {
    std::string text = type;
    text += "<";
    text += format_pointer(pointer);
    text += ">";
    return text;
}

static std::string format_function_value(lua_State* L, int index, FormatContext& ctx) {
    StackGuard guard(L);
    index = lua_absindex(L, index);

    ensure_stack(L, 1);
    lua_pushvalue(L, index);

    lua_Debug ar = {};
    std::string name;
    if (lua_getinfo(L, -1, "n", &ar) && ar.name && ar.name[0] != '\0') {
        name = ar.name;
    }

    std::string text = "function";
    if (!name.empty()) {
        text += " ";
        text += name;
    }

    text += "<";
    text += format_pointer(lua_topointer(L, -1));
    text += ">";

    return apply_style(ctx, Style::Red, text);
}

static std::string format_thread_value(lua_State* L, int index, FormatContext& ctx) {
    return apply_style(ctx, Style::Magenta, format_type_pointer("thread", lua_topointer(L, index)));
}

static std::string format_buffer_value(lua_State* L, int index, FormatContext& ctx) {
    size_t len = 0;
    const unsigned char* data = static_cast<const unsigned char*>(lua_tobuffer(L, index, &len));
    const size_t previewLen = std::min<size_t>(len, 16);

    std::string text = format_type_pointer("buffer", lua_topointer(L, index));
    text += "(";

    static constexpr char HEX[] = "0123456789abcdef";
    for (size_t i = 0; i < previewLen; i++) {
        text.push_back(HEX[(data[i] >> 4) & 0x0F]);
        text.push_back(HEX[data[i] & 0x0F]);
    }

    if (len > previewLen) text += "...";

    text += ")";
    return apply_style(ctx, Style::Magenta, text);
}

static std::string format_value(lua_State* L, int index, FormatContext& ctx, int depth,
                                bool preferPlainString) {
    StackGuard guard(L);
    index = lua_absindex(L, index);

    switch (lua_type(L, index)) {
        case LUA_TNIL:
            return apply_style(ctx, Style::Yellow, "nil");

        case LUA_TBOOLEAN:
            return apply_style(ctx, Style::Yellow, lua_toboolean(L, index) ? "true" : "false");

        case LUA_TNUMBER:
            return apply_style(ctx, Style::Cyan, format_lua_tostring(L, index));

        case LUA_TSTRING: {
            size_t len = 0;
            const char* s = lua_tolstring(L, index, &len);
            if (preferPlainString) return std::string(s, len);
            return format_quoted_string(ctx, s, len);
        }

        case LUA_TTABLE:
            return format_table(L, index, ctx, depth);

        case LUA_TFUNCTION:
            return format_function_value(L, index, ctx);

        case LUA_TUSERDATA:
        case LUA_TLIGHTUSERDATA:
            return format_opaque_value(L, index, ctx, "<userdata>");

        case LUA_TTHREAD:
            return format_thread_value(L, index, ctx);

        case LUA_TBUFFER:
            return format_buffer_value(L, index, ctx);

        case LUA_TVECTOR:
            return apply_style(ctx, Style::Magenta, format_lua_tostring(L, index));

        default:
            return apply_style(ctx, Style::Magenta, format_lua_tostring(L, index));
    }
}

}  // namespace

int eryx_lua_print(lua_State* L) {
    StackGuard guard(L);

    int n = lua_gettop(L);
    FormatContext ctx;
    ctx.colorsEnabled = should_use_color();

    std::string out;
    for (int i = 1; i <= n; i++) {
        if (i > 1) out += " ";
        out += format_value(L, i, ctx, 0, lua_type(L, i) == LUA_TSTRING);
    }
    out += "\n";

    fwrite(out.data(), 1, out.size(), stdout);
    fflush(stdout);
    return 0;
}
