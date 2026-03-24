-- Detects class patterns in type aliases (setmetatable-based class idioms).

local luau = require("@eryx/luau")

-- Detects three class patterns in a type alias's aliased type:
--   Pattern 1: typeof(setmetatable({} :: Fields, Impl))
--   Pattern 2: setmetatable<FieldsType, typeof(ImplTable)>
--   Pattern 3: setmetatable<{inline fields}, {inline meta}> (no named impl)
--
-- Returns (implTableName, fieldsTypeName, isInlineClass)
local function detectClassPattern(aliasedType: luau.AstType): (string?, string?, boolean)
	-- Pattern 1: typeof(setmetatable({} :: Fields, Impl))
	if aliasedType.type == "TypeTypeof" then
		local typeofNode = aliasedType :: luau.TypeTypeof
		local expr = typeofNode.expr
		if expr and expr.type == "ExprCall" then
			local call = expr :: luau.ExprCall
			local func = call.func
			local isSetmetatable = (
				func
				and func.type == "ExprGlobal"
				and (func :: luau.ExprGlobal).name == "setmetatable"
			)
			if isSetmetatable and call.args and #call.args >= 2 then
				local arg1 = call.args[1]
				local fieldsName: string? = nil
				if arg1 and arg1.type == "ExprTypeAssertion" then
					local assertion = arg1 :: luau.ExprTypeAssertion
					if assertion.annotation and assertion.annotation.type == "TypeReference" then
						fieldsName = (assertion.annotation :: luau.TypeReference).name
					end
				end
				local arg2 = call.args[2]
				local implName: string? = nil
				if arg2 then
					if arg2.type == "ExprGlobal" then
						implName = (arg2 :: luau.ExprGlobal).name
					elseif arg2.type == "ExprLocal" then
						local loc = arg2 :: luau.ExprLocal
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
	if aliasedType.type == "TypeReference" then
		local ref = aliasedType :: luau.TypeReference
		if ref.name == "setmetatable" and ref.parameters then
			local params = ref.parameters
			if #params >= 2 then
				local fieldsName: string? = nil
				local p1 = params[1]
				if p1 and p1.type == "TypeReference" then
					fieldsName = (p1 :: luau.TypeReference).name
				end
				local implName: string? = nil
				local p2 = params[2]
				if p2 and p2.type == "TypeTypeof" then
					local inner = (p2 :: luau.TypeTypeof).expr
					if inner then
						if inner.type == "ExprGlobal" then
							implName = (inner :: luau.ExprGlobal).name
						elseif inner.type == "ExprLocal" then
							local loc = inner :: luau.ExprLocal
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
				local p1 = params[1]
				if p1 and p1.type == "TypeTable" then
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
