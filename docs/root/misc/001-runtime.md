# The _RUNTIME specification

This document outlines the specification for `_RUNTIME` and `_LUAU`.

## Motivation

Currently Lua and Luau provide `_VERSION`. On Lua this represents the
Lua version, and on Luau it always contains `"Luau"`.

Luau runtimes often override this variable with a custom string
identifying the runtime name, along with version information. This is
annoying to work with programmatically and runs the risk of becoming the
`User-Agent` problem.

## Design

This document proposes the addition of new `_RUNTIME` and `_LUAU`
globals.

A conforming runtime must always provide at least `_RUNTIME`, though end
users should consider that non-conforming runtimes may not provide
either.

The proposed shape for both is:

```luau
--- Information about the runtime
type _RUNTIME = {
    --- The runtime name, strictly lowercase.
    --- For example, "lune", "zune", "seal", "eryx", "lute", etc
    read name: string,

    --- Version of the runtime itself (not the version of the Luau)
    --- One, both, or neither of `semantic` and `git` may be specified.
    read version: {
        --- A stringified representation of the version. This is very
        --- likely to be similar or identical to what is currently used
        --- for _VERSION, without the runtime name prefix.
        read display: string,

        --- The runtime version, represented using semantic versioning
        read semantic: {
            read major: number,
            read minor: number,
            read patch: number,
            read prerelease: string?,
            read build: string?,
        }?,

        --- The runtime version, represented as a specific git revision
        read git: {
            --- git clone URL
            --- This value may be omitted for privacy
            read url: string?,

            --- The commit this runtime was built against
            read commit: string,

            --- The git branch this runtime was built against. This is
            --- technically redundant given a commit hash, but can be
            --- convenient to have available.
            --- This value may be omitted for privacy
            read branch: string?,
        }?,
    },

    --- An optional URL associated with this runtime. This could be for
    --- documentation, or a general homepage. It could also be to the
    --- GitHub repository for this project.
    read url: string?,

    --- Any extra information the runtime wants to display about its
    --- capabilities, usecases, information, or featureset.
    read extra: {
        [string]: unknown
    }?,

    --- All other keys strictly reserved for future expansion
}

--- Information about the Luau version used. This is optional.
type _LUAU = {
    --- Luau version
    read version: {
        --- A stringified representation of the Luau version, eg "0.722"
        read display: string,

        read major: number,  -- 0
        read minor: number,  -- eg 722
    },

    --- Link to the upstream Luau repository used by the runtime.
    --- This should be a link to a git forge, (e.g. GitHub), and default
    --- to "https://github.com/luau-lang/luau". This URL should should
    --- be overridden if a runtime patches or otherwise modifies Luau
    --- before embedding.
    read url: string?,
}?
```

Both `_RUNTIME` and `_LUAU`, and all of their child tables, must be
marked as read-only (aka frozen) through the use of `lua_setreadonly`
when available.

### What goes in `extra`?

Anything, really. `extra` provides a place for runtime-specific
information to be provided.

In general it is encouraged to provide as much information as reasonably
possible here. This could for example include specific capabilities that
might be gated based on compile-time flags, versions of critical
third-party components such as mlua, luau FFlags, etc.

### Would a "capabilities" table not be superior.

Yes, it would be. An unfortunate concern however would be the ongoing
maintenance and universality of such a field. For example, if we
consider a simple `capabilities: {integer: boolean}`, it is very
reasonable to imagine a different runtime naming that same capability as
`integer64`. Likewise both `class` and `classes` could be imagined.

In order to support a rich capabilities field, an ongoing effort would
be required to identify every new feature, and assign it a unique,
agreed upon, name.

This is not out of the question, but would drastically increase the
scope and complexity of this proposal beyond what seems reasonable at
this time.

### Does this mean I should stop setting `_VERSION`?

This document makes no decision either way regarding changes to
`_VERSION`. It may be preferable to revert it to the default `"Luau"`
value, but it may also be preferable to leave it as-is for compatibility.


### `version` doesn't support anything other than semver or git.

That's true, but currently I don't think there's a desire for supporting
other VCSs like Mercurial. This would be a simple addition in the future
though.

### How should I define these types in a specific runtime?

The ideal way to expose these types is as a union. For example:

```luau
type function negate(ty)
    return types.negationof(ty)
end

declare _RUNTIME: {
    read name: negate<"myruntime">,
    ...  -- Rest of the above type definition
} | {
    read name: "myruntime",
    read version: {
        read display: string,
        -- We don't provide any detailed version information, but still need to define the fields
        read semantic: nil,
        read git: nil,
    },
    read url: string,
    -- Sample "extra" information
    read extra: {
        read foo: {
            read bar: string,
        }
    }
}
```

By doing this, users will receive type warnings if they access
`_RUNTIME` in a non-portable way, but are able to use
`assert(_RUNTIME.name == "myruntime")` to immediately narrow the types.

One important detail to note is that when a field is intentionally
omitted, it must be explicitly typed as `nil` in the runtime-specific
branch of the union. This is a mild workaround for the Luau
type-checker.

The syntax used here is the Luau definitions file syntax. This gets
placed into a `.d.luau` file that all type-related actions (LSPs,
built-in type analysis) load.

In order for the type narrowing to function correctly, this definition
relies upon type functions. These are a feature exclusively present in
Luau's new type solver (V2). In the case where support for the old
solver is required, or the configured environment rejects type functions
within `.d.luau` files, less precise types will need used.

### I don't want to expose my runtime version at all!

This is understandable. `_RUNTIME.version.display` is the only
non-optional field with regards to versions. This field is marked as
non-optional for the sake of drastic code simplification in the most
common case (that is, when a runtime does want to expose its version).

As this field is an unspecified string, runtimes not wishing to expose
their version are more than welcome to expose `display` as something
such as `"<redacted>"`, `"<unknown>"`, `"public"`, etc.

## Drawbacks

- **Introduces a new global.** Any new reserved global risks conflicting
  with existing code that already defines a variable with that name.
  `_RUNTIME` and `_LUAU` were chosen to match the existing `_G` /
  `_VERSION` naming convention and are unlikely to collide in practice,
  but the risk is non-zero.

- **Conformance is unenforceable.** There is no mechanism to validate
  that a runtime's `_RUNTIME` or `_LUAU` tables are well-formed. A
  runtime could provide malformed or partial tables and still claim
  conformance.

- **Not all runtimes might implement this feature.** There is a very
  real possibility that only a handful of available runtimes adopt this
  standard. This results in consumers having to check both `_RUNTIME`
  and `_VERSION`. This is considered an acceptable consideration, as
  there is still value in the structured information provided in
  situations where it is available, and runtime-detection logic can
  still be drastically simplified.

- **Global types are weird with the type system.** This is very true,
  and a little unfortunate. When using Luau-LSP, `.d.luau` files are
  available to expose global type definitions to the user. Many runtimes
  are already using such files to expose other runtime-defined globals,
  so this is not considered a major blocker.

## Alternatives

### `_ENVIRONMENT`

An alternative structure for this feature could look like:

```luau
declare _ENVIRONMENT: {
    runtime: { ... },
    luau: { ... }
}
```

This is a very reasonable alternative. `_RUNTIME` is currently favoured
for the convenience presented by `_RUNTIME.name` over
`_ENVIRONMENT.runtime.name`.

### Extending `_VERSION`

Some runtimes already set `_VERSION` to a runtime-specific string (e.g.
`"Lune 0.10.4+694"`). This could be standardised into a structured
format. This was rejected because `_VERSION` is a string, and structured
data cannot be cleanly encoded in a string without inventing a parsing
convention.

### Multiple top-level globals

Rather than one `_RUNTIME` table, individual globals could be exposed:
`_RUNTIME_NAME`, `_RUNTIME_VERSION`, etc. This avoids the nil-check
overhead on the table and keeps each value independently optional. It
was rejected because it pollutes the global namespace proportionally to
the amount of metadata exposed, and makes it harder to pass runtime
information around as a unit.

### Open-ended keys on `_RUNTIME`

Instead of an `extra` sub-table, runtimes could add their own keys
directly to `_RUNTIME`. This was rejected because it creates an
unmanaged collision space between runtime-defined keys and keys reserved
for future versions of this spec. The `extra` key provides a clear,
unambiguous boundary: anything inside it is runtime-defined, anything
outside it is either specified or reserved.

### All runtimes unify on a set of standard libraries, negating the need for runtime detection

This is generally an unreasonable expectation from runtimes. Further,
runtime detection would still likely be required for non-standardised
libraries and features, returning us to the `_VERSION` problem.