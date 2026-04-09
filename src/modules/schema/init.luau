--[=[
	@module @eryx/schema

	Runtime schema construction, validation, and parsing.

	This module is the public entrypoint for value schemas. It is designed
	for runtime data boundaries: request bodies, config files, CLI input,
	persisted payloads, plugin data, and any other dynamic values that should
	be validated before your application logic depends on them.

	## Why schemas instead of ad-hoc checks?

	Without schemas, validation logic tends to spread across call sites and
	diverge over time. With schemas, you define the contract once and reuse it:
	- one place for validation rules,
	- one consistent parse/validation behavior,
	- one composable unit for nested and shared types.

	## `parse` vs `validate`

	Every schema provides two runtime entrypoints:
	- `parse(value)` -> `(ok, parsedOrError)`
	- `validate(value)` -> `boolean`

	`validate` is for pass/fail checks.
	`parse` is for pass/fail plus normalized output.

	Use `parse` when:
	- you depend on transformed output (for example string trimming/casing),
	- you want actionable error messages,
	- you are at an external boundary and need diagnostics.

	Use `validate` when:
	- you only need a boolean gate,
	- you do not need transformed output or error details.

	## Quick Start

	```luau
	local schema = require("@eryx/schema")

	local User = schema.table({
		id = schema.number():int():positive(),
		name = schema.string():trimWhitespace():minLen(1),
		email = schema.optional(schema.string()),
	})

	local ok, parsedOrErr = User:parse({
		id = 7,
		name = "  Ada  ",
	})
	-- ok == true
	-- parsedOrErr.name == "Ada"
	```

	## Available Constructors

	### `schema.literal(value)`
	Matches exactly one literal value (string/number/boolean/nil).

	Good for:
	- discriminators (for example `kind = "user"`),
	- protocol constants,
	- strict mode flags.

	```luau
	local Kind = schema.literal("user")
	```

	### `schema.boolean()`
	Validates booleans.

	Good for:
	- feature switches,
	- toggle fields in payloads.

	### `schema.number()`
	Validates numbers and supports chainable numeric constraints.

	Common constraints:
	- range checks: `:gt`, `:gte`, `:lt`, `:lte`
	- sign checks: `:positive`, `:nonnegative`, `:negative`, `:nonpositive`
	- divisibility: `:multipleOf`
	- integer-only: `:int`

	```luau
	local Port = schema.number():int():gte(1):lte(65535)
	```

	### `schema.string()`
	Validates strings and supports both validation and parse-time mutation.

	Common validators:
	- size: `:minLen`, `:maxLen`, `:length`
	- pattern matching: `:match` (Lua patterns), `:regex`
	- containment: `:startsWith`, `:endsWith`, `:includes`
	- casing: `:isUpperCase`, `:isLowerCase`

	Common mutators:
	- `:trimWhitespace()`
	- `:toUpperCase()`
	- `:toLowerCase()`

	Use mutators when you want canonicalized output from `parse`.
	Use validators when you want strict input acceptance criteria.

	### `schema.array(childSchema)`
	Validates list-like tables where each element must satisfy a child schema.

	Common constraints:
	- `:minLen`
	- `:maxLen`
	- `:length`
	- `:nonempty`

	```luau
	local Tags = schema.array(schema.string():trimWhitespace()):nonempty()
	```

	### `schema.optional(childSchema)`
	Wraps a schema so `nil` is accepted.

	You can provide a default at parse time:
	```luau
	local RetryCount = schema.optional(schema.number():int()):default(3)
	```

	### `schema.anyOf(...)`
	Union schema. Parsing succeeds if any branch succeeds.
	Branches can be schemas or raw literals.

	```luau
	local Role = schema.anyOf("admin", "member", "guest")
	```

	### `schema.map(keySchema, valueSchema)`
	Validates key/value tables by validating both keys and values.
	Both key and value schemas can be full schemas or literals.

	Good for:
	- dynamic dictionaries,
	- metadata bags with constrained key/value types.

	## Table Schemas

	`schema.table({...})` creates object-like schemas with named fields.

	Default behavior is strict:
	- unknown keys fail parse,
	- required keys must be present,
	- optional fields are represented with `schema.optional(...)`.

	```luau
	local Config = schema.table({
		host = schema.string(),
		port = schema.number():int(),
		tls = schema.optional(schema.boolean()):default(false),
	})
	```

	## Struct Helpers (`@eryx/schema/struct`)

	Table schemas are created here with `schema.table(...)`.
	Table transformation helpers (strict/strip/passthrough/catchall/extend/etc)
	are provided by `@eryx/schema/struct`.

	```luau
	local Base = schema.table({ a = schema.number() })

	local struct = require("@eryx/schema/struct")
	local Strict = struct.strict(Base)
	local Strip = struct.strip(Base)
	local Pass = struct.passthrough(Base)
	```

	Common helpers from `@eryx/schema/struct`:
	- unknown key policy:
	  - `strict`
	  - `strip`
	  - `passthrough`
	  - `catchall`
	- shape transforms:
	  - `partial`
	  - `pick`
	  - `omit`
	  - `required`
	- composition:
	  - `extend`
	- output immutability:
	  - `readonly`
	  - `freeze`

	When to use these helpers:
	- `strip` at untrusted boundaries when extra keys should be ignored.
	- `passthrough` when preserving unknown extension keys is intentional.
	- `catchall` when extension keys are allowed but must still be typed.
	- `partial` for patch/update payloads.
	- `pick`/`omit` for endpoint-specific projections.
	- `required` when moving from partial input to strict internal shapes.

	## Full Integration Example

	```luau
	local schema = require("@eryx/schema")

	local struct = require("@eryx/schema/struct")
	local Payload = struct.strip(schema.table({
		id = schema.number():int(),
		role = schema.anyOf("admin", "member"),
		tags = schema.optional(schema.array(schema.string())),
	}))

	local ok, result = Payload:parse({
		id = 42,
		role = "admin",
		tags = { "ops" },
		extra = "ignored",
	})
	```

	## Notes and Conventions

	- Schema modifiers are immutable-style: chaining creates new schema objects.
	- Error messages are path-oriented for easier debugging of nested failures.
	- Favor small, reusable schema fragments and compose them.
	- Keep schemas close to your domain modules for discoverability and drift
	  prevention.
]=]
local literal = require("@self/literal")
local number = require("@self/number")
local stringSchema = require("@self/string")
local boolean = require("@self/boolean")
local array = require("@self/array")
local struct = require("@self/struct")
local optional = require("@self/optional")
local anyOf = require("@self/anyOf")
local map = require("@self/map")

local schema = {}

schema.literal = literal.literal
schema.number = number.number
schema.string = stringSchema.string
schema.boolean = boolean.boolean
schema.array = array.array
schema.table = struct.table
schema.optional = optional.optional
schema.anyOf = anyOf.anyOf
schema.map = map.map

return table.freeze(schema)
