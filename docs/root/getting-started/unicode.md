# Unicode

In Luau, `string`s are a collection of bytes with no additional metadata. It is common for strings to be encoded as either plain ANSI or UTF-8, but when using anything other than ANSI functions such as `string.lower` break.

Eryx introduces full Unicode support through the global `unicode` library and the `UnicodeString` type.

Additionally, a new global named `u` is introduced. This function takes either a UTF-8 string or an existing `UnicodeString`, and returns a `UnicodeString`. The primary way to use this function is as a literal, such as `foo(u"hello world")`.

```luau
local value = u"caf\u{00E9}"

print(typeof(value)) -- "UnicodeString"
print(tostring(value)) -- "caf\u{00E9}"
```

All raw string arguments accepted by `unicode` are expected to contain valid UTF-8 unless the function specifically documents that it works with encoded byte strings, such as `detectbom`, `fromutf16`, and `fromutf32`.

## u

```luau
function u(value: string | UnicodeString): UnicodeString
```

Converts a UTF-8 string into a `UnicodeString`. If `value` is already a `UnicodeString`, it is returned unchanged.

`UnicodeString` values keep cached codepoint boundaries, so methods such as `:sub`, `:codepoint`, and `#value` work in codepoints instead of bytes.

## UnicodeString

`UnicodeString` stores validated UTF-8 text and exposes methods through the same table used by the global `unicode` library. That means many functions are available in both forms:

```luau
unicode.normalise("e\u{0301}", "NFC")
u"e\u{0301}":normalise("NFC")
```

The type also implements a few Luau operations directly:

| Operation | Meaning |
| --------- | ------- |
| `#value` | Returns the number of codepoints |
| `tostring(value)` | Returns the underlying UTF-8 bytes as a Luau string |
| `left == right` | Compares two `UnicodeString` values by exact UTF-8 contents |
| `left .. right` | Concatenates a `UnicodeString` with another `UnicodeString` or string, returning a `UnicodeString` |

These operations correspond to the `__len`, `__tostring`, `__eq`, and `__concat` metamethods.

The `#` operator and `UnicodeString:len()` return the number of codepoints, not bytes and not grapheme clusters. For grapheme cluster length, use `unicode.len(value)`.

```luau
local value = u"A\u{00E9}\u{1F642}"

print(#value) -- 3 codepoints
print(value:sub(2, -1)) -- "\u{00E9}\u{1F642}"
```

## unicode.version

```luau
unicode.version: string
```

The Unicode standard version used by Eryx. At the time of writing this value is `"17.0.0"`.

## unicode.fromname

```luau
function unicode.fromname(
    name: string,
    default: (string | UnicodeString)?
): UnicodeString?
```

Looks up a Unicode character name or named sequence and returns it as a `UnicodeString`.

Names are matched case-insensitively. Extra whitespace and underscores are treated as spaces, so `"left_curly_bracket"` and `"   LEFT   CURLY   BRACKET"` both resolve to `{`.

If `name` cannot be found, `default` is returned as a `UnicodeString` when provided. Otherwise, the function returns `nil`.

```luau
print(unicode.fromname("SNOWMAN")) -- "\u{2603}"
print(unicode.fromname("KEYCAP DIGIT ONE")) -- "1\u{FE0F}\u{20E3}"
print(unicode.fromname("not real", "?")) -- "?"
```

## unicode.tonumber

```luau
function unicode.tonumber(grapheme: string | UnicodeString): number?
```

Returns the Unicode numeric value of a single-codepoint string. This includes decimal digits and numeric characters such as fractions.

If the input is not exactly one codepoint, or the codepoint has no Unicode numeric value, this returns `nil`.

```luau
print(unicode.tonumber("9")) -- 9
print(unicode.tonumber("\u{00BD}")) -- 0.5
print(unicode.tonumber("ab")) -- nil
```

## unicode.category

```luau
function unicode.category(codepoint: number): string
```

Returns the Unicode general category for a codepoint number, such as `"Lu"`, `"Ll"`, `"Nd"`, or `"Mn"`.

The codepoint must be in the range `0` through `0x10ffff`.

```luau
print(unicode.category(0x41)) -- "Lu"
print(unicode.category(0x0301)) -- "Mn"
```

When called as a `UnicodeString` method, `category` accepts a one-based codepoint index:

```luau
function UnicodeString:category(index: number?): string
```

Negative indices count back from the end. The default index is `1`.

## unicode.name

```luau
function unicode.name(grapheme: string | UnicodeString): string
```

Returns the Unicode name for a string containing exactly one codepoint.

This function errors if the input has zero codepoints, multiple codepoints, or no Unicode name.

```luau
print(unicode.name("A")) -- "LATIN CAPITAL LETTER A"
```

## unicode.normalise

```luau
function unicode.normalise(
    source: string | UnicodeString,
    format: "NFC" | "NFKC" | "NFD" | "NFKD"
): UnicodeString
```

Returns `source` normalized to one of the four Unicode normalization forms.

`NFC` and `NFD` perform canonical normalization. `NFKC` and `NFKD` also apply compatibility decomposition, which can change formatting distinctions.

```luau
local composed = unicode.normalise("e\u{0301}", "NFC")
print(composed) -- "\u{00E9}"
```

## unicode.isnormalised

```luau
function unicode.isnormalised(
    source: string | UnicodeString,
    format: "NFC" | "NFKC" | "NFD" | "NFKD"
): boolean
```

Returns whether `source` is already normalized to the requested form.

```luau
print(unicode.isnormalised("\u{00E9}", "NFC")) -- true
print(unicode.isnormalised("e\u{0301}", "NFC")) -- false
```

## unicode.foldcase

```luau
function unicode.foldcase(source: string | UnicodeString): UnicodeString
```

Applies Unicode case folding. This is useful for case-insensitive comparison.

```luau
print(unicode.foldcase("Stra\u{00DF}e")) -- "strasse"
```

## unicode.touppercase

```luau
function unicode.touppercase(source: string | UnicodeString): UnicodeString
```

Applies Unicode uppercase mapping.

```luau
print(unicode.touppercase("stra\u{00DF}e")) -- "STRASSE"
```

## unicode.tolowercase

```luau
function unicode.tolowercase(source: string | UnicodeString): UnicodeString
```

Applies Unicode lowercase mapping.

```luau
print(unicode.tolowercase("HELLO")) -- "hello"
```

## unicode.totitlecase

```luau
function unicode.totitlecase(source: string | UnicodeString): UnicodeString
```

Applies titlecase mapping to the first codepoint and lowercase mapping to the remaining codepoints.

```luau
print(unicode.totitlecase("hELLO")) -- "Hello"
```

## unicode.graphemes

```luau
function unicode.graphemes(source: string | UnicodeString): () -> UnicodeString?
```

Returns an iterator over Unicode extended grapheme clusters. Each value yielded by the iterator is a `UnicodeString`.

This is the API to use when you want to move through text by what users generally perceive as characters.

```luau
for grapheme in unicode.graphemes("e\u{0301}\u{1F642}") do
    print(grapheme)
end
```

## unicode.len

```luau
function unicode.len(source: string | UnicodeString): number
```

Returns the number of grapheme clusters in `source`.

This differs from `#u(source)`, which counts codepoints.

```luau
print(unicode.len("e\u{0301}")) -- 1
print(#u"e\u{0301}") -- 2
```

## unicode.sub

```luau
function unicode.sub(
    source: string | UnicodeString,
    first: number,
    last: number?
): UnicodeString
```

Returns a substring using one-based grapheme cluster indices. Negative indices count back from the end, and `last` defaults to `-1`.

```luau
print(unicode.sub("A\u{00E9}\u{1F642}", 2, -1)) -- "\u{00E9}\u{1F642}"
```

## unicode.detectbom

```luau
function unicode.detectbom(source: string): ("little" | "big")?, ("utf16" | "utf32")?, number
```

Detects a UTF-16 or UTF-32 byte order mark at the beginning of `source`.

Returns the byte order, encoding kind, and BOM byte length. If no BOM is present, this returns `nil`, `nil`, and `0`.

```luau
local bytes = unicode.toutf16("A", "little", true)
local endian, kind, length = unicode.detectbom(bytes)

print(endian, kind, length) -- "little", "utf16", 2
```

## unicode.fromutf16

```luau
function unicode.fromutf16(
    source: string,
    endian: ("little" | "big")?,
    strict: boolean?,
    preserveBom: boolean?
): UnicodeString
```

Decodes a UTF-16 byte string into a `UnicodeString`.

If `endian` is omitted, little-endian is used unless a BOM is present. By default, a leading BOM is used to detect byte order and is not included in the returned string. Set `preserveBom` to `true` to keep it as U+FEFF.

If a BOM is present and conflicts with the explicit `endian` argument, the function errors. The byte length must be even.

The `strict` argument changes the error message used for unpaired surrogates, but unpaired surrogates always error because they cannot be represented by `UnicodeString`.

## unicode.fromutf32

```luau
function unicode.fromutf32(
    source: string,
    endian: ("little" | "big")?,
    strict: boolean?,
    preserveBom: boolean?
): UnicodeString
```

Decodes a UTF-32 byte string into a `UnicodeString`.

If `endian` is omitted, little-endian is used unless a BOM is present. By default, a leading BOM is used to detect byte order and is not included in the returned string. Set `preserveBom` to `true` to keep it as U+FEFF.

If a BOM is present and conflicts with the explicit `endian` argument, the function errors. The byte length must be a multiple of four. Codepoints outside the Unicode scalar range, including surrogate codepoints, error.

The `strict` argument is accepted for symmetry with `fromutf16`, but UTF-32 decoding always rejects invalid codepoints.

## unicode.toutf16

```luau
function unicode.toutf16(
    source: string | UnicodeString,
    endian: ("little" | "big")?,
    includeBom: boolean?,
    strict: boolean?
): string
```

Encodes UTF-8 text as UTF-16 bytes.

`endian` defaults to `"little"`. `includeBom` defaults to `true`, so `unicode.toutf16("A")` starts with a UTF-16 little-endian BOM. The `strict` argument is accepted by the type surface but is not currently used during encoding.

```luau
local bytes = unicode.toutf16("A\u{1F642}", "big", false)
print(unicode.fromutf16(bytes, "big")) -- "A\u{1F642}"
```

## unicode.toutf32

```luau
function unicode.toutf32(
    source: string | UnicodeString,
    endian: ("little" | "big")?,
    includeBom: boolean?
): string
```

Encodes UTF-8 text as UTF-32 bytes.

`endian` defaults to `"little"`. `includeBom` defaults to `false`.

```luau
local bytes = unicode.toutf32("A\u{1F642}", "big", true)
print(unicode.fromutf32(bytes)) -- "A\u{1F642}"
```

## UnicodeString methods

These methods operate only on existing `UnicodeString` values.

```luau
function UnicodeString:len(): number
function UnicodeString:sub(first: number, last: number?): UnicodeString
function UnicodeString:codepoint(first: number?, last: number?): ...number
function UnicodeString:codepoints(): () -> number?
function UnicodeString:find(needle: UnicodeString, init: number?): (number?, number?)
function UnicodeString:rep(count: number): UnicodeString
function UnicodeString:reverse(): UnicodeString
function UnicodeString:split(separator: UnicodeString): { UnicodeString }
```

`UnicodeString:len`, `:sub`, `:codepoint`, `:codepoints`, `:find`, `:reverse`, and `:split(u"")` work in codepoint units. Negative indices count back from the end where applicable.

`UnicodeString:find` searches for an exact UTF-8 substring and returns one-based codepoint bounds when the match aligns to codepoint boundaries. It returns `nil` when no match is found.

`UnicodeString:split` returns an array of `UnicodeString` parts. An empty separator splits the string into individual codepoints.

The following methods are also available on `UnicodeString` and behave like the corresponding `unicode` functions with `self` as the first argument:

```luau
function UnicodeString:tonumber(): number?
function UnicodeString:name(): string
function UnicodeString:normalise(format: "NFC" | "NFKC" | "NFD" | "NFKD"): UnicodeString
function UnicodeString:isnormalised(format: "NFC" | "NFKC" | "NFD" | "NFKD"): boolean
function UnicodeString:foldcase(): UnicodeString
function UnicodeString:touppercase(): UnicodeString
function UnicodeString:tolowercase(): UnicodeString
function UnicodeString:totitlecase(): UnicodeString
function UnicodeString:graphemes(): () -> UnicodeString?
function UnicodeString:toutf16(endian: ("little" | "big")?, includeBom: boolean?, strict: boolean?): string
function UnicodeString:toutf32(endian: ("little" | "big")?, includeBom: boolean?): string
```
