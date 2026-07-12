#include "lunicode.hpp"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <new>
#include <string>
#include <string_view>
#include <vector>

#include "generated/unicode_data.hpp"
#include "generated/unicode_name.hpp"
#include "generated/unicode_type.hpp"
#include "lua.h"
#include "lualib.h"
#include "userdata.hpp"

constexpr const char* UnicodeStringType = "UnicodeString";
constexpr const char* CategoryNames[] = {
    "Cn", "Lu", "Ll", "Lt", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs",
    "Co", "Cn", "Lm", "Lo", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So",
};

struct UnicodeString {
    // Byte offsets for codepoint boundaries are always cached; grapheme boundaries are rare and
    // filled only by grapheme-aware APIs.
    std::string utf8;
    std::vector<size_t> offsets;
    std::vector<size_t> graphemeOffsets;
};

static UnicodeString* testUnicodeString(lua_State* L, int index);
static UnicodeString* pushUnicodeString(lua_State* L, std::string value);

enum GraphemeBreak : uint8_t {
    GraphemeOther,
    GraphemePrepend,
    GraphemeCr,
    GraphemeLf,
    GraphemeControl,
    GraphemeExtend,
    GraphemeRegionalIndicator,
    GraphemeSpacingMark,
    GraphemeL,
    GraphemeV,
    GraphemeT,
    GraphemeLv,
    GraphemeLvt,
    GraphemeZwj,
};

enum IndicConjunctBreak : uint8_t {
    IndicNone,
    IndicLinker,
    IndicConsonant,
    IndicExtend,
};

// Decodes one strict UTF-8 codepoint and advances offset past it.
// Used anywhere raw bytes are validated, indexed, transformed, or transcoded.
static bool decodeCodepoint(std::string_view text, size_t& offset, uint32_t& codepoint) {
    if (offset >= text.size()) return false;

    const auto first = static_cast<uint8_t>(text[offset]);

    if (first <= 0x7F) {
        codepoint = first;
        ++offset;
        return true;
    }

    size_t length = 0;
    uint32_t value = 0;
    uint32_t minimum = 0;

    if ((first & 0xe0) == 0xc0) {
        length = 2;
        value = first & 0x1f;
        minimum = 0x80;
    } else if ((first & 0xf0) == 0xe0) {
        length = 3;
        value = first & 0x0f;
        minimum = 0x800;
    } else if ((first & 0xf8) == 0xf0) {
        length = 4;
        value = first & 0x07;
        minimum = 0x10000;
    } else {
        return false;
    }

    if (text.size() - offset < length) return false;

    for (size_t i = 1; i < length; ++i) {
        const auto byte = static_cast<uint8_t>(text[offset + i]);
        if ((byte & 0xc0) != 0x80) return false;
        value = (value << 6) | (byte & 0x3f);
    }

    if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;

    offset += length;
    codepoint = value;
    return true;
}

// Appends one Unicode scalar value to a UTF-8 output buffer.
// Used by normalization, case mapping, name lookup, and UTF-16/UTF-32 decoders.
static void appendCodepoint(std::string& output, uint32_t codepoint) {
    if (codepoint <= 0x7f) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else if (codepoint <= 0xffff) {
        output.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else {
        output.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    }
}

// Reads a Lua string argument as bytes without validating Unicode.
// Used for byte-oriented inputs such as BOM detection and encoded UTF-16/UTF-32 strings.
static std::string_view checkRawString(lua_State* L, int index) {
    size_t length = 0;
    const char* text = luaL_checklstring(L, index, &length);
    return std::string_view(text, length);
}

// Reads either UnicodeString userdata or a raw Lua string without forcing a validation pass.
// Used by APIs that immediately decode or otherwise validate the text themselves.
static std::string_view checkUnicodeText(lua_State* L, int index) {
    if (UnicodeString* value = testUnicodeString(L, index)) return value->utf8;
    return checkRawString(L, index);
}

// Decodes one codepoint or raises a Lua argument error for invalid UTF-8.
// Used by streaming transforms so raw string inputs are decoded and validated in one pass.
static bool checkedDecodeCodepoint(lua_State* L, int index, std::string_view text, size_t& offset,
                                   uint32_t& codepoint) {
    if (decodeCodepoint(text, offset, codepoint)) return true;
    luaL_argerror(L, index, "invalid UTF-8 string");
    return false;
}

// Parses an optional "little" or "big" endian argument.
// Used by UTF-16/UTF-32 encode and decode entry points.
static bool isLittleEndian(lua_State* L, int index, bool defaultLittle) {
    const char* endian = luaL_optstring(L, index, defaultLittle ? "little" : "big");
    if (std::string_view(endian) == "little") return true;
    if (std::string_view(endian) == "big") return false;
    luaL_argerror(L, index, "expected 'little' or 'big'");
    return false;
}

// Reads an unsigned 16-bit value from a byte string in the selected byte order.
// Used by BOM detection and UTF-16 decoding.
static uint16_t readU16(std::string_view source, size_t offset, bool little) {
    const auto first = static_cast<uint8_t>(source[offset]);
    const auto second = static_cast<uint8_t>(source[offset + 1]);
    return little ? static_cast<uint16_t>(first | (second << 8))
                  : static_cast<uint16_t>((first << 8) | second);
}

// Reads an unsigned 32-bit value from a byte string in the selected byte order.
// Used by BOM detection and UTF-32 decoding.
static uint32_t readU32(std::string_view source, size_t offset, bool little) {
    const auto b0 = static_cast<uint8_t>(source[offset]);
    const auto b1 = static_cast<uint8_t>(source[offset + 1]);
    const auto b2 = static_cast<uint8_t>(source[offset + 2]);
    const auto b3 = static_cast<uint8_t>(source[offset + 3]);
    if (little)
        return uint32_t(b0) | (uint32_t(b1) << 8) | (uint32_t(b2) << 16) | (uint32_t(b3) << 24);
    return (uint32_t(b0) << 24) | (uint32_t(b1) << 16) | (uint32_t(b2) << 8) | uint32_t(b3);
}

// Appends an unsigned 16-bit value to a byte string in the selected byte order.
// Used by UTF-16 encoding and optional BOM emission.
static void appendU16(std::string& output, uint16_t value, bool little) {
    if (little) {
        output.push_back(static_cast<char>(value & 0xff));
        output.push_back(static_cast<char>(value >> 8));
    } else {
        output.push_back(static_cast<char>(value >> 8));
        output.push_back(static_cast<char>(value & 0xff));
    }
}

// Appends an unsigned 32-bit value to a byte string in the selected byte order.
// Used by UTF-32 encoding and optional BOM emission.
static void appendU32(std::string& output, uint32_t value, bool little) {
    if (little) {
        output.push_back(static_cast<char>(value & 0xff));
        output.push_back(static_cast<char>((value >> 8) & 0xff));
        output.push_back(static_cast<char>((value >> 16) & 0xff));
        output.push_back(static_cast<char>(value >> 24));
    } else {
        output.push_back(static_cast<char>(value >> 24));
        output.push_back(static_cast<char>((value >> 16) & 0xff));
        output.push_back(static_cast<char>((value >> 8) & 0xff));
        output.push_back(static_cast<char>(value & 0xff));
    }
}

// Builds byte offsets for every codepoint boundary, including 0 and the final byte length.
// Used when constructing UnicodeString values and by normalization helpers.
static bool buildOffsets(std::string_view text, std::vector<size_t>& offsets) {
    offsets.clear();
    offsets.push_back(0);

    size_t offset = 0;
    while (offset < text.size()) {
        uint32_t codepoint = 0;
        if (!decodeCodepoint(text, offset, codepoint)) return false;
        offsets.push_back(offset);
    }

    return true;
}

// Materializes codepoints from already-validated UTF-8 and cached codepoint offsets.
// Used when algorithms need random access to codepoints, such as graphemes and normalization.
static std::vector<uint32_t> decodeCodepoints(std::string_view text,
                                              const std::vector<size_t>& offsets) {
    std::vector<uint32_t> codepoints;
    codepoints.reserve(offsets.size() - 1);
    for (size_t index = 0; index + 1 < offsets.size(); ++index) {
        size_t offset = offsets[index];
        uint32_t codepoint = 0;
        decodeCodepoint(text, offset, codepoint);
        codepoints.push_back(codepoint);
    }
    return codepoints;
}

// Materializes codepoints from raw Lua string input, validating as it decodes.
// Used by normalization when no UnicodeString offset cache is available.
static std::vector<uint32_t> decodeCodepointsChecked(lua_State* L, int index,
                                                     std::string_view text) {
    std::vector<uint32_t> codepoints;
    codepoints.reserve(text.size());
    size_t offset = 0;
    while (offset < text.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, index, text, offset, codepoint);
        codepoints.push_back(codepoint);
    }
    return codepoints;
}

// Checks the grapheme break classes that force a cluster boundary.
// Used by the Unicode grapheme boundary rules.
static bool isControl(uint8_t graphemeBreak) {
    return graphemeBreak == GraphemeCr || graphemeBreak == GraphemeLf ||
           graphemeBreak == GraphemeControl;
}

// Checks the extended-pictographic + Extend* + ZWJ prefix required by emoji ZWJ clusters.
// Used by isGraphemeBoundary for the GB11 grapheme break rule.
static bool hasExtendedPictographicZwjPrefix(const std::vector<uint32_t>& codepoints,
                                             size_t index) {
    if (index < 2 ||
        eryx::unicode::data::recordFor(codepoints[index - 1]).graphemeBreak != GraphemeZwj)
        return false;

    size_t cursor = index - 1;
    while (cursor > 0 &&
           eryx::unicode::data::recordFor(codepoints[cursor - 1]).graphemeBreak == GraphemeExtend)
        --cursor;

    return cursor > 0 &&
           eryx::unicode::data::recordFor(codepoints[cursor - 1]).extendedPictographic != 0;
}

// Checks for a preceding consonant/linker sequence that keeps Indic conjuncts together.
// Used by isGraphemeBoundary for the Indic conjunct break rule.
static bool hasIndicConjunctPrefix(const std::vector<uint32_t>& codepoints, size_t index) {
    if (eryx::unicode::data::recordFor(codepoints[index]).indicConjunctBreak != IndicConsonant)
        return false;

    bool linkerSeen = false;
    size_t cursor = index;
    while (cursor > 0) {
        const uint8_t property =
            eryx::unicode::data::recordFor(codepoints[cursor - 1]).indicConjunctBreak;
        if (property == IndicLinker) {
            linkerSeen = true;
            --cursor;
        } else if (property == IndicExtend) {
            --cursor;
        } else {
            return linkerSeen && property == IndicConsonant;
        }
    }
    return false;
}

// Applies Unicode grapheme boundary rules between codepoints[index - 1] and codepoints[index].
// Used while building the lazy grapheme offset cache.
static bool isGraphemeBoundary(const std::vector<uint32_t>& codepoints, size_t index) {
    const auto& before = eryx::unicode::data::recordFor(codepoints[index - 1]);
    const auto& after = eryx::unicode::data::recordFor(codepoints[index]);
    const uint8_t left = before.graphemeBreak;
    const uint8_t right = after.graphemeBreak;

    if (left == GraphemeCr && right == GraphemeLf) return false;
    if (isControl(left) || isControl(right)) return true;
    if (left == GraphemeL &&
        (right == GraphemeL || right == GraphemeV || right == GraphemeLv || right == GraphemeLvt))
        return false;
    if ((left == GraphemeLv || left == GraphemeV) && (right == GraphemeV || right == GraphemeT))
        return false;
    if ((left == GraphemeLvt || left == GraphemeT) && right == GraphemeT) return false;
    if (right == GraphemeExtend || right == GraphemeZwj || right == GraphemeSpacingMark)
        return false;
    if (left == GraphemePrepend) return false;
    if (hasIndicConjunctPrefix(codepoints, index)) return false;
    if (after.extendedPictographic != 0 && hasExtendedPictographicZwjPrefix(codepoints, index))
        return false;
    if (left == GraphemeRegionalIndicator && right == GraphemeRegionalIndicator) {
        size_t regionalIndicators = 0;
        for (size_t cursor = index; cursor > 0; --cursor) {
            if (eryx::unicode::data::recordFor(codepoints[cursor - 1]).graphemeBreak !=
                GraphemeRegionalIndicator)
                break;
            ++regionalIndicators;
        }
        if (regionalIndicators % 2 == 1) return false;
    }
    return true;
}

// Builds byte offsets for every grapheme cluster boundary, including start and end.
// Used lazily by grapheme iteration, unicode.len, and grapheme-based unicode.sub.
static std::vector<size_t> buildGraphemeOffsets(const std::vector<size_t>& offsets,
                                                const std::vector<uint32_t>& codepoints) {
    std::vector<size_t> result;
    result.reserve(offsets.size());
    result.push_back(0);
    for (size_t index = 1; index < codepoints.size(); ++index) {
        if (isGraphemeBoundary(codepoints, index)) result.push_back(offsets[index]);
    }
    if (offsets.size() > 1) result.push_back(offsets.back());
    return result;
}

// Appends a decomposed codepoint while preserving canonical combining class order.
// Used by recursive decomposition before optional recomposition.
static void appendCanonicalOrdered(std::vector<uint32_t>& output, uint32_t codepoint) {
    output.push_back(codepoint);
    const uint8_t combiningClass = eryx::unicode::data::recordFor(codepoint).combiningClass;
    if (combiningClass == 0) return;

    size_t index = output.size() - 1;
    while (index > 0) {
        const uint8_t previousClass =
            eryx::unicode::data::recordFor(output[index - 1]).combiningClass;
        if (previousClass == 0 || previousClass <= combiningClass) break;
        output[index] = output[index - 1];
        output[index - 1] = codepoint;
        --index;
    }
}

// Decomposes one codepoint recursively, using algorithmic Hangul handling where applicable.
// Used by normaliseText for NFC/NFD/NFKC/NFKD.
static void decomposeCodepoint(std::vector<uint32_t>& output, uint32_t codepoint,
                               bool compatibility) {
    constexpr uint32_t SBase = 0xac00;
    constexpr uint32_t LBase = 0x1100;
    constexpr uint32_t VBase = 0x1161;
    constexpr uint32_t TBase = 0x11a7;
    constexpr uint32_t VCount = 21;
    constexpr uint32_t TCount = 28;
    constexpr uint32_t NCount = VCount * TCount;
    constexpr uint32_t SCount = 19 * NCount;

    const uint32_t syllableIndex = codepoint - SBase;
    if (syllableIndex < SCount) {
        appendCanonicalOrdered(output, LBase + syllableIndex / NCount);
        appendCanonicalOrdered(output, VBase + (syllableIndex % NCount) / TCount);
        const uint32_t trailing = TBase + syllableIndex % TCount;
        if (trailing != TBase) appendCanonicalOrdered(output, trailing);
        return;
    }

    const uint32_t* parts = nullptr;
    uint8_t count = 0;
    if (!eryx::unicode::data::decompositionFor(codepoint, compatibility, parts, count)) {
        appendCanonicalOrdered(output, codepoint);
        return;
    }
    for (uint8_t index = 0; index < count; ++index)
        decomposeCodepoint(output, parts[index], compatibility);
}

// Attempts canonical composition of a starter plus following codepoint.
// Used by recompose for NFC and NFKC output.
static uint32_t composeCodepoints(uint32_t starter, uint32_t codepoint) {
    constexpr uint32_t SBase = 0xac00;
    constexpr uint32_t LBase = 0x1100;
    constexpr uint32_t VBase = 0x1161;
    constexpr uint32_t TBase = 0x11a7;
    constexpr uint32_t LCount = 19;
    constexpr uint32_t VCount = 21;
    constexpr uint32_t TCount = 28;
    constexpr uint32_t NCount = VCount * TCount;
    constexpr uint32_t SCount = LCount * NCount;

    const uint32_t leadingIndex = starter - LBase;
    const uint32_t vowelIndex = codepoint - VBase;
    if (leadingIndex < LCount && vowelIndex < VCount)
        return SBase + (leadingIndex * VCount + vowelIndex) * TCount;

    const uint32_t syllableIndex = starter - SBase;
    const uint32_t trailingIndex = codepoint - TBase;
    if (syllableIndex < SCount && syllableIndex % TCount == 0 && trailingIndex > 0 &&
        trailingIndex < TCount)
        return starter + trailingIndex;

    return eryx::unicode::data::composePair(starter, codepoint);
}

// Recombines a canonical decomposition according to Unicode composition rules.
// Used by normaliseText when the requested form is NFC or NFKC.
static std::vector<uint32_t> recompose(std::vector<uint32_t> decomposed) {
    if (decomposed.size() <= 1) return decomposed;

    std::vector<uint32_t> output;
    output.reserve(decomposed.size());
    output.push_back(decomposed[0]);
    size_t starterPosition = 0;
    uint32_t starter = output[0];
    uint8_t lastCombiningClass = 0;

    for (size_t index = 1; index < decomposed.size(); ++index) {
        const uint32_t codepoint = decomposed[index];
        const uint8_t combiningClass = eryx::unicode::data::recordFor(codepoint).combiningClass;
        const uint32_t composed = (lastCombiningClass < combiningClass || combiningClass == 0)
                                      ? composeCodepoints(starter, codepoint)
                                      : 0;
        if (composed != 0) {
            output[starterPosition] = composed;
            starter = composed;
        } else {
            if (combiningClass == 0) {
                starterPosition = output.size();
                starter = codepoint;
            }
            output.push_back(codepoint);
            lastCombiningClass = combiningClass;
        }
    }
    return output;
}

// Normalizes UTF-8 text to NFC, NFD, NFKC, or NFKD based on Lua arguments.
// Used by UnicodeString:normalise, unicode.normalise, and isNormalised comparisons.
static std::string normaliseText(lua_State* L, int sourceIndex, int formatIndex) {
    const std::string_view format = luaL_checkstring(L, formatIndex);
    const bool compatibility = format == "NFKC" || format == "NFKD";
    const bool compose = format == "NFC" || format == "NFKC";
    if (!compose && format != "NFD" && format != "NFKD")
        luaL_argerror(L, formatIndex, "expected NFC, NFD, NFKC, or NFKD");

    std::vector<uint32_t> codepoints;
    if (UnicodeString* value = testUnicodeString(L, sourceIndex)) {
        codepoints = decodeCodepoints(value->utf8, value->offsets);
    } else {
        codepoints = decodeCodepointsChecked(L, sourceIndex, checkRawString(L, sourceIndex));
    }

    std::vector<uint32_t> decomposed;
    for (uint32_t codepoint : codepoints) decomposeCodepoint(decomposed, codepoint, compatibility);
    const std::vector<uint32_t> result =
        compose ? recompose(std::move(decomposed)) : std::move(decomposed);

    std::string output;
    for (uint32_t codepoint : result) appendCodepoint(output, codepoint);
    return output;
}

// Requires a UnicodeString userdata at a Lua stack index and returns its C++ storage.
// Used by methods that only operate on already-constructed UnicodeString values.
static UnicodeString* checkUnicodeString(lua_State* L, int index) {
    udataRef* ref = eryxUdata_getudata(L, UnicodeStringType);
    if (!ref) {
        luaL_error(L, "%s userdata is not registered", UnicodeStringType);
        return nullptr;
    }
    return static_cast<UnicodeString*>(eryxUdata_checkudata(L, ref, index));
}

// Returns UnicodeString storage if the stack value has the right metatable, otherwise null.
// Used by coercion and mixed string/UnicodeString operations.
static UnicodeString* testUnicodeString(lua_State* L, int index) {
    udataRef* ref = eryxUdata_getudata(L, UnicodeStringType);
    return ref ? static_cast<UnicodeString*>(eryxUdata_testudata(L, ref, index)) : nullptr;
}

// Returns cached grapheme offsets, computing them on first use.
// Used only by grapheme-aware APIs so ordinary UnicodeString creation stays cheap.
static const std::vector<size_t>& graphemeOffsetsFor(UnicodeString* value) {
    if (value->graphemeOffsets.empty()) {
        std::vector<uint32_t> codepoints = decodeCodepoints(value->utf8, value->offsets);
        value->graphemeOffsets = buildGraphemeOffsets(value->offsets, codepoints);
    }
    return value->graphemeOffsets;
}

// Runs the C++ destructor for UnicodeString userdata allocated by eryxUdata_pushudata.
// Used by pushUnicodeString so the cached vectors and backing string are released correctly.
static void unicodestring_dtor(lua_State*, void* ud) {
    static_cast<UnicodeString*>(ud)->~UnicodeString();
}

// Allocates and pushes a UnicodeString userdata from UTF-8 bytes after validation.
// Used by constructors and every operation that returns a UnicodeString.
static UnicodeString* pushUnicodeString(lua_State* L, std::string value) {
    std::vector<size_t> offsets;
    if (!buildOffsets(value, offsets)) luaL_error(L, "invalid UTF-8 string");

    udataRef* ref = eryxUdata_getudata(L, UnicodeStringType);
    if (!ref) {
        luaL_error(L, "%s userdata is not registered", UnicodeStringType);
        return nullptr;
    }
    void* storage = eryxUdata_pushudata(L, ref);
    auto* result = new (storage) UnicodeString{ std::move(value), std::move(offsets), {} };
    return result;
}

// Converts a raw Lua string argument to UnicodeString in-place, or returns existing userdata.
// Used by unicode namespace functions that accept either strings or UnicodeString values.
static UnicodeString* coerceUnicodeStringArgument(lua_State* L, int index) {
    if (UnicodeString* value = testUnicodeString(L, index)) return value;

    size_t length = 0;
    const char* text = luaL_checklstring(L, index, &length);
    UnicodeString* value = pushUnicodeString(L, std::string(text, length));
    lua_replace(L, index);
    return value;
}

// Converts Lua-style negative indices into positive one-based positions.
// Used by codepoint and grapheme slicing/indexing APIs.
static int relativePosition(int position, size_t length) {
    if (position < 0) position += static_cast<int>(length) + 1;
    return position >= 0 ? position : 0;
}

// Returns the raw UTF-8 backing bytes for tostring(value).
// Registered as the UnicodeString __tostring metamethod.
static int ustring_mt_tostring(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, 1);
    lua_pushlstring(L, value->utf8.data(), value->utf8.size());
    return 1;
}

// Converts a single-codepoint numeric UnicodeString/string into its Unicode numeric value.
// Used by UnicodeString:toNumber and unicode.toNumber.
static int ustring_tonumber(lua_State* L) {
    UnicodeString* value = coerceUnicodeStringArgument(L, 1);
    if (value->offsets.size() != 2) {
        lua_pushnil(L);
        return 1;
    }
    size_t offset = 0;
    uint32_t codepoint = 0;
    decodeCodepoint(value->utf8, offset, codepoint);
    double number = 0;
    if (!eryx::unicode::type::numericValue(codepoint, number)) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushnumber(L, number);
    return 1;
}

// Looks up the Unicode character name for exactly one codepoint.
// Used by UnicodeString:name and unicode.name.
static int ustring_name(lua_State* L) {
    UnicodeString* value = coerceUnicodeStringArgument(L, 1);
    if (value->offsets.size() != 2) luaL_error(L, "unicode.name expects exactly one codepoint");
    size_t offset = 0;
    uint32_t codepoint = 0;
    decodeCodepoint(value->utf8, offset, codepoint);
    std::string name;
    if (!eryx::unicode::name::nameFor(codepoint, name))
        luaL_error(L, "No unicode name found for U+%X", codepoint);
    lua_pushlstring(L, name.data(), name.size());
    return 1;
}

// Returns a new UnicodeString normalized to the requested Unicode normalization form.
// Used by UnicodeString:normalise and unicode.normalise.
static int ustring_normalise(lua_State* L) {
    pushUnicodeString(L, normaliseText(L, 1, 2));
    return 1;
}

// Reports whether input text already matches the requested normalization form.
// Used by UnicodeString:isNormalised and unicode.isNormalised.
static int ustring_isnormalised(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    lua_pushboolean(L, normaliseText(L, 1, 2) == source);
    return 1;
}

// Applies Unicode case folding and returns the folded text as a UnicodeString.
// Used by UnicodeString:foldCase and unicode.foldCase.
static int ustring_foldcase(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    std::string output;
    size_t offset = 0;
    while (offset < source.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, 1, source, offset, codepoint);
        uint32_t mapped[3] = {};
        const uint8_t count =
            eryx::unicode::type::mapCase(codepoint, eryx::unicode::type::CaseMapping::Fold, mapped);
        for (uint8_t index = 0; index < count; ++index) appendCodepoint(output, mapped[index]);
    }
    pushUnicodeString(L, std::move(output));
    return 1;
}

// Applies Unicode uppercase mapping and returns the mapped text as a UnicodeString.
// Used by UnicodeString:toUpperCase and unicode.toUpperCase.
static int ustring_touppercase(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    std::string output;
    size_t offset = 0;
    while (offset < source.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, 1, source, offset, codepoint);
        uint32_t mapped[3] = {};
        const uint8_t count = eryx::unicode::type::mapCase(
            codepoint, eryx::unicode::type::CaseMapping::Upper, mapped);
        for (uint8_t index = 0; index < count; ++index) appendCodepoint(output, mapped[index]);
    }
    pushUnicodeString(L, std::move(output));
    return 1;
}

// Applies Unicode lowercase mapping and returns the mapped text as a UnicodeString.
// Used by UnicodeString:toLowercase and unicode.toLowercase.
static int ustring_tolowercase(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    std::string output;
    size_t offset = 0;
    while (offset < source.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, 1, source, offset, codepoint);
        uint32_t mapped[3] = {};
        const uint8_t count = eryx::unicode::type::mapCase(
            codepoint, eryx::unicode::type::CaseMapping::Lower, mapped);
        for (uint8_t index = 0; index < count; ++index) appendCodepoint(output, mapped[index]);
    }
    pushUnicodeString(L, std::move(output));
    return 1;
}

// Applies Unicode titlecase mapping and returns the mapped text as a UnicodeString.
// Used by UnicodeString:toTitleCase and unicode.toTitleCase.
static int ustring_totitlecase(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    std::string output;
    size_t offset = 0;
    bool first = true;
    while (offset < source.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, 1, source, offset, codepoint);
        uint32_t mapped[3] = {};
        const auto mapping = first ? eryx::unicode::type::CaseMapping::Title
                                   : eryx::unicode::type::CaseMapping::Lower;
        const uint8_t count = eryx::unicode::type::mapCase(codepoint, mapping, mapped);
        for (uint8_t index = 0; index < count; ++index) appendCodepoint(output, mapped[index]);
        first = false;
    }
    pushUnicodeString(L, std::move(output));
    return 1;
}

// Returns the number of codepoints in a UnicodeString.
// Registered as the UnicodeString __len metamethod.
static int ustring_mt_len(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, 1);
    lua_pushinteger(L, static_cast<int>(value->offsets.size() - 1));
    return 1;
}

// Compares two UnicodeString userdata values by exact UTF-8 byte contents.
// Registered as the UnicodeString __eq metamethod.
static int ustring_mt_eq(lua_State* L) {
    UnicodeString* left = testUnicodeString(L, 1);
    UnicodeString* right = testUnicodeString(L, 2);
    lua_pushboolean(L, left && right && left->utf8 == right->utf8);
    return 1;
}

// Concatenates two UnicodeString/string operands and returns a UnicodeString.
// Registered as the UnicodeString __concat metamethod.
static int ustring_mt_concat(lua_State* L) {
    std::string result;
    for (int index = 1; index <= 2; ++index) {
        if (UnicodeString* value = testUnicodeString(L, index)) {
            result += value->utf8;
        } else {
            size_t length = 0;
            const char* text = luaL_checklstring(L, index, &length);
            result.append(text, length);
        }
    }

    pushUnicodeString(L, std::move(result));
    return 1;
}

// Pushes numeric codepoints for a one-based inclusive codepoint range.
// Used by UnicodeString:codepoint.
static int ustring_codepoint(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, 1);
    const size_t length = value->offsets.size() - 1;
    int start = relativePosition(luaL_optinteger(L, 2, 1), length);
    int end = relativePosition(luaL_optinteger(L, 3, start), length);

    start = std::max(start, 1);
    end = std::min(end, static_cast<int>(length));
    if (start > end) return 0;

    const int count = end - start + 1;
    luaL_checkstack(L, count, "too many codepoints");
    for (int index = start - 1; index < end; ++index) {
        size_t offset = value->offsets[index];
        uint32_t codepoint = 0;
        decodeCodepoint(value->utf8, offset, codepoint);
        lua_pushinteger(L, static_cast<int>(codepoint));
    }
    return count;
}

// Iterator step that yields the next codepoint value from a captured UnicodeString.
// Created by UnicodeString:codepoints.
static int ustring_codepoints_next(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, lua_upvalueindex(1));
    int index = static_cast<int>(lua_tointeger(L, lua_upvalueindex(2)));
    const int length = static_cast<int>(value->offsets.size() - 1);
    if (index >= length) return 0;

    size_t offset = value->offsets[index];
    uint32_t codepoint = 0;
    decodeCodepoint(value->utf8, offset, codepoint);
    lua_pushinteger(L, index + 1);
    lua_replace(L, lua_upvalueindex(2));
    lua_pushinteger(L, static_cast<int>(codepoint));
    return 1;
}

// Creates an iterator over codepoint numbers.
// Used by UnicodeString:codepoints.
static int ustring_codepoints(lua_State* L) {
    checkUnicodeString(L, 1);
    lua_pushvalue(L, 1);
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, ustring_codepoints_next, "UnicodeString.codepoints", 2);
    return 1;
}

// Iterator step that yields the next grapheme cluster as a UnicodeString.
// Created by UnicodeString:graphemes and unicode.graphemes.
static int ustring_graphemes_next(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, lua_upvalueindex(1));
    int index = static_cast<int>(lua_tointeger(L, lua_upvalueindex(2)));
    const std::vector<size_t>& graphemeOffsets = graphemeOffsetsFor(value);
    const int length = static_cast<int>(graphemeOffsets.size() - 1);
    if (index >= length) return 0;

    const size_t begin = graphemeOffsets[index];
    const size_t end = graphemeOffsets[index + 1];
    lua_pushinteger(L, index + 1);
    lua_replace(L, lua_upvalueindex(2));
    pushUnicodeString(L, value->utf8.substr(begin, end - begin));
    return 1;
}

// Finds an exact UTF-8 substring and returns codepoint index bounds when aligned.
// Used by UnicodeString:find.
static int ustring_find(lua_State* L) {
    UnicodeString* haystack = checkUnicodeString(L, 1);
    UnicodeString* needle = checkUnicodeString(L, 2);
    const size_t length = haystack->offsets.size() - 1;
    int initial = relativePosition(luaL_optinteger(L, 3, 1), length);
    initial = std::clamp(initial, 1, static_cast<int>(length) + 1);

    const size_t byteStart = haystack->offsets[initial - 1];
    const size_t found = haystack->utf8.find(needle->utf8, byteStart);
    if (found == std::string::npos) {
        lua_pushnil(L);
        return 1;
    }

    const auto first = std::lower_bound(haystack->offsets.begin(), haystack->offsets.end(), found);
    const size_t foundEnd = found + needle->utf8.size();
    const auto last =
        std::lower_bound(haystack->offsets.begin(), haystack->offsets.end(), foundEnd);
    if (first == haystack->offsets.end() || *first != found || last == haystack->offsets.end() ||
        *last != foundEnd) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushinteger(L, static_cast<int>(first - haystack->offsets.begin()) + 1);
    lua_pushinteger(L, static_cast<int>(last - haystack->offsets.begin()));
    return 2;
}

// Repeats a UnicodeString a requested number of times, guarding against oversized output.
// Used by UnicodeString:rep.
static int ustring_rep(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, 1);
    int count = luaL_checkinteger(L, 2);
    if (count <= 0) {
        pushUnicodeString(L, {});
        return 1;
    }

    if (!value->utf8.empty() &&
        static_cast<size_t>(count) > std::string().max_size() / value->utf8.size())
        luaL_error(L, "resulting Unicode string is too large");

    std::string result;
    result.reserve(value->utf8.size() * static_cast<size_t>(count));
    for (int index = 0; index < count; ++index) result += value->utf8;
    pushUnicodeString(L, std::move(result));
    return 1;
}

// Reverses a UnicodeString by codepoint rather than by byte.
// Used by UnicodeString:reverse.
static int ustring_reverse(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, 1);
    std::string result;
    result.reserve(value->utf8.size());
    for (size_t index = value->offsets.size() - 1; index > 0; --index) {
        const size_t begin = value->offsets[index - 1];
        result.append(value->utf8, begin, value->offsets[index] - begin);
    }
    pushUnicodeString(L, std::move(result));
    return 1;
}

// Splits a UnicodeString by another UnicodeString separator and returns a Lua array.
// Used by UnicodeString:split; an empty separator splits into codepoints.
static int ustring_split(lua_State* L) {
    UnicodeString* value = checkUnicodeString(L, 1);
    UnicodeString* separator = checkUnicodeString(L, 2);

    if (separator->utf8.empty()) {
        const size_t count = value->offsets.size() - 1;
        lua_createtable(L, static_cast<int>(count), 0);
        for (size_t index = 0; index < count; ++index) {
            pushUnicodeString(
                L, value->utf8.substr(value->offsets[index],
                                      value->offsets[index + 1] - value->offsets[index]));
            lua_rawseti(L, -2, static_cast<int>(index + 1));
        }
        return 1;
    }

    lua_newtable(L);
    size_t start = 0;
    int outputIndex = 1;
    while (true) {
        const size_t found = value->utf8.find(separator->utf8, start);
        if (found == std::string::npos) {
            pushUnicodeString(L, value->utf8.substr(start));
            lua_rawseti(L, -2, outputIndex);
            break;
        }

        pushUnicodeString(L, value->utf8.substr(start, found - start));
        lua_rawseti(L, -2, outputIndex++);
        start = found + separator->utf8.size();
    }
    return 1;
}

// Encodes Unicode text to UTF-16 bytes with configurable endianness and optional BOM.
// Used by UnicodeString:toUtf16 and unicode.toUtf16.
static int ustring_toutf16(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    const bool little = isLittleEndian(L, 2, true);
    const bool includeBom = lua_isnoneornil(L, 3) || lua_toboolean(L, 3);

    std::string output;
    output.reserve(source.size() * 2 + (includeBom ? 2 : 0));
    if (includeBom) appendU16(output, 0xfeff, little);

    size_t offset = 0;
    while (offset < source.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, 1, source, offset, codepoint);
        if (codepoint <= 0xffff) {
            appendU16(output, static_cast<uint16_t>(codepoint), little);
        } else {
            codepoint -= 0x10000;
            appendU16(output, static_cast<uint16_t>(0xd800 + (codepoint >> 10)), little);
            appendU16(output, static_cast<uint16_t>(0xdc00 + (codepoint & 0x3ff)), little);
        }
    }
    lua_pushlstring(L, output.data(), output.size());
    return 1;
}

// Encodes Unicode text to UTF-32 bytes with configurable endianness and optional BOM.
// Used by UnicodeString:toUtf32 and unicode.toUtf32.
static int ustring_toutf32(lua_State* L) {
    const std::string_view source = checkUnicodeText(L, 1);
    const bool little = isLittleEndian(L, 2, true);
    const bool includeBom = !lua_isnoneornil(L, 3) && lua_toboolean(L, 3);

    std::string output;
    output.reserve((source.size() + 1) * 4);
    if (includeBom) appendU32(output, 0xfeff, little);

    size_t offset = 0;
    while (offset < source.size()) {
        uint32_t codepoint = 0;
        checkedDecodeCodepoint(L, 1, source, offset, codepoint);
        appendU32(output, codepoint, little);
    }
    lua_pushlstring(L, output.data(), output.size());
    return 1;
}

// Implements the global u(...) constructor for UnicodeString values.
// Returns existing UnicodeString userdata unchanged, otherwise validates and wraps UTF-8.
static int unicode_u(lua_State* L) {
    if (UnicodeString* value = testUnicodeString(L, 1)) {
        lua_pushvalue(L, 1);
        return 1;
    }

    size_t length = 0;
    const char* text = luaL_checklstring(L, 1, &length);
    pushUnicodeString(L, std::string(text, length));
    return 1;
}

// Converts a Unicode character name or named sequence into a UnicodeString.
// Used by unicode.fromName, with an optional Unicode fallback when the name is unknown.
static int unicode_fromname(lua_State* L) {
    std::string query(checkRawString(L, 1));
    std::string normalised;
    normalised.reserve(query.size());
    bool pendingSpace = false;
    for (unsigned char character : query) {
        if (std::isspace(character) || character == '_') {
            pendingSpace = !normalised.empty();
            continue;
        }
        if (pendingSpace) {
            normalised.push_back(' ');
            pendingSpace = false;
        }
        normalised.push_back(static_cast<char>(std::toupper(character)));
    }

    std::vector<uint32_t> codepoints;
    if (!eryx::unicode::name::codepointsFromName(normalised, codepoints)) {
        if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
            if (testUnicodeString(L, 2)) {
                lua_pushvalue(L, 2);
            } else {
                const std::string_view fallback = checkRawString(L, 2);
                pushUnicodeString(L, std::string(fallback));
            }
        } else {
            lua_pushnil(L);
        }
        return 1;
    }

    std::string output;
    for (uint32_t codepoint : codepoints) appendCodepoint(output, codepoint);
    pushUnicodeString(L, std::move(output));
    return 1;
}

// Dispatches category lookup for both unicode.category(codepoint) and value:category(index).
// Used by the shared unicode table that also serves as UnicodeString.__index.
static int unicode_category(lua_State* L) {
    if (UnicodeString* value = testUnicodeString(L, 1)) {
        const size_t length = value->offsets.size() - 1;
        int index = relativePosition(luaL_optinteger(L, 2, 1), length);
        if (index < 1 || index > static_cast<int>(length))
            luaL_error(L, "codepoint index out of range");

        size_t offset = value->offsets[index - 1];
        uint32_t codepoint = 0;
        decodeCodepoint(value->utf8, offset, codepoint);
        const auto& record = eryx::unicode::data::recordFor(codepoint);
        lua_pushstring(L, CategoryNames[record.category]);
        return 1;
    }

    const int codepoint = luaL_checkinteger(L, 1);
    if (codepoint < 0 || codepoint > 0x10ffff) luaL_error(L, "codepoint out of range");
    const auto& record = eryx::unicode::data::recordFor(static_cast<uint32_t>(codepoint));
    lua_pushstring(L, CategoryNames[record.category]);
    return 1;
}

// Returns the number of grapheme clusters in string-like input.
// Used by unicode.len and intentionally triggers the lazy grapheme cache.
static int unicode_len(lua_State* L) {
    UnicodeString* value = coerceUnicodeStringArgument(L, 1);
    lua_pushinteger(L, static_cast<int>(graphemeOffsetsFor(value).size() - 1));
    return 1;
}

// Coerces string-like input and creates a grapheme-cluster iterator.
// Used by unicode.graphemes.
static int ustring_graphemes(lua_State* L) {
    coerceUnicodeStringArgument(L, 1);
    lua_pushvalue(L, 1);
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, ustring_graphemes_next, "unicode.graphemes", 2);
    return 1;
}

// Returns a substring using grapheme cluster indices.
// Used by unicode.sub and intentionally triggers the lazy grapheme cache.
static int unicode_sub(lua_State* L) {
    UnicodeString* value = coerceUnicodeStringArgument(L, 1);
    const std::vector<size_t>& graphemeOffsets = graphemeOffsetsFor(value);
    const size_t length = graphemeOffsets.size() - 1;
    int start = relativePosition(luaL_checkinteger(L, 2), length);
    int end = relativePosition(luaL_optinteger(L, 3, -1), length);

    start = std::max(start, 1);
    end = std::min(end, static_cast<int>(length));
    if (start > end) {
        pushUnicodeString(L, {});
        return 1;
    }

    const size_t beginOffset = graphemeOffsets[start - 1];
    const size_t endOffset = graphemeOffsets[end];
    pushUnicodeString(L, value->utf8.substr(beginOffset, endOffset - beginOffset));
    return 1;
}

// Detects UTF-16/UTF-32 byte order marks in a raw byte string.
// Used by unicode.detectBom and returns endian, encoding, and BOM byte length.
static int unicode_detectbom(lua_State* L) {
    const std::string_view source = checkRawString(L, 1);
    if (source.size() >= 4) {
        const uint32_t leading = readU32(source, 0, true);
        if (leading == 0x0000feff) {
            lua_pushstring(L, "little");
            lua_pushstring(L, "utf32");
            lua_pushinteger(L, 4);
            return 3;
        }
        if (leading == 0xfffe0000) {
            lua_pushstring(L, "big");
            lua_pushstring(L, "utf32");
            lua_pushinteger(L, 4);
            return 3;
        }
    }
    if (source.size() >= 2) {
        const uint16_t leading = readU16(source, 0, true);
        if (leading == 0xfeff) {
            lua_pushstring(L, "little");
            lua_pushstring(L, "utf16");
            lua_pushinteger(L, 2);
            return 3;
        }
        if (leading == 0xfffe) {
            lua_pushstring(L, "big");
            lua_pushstring(L, "utf16");
            lua_pushinteger(L, 2);
            return 3;
        }
    }
    lua_pushnil(L);
    lua_pushnil(L);
    lua_pushinteger(L, 0);
    return 3;
}

// Decodes UTF-16 bytes into a UnicodeString, handling byte order, BOMs, and surrogates.
// Used by unicode.fromUtf16.
static int unicode_fromutf16(lua_State* L) {
    const std::string_view source = checkRawString(L, 1);
    if (source.size() % 2 != 0) luaL_error(L, "Malformed UTF-16 string: byte length must be even");

    bool little = true;
    size_t offset = 0;
    if (!lua_isnoneornil(L, 2)) little = isLittleEndian(L, 2, true);
    const bool strict = !lua_isnoneornil(L, 3) && lua_toboolean(L, 3);
    const bool preserveBom = !lua_isnoneornil(L, 4) && lua_toboolean(L, 4);
    if (!preserveBom && source.size() >= 2) {
        const uint16_t leading = readU16(source, 0, true);
        if (leading == 0xfeff || leading == 0xfffe) {
            const bool bomLittle = leading == 0xfeff;
            if (!lua_isnoneornil(L, 2) && little != bomLittle)
                luaL_error(L, "UTF-16 BOM conflicts with requested byte order");
            little = bomLittle;
            offset = 2;
        }
    }

    std::string output;
    while (offset < source.size()) {
        const uint16_t first = readU16(source, offset, little);
        offset += 2;
        if (first >= 0xd800 && first <= 0xdbff) {
            if (offset + 2 <= source.size()) {
                const uint16_t second = readU16(source, offset, little);
                if (second >= 0xdc00 && second <= 0xdfff) {
                    offset += 2;
                    appendCodepoint(
                        output, 0x10000 + ((uint32_t(first - 0xd800) << 10) | (second - 0xdc00)));
                    continue;
                }
            }
            luaL_error(
                L, strict
                       ? "Malformed UTF-16 string: unpaired high surrogate"
                       : "UTF-16 contains a surrogate that cannot be represented by UnicodeString");
        }
        if (first >= 0xdc00 && first <= 0xdfff)
            luaL_error(
                L, strict
                       ? "Malformed UTF-16 string: unpaired low surrogate"
                       : "UTF-16 contains a surrogate that cannot be represented by UnicodeString");
        appendCodepoint(output, first);
    }
    pushUnicodeString(L, std::move(output));
    return 1;
}

// Decodes UTF-32 bytes into a UnicodeString, handling byte order and optional BOM removal.
// Used by unicode.fromUtf32.
static int unicode_fromutf32(lua_State* L) {
    const std::string_view source = checkRawString(L, 1);
    if (source.size() % 4 != 0)
        luaL_error(L, "Malformed UTF-32 string: byte length must be a multiple of 4");

    bool little = true;
    size_t offset = 0;
    if (!lua_isnoneornil(L, 2)) little = isLittleEndian(L, 2, true);
    const bool preserveBom = !lua_isnoneornil(L, 4) && lua_toboolean(L, 4);
    if (!preserveBom && source.size() >= 4) {
        const uint32_t leading = readU32(source, 0, true);
        if (leading == 0x0000feff || leading == 0xfffe0000) {
            const bool bomLittle = leading == 0x0000feff;
            if (!lua_isnoneornil(L, 2) && little != bomLittle)
                luaL_error(L, "UTF-32 BOM conflicts with requested byte order");
            little = bomLittle;
            offset = 4;
        }
    }

    std::string output;
    while (offset < source.size()) {
        const uint32_t codepoint = readU32(source, offset, little);
        offset += 4;
        if (codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff))
            luaL_error(L, "invalid UTF-32 codepoint");
        appendCodepoint(output, codepoint);
    }
    pushUnicodeString(L, std::move(output));
    return 1;
}

static int ustring_get_version(lua_State* L) {
    lua_pushstring(L, eryx::unicode::data::Version);
    return 1;
}

static luaL_Reg unicodeStringMetamethods[] = {
    { "__tostring", ustring_mt_tostring }, { "__len", ustring_mt_len }, { "__eq", ustring_mt_eq },
    { "__concat", ustring_mt_concat },     { nullptr, nullptr },
};

static luaL_Reg unicodeStringMethods[] = {
    { "fromname", unicode_fromname },
    { "category", unicode_category },
    { "detectbom", unicode_detectbom },
    { "fromutf16", unicode_fromutf16 },
    { "fromutf32", unicode_fromutf32 },
    { "tonumber", ustring_tonumber },
    { "name", ustring_name },
    { "normalise", ustring_normalise },
    { "isnormalised", ustring_isnormalised },
    { "foldcase", ustring_foldcase },
    { "touppercase", ustring_touppercase },
    { "tolowercase", ustring_tolowercase },
    { "totitlecase", ustring_totitlecase },
    { "len", unicode_len },
    { "sub", unicode_sub },
    { "codepoint", ustring_codepoint },
    { "codepoints", ustring_codepoints },
    { "graphemes", ustring_graphemes },
    { "find", ustring_find },
    { "rep", ustring_rep },
    { "reverse", ustring_reverse },
    { "split", ustring_split },
    { "toutf16", ustring_toutf16 },
    { "toutf32", ustring_toutf32 },
    { nullptr, nullptr },
};

static udataField unicodeStringFields[] = {
    { "version", ustring_get_version, nullptr },
    { nullptr, nullptr, nullptr },
};

static udataDef unicodeStringDef = {
    .name = UnicodeStringType,
    .size = sizeof(UnicodeString),
    .fields = unicodeStringFields,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = unicodeStringMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = unicodeStringMethods,
    .destructor = unicodestring_dtor,
};

// Installs the UnicodeString metatable, global u(...) constructor, and unicode namespace table.
// Called by the runtime wrapper during library initialization.
void unicode_string_lib_register(lua_State* L) {
    eryxUdata_registerudata(L, &unicodeStringDef);

    // This is the public unicode namespace; UnicodeString exposes the same functions via udataDef.
    lua_newtable(L);
    lua_pushstring(L, eryx::unicode::data::Version);
    lua_setfield(L, -2, "version");
    eryxUdata_addmethodstotable(L, &unicodeStringDef, -1);

    lua_setreadonly(L, -1, true);
    lua_setglobal(L, "unicode");

    lua_pushcfunction(L, unicode_u, "u");
    lua_setglobal(L, "u");
}
