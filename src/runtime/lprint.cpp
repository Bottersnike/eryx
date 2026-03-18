#include "lprint.hpp"

static int already_seen(lua_State* L, int t, int visited) {
    lua_pushvalue(L, t);
    lua_rawget(L, visited);
    int seen = !lua_isnil(L, -1);
    lua_pop(L, 1);
    return seen;
}

static void mark_seen(lua_State* L, int t, int visited) {
    lua_pushvalue(L, t);
    lua_pushboolean(L, 1);
    lua_rawset(L, visited);
}

static void print_escaped_string(const char* s, size_t len) {
    putchar('"');
    for (size_t i = 0; i < len; i++) {
        switch (s[i]) {
            case '\a':  printf("\\a"); break;
            case '\b':  printf("\\b"); break;
            case '\f':  printf("\\f"); break;
            case '\n':  printf("\\n"); break;
            case '\r':  printf("\\r"); break;
            case '\t':  printf("\\t"); break;
            case '\v':  printf("\\v"); break;
            case '\\': printf("\\\\"); break;
            case '"':   printf("\\\""); break;
            case '\0':  printf("\\0"); break;
            default:
                if ((unsigned char)s[i] < 0x20) {
                    printf("\\x%02x", (unsigned char)s[i]);
                } else {
                    putchar(s[i]);
                }
                break;
        }
    }
    putchar('"');
}

// Forward decl
static void print_value(lua_State* L, int index, int visited);

static bool is_legal_name(const char* name) {
    // Empty string
    if (strlen(name) == 0) {
        return false;
    }

    // Keywords
    if (strcmp(name, "and") == 0 || strcmp(name, "break") == 0 || strcmp(name, "do") == 0 ||
        strcmp(name, "else") == 0 || strcmp(name, "elseif") == 0 || strcmp(name, "end") == 0 ||
        strcmp(name, "false") == 0 || strcmp(name, "for") == 0 || strcmp(name, "function") == 0 ||
        strcmp(name, "goto") == 0 || strcmp(name, "if") == 0 || strcmp(name, "in") == 0 ||
        strcmp(name, "local") == 0 || strcmp(name, "nil") == 0 || strcmp(name, "not") == 0 ||
        strcmp(name, "or") == 0 || strcmp(name, "repeat") == 0 || strcmp(name, "return") == 0 ||
        strcmp(name, "then") == 0 || strcmp(name, "true") == 0 || strcmp(name, "until") == 0 ||
        strcmp(name, "while") == 0) {
        return false;
    }

    // Valid characters
    for (int i = 0; i < strlen(name); i++) {
        char chr = name[i];
        if (i != 0 && '0' <= chr && chr <= '9') {
            continue;
        }
        if ('a' <= chr && chr <= 'z') {
            continue;
        }
        if ('A' <= chr && chr <= 'Z') {
            continue;
        }
        if (chr == '_') {
            continue;
        }
        return false;
    }
    return true;
}

static void print_table(lua_State* L, int index, int visited) {
    index = lua_absindex(L, index);

    if (already_seen(L, index, visited)) {
        printf("{...}");
        return;
    }
    mark_seen(L, index, visited);

    printf("{");

    int first = 1;

    // Array part length
    lua_Integer n = lua_objlen(L, index);

    // Print array part
    for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, index, i);

        if (!lua_isnil(L, -1)) {
            if (!first) printf(", ");
            first = 0;

            print_value(L, -1, visited);
        }

        lua_pop(L, 1);
    }

    // Print hash part
    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        // Skip array keys we already printed
        if (lua_type(L, -2) == LUA_TNUMBER) {
            lua_Number k = lua_tonumber(L, -2);
            if (k >= 1 && k <= n && (lua_Integer)k == k) {
                lua_pop(L, 1);
                continue;
            }
        }

        if (!first) printf(", ");
        first = 0;

        if (lua_isstring(L, -2)) {
            // Check if -2 is a name string
            const char* key = lua_tostring(L, -2);
            if (is_legal_name(key)) {
                printf("%s", key);
            } else {
                printf("[");
                size_t klen;
                const char* kstr = lua_tolstring(L, -2, &klen);
                print_escaped_string(kstr, klen);
                printf("]");
            }

            // printf("[");
            // print_value(L, -2, visited);
            // printf("]");
        } else {
            printf("[");
            print_value(L, -2, visited);
            printf("]");
        }

        printf(" = ");
        print_value(L, -1, visited);

        lua_pop(L, 1);
    }

    printf("}");
}

static void print_value(lua_State* L, int index, int visited) {
    int t = lua_type(L, index);

    switch (t) {
        case LUA_TNIL:
            printf("nil");
            break;
        case LUA_TBOOLEAN:
            if (lua_toboolean(L, index))
                printf("true");
            else
                printf("false");
            break;
        // case LUA_TLIGHTUSERDATA:
        //     printf("lightuserdata");
        //     break;
        case LUA_TNUMBER: {
            double num = lua_tonumber(L, index);
            if (ceil(num) == floor(num)) {
                printf("%d", (unsigned int)num);
            } else if (isnan(num)) {
                printf("NaN");
            } else if (isinf(num)) {
                printf("Inf");
            } else {
                printf("%f", lua_tonumber(L, index));
            }
            break;
        }
        case LUA_TTABLE:
            print_table(L, index, visited);
            break;

        case LUA_TSTRING: {
            size_t slen;
            const char* str = lua_tolstring(L, index, &slen);
            print_escaped_string(str, slen);
            break;
        }

        default: {
            size_t len;
            const char* s = luaL_tolstring(L, index, &len);
            fwrite(s, 1, len, stdout);
            lua_pop(L, 1);
            break;
        }
    }
}

int eryx_lua_print(lua_State* L) {
    int n = lua_gettop(L);

    // Visited table
    lua_newtable(L);
    int visited = lua_gettop(L);

    for (int i = 1; i <= n; i++) {
        if (i > 1) printf("\t");
        // Top-level strings don't have "s around them
        if (lua_type(L, i) == LUA_TSTRING) {
            printf("%s", lua_tostring(L, i));
        } else {
            print_value(L, i, visited);
        }
    }

    printf("\n");
    return 0;
}
