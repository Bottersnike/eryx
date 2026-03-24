-- Parses doc-comment tags from raw comment text.
--
-- Supported tags:
--   @yields                         Marks function as yieldable (no arguments)
--   @param <name> [description]     Parameter documentation (name must match a known param)
--   @param <name> <type> -- [desc]  Parameter with explicit type override
--   @return [description]           Return value documentation
--   @return <type> -- [description] Return with explicit type
--   @error <type> -- [description]  Documents a possible error (type parsed if -- present)
--   @unreleased                     Marks as unreleased
--   @since <version>                Version when this was introduced
--   @deprecated                     Marks as deprecated
--   @deprecated [description]       Deprecated with reason
--   @deprecated <version> -- [desc] Deprecated at version with reason
--   @private                        Marks as private (excluded from public docs)
--   @ignore                         Totally excluded from generated documentation
--   @tag <name>                     Adds a custom tag

-- ═══════════════════════════════════════════════════════════════════════════
-- Types
-- ═══════════════════════════════════════════════════════════════════════════

export type ParsedParam = {
	name: string,
	description: string,
	typeOverride: string?, -- non-nil when `@param name type -- desc` form is used
}

export type ParsedReturn = {
	description: string,
	type: string?, -- non-nil when `@return type -- desc` form is used
}

export type ParsedError = {
	description: string,
	type: string?, -- non-nil when `@error type -- desc` form is used
}

export type DeprecatedInfo = {
	version: string?,
	description: string?,
}

export type ParsedDoc = {
	body: string,
	params: { ParsedParam },
	returns: { ParsedReturn },
	errors: { ParsedError },
	yields: boolean,
	unreleased: boolean,
	since: string?,
	deprecated: DeprecatedInfo?,
	private: boolean,
	ignore: boolean,
	tags: { string },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════════════════════

local function trim(s: string): string
	return (s:match("^%s*(.-)%s*$")) :: string
end

-- Check if a word is in the known parameter names set.
local function isKnownParam(word: string, knownParams: { [string]: boolean }?): boolean
	if not knownParams then
		return true -- no param list provided, assume it's a name (backward compat)
	end
	return (knownParams :: { [string]: boolean })[word] == true
end

-- Split on ` -- `: returns (before, after) or nil if no separator found.
local function splitOnDashes(s: string): (string?, string?)
	local before, after = s:match("^(.-)%s+%-%-%s*(.*)$")
	return before, after
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Parser
-- ═══════════════════════════════════════════════════════════════════════════

--- Parse a raw doc-comment string into structured tags and body text.
--- `knownParamNames` is an optional set of parameter names (e.g. `{path=true, mode=true}`)
--- used to disambiguate `@param name desc` from `@param desc`.
local function parseDocTags(raw: string, knownParamNames: { [string]: boolean }?): ParsedDoc
	local bodyLines: { string } = {}
	local params: { ParsedParam } = {}
	local returns: { ParsedReturn } = {}
	local errors: { ParsedError } = {}
	local yields = false
	local unreleased = false
	local since: string? = nil
	local deprecated: DeprecatedInfo? = nil
	local private = false
	local ignore = false
	local tags: { string } = {}

	-- Tracks what the current continuation target is.
	local currentTag: string? = nil
	local curIdx: number? = nil -- index into params, returns, or errors

	for _, line in string.split(raw, "\n") do
		local t = trim(line)

		-- ── @yields ──────────────────────────────────────────────────────
		if t:match("^@yields") then
			yields = true
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── @param ──────────────────────────────────────────────────────
		local paramRest = t:match("^@param%s+(.+)$")
		if paramRest then
			local firstWord, remainder = paramRest:match("^(%S+)%s*(.*)$")

			if firstWord and isKnownParam(firstWord, knownParamNames) then
				-- First word is a known param name.
				remainder = remainder or ""
				local before, after = splitOnDashes(remainder)
				if before ~= nil then
					-- @param name type -- description
					local typeStr = trim(before :: string)
					table.insert(
						params,
						{
							name = firstWord,
							description = after or "",
							typeOverride = if typeStr ~= "" then typeStr else nil,
						} :: ParsedParam
					)
				else
					-- @param name description (no type override)
					table.insert(
						params,
						{
							name = firstWord,
							description = remainder,
						} :: ParsedParam
					)
				end
				currentTag, curIdx = "param", #params
			else
				-- First word is NOT a known param — entire rest is description, no name match.
				-- Append to body as-is since we can't associate it with a parameter.
				table.insert(bodyLines, line)
				currentTag, curIdx = nil, nil
			end
			continue
		end

		-- ── @return ─────────────────────────────────────────────────────
		local returnRest = t:match("^@returns?%s*(.*)$")
		if returnRest then
			returnRest = returnRest or ""
			local before, after = splitOnDashes(returnRest)
			if before ~= nil then
				-- @return type -- description
				local typeStr = trim(before :: string)
				table.insert(
					returns,
					{
						description = after or "",
						type = if typeStr ~= "" then typeStr else nil,
					} :: ParsedReturn
				)
			else
				-- @return description (no type)
				table.insert(
					returns,
					{
						description = returnRest,
					} :: ParsedReturn
				)
			end
			currentTag, curIdx = "return", #returns
			continue
		end

		-- ── @error ──────────────────────────────────────────────────────
		local errorRest = t:match("^@error%s+(.+)$")
		if errorRest then
			local before, after = splitOnDashes(errorRest)
			if before ~= nil then
				-- @error type -- description
				table.insert(
					errors,
					{
						type = trim(before :: string),
						description = after or "",
					} :: ParsedError
				)
			else
				-- @error description
				table.insert(
					errors,
					{
						description = errorRest,
					} :: ParsedError
				)
			end
			currentTag, curIdx = "error", #errors
			continue
		end

		-- ── @unreleased ─────────────────────────────────────────────────
		if t:match("^@unreleased") then
			unreleased = true
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── @since ──────────────────────────────────────────────────────
		local sinceVersion = t:match("^@since%s+(%S+)")
		if sinceVersion then
			since = sinceVersion
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── @deprecated ─────────────────────────────────────────────────
		if t:match("^@deprecated") then
			local depRest = t:match("^@deprecated%s+(.+)$")
			if depRest then
				local before, after = splitOnDashes(depRest)
				if before ~= nil then
					-- @deprecated version -- description
					deprecated = {
						version = trim(before :: string),
						description = after or "",
					}
				else
					-- @deprecated description (or just a version — treat as description)
					deprecated = { description = depRest }
				end
			else
				-- Bare @deprecated
				deprecated = {}
			end
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── @private ────────────────────────────────────────────────────
		if t:match("^@private") then
			private = true
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── @ignore ─────────────────────────────────────────────────────
		if t:match("^@ignore") then
			ignore = true
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── @tag ────────────────────────────────────────────────────────
		local tagName = t:match("^@tag%s+(.+)$")
		if tagName then
			table.insert(tags, trim(tagName))
			currentTag, curIdx = nil, nil
			continue
		end

		-- ── Other unknown @tag — stop continuation, add to body ─────────
		if t:match("^@%w") then
			currentTag, curIdx = nil, nil
			table.insert(bodyLines, line)
			continue
		end

		-- ── Continuation of previous tag, or body text ──────────────────
		if currentTag == "param" and curIdx then
			local p = params[curIdx]
			p.description = if p.description == "" then t else p.description .. " " .. t
		elseif currentTag == "return" and curIdx then
			local r = returns[curIdx]
			r.description = if r.description == "" then t else r.description .. " " .. t
		elseif currentTag == "error" and curIdx then
			local e = errors[curIdx]
			e.description = if e.description == "" then t else e.description .. " " .. t
		else
			table.insert(bodyLines, line)
		end
	end

	return {
		body = table.concat(bodyLines, "\n"),
		params = params,
		returns = returns,
		errors = errors,
		yields = yields,
		unreleased = unreleased,
		since = since,
		deprecated = deprecated,
		private = private,
		ignore = ignore,
		tags = tags,
	}
end

return {
	parseDocTags = parseDocTags,
}
