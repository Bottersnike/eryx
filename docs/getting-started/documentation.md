# Writing Documentation

Eryx comes with a powerful documentation generation engine. It was used to generate this site!

API documentation is **exclusively** extracted from your code and its structure, along with associated documentation comments. Documentation comments should be denoted with either `---` or wrapped in `--[=[ ... ]=]`.

When locating the documentation for a piece of code, the line directly above is checked. That is:

```luau
--- Answer to life the universe and everything

local result = 42
```

Will not have associated documentation, but the following snippet would:

```luau
--- Answer to life the universe and everything
local result = 42
```

All documentation strings are expected to be written using markdown.

The API documenter locates the final `return` statement from your module. Only fields that are present on that returned value are documented.

Modules with multiple returns or dynamic assignment to their returned table will not have documentation correctly generated.

## Documenting modules

A documentation comment at the very first line is considered a documentation comment.

If a code line is present immediately below this documentation comment, and that code line is documentable, the comment will be associated with that code line. As such, it's recommended to always leave a blank line after a module comment.

## Documenting functions

The types for arguments, returns, and generics are all automatically extracted from your code. You should not duplicate them in your comments. Parameters are documented using `@param` and the return value with `@return`. Inline comments are not read. For example:

```luau
--- This is a function of interest
--- @param arg1 The first argument
--- @param arg2 The second argument
--- @return A buffer
function foo.bar(arg1: number, arg2: string): buffer
end
```

While `@param` supports providing a type, this should **never** be used. It supports this for parsing-compatibility with older codebases.

## Documenting classes

Classes are automatically detected by the presence of an `export type`, not `MyClass.__index = MyClass`. Three patterns are supported:

```luau
export type MyClass = typeof(setmetatable({} :: Fields, Impl))
export type MyClass = setmetatable<FieldsType, typeof(Impl)>
export type MyClass = setmetatable<{inline fields}, {inline meta}>
```

Class documentation should be associated with the `export type MyClass` line, not `local MyClass = {}`.

Once a table has been identified as being a class, it's member functions, methods and fields are automatically grouped into that class.

## Documenting type aliases

Type aliases can have a preceding documentation comment. In addition, for table aliases, each field can have a documentation comment. For example:

```luau
--- FooBar is a very interesting type
export type FooBar = {
    --- This comment documents foo
    foo: number,
    --- This comment documents bar
    bar: number,
    buzz: number,  --- This comment is also picked up, and documents buzz
}
```

## Documentation tags

As seen earlier, functions have `@param` and `@return`. A number of other tags are supported:

| Tag                                      | Function                             |
| ---------------------------------------- | ------------------------------------ |
| `@yields`                                | Marks a function as yielding         |
| `@param <name> [description]`            | Documents a parameter                |
| `@param <name> <type> -- [desc]`         | Alternative form of `@param`         |
| `@return [description]`                  | Documents the return type            |
| `@return <type> -- [desc]`               | Alternative form of `@return`        |
| `@error <type> -- [description]`         | Marks a function as erroring         |
| `@unreleased`                            | Marks a feature as unreleased        |
| `@since <version>`                       | The version this was introduced      |
| `@deprecated [description]`              | Marks as deprecated                  |
| `@deprecated <version> -- [description]` | Marks as deprecated since `version`  |
| `@private`                               | Marks this as private                |
| `@ignore`                                | Entirely ignores this item from docs |
| `@tag <tag>`                             | Arbitrary custom tags                |

## Generating documentation

To generate documentation, you first require a configuration file. Create a file named `eryxdoc.config.luau` at the root of the project you want to document. This file should return a single value detailing the project configuration.

The full configuration format can be found in [[eryxdoc.Config|the API reference]], but the configuration used to build this site is a good starting point:

```luau
return {
	output = "build-docs/",

	modules = "./src/modules",
	articles = "./docs",
	prefix = "@eryx",

	title = "Eryx Documentation",
	siteRoot = "/",
	baseUrl = "https://eryx.bsnk.me",
	exportMode = "directory",

	static = "./docs/static",
	staticMount = "static",
}
```

Set `staticMount = "/"` to copy and serve files from `static` at the site root instead of under `/static/`.

Once our project is configured, we can start the development server using `eryx doc --dev`. The development server supports live-reload as you make changes to your project.

To produce a build, simply run `eryx doc`.
