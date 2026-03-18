--[=[
	Imperative command-line argument parser.

	Supports positional arguments, flags, options with values, subcommands,
	and merged short flags. A built-in `--help`/`-h` flag is registered by
	default and can be customised or disabled.

	```luau
	local argparse = require("@eryx/argparse2")

	local parser = argparse.Parser.new("mytool", "A handy CLI")
	parser:AddPositional("file", "string", nil, true, "Input file")
	parser:AddFlag("verbose", "v", "Enable verbose output")
	parser:AddOption("port", "p", "number", 8080, nil, "Port to listen on")

	local run = parser:AddSubCommand("run", "Run a script")
	run:AddPositional("script", "string", false, "Script to run")

	local config = parser:Parse()
	```
]=]

local os = require("@eryx/os")
local argparse = {}

local Parser = {}
Parser.__index = Parser

--[=[
	A command-line parser that can be configured with positional arguments,
	boolean flags, key-value options, and subcommands.

	Every new parser comes with a built-in `--help`/`-h` flag. Use
	[[Parser.DisableHelp]] to remove it or [[Parser.SetHelpHandler]] to replace its
	behaviour.
]=]
export type Parser = setmetatable<
	{
		--- The program or subcommand name shown in help text.
		name: string,
		--- One-line summary printed below the usage line.
		description: string?,
		--- Text printed at the very end of help output.
		epilog: string?,
		--- Registered positional arguments, in order.
		positionals: {
			{
				name: string,
				type: "string" | "number",
				description: string?,
				optional: boolean?,
				default: any?,
			}
		},
		--- Registered boolean flags.
		flags: {
			{
				longName: string,
				shortName: string?,
				description: string?,
			}
		},
		--- Registered key-value options.
		options: {
			{
				longName: string,
				shortName: string?,
				type: "string" | "number",
				description: string?,
				optional: boolean,
				default: any?,
			}
		},
		--- Registered subcommands, keyed by name.
		subCommands: { [string]: Parser },
		--- The function invoked when `--help` is parsed.
		_helpHandler: (self: Parser) -> (),
	},
	typeof(Parser)
>

local function defaultHelpHandler(self: Parser)
	print(self:GenerateHelp())
	os.exit(0)
end

--[=[
	Creates a new [[Parser]].

	The parser starts with a built-in `--help`/`-h` flag that prints
	generated help text and exits.

	@param name The program or subcommand name shown in usage text.
	@param description One-line summary printed below the usage line.
	@param epilog Text printed at the very end of help output.
	@return Parser -- A new parser ready to be configured.
]=]
function Parser.new(name: string, description: string?, epilog: string?): Parser
	local self = setmetatable({
		name = name,
		description = description,
		epilog = epilog,
		positionals = {},
		flags = {},
		options = {},
		subCommands = {},
		_helpHandler = defaultHelpHandler,
	}, Parser)
	self:AddFlag("help", "h", "Show help message")
	return self
end

--- Check that a long name doesn't conflict with existing flags or options.
local function checkLongConflict(self: Parser, longName: string)
	for _, flag in self.flags do
		if flag.longName == longName then
			error(`Long name '--{longName}' is already used by a flag`)
		end
	end
	for _, opt in self.options do
		if opt.longName == longName then
			error(`Long name '--{longName}' is already used by an option`)
		end
	end
end

--- Check that a short name doesn't conflict with existing flags or options.
local function checkShortConflict(self: Parser, shortName: string)
	for _, flag in self.flags do
		if flag.shortName == shortName then
			error(`Short name '-{shortName}' is already used by flag '--{flag.longName}'`)
		end
	end
	for _, opt in self.options do
		if opt.shortName == shortName then
			error(`Short name '-{shortName}' is already used by option '--{opt.longName}'`)
		end
	end
end

--[=[
	Registers a subcommand under this parser.

	When the subcommand name is encountered during parsing, all remaining
	arguments are delegated to the subcommand's parser. The subcommand's
	result table is stored under its name in the parent result.

	@param name The subcommand name (must not collide with an existing subcommand).
	@param description One-line summary shown in help text.
	@param epilog Text printed at the end of the subcommand's help.
	@return Parser -- The new subcommand parser, ready to be configured.
	@error Throws if a subcommand with the same name is already registered.
]=]
function Parser.AddSubCommand(self: Parser, name: string, description: string?, epilog: string?): Parser
	if self.subCommands[name] then
		error(`Subcommand '{name}' is already registered`)
	end
	local sub = Parser.new(name, description, epilog)
	self.subCommands[name] = sub
	return sub
end

--[=[
	Removes the built-in `--help`/`-h` flag and sets the help handler to
	a no-op. After calling this, `--help` and `-h` are free to be
	re-registered as custom flags or options.
]=]
function Parser.DisableHelp(self: Parser)
	for i, flag in self.flags do
		if flag.longName == "help" then
			table.remove(self.flags, i)
			break
		end
	end
	self._helpHandler = function() end
end

--[=[
	Replaces the built-in help behaviour with a custom handler.

	The handler receives the parser so it can call [[Parser.GenerateHelp]] or
	inspect registered arguments. The built-in `--help`/`-h` flag remains
	registered; only the action changes.

	```luau
	parser:SetHelpHandler(function(p)
		io.write(p:GenerateHelp())
		os.exit(2)
	end)
	```

	@param handler A function called when `--help` or `-h` is parsed.
]=]
function Parser.SetHelpHandler(self: Parser, handler: (self: Parser) -> ())
	self._helpHandler = handler
end

--[=[
	Registers a positional argument.

	Positional arguments are consumed left-to-right in the order they are
	added. Required positionals must come before any optional ones.

	If a `default` is provided the positional is automatically optional.
	To make a positional optional with no default, pass `nil` for default
	and `false` for required.

	@param name Key used in the result table.
	@param type `"string"` or `"number"` — numeric values are coerced automatically.
	@param default Default value when omitted. Implies optional when non-nil.
	@param required Whether the argument must be provided. Defaults to `true` unless a default is given.
	@param description Human-readable text shown in help output.
	@error Throws if a positional with the same name already exists.
	@error Throws if a required positional is added after an optional one.
	@error Throws if a default is provided for a required positional.
]=]
function Parser.AddPositional(
	self: Parser,
	name: string,
	type: "string" | "number",
	default: any?,
	required: boolean?,
	description: string?
)
	for _, pos in self.positionals do
		if pos.name == name then
			error(`Positional '{name}' is already registered`)
		end
	end

	-- Infer: non-nil default -> optional, otherwise required unless explicitly overridden
	local isRequired = if required ~= nil then required else default == nil

	if isRequired and default ~= nil then
		error("A default argument cannot be provided for a required positional")
	end

	if isRequired then
		for _, i in self.positionals do
			if i.optional then
				error("Cannot have required positional argument after an optional positional argument")
			end
		end
	end
	table.insert(self.positionals, {
		name = name,
		type = type,
		description = description,
		optional = not isRequired,
		default = default,
	})
end

--[=[
	Registers a boolean flag (`true` when present, `false` when absent).

	Flags can be combined in short form: `-vh` sets both `-v` and `-h`.

	@param longName The `--long` name (without dashes).
	@param shortName Optional single-character `-s` alias.
	@param description Human-readable text shown in help output.
	@error Throws if the long or short name conflicts with an existing flag or option.
]=]
function Parser.AddFlag(self: Parser, longName: string, shortName: string?, description: string?)
	checkLongConflict(self, longName)
	if shortName then
		checkShortConflict(self, shortName)
	end
	table.insert(self.flags, {
		longName = longName,
		shortName = shortName,
		description = description,
	})
end

--[=[
	Registers a key-value option.

	Options consume the next argument (or the `=`-separated value) as their
	value. In merged short form the last character is treated as the option
	and everything after it (or the next argument) is the value:
	`-vp 8080` sets `-v` (flag) and `-p 8080` (option).

	If a `default` is provided the option is automatically optional.
	To make an option optional with no default, pass `nil` for default
	and `false` for required.

	@param longName The `--long` name (without dashes).
	@param shortName Optional single-character `-s` alias.
	@param type `"string"` or `"number"` — numeric values are coerced automatically.
	@param default Default value when omitted. Implies optional when non-nil.
	@param required Whether the option must be provided. Defaults to `true` unless a default is given.
	@param description Human-readable text shown in help output.
	@error Throws if the long or short name conflicts with an existing flag or option.
	@error Throws if a default is provided for a required option.
]=]
function Parser.AddOption(
	self: Parser,
	longName: string,
	shortName: string?,
	type: "string" | "number",
	default: any?,
	required: boolean?,
	description: string?
)
	checkLongConflict(self, longName)
	if shortName then
		checkShortConflict(self, shortName)
	end

	-- Infer: non-nil default -> optional, otherwise required unless explicitly overridden
	local isRequired = if required ~= nil then required else default == nil

	if isRequired and default ~= nil then
		error("A default argument cannot be provided for a required option")
	end

	table.insert(self.options, {
		longName = longName,
		shortName = shortName,
		type = type,
		description = description,
		optional = not isRequired,
		default = default,
	})
end

--[=[
	Builds a human-readable help string from the parser's current
	configuration, including usage line, description, arguments,
	subcommands, flags, options, and epilog.

	@return string -- The formatted help text.
]=]
function Parser.GenerateHelp(self: Parser): string
	local lines = {}

	-- Usage line
	local usage = `Usage: {self.name}`
	for _, pos in self.positionals do
		if pos.optional then
			usage ..= ` [{pos.name}]`
		else
			usage ..= ` <{pos.name}>`
		end
	end
	if next(self.subCommands) then
		usage ..= " [command]"
	end
	usage ..= " [options]"
	table.insert(lines, usage)

	if self.description then
		table.insert(lines, "")
		table.insert(lines, self.description)
	end

	-- Positional arguments
	if #self.positionals > 0 then
		table.insert(lines, "")
		table.insert(lines, "Arguments:")
		for _, pos in self.positionals do
			local label = if pos.optional then `  [{pos.name}]` else `  <{pos.name}>`
			local desc = pos.description or ""
			local typeHint = `({pos.type})`
			table.insert(lines, `{label}  {typeHint}  {desc}`)
		end
	end

	-- Subcommands
	if next(self.subCommands) then
		table.insert(lines, "")
		table.insert(lines, "Commands:")
		for name, sub in self.subCommands do
			local desc = sub.description or ""
			table.insert(lines, `  {name}  {desc}`)
		end
	end

	-- Flags
	if #self.flags > 0 then
		table.insert(lines, "")
		table.insert(lines, "Flags:")
		for _, flag in self.flags do
			local short = if flag.shortName then `-{flag.shortName}, ` else "    "
			local desc = flag.description or ""
			table.insert(lines, `  {short}--{flag.longName}  {desc}`)
		end
	end

	-- Options
	if #self.options > 0 then
		table.insert(lines, "")
		table.insert(lines, "Options:")
		for _, opt in self.options do
			local short = if opt.shortName then `-{opt.shortName}, ` else "    "
			local req = if opt.optional then "(optional)" else "(required)"
			local def = if opt.default ~= nil then ` [default: {opt.default}]` else ""
			local desc = opt.description or ""
			table.insert(lines, `  {short}--{opt.longName} <{opt.type}>  {req}{def}  {desc}`)
		end
	end

	if self.epilog then
		table.insert(lines, "")
		table.insert(lines, self.epilog)
	end

	return table.concat(lines, "\n")
end

--[=[
	Parses command-line arguments against this parser's configuration.

	Parsing supports:
	- **Positional arguments** — consumed left-to-right.
	- **Long flags / options** — `--verbose`, `--port 8080`, `--port=8080`.
	- **Short flags / options** — `-v`, `-p 8080`.
	- **Merged short flags** — `-vh` expands to `-v -h`.
	  The last character may be an option: `-vp 8080` -> `-v` flag + `-p 8080` option.
	- **Subcommands** — remaining arguments are delegated to the
	  subcommand's parser and its result is stored under the subcommand name.

	If the built-in `--help` flag is set, the help handler is invoked
	**before** required-argument validation, so `mytool --help` always works.

	@param arguments Argument list to parse. Defaults to `os.cliargs()`.
	@return { [string]: any } -- A table mapping argument names to their parsed values.
	@error Throws on unknown flags/options, missing required arguments, or type coercion failures.
]=]
function Parser.Parse(self: Parser, arguments: { string }?): { [string]: any }
	local args: { string } = arguments or os.cliargs()

	local result: { [string]: any } = {}
	local positionalIndex = 1
	local i = 1

	-- Initialize flag defaults to false
	for _, flag in self.flags do
		result[flag.longName] = false
	end

	-- Initialize positional defaults
	for _, pos in self.positionals do
		if pos.default ~= nil then
			result[pos.name] = pos.default
		end
	end

	-- Initialize option defaults
	for _, opt in self.options do
		if opt.default ~= nil then
			result[opt.longName] = opt.default
		end
	end

	-- Helper: find a flag by short name
	local function findFlagByShort(short: string): typeof(self.flags[1])?
		for _, flag in self.flags do
			if flag.shortName == short then
				return flag
			end
		end
		return nil
	end

	-- Helper: find an option by short name
	local function findOptionByShort(short: string): typeof(self.options[1])?
		for _, opt in self.options do
			if opt.shortName == short then
				return opt
			end
		end
		return nil
	end

	-- Helper: find a flag by long name
	local function findFlagByLong(long: string): typeof(self.flags[1])?
		for _, flag in self.flags do
			if flag.longName == long then
				return flag
			end
		end
		return nil
	end

	-- Helper: find an option by long name
	local function findOptionByLong(long: string): typeof(self.options[1])?
		for _, opt in self.options do
			if opt.longName == long then
				return opt
			end
		end
		return nil
	end

	-- Helper: coerce a value to the expected type
	local function coerce(value: string, expectedType: "string" | "number"): string | number
		if expectedType == "number" then
			local n = tonumber(value)
			if n == nil then
				error(`Expected a number, got '{value}'`)
			end
			return n
		end
		return value
	end

	while i <= #args do
		local arg = args[i]

		-- Long option/flag: --name or --name=value
		if string.sub(arg, 1, 2) == "--" then
			local body = string.sub(arg, 3)
			local eqPos = string.find(body, "=")

			if eqPos then
				-- --key=value form
				local key = string.sub(body, 1, eqPos - 1)
				local value = string.sub(body, eqPos + 1)
				local opt = findOptionByLong(key)
				if not opt then
					error(`Unknown option '--{key}'`)
				end
				result[opt.longName] = coerce(value, opt.type)
			else
				-- Could be a flag or an option expecting next arg
				local flag = findFlagByLong(body)
				if flag then
					result[flag.longName] = true
				else
					local opt = findOptionByLong(body)
					if not opt then
						error(`Unknown flag or option '--{body}'`)
					end
					i += 1
					if i > #args then
						error(`Option '--{body}' expects a value`)
					end
					result[opt.longName] = coerce(args[i], opt.type)
				end
			end

		-- Short option/flag(s): -h, -ho, -ho 5
		elseif string.sub(arg, 1, 1) == "-" and #arg > 1 then
			local chars = string.sub(arg, 2)
			local j = 1
			while j <= #chars do
				local ch = string.sub(chars, j, j)
				local flag = findFlagByShort(ch)
				local opt = findOptionByShort(ch)

				if flag and not opt then
					result[flag.longName] = true
				elseif opt then
					-- Option consumes the rest of the merged chars or next argument
					local rest = string.sub(chars, j + 1)
					if #rest > 0 then
						result[opt.longName] = coerce(rest, opt.type)
					else
						i += 1
						if i > #args then
							error(`Option '-{ch}' expects a value`)
						end
						result[opt.longName] = coerce(args[i], opt.type)
					end
					break -- rest was consumed
				else
					error(`Unknown flag or option '-{ch}'`)
				end
				j += 1
			end

		-- Check for subcommand
		elseif self.subCommands[arg] then
			-- Validate that all required positionals before this subcommand were provided
			for idx = 1, positionalIndex - 1 do
				-- already consumed, skip
			end
			for idx = positionalIndex, #self.positionals do
				local pos = self.positionals[idx]
				if not pos.optional then
					error(`Missing required positional argument '{pos.name}' (before subcommand '{arg}')`)
				end
			end

			local sub = self.subCommands[arg]
			local remaining = {}
			for k = i + 1, #args do
				table.insert(remaining, args[k])
			end
			local subResult = sub:Parse(remaining)
			result[arg] = subResult
			return result

		-- Positional argument
		else
			if positionalIndex > #self.positionals then
				error(`Unexpected argument '{arg}'`)
			end
			local pos = self.positionals[positionalIndex]
			result[pos.name] = coerce(arg, pos.type)
			positionalIndex += 1
		end

		i += 1
	end

	-- Help: invoke handler before validation
	if result.help == true then
		self._helpHandler(self)
	end
	result.help = nil

	-- Validate required positionals were provided
	for idx, pos in self.positionals do
		if not pos.optional and result[pos.name] == nil then
			error(`Missing required positional argument '{pos.name}'`)
		end
	end

	-- Validate required options were provided
	for _, opt in self.options do
		if not opt.optional and result[opt.longName] == nil then
			error(`Missing required option '--{opt.longName}'`)
		end
	end

	return result
end

argparse.Parser = Parser

return argparse
