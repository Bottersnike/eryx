--- @ignore

export type LineCursor = {
	byte: number, -- The actual byte offset (1 indexed)
	column: number, -- The column, tab-aware (1 indexed)
}

local tabUtil = {}

tabUtil.TAB_STOP = 4

--- Calculate the indentation level in a string, starting at [offset].
--- Tab-stop aware
function tabUtil.indentationLevel(line: string, offset: LineCursor): LineCursor
	local col = offset.column

	local byteDelta = 0
	local colDelta = 0

	for i = offset.byte, #line do
		local c = line:sub(i, i)

		if c == " " then
			byteDelta += 1

			col += 1
			colDelta += 1
		elseif c == "\t" then
			local advance = tabUtil.TAB_STOP - ((col - 1) % tabUtil.TAB_STOP)

			byteDelta += 1

			col += advance
			colDelta += advance
		else
			break
		end
	end

	return {
		byte = byteDelta,
		column = colDelta,
	}
end

--[=[
Match a string an up to `maxLeading` levels of indentation into a line

@param line Line to match
@param offset Offset in the line to start with
@param maxLeading Maximum leading to allow
@param match String to match
@return A boolean for if we matched, then the real string offset for the end of the indentation
]=]
function tabUtil.matchWithLeadingIndentation(
	line: string,
	offset: LineCursor,
	match: string,
	maxLeading: number
): (boolean, LineCursor)
	local i = offset.byte
	local col = offset.column

	local byteDelta = 0
	local colDelta = 0

	-- Scan indentation WITHOUT exceeding maxLeading
	while i <= #line do
		local c = line:sub(i, i)

		if c == " " then
			if colDelta + 1 > maxLeading then
				break
			end

			i += 1
			byteDelta += 1

			col += 1
			colDelta += 1
		elseif c == "\t" then
			local advance = tabUtil.TAB_STOP - ((col - 1) % tabUtil.TAB_STOP)

			if colDelta + advance > maxLeading then
				break
			end

			i += 1
			byteDelta += 1

			col += advance
			colDelta += advance
		else
			break
		end
	end

	-- Now attempt to match at this position
	if line:sub(i, i + #match - 1) == match then
		return true,
			{
				byte = byteDelta + #match,
				column = colDelta + #match, -- match is literal chars, so 1 column each
			}
	end

	return false, {
		byte = 0,
		column = 0,
	}
end

function tabUtil.advanceAtMostNWhitespace(line: string, offset: LineCursor, targetColumns: number): LineCursor
	local i = offset.byte
	local col = offset.column

	local byteDelta = 0
	local colDelta = 0

	while i <= #line and colDelta < targetColumns do
		local c = line:sub(i, i)

		if c == " " then
			i += 1
			byteDelta += 1

			col += 1
			colDelta += 1
		elseif c == "\t" then
			local advance = tabUtil.TAB_STOP - ((col - 1) % tabUtil.TAB_STOP)

			-- Check if we're only going to partially consume this tab
			if colDelta + advance > targetColumns then
				return {
					byte = byteDelta,
					column = targetColumns,
				}
			end

			i += 1
			byteDelta += 1

			col += advance
			colDelta += advance
		else
			break
		end
	end

	return {
		byte = byteDelta,
		column = colDelta,
	}
end
return table.freeze(tabUtil)
