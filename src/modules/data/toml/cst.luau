local cst = {}

type State = {
	root: { [any]: any },
	source: string?,
	dirty: boolean,
	proxyByTable: { [any]: any },
	tableByProxy: { [any]: any },
	pathByTable: { [any]: { string } },
	styleByPath: { [string]: string },
	commentByPathAndWhere: { [string]: string },
	assignmentByPath: { [string]: any },
	headerByPath: { [string]: any },
	changedByPath: { [string]: number },
	changeSeq: number,
}

local stateByProxy: { [any]: any } = {}

local function normalizePath(path: any): { string }
	if type(path) == "string" then
		local out: { string } = {}
		for part in string.gmatch(path, "[^%.]+") do
			table.insert(out, part)
		end
		return out
	elseif type(path) == "table" then
		local out: { string } = {}
		for i = 1, #path do
			table.insert(out, tostring((path :: any)[i]))
		end
		return out
	end
	error("path must be a dotted string or an array of path parts")
end

local function pathKey(path: { string }): string
	return table.concat(path, "\0")
end

local function pathWhereKey(path: { string }, where: string): string
	return pathKey(path) .. "\0" .. where
end

local function unwrapAssignedValue(state: State, value: any): any
	if type(value) ~= "table" then
		return value
	end
	local assignedFromProxy = state.tableByProxy[value]
	if assignedFromProxy ~= nil then
		return assignedFromProxy
	end
	return value
end

local function markChanged(state: State, path: { string })
	state.changeSeq += 1
	state.changedByPath[pathKey(path)] = state.changeSeq
end

local function makeProxy(state: State, tableValue: { [any]: any }, path: { string }): any
	local existing = state.proxyByTable[tableValue]
	if existing ~= nil then
		return existing
	end

	local proxy = {}
	state.proxyByTable[tableValue] = proxy
	state.tableByProxy[proxy] = tableValue
	state.pathByTable[tableValue] = path
	stateByProxy[proxy] = state

	setmetatable(proxy, {
		__index = function(_, key)
			local value = (tableValue :: any)[key]
			if type(value) == "table" then
				local childPath = table.clone(path)
				table.insert(childPath, tostring(key))
				return makeProxy(state, value :: { [any]: any }, childPath)
			end
			return value
		end,
		__newindex = function(_, key, value)
			local unwrapped = unwrapAssignedValue(state, value)
			local t = tableValue :: any
			t[key] = unwrapped
			local changedPath = table.clone(path)
			table.insert(changedPath, tostring(key))
			markChanged(state, changedPath)
			if type(unwrapped) == "table" then
				state.pathByTable[unwrapped] = changedPath
			end
			state.dirty = true
		end,
		__pairs = function()
			return next, tableValue, nil
		end,
		__len = function()
			return #tableValue
		end,
	})

	return proxy
end

function cst.fromDecoded(source: string, decoded: { [any]: any }, cstData: any?): any
	local assignmentByPath = {}
	local headerByPath = {}
	if type(cstData) == "table" and type((cstData :: any).assignmentByPath) == "table" then
		assignmentByPath = (cstData :: any).assignmentByPath
		if type((cstData :: any).headerByPath) == "table" then
			headerByPath = (cstData :: any).headerByPath
		end
	elseif type(cstData) == "table" then
		assignmentByPath = cstData
	end

	local state: State = {
		root = decoded,
		source = source,
		dirty = false,
		proxyByTable = {},
		tableByProxy = {},
		pathByTable = {},
		styleByPath = {},
		commentByPathAndWhere = {},
		assignmentByPath = assignmentByPath,
		headerByPath = headerByPath,
		changedByPath = {},
		changeSeq = 0,
	}
	return makeProxy(state, decoded, {})
end

function cst.newEmpty(): any
	local root = {}
	local state: State = {
		root = root,
		source = nil,
		dirty = true,
		proxyByTable = {},
		tableByProxy = {},
		pathByTable = {},
		styleByPath = {},
		commentByPathAndWhere = {},
		assignmentByPath = {},
		headerByPath = {},
		changedByPath = {},
		changeSeq = 0,
	}
	return makeProxy(state, root, {})
end

function cst.isCSTObject(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	return stateByProxy[value] ~= nil
end

function cst.getSourceIfUnchanged(value: any): string?
	local state = stateByProxy[value]
	if state == nil then
		return nil
	end
	if state.dirty then
		return nil
	end
	return state.source
end

function cst.getOriginalSource(value: any): string?
	local state = stateByProxy[value]
	if state == nil then
		return nil
	end
	return state.source
end

function cst.getSemanticRoot(value: any): { [any]: any }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return state.root
end

function cst.getStyleMap(value: any): { [string]: string }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return state.styleByPath
end

function cst.getCommentMap(value: any): { [string]: string }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return state.commentByPathAndWhere
end

function cst.getAssignmentMap(value: any): { [string]: any }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return state.assignmentByPath
end

function cst.getHeaderMap(value: any): { [string]: any }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return state.headerByPath
end

function cst.getChangedPathMap(value: any): { [string]: number }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return state.changedByPath
end

local function getAtPath(root: any, path: { string }): any
	local cursor = root
	for i = 1, #path do
		if type(cursor) ~= "table" then
			return nil
		end
		cursor = (cursor :: any)[path[i]]
		if cursor == nil then
			return nil
		end
	end
	return cursor
end

function cst.getValueAtPath(value: any, path: { string }): any
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return getAtPath(state.root, path)
end

local function cloneValue(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for k, v in value do
		copy[k] = cloneValue(v)
	end
	setmetatable(copy, getmetatable(value))
	return copy
end

function cst.toTable(value: any): { [any]: any }
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	return cloneValue(state.root)
end

function cst.setStyle(value: any, path: any, style: string)
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	if style ~= "header" and style ~= "dotted" then
		error("style must be 'header' or 'dotted'")
	end
	local parts = normalizePath(path)
	state.styleByPath[pathKey(parts)] = style
	markChanged(state, parts)
	state.dirty = true
end

function cst.getStyle(value: any, path: any): string?
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	local parts = normalizePath(path)
	return state.styleByPath[pathKey(parts)]
end

function cst.setComment(value: any, path: any, comment: string, where: string?)
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	local slot = if where == nil then "before" else where
	if slot ~= "before" and slot ~= "inline" and slot ~= "after" then
		error("where must be 'before', 'inline', or 'after'")
	end
	local parts = normalizePath(path)
	state.commentByPathAndWhere[pathWhereKey(parts, slot)] = comment
	markChanged(state, parts)
	state.dirty = true
end

function cst.getComment(value: any, path: any, where: string?): string?
	local state = stateByProxy[value]
	if state == nil then
		error("value is not a TOML CST object")
	end
	local slot = if where == nil then "before" else where
	local parts = normalizePath(path)
	return state.commentByPathAndWhere[pathWhereKey(parts, slot)]
end

return cst
