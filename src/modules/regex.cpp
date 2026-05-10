// regex.cpp – PCRE2-based regular expression module for Luau
// Exposes pattern compilation, matching, searching, splitting, and replacement.

#include <cstring>
#include <string>
#include <vector>

#define PCRE2_CODE_UNIT_WIDTH 8
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "pcre2.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_regex",
};
LUAU_MODULE_INFO()

// ── Metatable names ─────────────────────────────────────────────────────────

static const char* MT_REGEX = "Regex";
static const char* MT_MATCH = "RegexMatch";

// ── Userdata structs ────────────────────────────────────────────────────────

struct LuaRegex {
    pcre2_code* re;
};

struct LuaMatch {
    pcre2_code* re;  // borrowed, not owned
    pcre2_match_data* md;
    const char* subject;  // kept alive by Lua string ref (upvalue or field)
    size_t subject_len;
    uint32_t capture_count;
};

// ── Helpers ─────────────────────────────────────────────────────────────────

static LuaRegex* check_regex(lua_State* L, int idx) {
    return (LuaRegex*)luaL_checkudata(L, idx, MT_REGEX);
}

static LuaMatch* check_match(lua_State* L, int idx) {
    return (LuaMatch*)luaL_checkudata(L, idx, MT_MATCH);
}

static void check_regex_valid(lua_State* L, LuaRegex* ud) {
    if (!ud->re) luaL_error(L, "attempt to use a freed regex");
}

static void pcre2_error_message(lua_State* L, int errorcode) {
    PCRE2_UCHAR buf[256];
    pcre2_get_error_message(errorcode, buf, sizeof(buf));
    luaL_error(L, "regex error: %s", (const char*)buf);
}

// Parse flags string into PCRE2 compile options
static uint32_t parse_flags(lua_State* L, const char* flags) {
    uint32_t opts = 0;
    if (!flags) return opts;
    for (const char* p = flags; *p; p++) {
        switch (*p) {
            case 'i':
                opts |= PCRE2_CASELESS;
                break;
            case 'm':
                opts |= PCRE2_MULTILINE;
                break;
            case 's':
                opts |= PCRE2_DOTALL;
                break;
            case 'x':
                opts |= PCRE2_EXTENDED;
                break;
            case 'u':
                opts |= PCRE2_UTF;
                break;
            case 'U':
                opts |= PCRE2_UNGREEDY;
                break;
            case 'n':
                opts |= PCRE2_NO_AUTO_CAPTURE;
                break;
            default:
                luaL_error(L, "unknown regex flag: '%c'", *p);
        }
    }
    return opts;
}

// Compile a pattern, returning the pcre2_code* (or error via luaL_error)
static pcre2_code* compile_pattern(lua_State* L, const char* pattern, size_t patlen,
                                   uint32_t options) {
    int errorcode;
    PCRE2_SIZE erroroffset;
    pcre2_code* re =
        pcre2_compile((PCRE2_SPTR)pattern, patlen, options, &errorcode, &erroroffset, nullptr);
    if (!re) {
        PCRE2_UCHAR buf[256];
        pcre2_get_error_message(errorcode, buf, sizeof(buf));
        luaL_error(L, "regex compile error at offset %d: %s", (int)erroroffset, (const char*)buf);
    }
    return re;
}

// Push a match result table for a single match (with captures)
// ovector is the output vector, rc is the match count
// subject/subjectlen is the input string
// If pushFull is true, also push the full match as .match
static void push_match_table(lua_State* L, pcre2_code* re, pcre2_match_data* md,
                             const char* subject, size_t subject_len, int rc) {
    PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);

    lua_newtable(L);

    // Full match as "match" field
    if (rc > 0 && ov[0] != PCRE2_UNSET) {
        lua_pushlstring(L, subject + ov[0], ov[1] - ov[0]);
        lua_setfield(L, -2, "match");

        lua_pushinteger(L, (int)(ov[0] + 1));  // 1-based
        lua_setfield(L, -2, "start");

        lua_pushinteger(L, (int)ov[1]);  // end is inclusive in Luau convention
        lua_setfield(L, -2, "finish");
    }

    // Numbered captures as array part [1], [2], ...
    for (int i = 1; i < rc; i++) {
        if (ov[2 * i] == PCRE2_UNSET) {
            lua_pushnil(L);  // nil for unmatched optional groups
        } else {
            lua_pushlstring(L, subject + ov[2 * i], ov[2 * i + 1] - ov[2 * i]);
        }
        lua_rawseti(L, -2, i);
    }

    // Named captures
    uint32_t namecount;
    pcre2_pattern_info(re, PCRE2_INFO_NAMECOUNT, &namecount);
    if (namecount > 0) {
        uint32_t name_entry_size;
        PCRE2_SPTR name_table;
        pcre2_pattern_info(re, PCRE2_INFO_NAMEENTRYSIZE, &name_entry_size);
        pcre2_pattern_info(re, PCRE2_INFO_NAMETABLE, &name_table);

        for (uint32_t i = 0; i < namecount; i++) {
            int n = (name_table[0] << 8) | name_table[1];
            const char* name = (const char*)(name_table + 2);
            if (n < rc && ov[2 * n] != PCRE2_UNSET) {
                lua_pushlstring(L, subject + ov[2 * n], ov[2 * n + 1] - ov[2 * n]);
            } else {
                lua_pushboolean(L, 0);
            }
            lua_setfield(L, -2, name);
            name_table += name_entry_size;
        }
    }
}

// ── Regex methods ───────────────────────────────────────────────────────────

// regex:isMatch(subject, offset?) -> bool
static int regex_isMatch(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);
    size_t len;
    const char* subject = luaL_checklstring(L, 2, &len);
    int offset = (int)luaL_optinteger(L, 3, 1) - 1;  // convert from 1-based
    if (offset < 0) offset = 0;

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(ud->re, nullptr);
    int rc = pcre2_match(ud->re, (PCRE2_SPTR)subject, len, (PCRE2_SIZE)offset, 0, md, nullptr);
    pcre2_match_data_free(md);

    lua_pushboolean(L, rc >= 0);
    return 1;
}

// regex:find(subject, offset?) -> MatchResult?
static int regex_find(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);
    size_t len;
    const char* subject = luaL_checklstring(L, 2, &len);
    int offset = (int)luaL_optinteger(L, 3, 1) - 1;
    if (offset < 0) offset = 0;

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(ud->re, nullptr);
    int rc = pcre2_match(ud->re, (PCRE2_SPTR)subject, len, (PCRE2_SIZE)offset, 0, md, nullptr);

    if (rc == PCRE2_ERROR_NOMATCH) {
        pcre2_match_data_free(md);
        lua_pushnil(L);
        return 1;
    }
    if (rc < 0) {
        pcre2_match_data_free(md);
        pcre2_error_message(L, rc);
        return 0;
    }

    push_match_table(L, ud->re, md, subject, len, rc);
    pcre2_match_data_free(md);
    return 1;
}

// regex:findAll(subject) -> {MatchResult}
static int regex_findAll(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);
    size_t len;
    const char* subject = luaL_checklstring(L, 2, &len);

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(ud->re, nullptr);
    lua_newtable(L);
    int index = 1;
    PCRE2_SIZE offset = 0;

    while (offset <= len) {
        int rc = pcre2_match(ud->re, (PCRE2_SPTR)subject, len, offset, 0, md, nullptr);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) {
            pcre2_match_data_free(md);
            pcre2_error_message(L, rc);
            return 0;
        }

        PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);
        push_match_table(L, ud->re, md, subject, len, rc);
        lua_rawseti(L, -2, index++);

        // Advance past this match (handle zero-length matches)
        PCRE2_SIZE new_offset = ov[1];
        if (new_offset == offset) {
            new_offset++;
        }
        offset = new_offset;
    }

    pcre2_match_data_free(md);
    return 1;
}

// regex:replace(subject, replacement, limit?) -> string
// replacement is a string (supports $0, $1, ${name} backreferences via PCRE2_SUBSTITUTE_EXTENDED)
static int regex_replace(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);
    size_t subj_len;
    const char* subject = luaL_checklstring(L, 2, &subj_len);
    size_t repl_len;
    const char* replacement = luaL_checklstring(L, 3, &repl_len);
    int limit = (int)luaL_optinteger(L, 4, 0);  // 0 = replace all

    uint32_t sub_options = PCRE2_SUBSTITUTE_EXTENDED | PCRE2_SUBSTITUTE_OVERFLOW_LENGTH;
    if (limit == 0) sub_options |= PCRE2_SUBSTITUTE_GLOBAL;

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(ud->re, nullptr);

    if (limit > 0 && limit != 1) {
        // For limited replacements > 1, we do it iteratively
        std::string result;
        PCRE2_SIZE offset = 0;
        int count = 0;
        const char* src = subject;
        size_t src_len = subj_len;

        while (count < limit && offset <= src_len) {
            int rc = pcre2_match(ud->re, (PCRE2_SPTR)src, src_len, offset, 0, md, nullptr);
            if (rc == PCRE2_ERROR_NOMATCH) break;
            if (rc < 0) {
                pcre2_match_data_free(md);
                pcre2_error_message(L, rc);
                return 0;
            }

            PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);

            // Append text before match
            result.append(src + offset, ov[0] - offset);

            // Do single substitution for this match
            PCRE2_SIZE out_len = 0;
            // First call to get size
            int sr =
                pcre2_substitute(ud->re, (PCRE2_SPTR)src, src_len, ov[0],
                                 PCRE2_SUBSTITUTE_EXTENDED | PCRE2_SUBSTITUTE_OVERFLOW_LENGTH |
                                     PCRE2_SUBSTITUTE_MATCHED | PCRE2_SUBSTITUTE_REPLACEMENT_ONLY,
                                 md, nullptr, (PCRE2_SPTR)replacement, repl_len, nullptr, &out_len);

            if (sr == PCRE2_ERROR_NOMEMORY) {
                std::vector<PCRE2_UCHAR> buf(out_len + 1);
                PCRE2_SIZE buf_len = out_len + 1;
                sr = pcre2_substitute(ud->re, (PCRE2_SPTR)src, src_len, ov[0],
                                      PCRE2_SUBSTITUTE_EXTENDED | PCRE2_SUBSTITUTE_MATCHED |
                                          PCRE2_SUBSTITUTE_REPLACEMENT_ONLY,
                                      md, nullptr, (PCRE2_SPTR)replacement, repl_len, buf.data(),
                                      &buf_len);
                if (sr < 0) {
                    pcre2_match_data_free(md);
                    pcre2_error_message(L, sr);
                    return 0;
                }
                result.append((const char*)buf.data(), buf_len);
            } else if (sr < 0) {
                pcre2_match_data_free(md);
                pcre2_error_message(L, sr);
                return 0;
            }

            PCRE2_SIZE new_offset = ov[1];
            if (new_offset == offset) new_offset++;
            offset = new_offset;
            count++;
        }

        // Append remainder
        if (offset <= src_len) result.append(src + offset, src_len - offset);

        pcre2_match_data_free(md);
        lua_pushlstring(L, result.data(), result.size());
        return 1;
    }

    // Simple case: replace all or replace first (limit=1 handled by no GLOBAL flag)
    if (limit == 1) sub_options &= ~PCRE2_SUBSTITUTE_GLOBAL;

    // First attempt with a reasonable buffer
    PCRE2_SIZE out_len = subj_len + 256;
    std::vector<PCRE2_UCHAR> outbuf(out_len);

    int rc = pcre2_substitute(ud->re, (PCRE2_SPTR)subject, subj_len, 0, sub_options, md, nullptr,
                              (PCRE2_SPTR)replacement, repl_len, outbuf.data(), &out_len);

    if (rc == PCRE2_ERROR_NOMEMORY) {
        // out_len now has the required size
        outbuf.resize(out_len + 1);
        out_len = outbuf.size();
        sub_options &= ~PCRE2_SUBSTITUTE_OVERFLOW_LENGTH;
        rc = pcre2_substitute(ud->re, (PCRE2_SPTR)subject, subj_len, 0, sub_options, md, nullptr,
                              (PCRE2_SPTR)replacement, repl_len, outbuf.data(), &out_len);
    }

    pcre2_match_data_free(md);

    if (rc < 0) {
        pcre2_error_message(L, rc);
        return 0;
    }

    lua_pushlstring(L, (const char*)outbuf.data(), out_len);
    return 1;
}

// regex:split(subject, limit?) -> {string}
static int regex_split(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);
    size_t len;
    const char* subject = luaL_checklstring(L, 2, &len);
    int limit = (int)luaL_optinteger(L, 3, 0);  // 0 = no limit

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(ud->re, nullptr);
    lua_newtable(L);
    int index = 1;
    PCRE2_SIZE offset = 0;
    int splits = 0;

    while (offset <= len) {
        if (limit > 0 && splits >= limit - 1) break;

        int rc = pcre2_match(ud->re, (PCRE2_SPTR)subject, len, offset, 0, md, nullptr);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) {
            pcre2_match_data_free(md);
            pcre2_error_message(L, rc);
            return 0;
        }

        PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);

        // Push the substring before this match
        lua_pushlstring(L, subject + offset, ov[0] - offset);
        lua_rawseti(L, -2, index++);
        splits++;

        // If there are captures, push them too
        for (int i = 1; i < rc; i++) {
            if (ov[2 * i] == PCRE2_UNSET) {
                lua_pushboolean(L, 0);
            } else {
                lua_pushlstring(L, subject + ov[2 * i], ov[2 * i + 1] - ov[2 * i]);
            }
            lua_rawseti(L, -2, index++);
        }

        PCRE2_SIZE new_offset = ov[1];
        if (new_offset == offset) new_offset++;
        offset = new_offset;
    }

    // Push remainder
    if (offset <= len) {
        lua_pushlstring(L, subject + offset, len - offset);
        lua_rawseti(L, -2, index++);
    }

    pcre2_match_data_free(md);
    return 1;
}

// regex:captureCount() -> number
static int regex_captureCount(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);
    uint32_t count;
    pcre2_pattern_info(ud->re, PCRE2_INFO_CAPTURECOUNT, &count);
    lua_pushinteger(L, count);
    return 1;
}

// regex:namedCaptures() -> {string}
static int regex_namedCaptures(lua_State* L) {
    LuaRegex* ud = check_regex(L, 1);
    check_regex_valid(L, ud);

    uint32_t namecount;
    pcre2_pattern_info(ud->re, PCRE2_INFO_NAMECOUNT, &namecount);

    lua_newtable(L);

    if (namecount > 0) {
        uint32_t name_entry_size;
        PCRE2_SPTR name_table;
        pcre2_pattern_info(ud->re, PCRE2_INFO_NAMEENTRYSIZE, &name_entry_size);
        pcre2_pattern_info(ud->re, PCRE2_INFO_NAMETABLE, &name_table);

        for (uint32_t i = 0; i < namecount; i++) {
            int n = (name_table[0] << 8) | name_table[1];
            const char* name = (const char*)(name_table + 2);
            lua_pushinteger(L, n);
            lua_setfield(L, -2, name);
            name_table += name_entry_size;
        }
    }

    return 1;
}

// ── Regex __index ───────────────────────────────────────────────────────────

static int regex_index(lua_State* L) {
    const char* key = luaL_checkstring(L, 2);
    lua_getmetatable(L, 1);
    lua_getfield(L, -1, key);
    return 1;
}

// ── Regex __gc ──────────────────────────────────────────────────────────────

static int regex_gc(lua_State* L) {
    LuaRegex* ud = (LuaRegex*)lua_touserdata(L, 1);
    if (ud && ud->re) {
        pcre2_code_free(ud->re);
        ud->re = nullptr;
    }
    return 0;
}

// ── Regex __tostring ────────────────────────────────────────────────────────

static int regex_tostring(lua_State* L) {
    lua_pushstring(L, "Regex");
    return 1;
}

// ── Module-level functions ──────────────────────────────────────────────────

// regex.new(pattern, flags?) -> Regex
static int regex_new(lua_State* L) {
    size_t patlen;
    const char* pattern = luaL_checklstring(L, 1, &patlen);
    const char* flags = luaL_optstring(L, 2, nullptr);

    uint32_t options = parse_flags(L, flags);
    pcre2_code* re = compile_pattern(L, pattern, patlen, options);

    LuaRegex* ud = (LuaRegex*)lua_newuserdata(L, sizeof(LuaRegex));
    ud->re = re;
    luaL_getmetatable(L, MT_REGEX);
    lua_setmetatable(L, -2);
    return 1;
}

// regex.isMatch(pattern, subject, flags?) -> bool
static int regex_static_isMatch(lua_State* L) {
    size_t patlen;
    const char* pattern = luaL_checklstring(L, 1, &patlen);
    size_t subj_len;
    const char* subject = luaL_checklstring(L, 2, &subj_len);
    const char* flags = luaL_optstring(L, 3, nullptr);

    uint32_t options = parse_flags(L, flags);
    pcre2_code* re = compile_pattern(L, pattern, patlen, options);

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(re, nullptr);
    int rc = pcre2_match(re, (PCRE2_SPTR)subject, subj_len, 0, 0, md, nullptr);
    pcre2_match_data_free(md);
    pcre2_code_free(re);

    lua_pushboolean(L, rc >= 0);
    return 1;
}

// regex.find(pattern, subject, flags?) -> MatchResult?
static int regex_static_find(lua_State* L) {
    size_t patlen;
    const char* pattern = luaL_checklstring(L, 1, &patlen);
    size_t subj_len;
    const char* subject = luaL_checklstring(L, 2, &subj_len);
    const char* flags = luaL_optstring(L, 3, nullptr);

    uint32_t options = parse_flags(L, flags);
    pcre2_code* re = compile_pattern(L, pattern, patlen, options);

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(re, nullptr);
    int rc = pcre2_match(re, (PCRE2_SPTR)subject, subj_len, 0, 0, md, nullptr);

    if (rc == PCRE2_ERROR_NOMATCH) {
        pcre2_match_data_free(md);
        pcre2_code_free(re);
        lua_pushnil(L);
        return 1;
    }
    if (rc < 0) {
        pcre2_match_data_free(md);
        pcre2_code_free(re);
        pcre2_error_message(L, rc);
        return 0;
    }

    push_match_table(L, re, md, subject, subj_len, rc);
    pcre2_match_data_free(md);
    pcre2_code_free(re);
    return 1;
}

// regex.findAll(pattern, subject, flags?) -> {MatchResult}
static int regex_static_findAll(lua_State* L) {
    size_t patlen;
    const char* pattern = luaL_checklstring(L, 1, &patlen);
    size_t subj_len;
    const char* subject = luaL_checklstring(L, 2, &subj_len);
    const char* flags = luaL_optstring(L, 3, nullptr);

    uint32_t options = parse_flags(L, flags);
    pcre2_code* re = compile_pattern(L, pattern, patlen, options);

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(re, nullptr);
    lua_newtable(L);
    int index = 1;
    PCRE2_SIZE offset = 0;

    while (offset <= subj_len) {
        int rc = pcre2_match(re, (PCRE2_SPTR)subject, subj_len, offset, 0, md, nullptr);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) {
            pcre2_match_data_free(md);
            pcre2_code_free(re);
            pcre2_error_message(L, rc);
            return 0;
        }

        PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);
        push_match_table(L, re, md, subject, subj_len, rc);
        lua_rawseti(L, -2, index++);

        PCRE2_SIZE new_offset = ov[1];
        if (new_offset == offset) new_offset++;
        offset = new_offset;
    }

    pcre2_match_data_free(md);
    pcre2_code_free(re);
    return 1;
}

// regex.replace(pattern, subject, replacement, flags?) -> string
static int regex_static_replace(lua_State* L) {
    size_t patlen;
    const char* pattern = luaL_checklstring(L, 1, &patlen);
    size_t subj_len;
    const char* subject = luaL_checklstring(L, 2, &subj_len);
    size_t repl_len;
    const char* replacement = luaL_checklstring(L, 3, &repl_len);
    const char* flags = luaL_optstring(L, 4, nullptr);

    uint32_t options = parse_flags(L, flags);
    pcre2_code* re = compile_pattern(L, pattern, patlen, options);

    uint32_t sub_options =
        PCRE2_SUBSTITUTE_GLOBAL | PCRE2_SUBSTITUTE_EXTENDED | PCRE2_SUBSTITUTE_OVERFLOW_LENGTH;
    pcre2_match_data* md = pcre2_match_data_create_from_pattern(re, nullptr);

    PCRE2_SIZE out_len = subj_len + 256;
    std::vector<PCRE2_UCHAR> outbuf(out_len);

    int rc = pcre2_substitute(re, (PCRE2_SPTR)subject, subj_len, 0, sub_options, md, nullptr,
                              (PCRE2_SPTR)replacement, repl_len, outbuf.data(), &out_len);

    if (rc == PCRE2_ERROR_NOMEMORY) {
        outbuf.resize(out_len + 1);
        out_len = outbuf.size();
        sub_options &= ~PCRE2_SUBSTITUTE_OVERFLOW_LENGTH;
        rc = pcre2_substitute(re, (PCRE2_SPTR)subject, subj_len, 0, sub_options, md, nullptr,
                              (PCRE2_SPTR)replacement, repl_len, outbuf.data(), &out_len);
    }

    pcre2_match_data_free(md);
    pcre2_code_free(re);

    if (rc < 0) {
        pcre2_error_message(L, rc);
        return 0;
    }

    lua_pushlstring(L, (const char*)outbuf.data(), out_len);
    return 1;
}

// regex.split(pattern, subject, flags?) -> {string}
static int regex_static_split(lua_State* L) {
    size_t patlen;
    const char* pattern = luaL_checklstring(L, 1, &patlen);
    size_t subj_len;
    const char* subject = luaL_checklstring(L, 2, &subj_len);
    const char* flags = luaL_optstring(L, 3, nullptr);

    uint32_t options = parse_flags(L, flags);
    pcre2_code* re = compile_pattern(L, pattern, patlen, options);

    pcre2_match_data* md = pcre2_match_data_create_from_pattern(re, nullptr);
    lua_newtable(L);
    int index = 1;
    PCRE2_SIZE offset = 0;

    while (offset <= subj_len) {
        int rc = pcre2_match(re, (PCRE2_SPTR)subject, subj_len, offset, 0, md, nullptr);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) {
            pcre2_match_data_free(md);
            pcre2_code_free(re);
            pcre2_error_message(L, rc);
            return 0;
        }

        PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);

        lua_pushlstring(L, subject + offset, ov[0] - offset);
        lua_rawseti(L, -2, index++);

        for (int i = 1; i < rc; i++) {
            if (ov[2 * i] == PCRE2_UNSET) {
                lua_pushboolean(L, 0);
            } else {
                lua_pushlstring(L, subject + ov[2 * i], ov[2 * i + 1] - ov[2 * i]);
            }
            lua_rawseti(L, -2, index++);
        }

        PCRE2_SIZE new_offset = ov[1];
        if (new_offset == offset) new_offset++;
        offset = new_offset;
    }

    if (offset <= subj_len) {
        lua_pushlstring(L, subject + offset, subj_len - offset);
        lua_rawseti(L, -2, index++);
    }

    pcre2_match_data_free(md);
    pcre2_code_free(re);
    return 1;
}

// regex.escape(str) -> string
// Escapes all PCRE2 metacharacters in the input string
static int regex_escape(lua_State* L) {
    size_t len;
    const char* input = luaL_checklstring(L, 1, &len);
    std::string result;
    result.reserve(len * 2);

    for (size_t i = 0; i < len; i++) {
        char c = input[i];
        switch (c) {
            case '\\':
            case '^':
            case '$':
            case '.':
            case '[':
            case ']':
            case '(':
            case ')':
            case '{':
            case '}':
            case '*':
            case '+':
            case '?':
            case '|':
                result += '\\';
                break;
        }
        result += c;
    }

    lua_pushlstring(L, result.data(), result.size());
    return 1;
}

// ── Module entry ────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_regex(lua_State* L) {
    // -- Regex metatable --
    luaL_newmetatable(L, MT_REGEX);
    lua_pushcfunction(L, regex_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, regex_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, regex_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, regex_isMatch, "isMatch");
    lua_setfield(L, -2, "isMatch");
    lua_pushcfunction(L, regex_find, "find");
    lua_setfield(L, -2, "find");
    lua_pushcfunction(L, regex_findAll, "findAll");
    lua_setfield(L, -2, "findAll");
    lua_pushcfunction(L, regex_replace, "replace");
    lua_setfield(L, -2, "replace");
    lua_pushcfunction(L, regex_split, "split");
    lua_setfield(L, -2, "split");
    lua_pushcfunction(L, regex_captureCount, "captureCount");
    lua_setfield(L, -2, "captureCount");
    lua_pushcfunction(L, regex_namedCaptures, "namedCaptures");
    lua_setfield(L, -2, "namedCaptures");
    lua_pop(L, 1);

    // -- Module table --
    lua_newtable(L);

    // Constructor
    lua_pushcfunction(L, regex_new, "new");
    lua_setfield(L, -2, "new");

    // Static convenience functions
    lua_pushcfunction(L, regex_static_isMatch, "isMatch");
    lua_setfield(L, -2, "isMatch");
    lua_pushcfunction(L, regex_static_find, "find");
    lua_setfield(L, -2, "find");
    lua_pushcfunction(L, regex_static_findAll, "findAll");
    lua_setfield(L, -2, "findAll");
    lua_pushcfunction(L, regex_static_replace, "replace");
    lua_setfield(L, -2, "replace");
    lua_pushcfunction(L, regex_static_split, "split");
    lua_setfield(L, -2, "split");
    lua_pushcfunction(L, regex_escape, "escape");
    lua_setfield(L, -2, "escape");

    // Flag constants
    lua_pushinteger(L, PCRE2_CASELESS);
    lua_setfield(L, -2, "CASELESS");
    lua_pushinteger(L, PCRE2_MULTILINE);
    lua_setfield(L, -2, "MULTILINE");
    lua_pushinteger(L, PCRE2_DOTALL);
    lua_setfield(L, -2, "DOTALL");
    lua_pushinteger(L, PCRE2_EXTENDED);
    lua_setfield(L, -2, "EXTENDED");
    lua_pushinteger(L, PCRE2_UTF);
    lua_setfield(L, -2, "UTF");
    lua_pushinteger(L, PCRE2_UNGREEDY);
    lua_setfield(L, -2, "UNGREEDY");
    lua_pushinteger(L, PCRE2_NO_AUTO_CAPTURE);
    lua_setfield(L, -2, "NO_AUTO_CAPTURE");
    lua_pushinteger(L, PCRE2_ANCHORED);
    lua_setfield(L, -2, "ANCHORED");
    lua_pushinteger(L, PCRE2_ENDANCHORED);
    lua_setfield(L, -2, "ENDANCHORED");
    lua_pushinteger(L, PCRE2_UCP);
    lua_setfield(L, -2, "UCP");
    lua_pushinteger(L, PCRE2_DUPNAMES);
    lua_setfield(L, -2, "DUPNAMES");

    lua_setreadonly(L, -1, true);
    return 1;
}
