# Unicode & Text

In Luau, a `string` is just a collection of bytes with no attached encoding. That works fine for ASCII, but the moment text contains anything else (accents, emoji, non-Latin scripts) the built-in `string` library starts to misbehave. `string.lower` only knows how to lowercase ASCII, `#text` counts bytes rather than characters, and `string.sub` will happily cut a multi-byte character in half.

Eryx fixes this by adding first-class Unicode support: the global `unicode` library, the `UnicodeString` type, and the `u""` literal that turns a UTF-8 string into a `UnicodeString`.

```luau
local value = u"café"

print(typeof(value))   -- "UnicodeString"
print(value:touppercase()) -- "CAFÉ", not "CAFé"
```

## The three units of length

The single most important idea when working with text is that "how long is this string" has three different answers, and they are routinely different from one another:

| Unit | What it counts | How to get it |
| ---- | -------------- | ------------- |
| **Bytes** | Raw storage; how the text sits in memory or on disk | `#rawString`, the `string` library |
| **Codepoints** | Individual Unicode scalar values | `#u(text)`, `UnicodeString:len()` |
| **Grapheme clusters** | What a human perceives as "a character" | `unicode.len(text)` |

These genuinely differ. A single user-perceived character can be built from several codepoints, and each codepoint can take several bytes:

```luau
local text = "e\u{0301}" -- "e" followed by a combining acute accent

print(#text)             -- 3 (bytes)
print(#u(text))          -- 2 (codepoints: "e" + combining accent)
print(unicode.len(text)) -- 1 (one grapheme cluster: "é")
```

Whenever you're slicing, measuring, or iterating text, decide *which* unit you actually mean. Reaching for the wrong one is the most common source of text-handling bugs. When you want to move through text the way a person reads it, iterate grapheme clusters with `unicode.graphemes`; when you need exact Unicode scalars, work in codepoints.

## Two ways to call everything

Most operations are available in two equivalent forms. You can call the `unicode` library function and pass the text in, or call a method directly on a `UnicodeString`:

```luau
unicode.normalise("e\u{0301}", "NFC") -- function form
u"e\u{0301}":normalise("NFC")         -- method form
```

Pick whichever reads better at the call site. The function form is convenient for one-off operations on a plain string; the method form flows nicely when you're already holding a `UnicodeString` and want to chain operations.

`UnicodeString` also implements the operators you'd expect: `#value` for length in codepoints, `tostring(value)` to get the UTF-8 bytes back, `==` for content comparison, and `..` for concatenation.

## Normalisation and comparison

Unicode often lets the same text be encoded in more than one way. "é" can be a single precomposed codepoint, or an "e" followed by a separate combining accent. They look identical but are *not* byte-equal, which means a naive `==` can report two visually identical strings as different.

*Normalisation* rewrites text into a canonical form so that equivalent text compares equal:

```luau
local a = unicode.normalise("e\u{0301}", "NFC")
local b = unicode.normalise("\u{00E9}", "NFC")
print(a == b) -- true
```

For case-insensitive comparison, prefer `unicode.foldcase` over lowercasing. Case folding is designed specifically for comparison and handles cases that simple lowercasing does not (for example, German "ß" folds to "ss").

## Where to go next

This page covers the model. For the complete API (every function, the encoding/decoding helpers such as `fromutf16`, `toutf32`, and `detectbom`, and the full list of `UnicodeString` methods) see the [[reference/unicode|Unicode reference]].
