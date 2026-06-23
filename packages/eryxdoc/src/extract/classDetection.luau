--- @ignore

-- Detects class patterns in type aliases (setmetatable-based class idioms).

local luau = require("@eryx/luau/ast")

local function unwrapTypeOrPack(value: any): luau.AstType?
	if type(value) ~= "table" then
		return nil
	end
	if value.type then
		return value :: luau.AstType
	end
	if value.kind == "Type" and value.value and type(value.value) == "table" and value.value.type then
		return value.value :: luau.AstType
	end
	return nil
end

-- Detects three class patterns in a type alias's aliased type:
--   Pattern 1: typeof(setmetatable({} :: Fields, Impl))
--   Pattern 2: setmetatable<FieldsType, typeof(ImplTable)>
--   Pattern 3: setmetatable<{inline fields}, {inline meta}> (no named impl)
--
-- Returns (implTableName, fieldsTypeName, isInlineClass)
local function detectClassPattern(aliasedType: luau.AstType): (string?, string?, boolean)
	-- Pattern 1: typeof(setmetatable({} :: Fields, Impl))
	if aliasedType.type == "typeof" then
		local typeofNode = aliasedType :: luau.AstTypeTypeof
		local expr = typeofNode.expr
		if expr and expr.type == "call" then
			local call = expr :: luau.AstExprCall
			local func = call.func
			local isSetmetatable = (
				func
				and func.type == "global"
				and (func :: luau.AstExprGlobal).name == "setmetatable"
			)
			if isSetmetatable and call.args and #call.args >= 2 then
				local arg1 = call.args[1]
				local fieldsName: string? = nil
				if arg1 and arg1.type == "typeAssertion" then
					local assertion = arg1 :: luau.AstExprTypeAssertion
					if assertion.annotation and assertion.annotation.type == "reference" then
						fieldsName = (assertion.annotation :: luau.AstTypeReference).name
					end
				end
				local arg2 = call.args[2]
				local implName: string? = nil
				if arg2 then
					if arg2.type == "global" then
						implName = (arg2 :: luau.AstExprGlobal).name
					elseif arg2.type == "local" then
						local loc = arg2 :: luau.AstExprLocal
						implName = loc["local"] and loc["local"].name
					end
				end
				if implName then
					return implName, fieldsName, false
				end
			end
		end
	end

	-- Pattern 2: setmetatable<FieldsType, typeof(ImplTable)>
	if aliasedType.type == "reference" then
		local ref = aliasedType :: luau.AstTypeReference
		if ref.name == "setmetatable" and ref.parameters then
			local params = ref.parameters
			if #params >= 2 then
				local fieldsName: string? = nil
				local p1 = unwrapTypeOrPack(params[1])
				if p1 and p1.type == "reference" then
					fieldsName = (p1 :: luau.AstTypeReference).name
				end
				local implName: string? = nil
				local p2 = unwrapTypeOrPack(params[2])
				if p2 and p2.type == "typeof" then
					local inner = (p2 :: luau.AstTypeTypeof).expr
					if inner then
						if inner.type == "global" then
							implName = (inner :: luau.AstExprGlobal).name
						elseif inner.type == "local" then
							local loc = inner :: luau.AstExprLocal
							implName = loc["local"] and loc["local"].name
						end
					end
				end
				if implName then
					return implName, fieldsName, false
				end
			end

			-- Pattern 3: setmetatable<{fields}, {meta}> (inline, no named impl)
			if #params >= 1 then
				local p1 = unwrapTypeOrPack(params[1])
				if p1 and p1.type == "table" then
					return nil, nil, true
				end
			end
		end
	end

	return nil, nil, false
end

return {
	detectClassPattern = detectClassPattern,
}
