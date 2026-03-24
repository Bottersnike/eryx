# Style Conventions

The following document outlines a basic style guide for Luau code, followed by the Eryx standard library.

## Naming conventions

- Classes are always named in `PascalCase`
- Class properties always use `camelCase`
- Class functions (`Foo.bar()`) always use `camelCase`
- Class methods (`Foo:bar()`) always use `camelCase`
- Local variables always use `camelCase`
- Constants always use `SHOUTING_SNAKE_CASE`
- "Private" variables and functions are designated by prefixing their name with an underscore (`_`)
- *Really* "private" variables and functions are designed by prefixing their name with two underscores (`__`). Avoid accessing these when at all possible.
- Types are always named in `PascalCase`. Prefixing a type name with `T` for disambiguation is performed occasionally, but discouraged when not strictly required.
- When an acronym is present in a name (eg `HTTP`), only the first letter (if any) should be capitalised. For example, `makeHttpRequest` or `httpStatusCode`. Abbreviations representing sets (such as `HSV` or `RGB`) are an exception to this.

## Use of whitespace

- All Luau scripts must be intended using the tab character
- When possible, lines should be under 100 characters. 120 characters is the absolute allowable limit.
- Comments should be wrapped at the 79 character mark
- Whitespace is not allowable at the end of a line
- All files must end with a blank line
- Spaces must be present around all binary operators (`+`, `-`, `*`, etc).
- Single-line tables should have a space after `{` and before `}`. This also applies to types.
- Double quotes (`"`) should be used in all cases other than when a string includes a `"` character, in which case using `' " '` is preferable to escaping the quote. When both are present in a string, `"` should be used.
- Comments should always have a space after their `--`

## Documentation

- Simple documentation comments should use `---` rather than `--`
- More complex documentation comments should use a block comment with at least one `=` (eg `--[=[ ... ]=]`).

The determination of what comments are "complex" is not strictly defined, but any comments using notation such as `@param` are considered complex.

## Type conventions

The new type solver is used exclusively. Classes are defined as:

```luau
local MyClass = {}
MyClass.__index = MyClass
type MyClassProps = {...}
type MyClass = setmetatable<MyClassProps, typeof(MyClass)>
```

`MyClassProps` can be inlined into the `setmetatable<>` call when not required as a seperate type.
