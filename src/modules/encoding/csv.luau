--[=[
	CSV reading and writing utilities.
]=]

--[=[
	Core format description shared between parsing and generation.
	Dialect presets contain only these fields -- parse- and generate-specific
	options live on their respective option types.
]=]
export type Dialect = {
	--- Field separator (single byte). Default `","`.
	delimiter: string?,
	--- Character used to quote fields (single byte). Default `'"'`.
	quotechar: string?,
	--- Character used to escape special characters (single byte). Default `nil` (disabled).
	escapechar: string?,
	--- Whether a quote character inside a quoted field is escaped by doubling it. Default `true`.
	doublequote: boolean?,
	--- One of the `csv.QUOTE_*` constants controlling quoting behaviour. Default `QUOTE_MINIMAL`.
	quoting: number?,
	--- String appended after each row during generation. Default `"\r\n"`.
	lineterminator: string?,
}

--[=[
	Options for `csv.parse`. Inherits all `Dialect` fields as per-call overrides;
	resolution order is: option field > dialect field > hard default.
]=]
export type ParseOptions = Dialect & {
	--- Base dialect -- a registered name or an inline `Dialect` table.
	dialect: (string | Dialect)?,
	--- Skip whitespace immediately following the delimiter. Default `false`.
	skipinitialspace: boolean?,
	--- Error on malformed input (bare quotes, unterminated fields, etc.). Default `false`.
	strict: boolean?,
	--- Single-byte prefix that marks an entire line as a comment. Default `nil` (disabled).
	comment: string?,
	--- Trim leading/trailing whitespace from unquoted fields. Default `false`.
	trimfields: boolean?,
	--- Maximum number of characters allowed per field. Default `nil` (unlimited).
	maxfieldsize: number?,
	--- Discard rows that consist of a single empty field. Default `false`.
	skipblanklines: boolean?,
}

--- Options for `csv.generate`. Inherits all `Dialect` fields as per-call overrides.
export type GenerateOptions = Dialect & {
	--- Base dialect -- a registered name or an inline `Dialect` table.
	dialect: (string | Dialect)?,
}

--- Additional options for `csv.parseDict`, on top of `ParseOptions`.
export type DictParseOptions = ParseOptions & {
	--- Explicit column names. When set, the first row is treated as data, not a header.
	columns: { string }?,
	--- Value used for missing fields when a row is shorter than the header. Default `""`.
	restval: string?,
}

--- Additional options for `csv.generateDict`, on top of `GenerateOptions`.
export type DictGenerateOptions = GenerateOptions & {
	--- Value used for missing keys when a dict row lacks a field name. Default `""`.
	restval: string?,
	--- Whether to emit a header row from the field names. Default `true`.
	writeheader: boolean?,
}

--- Result returned by `csv.sniff`.
export type SniffResult = {
	--- The best-guess field delimiter.
	delimiter: string,
	--- The detected quote character, or `nil` if none was found.
	quotechar: string?,
	--- Whether doubled-quote escaping is assumed.
	doublequote: boolean?,
}

local csv = {}

--- Quote only when the field contains special characters.
csv.QUOTE_MINIMAL = 0
--- Quote every field unconditionally.
csv.QUOTE_ALL = 1
--- Quote non-numeric fields; on read, reject unquoted non-numeric in strict mode.
csv.QUOTE_NONNUMERIC = 2
--- Never quote; use `escapechar` to protect special characters.
csv.QUOTE_NONE = 3

local dialects: { [string]: Dialect } = {
	excel = {
		delimiter = ",",
		quotechar = '"',
		escapechar = nil,
		doublequote = true,
		lineterminator = "\r\n",
		quoting = 0,
	},
	["excel-tab"] = {
		delimiter = "\t",
		quotechar = '"',
		escapechar = nil,
		doublequote = true,
		lineterminator = "\r\n",
		quoting = 0,
	},
	unix = {
		delimiter = ",",
		quotechar = '"',
		escapechar = nil,
		doublequote = true,
		lineterminator = "\n",
		quoting = 1,
	},
	tsv = {
		delimiter = "\t",
		quotechar = '"',
		escapechar = nil,
		doublequote = true,
		lineterminator = "\n",
		quoting = 0,
	},
	pipe = {
		delimiter = "|",
		quotechar = '"',
		escapechar = nil,
		doublequote = true,
		lineterminator = "\n",
		quoting = 0,
	},
}

local DEFAULT_DIALECT: Dialect = dialects.excel

--- Resolve a single option with fallback chain: user > base > default.
local function resolve<T>(user: T?, base: T?, default: T): T
	if user ~= nil then
		return user
	end
	if base ~= nil then
		return base
	end
	return default
end

--[=[
	Resolve a dialect reference to a concrete `Dialect` table.
	Errors on unrecognised dialect names.
	@param dialect -- A registered dialect name, an inline Dialect table, or nil for the default.
	@return Dialect
]=]
local function resolveDialect(dialect: (string | Dialect)?): Dialect
	if type(dialect) == "string" then
		local d = dialects[dialect]
		if not d then
			error(`csv: unknown dialect "{dialect}"`)
		end
		return d
	elseif type(dialect) == "table" then
		return dialect
	end
	return DEFAULT_DIALECT
end

--[=[
	Assert that a character option is nil or exactly one byte long.
	@param name -- Option name shown in the error message.
	@param value -- The value to validate.
]=]
local function assertSingleByte(name: string, value: string?)
	if value ~= nil and #value ~= 1 then
		error(`csv: {name} must be a single byte character, got {#value} bytes`)
	end
end

--- Trim leading and trailing whitespace from a string.
local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) or s
end

--[=[
	Replace all occurrences of `find` with `repl` using plain-text matching.
	@param s -- The source string.
	@param find -- The substring to search for (literal, not a pattern).
	@param repl -- The replacement string.
	@return string
]=]
local function replaceAll(s: string, find: string, repl: string): string
	local out = {}
	local pos = 1
	local flen = #find
	while true do
		local i = string.find(s, find, pos, true)
		if not i then
			table.insert(out, string.sub(s, pos))
			break
		end
		if i > pos then
			table.insert(out, string.sub(s, pos, i - 1))
		end
		table.insert(out, repl)
		pos = i + flen
	end
	return table.concat(out)
end

--------------------------------------------------------------------------------
-- Parser
--
-- A byte-level state-machine that handles:
--   * quoted fields (with doubled-quote or escape-char escaping)
--   * embedded delimiters and newlines inside quoted fields
--   * mixed \r\n / \r / \n line endings
--   * UTF-8 BOM stripping
--   * comment lines, field trimming, max-field-size, strict mode
--   * QUOTE_NONNUMERIC strict validation
--------------------------------------------------------------------------------

--[=[
	Parse a CSV/TSV string into a list of rows.
	Each row is a list of string field values. Automatically strips a leading
	UTF-8 BOM and normalises all line-ending styles.
	@param input -- The raw CSV text to parse.
	@param opts -- Parsing options. See `ParseOptions` for available fields.
	@return { { string } } -- The parsed rows.
]=]
function csv.parse(input: string, opts: ParseOptions?): { { string } }
	if input == "" then
		return {}
	end

	-- Strip UTF-8 BOM
	if
		#input >= 3
		and string.byte(input, 1) == 0xEF
		and string.byte(input, 2) == 0xBB
		and string.byte(input, 3) == 0xBF
	then
		input = string.sub(input, 4)
		if input == "" then
			return {}
		end
	end

	local base = resolveDialect(opts and opts.dialect)
	local delim: string = resolve(opts and opts.delimiter, base.delimiter, ",")
	local qchar: string? = resolve(opts and opts.quotechar, base.quotechar, '"')
	local esc: string? = resolve(opts and opts.escapechar, base.escapechar, nil)
	local dblq: boolean = resolve(opts and opts.doublequote, base.doublequote, true)
	local quoting: number = resolve(opts and opts.quoting, base.quoting, 0)
	local skipsp: boolean = if opts and opts.skipinitialspace ~= nil then opts.skipinitialspace else false
	local strict: boolean = if opts and opts.strict ~= nil then opts.strict else false
	local comment: string? = if opts then opts.comment else nil
	local trimf: boolean = if opts and opts.trimfields ~= nil then opts.trimfields else false
	local maxfs: number? = if opts then opts.maxfieldsize else nil
	local skipblank: boolean = if opts and opts.skipblanklines ~= nil then opts.skipblanklines else false

	-- Validate single-byte constraints
	assertSingleByte("delimiter", delim)
	assertSingleByte("quotechar", qchar)
	assertSingleByte("escapechar", esc)
	assertSingleByte("comment", comment)

	-- Pre-compute byte values for the hot loop (-1 = feature disabled)
	local delimB = string.byte(delim, 1)
	local qcharB = qchar and string.byte(qchar, 1) or -1
	local escB = esc and string.byte(esc, 1) or -1
	local commentB = comment and string.byte(comment, 1) or -1

	local rows = {}
	local row = {}
	local buf = {}
	local bufN = 0
	local pos = 1
	local len = #input
	local inQ = false -- inside a quoted field
	local wasQ = false -- current field was opened with a quote
	local fstart = true -- at the very start of a new field
	local lstart = true -- at the start of a new line

	-- Flush the current field buffer into `row`.
	local function pushField()
		local val = table.concat(buf, "", 1, bufN)

		if trimf and not wasQ then
			val = trim(val)
		end

		if quoting == 2 and not wasQ and strict and tonumber(val) == nil then
			error("csv: non-numeric unquoted field in QUOTE_NONNUMERIC mode")
		end
		table.insert(row, val)

		bufN = 0
		wasQ = false
		fstart = true
	end

	-- Flush the current row into `rows`.
	local function pushRow()
		pushField()
		if not (skipblank and #row == 1 and row[1] == "") then
			table.insert(rows, row)
		end
		row = {}
		lstart = true
	end

	------------------------------------------------------------------ main loop
	while pos <= len do
		local b = string.byte(input, pos)

		if inQ then
			-------------------------------------------------------- quoted field
			if b == qcharB then
				local nb = pos < len and string.byte(input, pos + 1) or nil
				if dblq and nb == qcharB then
					-- doubled quote -> literal quote character
					if maxfs and bufN >= maxfs then
						error("csv: field exceeds maximum size of " .. tostring(maxfs))
					end
					bufN += 1
					buf[bufN] = qchar
					pos += 2
				else
					-- closing quote
					inQ = false
					pos += 1
				end
			elseif b == escB and esc then
				-- escape the next character
				pos += 1
				if pos <= len then
					if maxfs and bufN >= maxfs then
						error("csv: field exceeds maximum size of " .. tostring(maxfs))
					end
					bufN += 1
					buf[bufN] = string.sub(input, pos, pos)
					pos += 1
				elseif strict then
					error("csv: escape character at end of input")
				end
			else
				-- regular data byte inside quotes
				if maxfs and bufN >= maxfs then
					error("csv: field exceeds maximum size of " .. tostring(maxfs))
				end
				bufN += 1
				buf[bufN] = string.sub(input, pos, pos)
				pos += 1
			end
		else
			------------------------------------------------------ unquoted state

			if lstart and b == commentB and comment then
				-- skip the rest of this line
				while pos <= len do
					local cb = string.byte(input, pos)
					pos += 1
					if cb == 0x0A then
						break
					end
					if cb == 0x0D then
						if pos <= len and string.byte(input, pos) == 0x0A then
							pos += 1
						end
						break
					end
				end
				lstart = true
				fstart = true
			elseif fstart and skipsp and b == 0x20 then
				-- skip leading space in field
				pos += 1
			elseif fstart and b == qcharB and qchar then
				-- opening quote at field start
				inQ = true
				wasQ = true
				fstart = false
				lstart = false
				pos += 1
			elseif b == delimB then
				-- field delimiter
				pushField()
				lstart = false
				pos += 1
			elseif b == 0x0D then -- \r (possibly \r\n)
				local nb = pos < len and string.byte(input, pos + 1) or nil
				pushRow()
				pos += if nb == 0x0A then 2 else 1
			elseif b == 0x0A then -- \n
				pushRow()
				pos += 1
			elseif b == escB and esc then
				-- escape character outside quotes
				fstart = false
				lstart = false
				pos += 1
				if pos <= len then
					bufN += 1
					buf[bufN] = string.sub(input, pos, pos)
					pos += 1
				elseif strict then
					error("csv: escape character at end of input")
				end
			else
				-- regular data byte
				if strict and b == qcharB and not fstart then
					error("csv: bare quote character in unquoted field")
				end
				if maxfs and bufN >= maxfs then
					error("csv: field exceeds maximum size of " .. tostring(maxfs))
				end
				fstart = false
				lstart = false
				bufN += 1
				buf[bufN] = string.sub(input, pos, pos)
				pos += 1
			end
		end
	end

	-- unterminated quote
	if inQ and strict then
		error("csv: unexpected end of input inside quoted field")
	end

	-- flush any remaining data that wasn't terminated by a newline
	if not fstart or #row > 0 then
		pushRow()
	end

	return rows
end

--------------------------------------------------------------------------------
-- Generator
--------------------------------------------------------------------------------

type WriteOpts = {
	delimiter: string,
	quotechar: string?,
	escapechar: string?,
	doublequote: boolean,
	quoting: number,
}

--- Decide whether `s` needs to be wrapped in quotes (or escaped for QUOTE_NONE).
local function needsQuote(s: string, o: WriteOpts): boolean
	local q = o.quoting
	if q == 1 then
		return true
	end -- QUOTE_ALL
	if q == 2 then
		return tonumber(s) == nil
	end -- QUOTE_NONNUMERIC

	-- QUOTE_MINIMAL and QUOTE_NONE: check for special characters.
	-- For QUOTE_NONE this drives the escape-char path in encodeField.
	if string.find(s, o.delimiter, 1, true) then
		return true
	end
	if o.quotechar and string.find(s, o.quotechar, 1, true) then
		return true
	end
	if string.find(s, "\n", 1, true) or string.find(s, "\r", 1, true) then
		return true
	end
	return false
end

--[=[
	Encode a single field value into its CSV representation.
	@param val -- The raw field value (nil is treated as "").
	@param o -- Resolved write options.
	@return string -- The encoded field, quoted/escaped as needed.
]=]
local function encodeField(val: string?, o: WriteOpts): string
	local s = if val == nil then "" else tostring(val)
	local qchar = o.quotechar

	if not needsQuote(s, o) then
		return s
	end

	-- QUOTE_NONE: protect special characters with the escape char
	if o.quoting == 3 then
		local esc = o.escapechar
		if not esc then
			error("csv: escapechar required when quoting=QUOTE_NONE and field contains special characters")
		end
		-- order matters: escape the escape char first
		s = replaceAll(s, esc, esc .. esc)
		s = replaceAll(s, o.delimiter, esc .. o.delimiter)
		s = replaceAll(s, "\r", esc .. "\r")
		s = replaceAll(s, "\n", esc .. "\n")
		if qchar then
			s = replaceAll(s, qchar, esc .. qchar)
		end
		return s
	end

	-- standard quoting: wrap in quotes and escape inner quote chars
	if not qchar then
		error("csv: quotechar required to quote field")
	end
	if o.doublequote then
		s = replaceAll(s, qchar, qchar .. qchar)
	elseif o.escapechar then
		s = replaceAll(s, qchar, o.escapechar .. qchar)
	else
		error("csv: cannot escape quote character: doublequote is false and no escapechar is set")
	end
	return qchar .. s .. qchar
end

--[=[
	Serialize a list of rows into a CSV/TSV string.
	A line terminator is appended after every row, including the last
	(matching Python `csv.writer` behaviour).
	@param rows -- List of rows, where each row is a list of string field values.
	@param opts -- Generation options. See `GenerateOptions` for available fields.
	@return string -- The serialized CSV text.
]=]
function csv.generate(rows: { { string } }, opts: GenerateOptions?): string
	local base = resolveDialect(opts and opts.dialect)
	local delim: string = resolve(opts and opts.delimiter, base.delimiter, ",")
	local qchar: string? = resolve(opts and opts.quotechar, base.quotechar, '"')
	local esc: string? = resolve(opts and opts.escapechar, base.escapechar, nil)
	local dblq: boolean = resolve(opts and opts.doublequote, base.doublequote, true)
	local term: string = resolve(opts and opts.lineterminator, base.lineterminator, "\r\n")
	local quoting: number = resolve(opts and opts.quoting, base.quoting, 0)

	-- Validate single-byte constraints
	assertSingleByte("delimiter", delim)
	assertSingleByte("quotechar", qchar)
	assertSingleByte("escapechar", esc)

	local wo: WriteOpts = {
		delimiter = delim,
		quotechar = qchar,
		escapechar = esc,
		doublequote = dblq,
		quoting = quoting,
	}

	local parts = {}

	for i, row in rows do
		local fields = {}
		for j, v in row do
			fields[j] = encodeField(v, wo)
		end
		parts[i] = table.concat(fields, delim)
	end

	if #parts == 0 then
		return ""
	end
	return table.concat(parts, term) .. term
end

--------------------------------------------------------------------------------
-- Dictionary helpers
--------------------------------------------------------------------------------

--[=[
	Parse CSV input and return each row as a dictionary keyed by field name.
	Field names come from the first data row unless `opts.columns` is set,
	in which case the first row is treated as data. Missing fields are filled
	with `restval`; extra fields beyond the header are discarded.
	@param input -- The raw CSV text to parse.
	@param opts -- Parsing options. See `DictParseOptions` for available fields.
	@return { { [string]: string } } -- The parsed rows as dictionaries.
	@return { string } -- The resolved field names.
]=]
function csv.parseDict(input: string, opts: DictParseOptions?): ({ { [string]: string } }, { string })
	local raw = csv.parse(input, opts)
	if #raw == 0 then
		return {}, {}
	end

	local fieldnames: { string }
	local start: number

	if opts and opts.columns then
		fieldnames = opts.columns
		start = 1
	else
		fieldnames = {}
		for i, v in raw[1] do
			fieldnames[i] = tostring(v)
		end
		start = 2
	end

	local restval: string = if opts and opts.restval ~= nil then opts.restval else ""
	local nfields = #fieldnames

	local rows: { { [string]: string } } = {}
	for i = start, #raw do
		local r = raw[i]
		local dict: { [string]: string } = {}
		for j = 1, nfields do
			dict[fieldnames[j]] = if j <= #r then r[j] else restval
		end
		table.insert(rows, dict)
	end

	return rows, fieldnames
end

--[=[
	Serialize dictionary rows into CSV, optionally prepending a header row
	built from `fieldnames`. Each row is a table keyed by field name.
	@param rows -- List of dictionary rows to serialize.
	@param fieldnames -- Ordered column names that control output column order.
	@param opts -- Generation options. See `DictGenerateOptions` for available fields.
	@return string -- The serialized CSV text.
]=]
function csv.generateDict(rows: { { [string]: string } }, fieldnames: { string }, opts: DictGenerateOptions?): string
	local restval: string = if opts and opts.restval ~= nil then opts.restval else ""
	local writeheader: boolean = if opts and opts.writeheader ~= nil then opts.writeheader else true

	local out: { { string } } = {}

	if writeheader then
		table.insert(out, fieldnames)
	end

	for _, dict in rows do
		local row = {}
		for j, name in fieldnames do
			row[j] = if dict[name] ~= nil then dict[name] else restval
		end
		table.insert(out, row)
	end

	return csv.generate(out, opts)
end

--------------------------------------------------------------------------------
-- Dialect management
--------------------------------------------------------------------------------

--[=[
	Register (or overwrite) a named dialect.
	@param name -- The dialect name to register under.
	@param dialect -- The dialect definition.
]=]
function csv.registerDialect(name: string, dialect: Dialect)
	dialects[name] = dialect
end

--[=[
	Retrieve a named dialect table, or `nil` if not registered.
	@param name -- The dialect name to look up.
	@return Dialect?
]=]
function csv.getDialect(name: string): Dialect?
	return dialects[name]
end

--[=[
	Remove a named dialect. No-op if the name is not registered.
	@param name -- The dialect name to remove.
]=]
function csv.unregisterDialect(name: string)
	dialects[name] = nil
end

--[=[
	Return a sorted list of all registered dialect names.
	@return { string }
]=]
function csv.listDialects(): { string }
	local names = {}
	for k, _ in dialects do
		table.insert(names, k)
	end
	table.sort(names)
	return names
end

--------------------------------------------------------------------------------
-- Format sniffer
--------------------------------------------------------------------------------

--[=[
	Examine the first 20 non-empty lines of `input` and return a best-guess
	dialect. The heuristic prefers the delimiter that produces a consistent
	column count across all sample lines, breaking ties by column count.
	@param input -- The raw CSV text to analyse.
	@param candidates -- Delimiter characters to consider. Defaults to `{ ",", "\t", "|", ";", ":" }`.
	@return SniffResult
]=]
function csv.sniff(input: string, candidates: { string }?): SniffResult
	candidates = candidates or { ",", "\t", "|", ";", ":" }

	-- collect sample lines
	local lines = {}
	for line in string.gmatch(input, "[^\r\n]+") do
		if line ~= "" then
			table.insert(lines, line)
			if #lines >= 20 then
				break
			end
		end
	end
	if #lines == 0 then
		return { delimiter = "," }
	end

	local best, bestScore = ",", -1

	for _, d in candidates do
		local first = -1
		local consistent = true

		for _, line in lines do
			local n, inQ = 0, false
			for i = 1, #line do
				local c = string.sub(line, i, i)
				if c == '"' then
					inQ = not inQ
				elseif not inQ and c == d then
					n += 1
				end
			end
			if first == -1 then
				first = n
			elseif n ~= first then
				consistent = false
			end
		end

		local score = first * (if consistent then 10 else 1)
		if score > bestScore then
			best, bestScore = d, score
		end
	end

	return {
		delimiter = best,
		quotechar = if string.find(input, '"', 1, true) then '"' else nil,
		doublequote = true,
	}
end

return csv
