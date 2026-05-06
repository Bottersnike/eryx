--[=[
	Imperative command-line argument parser.

	Supports positional arguments, flags, options with values, subcommands,
	and merged short flags. A built-in `--help`/`-h` flag is registered by
	default and can be customised or disabled.

	```luau
	local argparse = require("@eryx/argparse")

	local parser = argparse.Parser.new("mytool", "A handy CLI")
	parser:addPositional("file", "string", nil, true, "Input file")
	parser:addFlag("verbose", "v", "Enable verbose output")
	parser:addOption("port", "p", "number", 8080, nil, "Port to listen on")

	local run = parser:addSubCommand("run", "Run a script")
	run:addPositional("script", "string", nil, true, "Script to run")

	local config = parser:parse()
	```
]=]

local os = require("@eryx/os")
local fs = require("@eryx/fs")
local stdio = require("@eryx/stdio")
local argparse = {}

local Parser = {}
Parser.__index = Parser

type PositionalSpec = {
	name: string,
	type: "string" | "number",
	description: string?,
	optional: boolean?,
	default: any?,
	variadic: boolean?,
}

type OptionSpec = {
	longName: string,
	shortName: string?,
	type: "string" | "number",
	description: string?,
	optional: boolean,
	default: any?,
	multiple: boolean?,
	arity: number?,
}

type MutuallyExclusiveGroup = {
	names: { string },
	required: boolean,
}

type TFlag = {
	longName: string,
	shortName: string?,
	description: string?,
}

--[=[
	A command-line parser that can be configured with positional arguments,
	boolean flags, key-value options, and subcommands.

	Every new parser comes with a built-in `--help`/`-h` flag. Use
	[[Parser.disableHelp]] to remove it or [[Parser.setHelpHandler]] to replace its
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
		positionals: { PositionalSpec },
		--- Registered boolean flags.
		flags: { TFlag },
		--- Registered key-value options.
		options: { OptionSpec },
		--- Registered subcommands, keyed by name.
		subCommands: { [string]: Parser },
		--- Mutually exclusive groups of flag/option names.
		mutexGroups: { MutuallyExclusiveGroup },
		--- The function invoked when `--help` is parsed.
		_helpHandler: (self: Parser) -> (),
		--- Whether the built-in `--help` / `-h` behavior is active.
		_helpEnabled: boolean,
	},
	typeof(Parser)
>

local function defaultHelpHandler(self: Parser)
	print(self:generateHelp())
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
		mutexGroups = {},
		_helpHandler = defaultHelpHandler,
		_helpEnabled = true,
	}, Parser)
	self:addFlag("help", "h", "Show help message")
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
function Parser.addSubCommand(self: Parser, name: string, description: string?, epilog: string?): Parser
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
function Parser.disableHelp(self: Parser)
	for i, flag in self.flags do
		if flag.longName == "help" then
			table.remove(self.flags, i)
			break
		end
	end
	self._helpEnabled = false
	self._helpHandler = function() end
end

--[=[
	Replaces the built-in help behaviour with a custom handler.

	The handler receives the parser so it can call [[Parser.generateHelp]] or
	inspect registered arguments. The built-in `--help`/`-h` flag remains
	registered; only the action changes.

	```luau
	parser:setHelpHandler(function(p)
		io.write(p:generateHelp())
		os.exit(2)
	end)
	```

	@param handler A function called when `--help` or `-h` is parsed.
]=]
function Parser.setHelpHandler(self: Parser, handler: (self: Parser) -> ())
	self._helpHandler = handler
end

--[=[
	Registers a positional argument.

	Positional arguments are consumed left-to-right in the order they are
	added. Required positionals must come before any optional ones.

	If a `default` is provided the positional is automatically optional.
	To make a positional optional with no default, pass `nil` for default
	and `false` for required.

	Set `variadic` to `true` to let the positional consume all remaining
	arguments. Variadic positionals must be the final positional.

	@param name Key used in the result table.
	@param type `"string"` or `"number"` - numeric values are coerced automatically.
	@param default Default value when omitted. Implies optional when non-nil.
	@param required Whether the argument must be provided. Defaults to `true` unless a default is given.
	@param description Human-readable text shown in help output.
	@param variadic Whether this positional should consume all remaining values.
	@error Throws if a positional with the same name already exists.
	@error Throws if a required positional is added after an optional one.
	@error Throws if a default is provided for a required positional.
]=]
function Parser.addPositional(
	self: Parser,
	name: string,
	type: "string" | "number",
	default: any?,
	required: boolean?,
	description: string?,
	variadic: boolean?
)
	for _, pos in self.positionals do
		if pos.name == name then
			error(`Positional '{name}' is already registered`)
		end
	end

	if #self.positionals > 0 and self.positionals[#self.positionals].variadic then
		error("Cannot add another positional argument after a variadic positional argument")
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
		variadic = variadic == true,
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
function Parser.addFlag(self: Parser, longName: string, shortName: string?, description: string?)
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

	`settings.multiple = true` allows an option to be repeated and collects
	its values into an array. `settings.arity` controls how many values each
	occurrence consumes.

	@param longName The `--long` name (without dashes).
	@param shortName Optional single-character `-s` alias.
	@param type `"string"` or `"number"` - numeric values are coerced automatically.
	@param default Default value when omitted. Implies optional when non-nil.
	@param required Whether the option must be provided. Defaults to `true` unless a default is given.
	@param description Human-readable text shown in help output.
	@param settings Optional parser settings such as `multiple` and `arity`.
	@error Throws if the long or short name conflicts with an existing flag or option.
	@error Throws if a default is provided for a required option.
]=]
function Parser.addOption(
	self: Parser,
	longName: string,
	shortName: string?,
	type: "string" | "number",
	default: any?,
	required: boolean?,
	description: string?,
	settings: { multiple: boolean?, arity: number? }?
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

	local arity = if settings and settings.arity ~= nil then settings.arity else 1
	local multiple = if settings then settings.multiple == true else false

	if arity < 1 then
		error("Option arity must be at least 1")
	end

	table.insert(self.options, {
		longName = longName,
		shortName = shortName,
		type = type,
		description = description,
		optional = not isRequired,
		default = default,
		multiple = multiple,
		arity = arity,
	})
end

--[=[
	Registers a mutually exclusive group of flags/options by long name.

	At most one name in the group may be present during parsing. If `required`
	is `true`, exactly one member must be present.
]=]
function Parser.addMutuallyExclusive(self: Parser, names: { string }, required: boolean?)
	if #names < 2 then
		error("A mutually exclusive group requires at least two names")
	end

	table.insert(self.mutexGroups, {
		names = names,
		required = required == true,
	})
end

type CompletionSpec = {
	path: string,
	commands: { string },
	options: { string },
}

local function completionIdent(programName: string): string
	return (programName:gsub("[^%w_]", "_"))
end

local function escapeSingleQuotedShell(s: string): string
	return (s:gsub("'", [['"'"']]))
end

local function escapePowerShellSingleQuoted(s: string): string
	return (s:gsub("'", "''"))
end

local function completionDebugPath(): string?
	local value = os.getenv("ERYX_COMPLETION_DEBUG")
	if value == nil or value == "" then
		return nil
	end

	if value == "1" then
		local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
		return fs.path.join(tmp, "eryx-completion.log")
	end

	return value
end

local function completionDebugLog(message: string)
	local path = completionDebugPath()
	-- print(path, message)
	if path == nil then
		return
	end

	local handle = fs.openSync(path, "a")
	handle:writeSync(message .. "\n")
	handle:closeSync()
end

local function buildCompletionSpecs(self: Parser, path: string, specs: { CompletionSpec })
	local commands = {}
	local options = {}

	for name in self.subCommands do
		table.insert(commands, name)
	end

	for _, flag in self.flags do
		table.insert(options, `--{flag.longName}`)
		if flag.shortName then
			table.insert(options, `-{flag.shortName}`)
		end
	end

	for _, opt in self.options do
		table.insert(options, `--{opt.longName}`)
		if opt.shortName then
			table.insert(options, `-{opt.shortName}`)
		end
	end

	table.sort(commands)
	table.sort(options)
	table.insert(specs, {
		path = path,
		commands = commands,
		options = options,
	})

	local subcommandNames = {}
	for name in self.subCommands do
		table.insert(subcommandNames, name)
	end
	table.sort(subcommandNames)

	for _, name in subcommandNames do
		local nextPath = if path == "" then name else `{path} {name}`
		buildCompletionSpecs(self.subCommands[name], nextPath, specs)
	end
end

local function findFlagByShort(self: Parser, short: string): TFlag?
	for _, flag in self.flags do
		if flag.shortName == short then
			return flag
		end
	end
	return nil
end

local function findOptionByShort(self: Parser, short: string): OptionSpec?
	for _, opt in self.options do
		if opt.shortName == short then
			return opt
		end
	end
	return nil
end

local function findFlagByLong(self: Parser, long: string): TFlag?
	for _, flag in self.flags do
		if flag.longName == long then
			return flag
		end
	end
	return nil
end

local function findOptionByLong(self: Parser, long: string): OptionSpec?
	for _, opt in self.options do
		if opt.longName == long then
			return opt
		end
	end
	return nil
end

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

--[=[
	Returns shell completion candidates for the parser after consuming the
	provided fully-typed arguments.

	This is intentionally conservative: if the parser is currently waiting
	for an option value it returns no candidates so the shell can fall back
	to filename or custom value completion.
]=]
function Parser.getCompletionCandidates(self: Parser, arguments: { string }?): { string }
	local args: { string } = arguments or os.cliargs()
	completionDebugLog(`argparse.getCompletionCandidates: parser={self.name} args={table.concat(args, " ")}`)
	local provided: { [string]: boolean } = {}
	local positionalIndex = 1
	local i = 1

	while i <= #args do
		local arg = args[i]

		if arg == "--" then
			completionDebugLog(`argparse.getCompletionCandidates: end-of-options marker encountered`)
			return {}
		elseif string.sub(arg, 1, 2) == "--" then
			local body = string.sub(arg, 3)
			local eqPos = string.find(body, "=")

			if eqPos then
				local key = string.sub(body, 1, eqPos - 1)
				local opt = findOptionByLong(self, key)
				if not opt then
					completionDebugLog(`argparse.getCompletionCandidates: unknown long option --{key}`)
					return {}
				end
				provided[opt.longName] = true
			else
				local flag = findFlagByLong(self, body)
				if flag then
					provided[flag.longName] = true
				else
					local opt = findOptionByLong(self, body)
					if not opt then
						completionDebugLog(`argparse.getCompletionCandidates: unknown long token --{body}`)
						return {}
					end
					local arity = opt.arity or 1
					if (#args - i) < arity then
						completionDebugLog(`argparse.getCompletionCandidates: waiting for value of --{opt.longName}`)
						return {}
					end
					provided[opt.longName] = true
					i += arity
				end
			end
		elseif string.sub(arg, 1, 1) == "-" and #arg > 1 then
			local chars = string.sub(arg, 2)
			local j = 1
			while j <= #chars do
				local ch = string.sub(chars, j, j)
				local flag = findFlagByShort(self, ch)
				local opt = findOptionByShort(self, ch)

				if flag and not opt then
					provided[flag.longName] = true
				elseif opt then
					provided[opt.longName] = true
					local rest = string.sub(chars, j + 1)
					if #rest == 0 then
						local arity = opt.arity or 1
						if (#args - i) < arity then
							completionDebugLog(`argparse.getCompletionCandidates: waiting for value of -{ch}`)
							return {}
						end
						i += arity
					elseif (opt.arity or 1) ~= 1 then
						completionDebugLog(
							`argparse.getCompletionCandidates: inline short option value rejected for -{ch}`
						)
						return {}
					end
					break
				else
					completionDebugLog(`argparse.getCompletionCandidates: unknown short token -{ch}`)
					return {}
				end
				j += 1
			end
		elseif self.subCommands[arg] then
			local sub = self.subCommands[arg]
			local remaining = {}
			for k = i + 1, #args do
				table.insert(remaining, args[k])
			end
			completionDebugLog(`argparse.getCompletionCandidates: descending into subcommand {arg}`)
			return sub:getCompletionCandidates(remaining)
		else
			if positionalIndex > #self.positionals then
				completionDebugLog(`argparse.getCompletionCandidates: unexpected positional token {arg}`)
				return {}
			end

			local pos = self.positionals[positionalIndex]
			if not pos.variadic then
				positionalIndex += 1
			end
		end

		i += 1
	end

	local candidates = {}
	local seen = {}

	local function addCandidate(value: string)
		if not seen[value] then
			seen[value] = true
			table.insert(candidates, value)
		end
	end

	local commandNames = {}
	for name in self.subCommands do
		table.insert(commandNames, name)
	end
	table.sort(commandNames)
	for _, name in commandNames do
		addCandidate(name)
	end

	for _, flag in self.flags do
		if not provided[flag.longName] then
			addCandidate(`--{flag.longName}`)
			if flag.shortName then
				addCandidate(`-{flag.shortName}`)
			end
		end
	end

	for _, opt in self.options do
		if opt.multiple or not provided[opt.longName] then
			addCandidate(`--{opt.longName}`)
			if opt.shortName then
				addCandidate(`-{opt.shortName}`)
			end
		end
	end

	table.sort(candidates)
	completionDebugLog(
		`argparse.getCompletionCandidates: parser={self.name} candidates={table.concat(candidates, ",")}`
	)
	return candidates
end

local function maybeEmitCompletionCandidates(self: Parser, args: { string }): boolean
	if os.getenv("ERYX_ARGPARSE_COMPLETE") ~= "1" then
		return false
	end

	completionDebugLog(
		`argparse.maybeEmitCompletionCandidates: parser={self.name} shell={os.getenv("ERYX_ARGPARSE_COMPLETE_SHELL") or ""}`
	)
	for _, candidate in self:getCompletionCandidates(args) do
		print(candidate)
	end
	completionDebugLog(`argparse.maybeEmitCompletionCandidates: emitted completion candidates`)
	os.exit(0)
	return true
end

local function renderBashCompletion(programName: string, ident: string, specs: { CompletionSpec }): string
	local nextCases = {}
	local candidateCases = {}

	for _, spec in specs do
		for _, cmd in spec.commands do
			local key = `{spec.path}|{cmd}`
			local nextPath = if spec.path == "" then cmd else `{spec.path} {cmd}`
			table.insert(
				nextCases,
				`        '{escapeSingleQuotedShell(key)}') printf '%s\n' '{escapeSingleQuotedShell(nextPath)}' ;;`
			)
		end

		local values = {}
		for _, cmd in spec.commands do
			table.insert(values, `'` .. escapeSingleQuotedShell(cmd) .. `'`)
		end
		for _, opt in spec.options do
			table.insert(values, `'` .. escapeSingleQuotedShell(opt) .. `'`)
		end
		local candidateBlock = if #values > 0 then "printf '%s\\n' " .. table.concat(values, " ") else ":"
		table.insert(candidateCases, `        '{escapeSingleQuotedShell(spec.path)}') {candidateBlock} ;;`)
	end

	return table.concat({
		`__{ident}_next_path() \{`,
		'    local path="$1"',
		'    local word="$2"',
		'    case "$path|$word" in',
		#nextCases > 0 and table.concat(nextCases, "\n") or "        *) : ;;",
		"        *) printf '%s\\n' \"$path\" ;;",
		"    esac",
		"}",
		"",
		`__{ident}_candidates() \{`,
		'    local path="$1"',
		'    case "$path" in',
		table.concat(candidateCases, "\n"),
		"        *) : ;;",
		"    esac",
		"}",
		"",
		`_{ident}_completions() \{`,
		"    local cur path word i",
		'    cur="${COMP_WORDS[COMP_CWORD]}"',
		'    path=""',
		"    for (( i = 1; i < COMP_CWORD; i++ )); do",
		'        word="${COMP_WORDS[i]}"',
		'        if [[ "$word" == -* ]]; then',
		"            continue",
		"        fi",
		`        path=\"$(__{ident}_next_path \"$path\" \"$word\")\"`,
		"    done",
		`    COMPREPLY=( $(compgen -W \"$(__{ident}_candidates \"$path\" | tr '\\n' ' ')\" -- \"$cur\") )`,
		"    return 0",
		"}",
		`complete -F _{ident}_completions {programName}`,
	}, "\n")
end

local function renderZshCompletion(programName: string, ident: string, specs: { CompletionSpec }): string
	local nextCases = {}
	local candidateCases = {}

	for _, spec in specs do
		for _, cmd in spec.commands do
			local key = `{spec.path}|{cmd}`
			local nextPath = if spec.path == "" then cmd else `{spec.path} {cmd}`
			table.insert(
				nextCases,
				`        '{escapeSingleQuotedShell(key)}') print -r -- '{escapeSingleQuotedShell(nextPath)}' ;;`
			)
		end

		local values = {}
		for _, cmd in spec.commands do
			table.insert(values, `'` .. escapeSingleQuotedShell(cmd) .. `'`)
		end
		for _, opt in spec.options do
			table.insert(values, `'` .. escapeSingleQuotedShell(opt) .. `'`)
		end
		local candidateBlock = if #values > 0 then "print -l -- " .. table.concat(values, " ") else ":"
		table.insert(candidateCases, `        '{escapeSingleQuotedShell(spec.path)}') {candidateBlock} ;;`)
	end

	return table.concat({
		`#compdef {programName}`,
		`__{ident}_next_path() \{`,
		'    local path="$1"',
		'    local word="$2"',
		'    case "$path|$word" in',
		#nextCases > 0 and table.concat(nextCases, "\n") or "        *) : ;;",
		'        *) print -r -- "$path" ;;',
		"    esac",
		"}",
		"",
		`__{ident}_candidates() \{`,
		'    local path="$1"',
		'    case "$path" in',
		table.concat(candidateCases, "\n"),
		"        *) : ;;",
		"    esac",
		"}",
		"",
		`_{ident}_completions() \{`,
		"    local path word i",
		"    local -a candidates",
		"    path=''",
		"    for (( i = 2; i < CURRENT; ++i )); do",
		'        word="${words[i]}"',
		'        if [[ "$word" == -* ]]; then',
		"            continue",
		"        fi",
		`        path=\"$(__{ident}_next_path \"$path\" \"$word\")\"`,
		"    done",
		`    candidates=(\"$\{(@f)$(__{ident}_candidates \"$path\")}\")`,
		"    compadd -- $candidates",
		"}",
		`_{ident}_completions "$@"`,
	}, "\n")
end

local function renderFishCompletion(programName: string, ident: string, specs: { CompletionSpec }): string
	local nextCases: { string } = {}
	local candidateCases: { string } = {}

	for _, spec in specs do
		for _, cmd in spec.commands do
			local key = `{spec.path}|{cmd}`
			local nextPath = if spec.path == "" then cmd else `{spec.path} {cmd}`
			table.insert(nextCases, `        case '{escapeSingleQuotedShell(key)}'`)
			table.insert(nextCases, `            echo '{escapeSingleQuotedShell(nextPath)}'`)
			table.insert(nextCases, "            return")
		end

		local values: { string } = {}
		for _, cmd in spec.commands do
			table.insert(values, `'` .. escapeSingleQuotedShell(cmd) .. `'`)
		end
		for _, opt in spec.options do
			table.insert(values, `'` .. escapeSingleQuotedShell(opt) .. `'`)
		end
		table.insert(candidateCases, `        case '{escapeSingleQuotedShell(spec.path)}'`)
		if #values > 0 then
			table.insert(candidateCases, "            printf '%s\\n' " .. table.concat(values, " "))
		else
			table.insert(candidateCases, "            return")
		end
	end

	return table.concat({
		`function __{ident}_next_path`,
		"    set -l path $argv[1]",
		"    set -l word $argv[2]",
		'    switch "$path|$word"',
		#nextCases > 0 and table.concat(nextCases, "\n") or "        case '*'",
		"        case '*'",
		"            echo $path",
		"    end",
		"end",
		"",
		`function __{ident}_path`,
		"    set -l tokens (commandline -opc)",
		"    set -l path ''",
		"    for word in $tokens[2..-1]",
		"        if string match -rq '^-' -- $word",
		"            continue",
		"        end",
		`        set path (__{ident}_next_path $path $word)`,
		"    end",
		"    echo $path",
		"end",
		"",
		`function __{ident}_candidates`,
		"    set -l path $argv[1]",
		"    switch $path",
		table.concat(candidateCases, "\n"),
		"        case '*'",
		"            return",
		"    end",
		"end",
		"",
		`complete -c {programName} -f -a '(__{ident}_candidates (__{ident}_path))'`,
	}, "\n")
end

local function renderPowerShellCompletion(programName: string, ident: string, specs: { CompletionSpec }): string
	local nextCases = {}
	local candidateCases = {}

	for _, spec in specs do
		for _, cmd in spec.commands do
			local key = `{spec.path}|{cmd}`
			local nextPath = if spec.path == "" then cmd else `{spec.path} {cmd}`
			table.insert(
				nextCases,
				`            '{escapePowerShellSingleQuoted(key)}' \{ return '{escapePowerShellSingleQuoted(nextPath)}' \}`
			)
		end

		local values = {}
		for _, cmd in spec.commands do
			table.insert(values, "'" .. escapePowerShellSingleQuoted(cmd) .. "'")
		end
		for _, opt in spec.options do
			table.insert(values, "'" .. escapePowerShellSingleQuoted(opt) .. "'")
		end
		local candidateBlock = if #values > 0 then "@(" .. table.concat(values, ", ") .. ")" else "@()"
		table.insert(
			candidateCases,
			`            '{escapePowerShellSingleQuoted(spec.path)}' \{ return {candidateBlock} \}`
		)
	end

	return table.concat({
		`Register-ArgumentCompleter -Native -CommandName '{escapePowerShellSingleQuoted(programName)}' -ScriptBlock \{`,
		"    param($wordToComplete, $commandAst, $cursorPosition)",
		"",
		`    function __{ident}_NextPath([string]$path, [string]$word) \{`,
		'        switch ("$path|$word") {',
		#nextCases > 0 and table.concat(nextCases, "\n") or "            default { return $path }",
		"            default { return $path }",
		"        }",
		"    }",
		"",
		`    function __{ident}_Candidates([string]$path) \{`,
		"        switch ($path) {",
		table.concat(candidateCases, "\n"),
		"            default { return @() }",
		"        }",
		"    }",
		"",
		"    $tokens = @()",
		"    foreach ($element in $commandAst.CommandElements) {",
		"        $tokens += $element.Extent.Text",
		"    }",
		"",
		"    $path = ''",
		"    for ($i = 1; $i -lt $tokens.Count; $i++) {",
		"        $word = $tokens[$i]",
		"        if ($word -like '-*') {",
		"            continue",
		"        }",
		`        $path = __{ident}_NextPath $path $word`,
		"    }",
		"",
		`    foreach ($candidate in (__{ident}_Candidates $path)) \{`,
		'        if ($candidate -like "$wordToComplete*") {',
		"            [System.Management.Automation.CompletionResult]::new($candidate, $candidate, 'ParameterValue', $candidate)",
		"        }",
		"    }",
		"}",
	}, "\n")
end

--[=[
	Generates a shell completion script for this parser.

	Supports `"bash"`, `"zsh"`, `"fish"`, and `"powershell"`, and generates
	subcommand-aware completions for commands and flags/options.
]=]
function Parser.generateCompletion(
	self: Parser,
	shell: "bash" | "zsh" | "fish" | "powershell",
	programName: string?
): string
	local prog = programName or self.name
	local ident = completionIdent(prog)
	local specs = {}
	buildCompletionSpecs(self, "", specs)

	if shell == "bash" then
		return renderBashCompletion(prog, ident, specs)
	elseif shell == "zsh" then
		return renderZshCompletion(prog, ident, specs)
	elseif shell == "fish" then
		return renderFishCompletion(prog, ident, specs)
	elseif shell == "powershell" then
		return renderPowerShellCompletion(prog, ident, specs)
	end

	error(`Unsupported shell '{shell}'`)
end

--[=[
	Builds a human-readable help string from the parser's current
	configuration, including usage line, description, arguments,
	subcommands, flags, options, and epilog.

	@return string -- The formatted help text.
]=]
function Parser.generateHelp(self: Parser): string
	local lines = {}

	-- Usage line
	local usage = `Usage: {self.name}`
	for _, pos in self.positionals do
		local name = if pos.variadic then `{pos.name}...` else pos.name
		if pos.optional then
			usage ..= ` [{name}]`
		else
			usage ..= ` <{name}>`
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
			local name = if pos.variadic then `{pos.name}...` else pos.name
			local label = if pos.optional then `  [{name}]` else `  <{name}>`
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
			local arity = opt.arity or 1
			local valueLabel = if arity == 1 then `<{opt.type}>` else `<{opt.type} x{arity}>`
			local multiple = if opt.multiple then " (repeatable)" else ""
			local desc = opt.description or ""
			table.insert(lines, `  {short}--{opt.longName} {valueLabel}  {req}{multiple}{def}  {desc}`)
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
	- **Positional arguments** - consumed left-to-right.
	- **Long flags / options** - `--verbose`, `--port 8080`, `--port=8080`.
	- **Short flags / options** - `-v`, `-p 8080`.
	- **Merged short flags** - `-vh` expands to `-v -h`.
	  The last character may be an option: `-vp 8080` -> `-v` flag + `-p 8080` option.
	- **Subcommands** - remaining arguments are delegated to the
	  subcommand's parser and its result is stored under the subcommand name.

	If the built-in `--help` flag is set, the help handler is invoked
	**before** required-argument validation, so `mytool --help` always works.

	@param arguments Argument list to parse. Defaults to `os.cliargs()`.
	@return { [string]: any } -- A table mapping argument names to their parsed values.
	@error Throws on unknown flags/options, missing required arguments, or type coercion failures.
]=]
function Parser.parse(self: Parser, arguments: { string }?, exitOnError: boolean?): { [string]: any }
	local args: { string } = arguments or os.cliargs()
	local shouldExitOnError = if exitOnError ~= nil then exitOnError else arguments == nil
	if maybeEmitCompletionCandidates(self, args) then
		return {}
	end

	local function fail(message: any)
		local text = tostring(message)
		if shouldExitOnError then
			stdio.writeerr(`{self.name}: {text}\n\n{self:generateHelp()}\n`)
			os.exit(2)
		end
		error(text)
	end

	local function coerceOrFail(value: string, expectedType: "string" | "number"): string | number
		local ok, coerced = pcall(coerce, value, expectedType)
		if ok then
			return coerced
		end
		fail(coerced)
		return value
	end

	local result: { [string]: any } = {}
	local provided: { [string]: boolean } = {}
	local positionalIndex = 1
	local i = 1
	local optionsEnded = false

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
		elseif opt.multiple then
			result[opt.longName] = {}
		end
	end

	local function appendOptionValue(opt: OptionSpec, value: any)
		if opt.multiple then
			local values = result[opt.longName]
			if values == nil then
				values = {}
				result[opt.longName] = values
			end
			if opt.arity == 1 then
				table.insert(values, value)
			else
				for _, item in value do
					table.insert(values, item)
				end
			end
		else
			result[opt.longName] = value
		end
		provided[opt.longName] = true
	end

	local function consumeOptionValues(opt: OptionSpec, inlineValue: string?, currentIndex: number): number
		local arity = opt.arity or 1
		local values = {}

		if inlineValue ~= nil then
			if arity ~= 1 then
				fail(`Option '--{opt.longName}' does not support inline values when arity is greater than 1`)
			end
			appendOptionValue(opt, coerceOrFail(inlineValue, opt.type))
			return currentIndex
		end

		for _ = 1, arity do
			currentIndex += 1
			if currentIndex > #args then
				fail(`Option '--{opt.longName}' expects {arity} value(s)`)
			end
			table.insert(values, coerceOrFail(args[currentIndex], opt.type))
		end

		if arity == 1 then
			appendOptionValue(opt, values[1])
		else
			appendOptionValue(opt, values)
		end

		return currentIndex
	end

	while i <= #args do
		local arg = args[i]

		-- Long option/flag: --name or --name=value
		if not optionsEnded and arg == "--" then
			optionsEnded = true
		elseif not optionsEnded and string.sub(arg, 1, 2) == "--" then
			local body = string.sub(arg, 3)
			local eqPos = string.find(body, "=")

			if eqPos then
				-- --key=value form
				local key = string.sub(body, 1, eqPos - 1)
				local value = string.sub(body, eqPos + 1)
				local opt = findOptionByLong(self, key)
				if not opt then
					fail(`Unknown option '--{key}'`)
				end
				i = consumeOptionValues(opt, value, i)
			else
				-- Could be a flag or an option expecting next arg
				local flag = findFlagByLong(self, body)
				if flag then
					result[flag.longName] = true
					provided[flag.longName] = true
				else
					local opt = findOptionByLong(self, body)
					if not opt then
						fail(`Unknown flag or option '--{body}'`)
					end
					i = consumeOptionValues(opt, nil, i)
				end
			end

		-- Short option/flag(s): -h, -ho, -ho 5
		elseif not optionsEnded and string.sub(arg, 1, 1) == "-" and #arg > 1 then
			local chars = string.sub(arg, 2)
			local j = 1
			while j <= #chars do
				local ch = string.sub(chars, j, j)
				local flag = findFlagByShort(self, ch)
				local opt = findOptionByShort(self, ch)

				if flag and not opt then
					result[flag.longName] = true
					provided[flag.longName] = true
				elseif opt then
					-- Option consumes the rest of the merged chars or next argument
					local rest = string.sub(chars, j + 1)
					i = consumeOptionValues(opt, if #rest > 0 then rest else nil, i)
					break -- rest was consumed
				else
					fail(`Unknown flag or option '-{ch}'`)
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
					fail(`Missing required positional argument '{pos.name}' (before subcommand '{arg}')`)
				end
			end

			local sub = self.subCommands[arg]
			local remaining = {}
			for k = i + 1, #args do
				table.insert(remaining, args[k])
			end
			local subResult = sub:parse(remaining, shouldExitOnError)
			result[arg] = subResult
			return result

		-- Positional argument
		else
			if positionalIndex > #self.positionals then
				fail(`Unexpected argument '{arg}'`)
			end
			local pos = self.positionals[positionalIndex]
			if pos.variadic then
				local values = result[pos.name]
				if values == nil then
					values = {}
					result[pos.name] = values
				end
				table.insert(values, coerceOrFail(arg, pos.type))
			else
				result[pos.name] = coerceOrFail(arg, pos.type)
				positionalIndex += 1
			end
		end

		i += 1
	end

	-- Help: invoke handler before validation
	if self._helpEnabled and result.help == true then
		self._helpHandler(self)
		result.help = nil
		return result
	end
	if self._helpEnabled then
		result.help = nil
	end

	-- Validate required positionals were provided
	for idx, pos in self.positionals do
		local value = result[pos.name]
		local missing = value == nil or (pos.variadic and #value == 0)
		if not pos.optional and missing then
			fail(`Missing required positional argument '{pos.name}'`)
		end
	end

	-- Validate required options were provided
	for _, opt in self.options do
		if not opt.optional and result[opt.longName] == nil then
			fail(`Missing required option '--{opt.longName}'`)
		end
	end

	-- Validate mutually exclusive groups
	for _, group in self.mutexGroups do
		local seen = 0
		local seenNames = {}

		for _, name in group.names do
			local known = false
			for _, flag in self.flags do
				if flag.longName == name then
					known = true
					break
				end
			end
			if not known then
				for _, opt in self.options do
					if opt.longName == name then
						known = true
						break
					end
				end
			end
			if not known then
				fail(`Unknown flag/option '{name}' in mutually exclusive group`)
			end

			if provided[name] then
				seen += 1
				table.insert(seenNames, name)
			end
		end

		if seen > 1 then
			fail(`Arguments {table.concat(seenNames, ", ")} are mutually exclusive`)
		end
		if group.required and seen == 0 then
			fail(`One of {table.concat(group.names, ", ")} is required`)
		end
	end

	return result
end

argparse.Parser = Parser

return table.freeze(argparse)
