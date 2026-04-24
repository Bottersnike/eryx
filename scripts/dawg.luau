--[=[
Original Algorithm:
  Steve Hanov, 2011. Released to the public domain.
  See http://stevehanov.ca/blog/index.php?id=115 for the accompanying article.

https://github.com/python/cpython/blob/main/Tools/unicode/dawg.py was
shamelessly used as a reference implementation.
]=]

export type Node = {
	id: number,
	final: boolean,
	edges: { [string]: Node },
	linearEdges: { Edge }?,
	_numReachableLinear: number?,
}

export type Edge = { label: string, child: Node }
type UncheckedNode = { parent: Node, letter: string, child: Node }

type DawgState = {
	previousWord: string,
	nextId: number,
	root: Node,
	uncheckedNodes: { UncheckedNode },
	minimizedNodes: { [string]: Node },
	data: { [string]: number },
	inverse: { [number]: string },
}

local function nodeSignature(node: Node): string
	local labels: { string } = {}
	for label in node.edges do
		table.insert(labels, label)
	end
	table.sort(labels)

	local parts: { string } = { if node.final then "1" else "0" }
	for _, label in labels do
		table.insert(parts, label)
		table.insert(parts, tostring(node.edges[label].id))
	end
	return table.concat(parts, "_")
end

local function makeNode(state: DawgState): Node
	local node: Node = {
		id = state.nextId,
		final = false,
		edges = {},
		linearEdges = nil,
		_numReachableLinear = nil,
	}
	state.nextId += 1
	return node
end

local function getNumReachableLinear(node: Node): number
	local cached = node._numReachableLinear
	if cached ~= nil then
		return cached
	end

	local count = 0
	if node.final then
		count += 1
	end
	if node.linearEdges then
		for _, edge in node.linearEdges do
			count += getNumReachableLinear(edge.child)
		end
	end
	node._numReachableLinear = count
	return count
end

local function numberAddBits(x: number, ...: number): number
	for _, bit in { ... } do
		if bit ~= 0 and bit ~= 1 then
			error("bit must be 0 or 1")
		end
		x = bit32.lshift(x, 1) + bit
	end
	return x
end

local function encodeVarIntUnsigned(i: number, out: { number }): number
	if i < 0 then
		error(`only positive numbers supported: {i}`)
	end
	local startLen = #out
	local value = i
	while true do
		local lowest7 = bit32.band(value, 0x7F)
		value = bit32.rshift(value, 7)
		if value ~= 0 then
			lowest7 = bit32.bor(lowest7, 0x80)
		end
		table.insert(out, lowest7)
		if value == 0 then
			break
		end
	end
	return #out - startLen
end

local function numberSplitBits1(x: number): (number, number)
	return bit32.rshift(x, 1), bit32.band(x, 1)
end

local function numberSplitBits2(x: number): (number, number, number)
	return bit32.rshift(x, 2), bit32.band(bit32.rshift(x, 1), 1), bit32.band(x, 1)
end

local function readByte(bytes: { number }, index0: number): number
	local value = bytes[index0 + 1]
	if value == nil then
		error(`byte index out of range: {index0}`)
	end
	return value
end

local function decodeVarIntUnsigned(bytes: { number }, index0: number): (number, number)
	local res = 0
	local shift = 0
	local index = index0
	while true do
		local byte = readByte(bytes, index)
		res += bit32.lshift(bit32.band(byte, 0x7F), shift)
		index += 1
		shift += 7
		if bit32.band(byte, 0x80) == 0 then
			return res, index
		end
	end
end

local function decodeNode(packed: { number }, nodeOffset: number): (number, number, number)
	local x, nextOffset = decodeVarIntUnsigned(packed, nodeOffset)
	local nodeCount, final = numberSplitBits1(x)
	return nodeCount, final, nextOffset
end

local function decodeEdge(
	packed: { number },
	edgeindex: number,
	prevChildOffset: number,
	offset: number
): (number, number, number, number)
	local x, nextOffset = decodeVarIntUnsigned(packed, offset)
	if x == 0 and edgeindex == 0 then
		error("decode past final node")
	end
	local childOffsetDiff, len1, lastEdge = numberSplitBits2(x)
	local childOffset = prevChildOffset + childOffsetDiff
	local size = 1
	local labelOffset = nextOffset
	if len1 == 0 then
		size, labelOffset = decodeVarIntUnsigned(packed, nextOffset)
	end
	return childOffset, lastEdge, size, labelOffset
end

local function matchEdge(packed: { number }, s: string, size: number, nodeOffset: number, stringPos0: number): boolean
	if size > 1 and stringPos0 + size > #s then
		return false
	end
	for i = 0, size - 1 do
		local packedByte = readByte(packed, nodeOffset + i)
		local sByte = string.byte(s, stringPos0 + i + 1)
		if sByte == nil then
			return false
		end
		if packedByte ~= sByte then
			if i > 0 then
				error("partial edge match")
			end
			return false
		end
	end
	return true
end

local Dawg = {}
Dawg.__index = Dawg

function Dawg.new(): DawgState
	local self = setmetatable({}, Dawg) :: unknown
	local state = self :: DawgState
	state.previousWord = ""
	state.nextId = 0
	state.uncheckedNodes = {}
	state.minimizedNodes = {}
	state.data = {}
	state.inverse = {}
	state.root = makeNode(state)
	return state
end

function Dawg._minimize(self: DawgState, downTo: number)
	for i = #self.uncheckedNodes, downTo + 1, -1 do
		local item = self.uncheckedNodes[i]
		local parent = item.parent
		local letter = item.letter
		local child = item.child
		local sig = nodeSignature(child)
		local canonical = self.minimizedNodes[sig]
		if canonical then
			parent.edges[letter] = canonical
		else
			self.minimizedNodes[sig] = child
		end
		table.remove(self.uncheckedNodes, i)
	end
end

function Dawg.insert(self: DawgState, word: string, value: number)
	for i = 1, #word do
		local ch = string.byte(word, i)
		if ch == nil or ch >= 128 then
			error("Use 7-bit ASCII characters only")
		end
	end

	if word <= self.previousWord then
		error("Words must be inserted in alphabetical order.")
	end
	if self.inverse[value] ~= nil then
		error(`value {value} is duplicate, got it for word {self.inverse[value]} and now {word}`)
	end

	local commonPrefix = 0
	local limit = math.min(#word, #self.previousWord)
	for i = 1, limit do
		if string.sub(word, i, i) ~= string.sub(self.previousWord, i, i) then
			break
		end
		commonPrefix += 1
	end

	Dawg._minimize(self, commonPrefix)
	self.data[word] = value
	self.inverse[value] = word

	local node = self.root
	if #self.uncheckedNodes ~= 0 then
		node = self.uncheckedNodes[#self.uncheckedNodes].child
	end
	for i = commonPrefix + 1, #word do
		local letter = string.sub(word, i, i)
		local nextNode = makeNode(self)
		node.edges[letter] = nextNode
		table.insert(self.uncheckedNodes, { parent = node, letter = letter, child = nextNode })
		node = nextNode
	end
	node.final = true
	self.previousWord = word
end

function Dawg.enumAllNodes(self: DawgState): { Node }
	local stack: { Node } = { self.root }
	local done: { [number]: boolean } = {}
	local out: { Node } = {}
	while #stack > 0 do
		local node = stack[#stack]
		stack[#stack] = nil
		if done[node.id] then
			continue
		end
		done[node.id] = true
		table.insert(out, node)
		local labels: { string } = {}
		for label in node.edges do
			table.insert(labels, label)
		end
		table.sort(labels)
		for _, label in labels do
			table.insert(stack, node.edges[label])
		end
	end
	return out
end

function Dawg._linearizeEdges(self: DawgState)
	local incomingCount: { [number]: number } = {}
	local nodes = Dawg.enumAllNodes(self)
	table.sort(nodes, function(a: Node, b: Node)
		return a.id < b.id
	end)

	for _, node in nodes do
		for _, child in node.edges do
			incomingCount[child.id] = (incomingCount[child.id] or 0) + 1
		end
	end

	for _, node in nodes do
		local labels: { string } = {}
		for label in node.edges do
			table.insert(labels, label)
		end
		table.sort(labels)

		local linearEdges: { Edge } = {}
		for _, label in labels do
			local child = node.edges[label]
			local s = label
			while true do
				local edgeCount = 0
				local nextLabel = ""
				local nextChild: Node? = nil
				for childLabel, grandchild in child.edges do
					edgeCount += 1
					nextLabel = childLabel
					nextChild = grandchild
				end
				if edgeCount == 1 and (incomingCount[child.id] or 0) == 1 and not child.final and nextChild ~= nil then
					s ..= nextLabel
					child = nextChild
				else
					break
				end
			end
			table.insert(linearEdges, { label = s, child = child })
		end
		node.linearEdges = linearEdges
		node._numReachableLinear = nil
	end
end

function Dawg._lookup(self: DawgState, word: string): number?
	local node = self.root
	local skipped = 0
	local index = 1
	while index <= #word do
		local matched = false
		for _, edge in (node.linearEdges or {}) do
			local label = edge.label
			local child = edge.child
			if string.sub(word, index, index) == string.sub(label, 1, 1) then
				if string.sub(word, index, index + #label - 1) == label then
					if node.final then
						skipped += 1
					end
					index += #label
					node = child
					matched = true
					break
				else
					return nil
				end
			end
			skipped += getNumReachableLinear(child)
		end
		if not matched then
			return nil
		end
	end
	return skipped
end

function Dawg._topologicalOrder(self: DawgState): ({ Node }, { number }, { [number]: number })
	local order: { Node } = {}
	local stack: { Node } = { self.root }
	local seen: { [number]: boolean } = {}
	while #stack > 0 do
		local node = stack[#stack]
		stack[#stack] = nil
		if seen[node.id] then
			continue
		end
		seen[node.id] = true
		table.insert(order, node)
		for _, edge in (node.linearEdges or {}) do
			table.insert(stack, edge.child)
		end
	end

	local incomingCount: { [number]: number } = {}
	for _, node in order do
		for _, edge in (node.linearEdges or {}) do
			local child = edge.child
			incomingCount[child.id] = (incomingCount[child.id] or 0) + 1
		end
	end

	local noIncoming: { Node } = {}
	table.insert(noIncoming, order[1])
	local topoorder: { Node } = {}
	local positions: { [number]: number } = {}
	while #noIncoming > 0 do
		local node = noIncoming[#noIncoming]
		noIncoming[#noIncoming] = nil
		table.insert(topoorder, node)
		positions[node.id] = #topoorder

		local edges = node.linearEdges or {}
		for i = #edges, 1, -1 do
			local child = edges[i].child
			local count = (incomingCount[child.id] or 0) - 1
			incomingCount[child.id] = count
			if count == 0 then
				table.insert(noIncoming, child :: Node)
			end
		end
	end

	for _, node in order do
		table.sort(node.linearEdges :: { Edge }, function(a: Edge, b: Edge)
			return (positions[a.child.id] or 0) < (positions[b.child.id] or 0)
		end)
	end

	getNumReachableLinear(topoorder[1])
	local dataCount = 0
	for _ in self.data do
		dataCount += 1
	end
	local linearData: { number } = table.create(dataCount, 0)
	local inverse: { [number]: number } = {}
	for word, value in self.data do
		local idx = Dawg._lookup(self, word)
		if idx == nil then
			error(`missing word after DAWG build: {word}`)
		end
		linearData[idx + 1] = value
		inverse[value] = idx
	end
	return topoorder, linearData, inverse
end

function Dawg.computePacked(self: DawgState, order: { Node }): { number }
	local function computeChunk(node: Node, offsets: { [number]: number }): { number }
		local result: { number } = {}
		local offset = offsets[node.id] or 0
		encodeVarIntUnsigned(numberAddBits(getNumReachableLinear(node), if node.final then 1 else 0), result)

		local linearEdges = node.linearEdges or {}
		if #linearEdges == 0 then
			if not node.final then
				error("non-final leaf")
			end
			encodeVarIntUnsigned(0, result)
		end

		local prevChildOffset = offset + #result
		for edgeIndex, edge in linearEdges do
			local label = edge.label
			local target = edge.child
			local childOffset = offsets[target.id] or 0
			local diff = childOffset - prevChildOffset
			local info = numberAddBits(diff, if #label == 1 then 1 else 0, if edgeIndex == #linearEdges then 1 else 0)
			if edgeIndex == 1 and info == 0 then
				error("invalid first edge info")
			end
			encodeVarIntUnsigned(info, result)
			prevChildOffset = childOffset
			if #label > 1 then
				encodeVarIntUnsigned(#label, result)
			end
			for i = 1, #label do
				local b = string.byte(label, i)
				if b == nil then
					error("invalid label byte")
				end
				table.insert(result, b)
			end
		end
		return result
	end

	local function computeNewOffsets(chunks: { { number } }, offsets: { [number]: number }): { [number]: number }?
		local newOffsets: { [number]: number } = {}
		local curr = 0
		local shouldContinue = false
		for i, node in order do
			if curr < (offsets[node.id] or 0) then
				shouldContinue = true
			end
			newOffsets[node.id] = curr
			curr += #chunks[i]
		end
		if not shouldContinue then
			return nil
		end
		return newOffsets
	end

	local offsets: { [number]: number } = {}
	for i, node in order do
		offsets[node.id] = (i - 1) * (2 ^ 30)
	end

	local chunks: { { number } } = {}
	local lastOffsets = offsets
	while true do
		chunks = {}
		for _, node in order do
			table.insert(chunks, computeChunk(node, offsets))
		end
		lastOffsets = offsets
		local nextOffsets = computeNewOffsets(chunks, offsets)
		if nextOffsets == nil then
			break
		end
		offsets = nextOffsets
	end

	local total: { number } = {}
	for i, node in order do
		local nodeOffsets = lastOffsets[node.id] or 0
		while #total < nodeOffsets do
			table.insert(total, 0)
		end
		if #total ~= nodeOffsets then
			error("offset mismatch while packing DAWG")
		end
		for _, b in chunks[i] do
			table.insert(total, b)
		end
	end
	return total
end

function Dawg.finish(self: DawgState): ({ number }, { number }, { [number]: number })
	if next(self.data) == nil then
		error("need at least one word in the dawg")
	end
	Dawg._minimize(self, 0)
	Dawg._linearizeEdges(self)
	local topoorder, linearData, inverse = Dawg._topologicalOrder(self)
	return Dawg.computePacked(self, topoorder), linearData, inverse
end

local function _lookupPacked(packed: { number }, s: string): number
	local stringPos0 = 0
	local nodeOffset = 0
	local skipped = 0
	while stringPos0 < #s do
		local _, final, edgeOffset = decodeNode(packed, nodeOffset)
		local prevChildOffset = edgeOffset
		local edgeindex = 0
		while true do
			local childOffset, lastEdge, size, labelOffset = decodeEdge(packed, edgeindex, prevChildOffset, edgeOffset)
			edgeindex += 1
			prevChildOffset = childOffset
			if matchEdge(packed, s, size, labelOffset, stringPos0) then
				if final == 1 then
					skipped += 1
				end
				stringPos0 += size
				nodeOffset = childOffset
				break
			end
			if lastEdge == 1 then
				error("lookup miss")
			end
			local descendantCount = decodeNode(packed, childOffset)
			skipped += descendantCount
			edgeOffset = labelOffset + size
		end
	end
	local _, final = decodeNode(packed, nodeOffset)
	if final == 1 then
		return skipped
	end
	error("lookup miss")
end

local function lookup(packed: { number }, data: { number }, s: string): number
	return data[_lookupPacked(packed, s) + 1]
end

local function _inverseLookup(packed: { number }, pos: number): string
	local out: { number } = {}
	local nodeOffset = 0
	local currentPos = pos
	while true do
		local _, final, edgeOffset = decodeNode(packed, nodeOffset)
		if final == 1 then
			if currentPos == 0 then
				local chars: { string } = {}
				for _, b in out do
					table.insert(chars, string.char(b))
				end
				return table.concat(chars)
			end
			currentPos -= 1
		end
		local prevChildOffset5 = edgeOffset
		local edgeindex = 0
		while true do
			local childOffset, lastEdge, size, labelOffset = decodeEdge(packed, edgeindex, prevChildOffset5, edgeOffset)
			edgeindex += 1
			prevChildOffset5 = childOffset
			local descendantCount = decodeNode(packed, childOffset)
			local nextPos = currentPos - descendantCount
			if nextPos < 0 then
				for i = 0, size - 1 do
					table.insert(out, readByte(packed, labelOffset + i))
				end
				nodeOffset = childOffset
				break
			end
			if lastEdge == 1 then
				error("inverse lookup miss")
			end
			currentPos = nextPos
			edgeOffset = labelOffset + size
		end
	end
end

local function inverseLookup(packed: { number }, inverse: { [number]: number }, value: number): string
	local pos = inverse[value]
	if pos == nil then
		error(`value not found in inverse table: {value}`)
	end
	return _inverseLookup(packed, pos)
end

local function buildCompressionDawg(ucdata: { { string | number } }): ({ number }, { number })
	table.sort(ucdata, function(a, b)
		return (a[1] :: string) < (b[1] :: string)
	end)

	local dawgState = Dawg.new()
	for _, entry in ucdata do
		Dawg.insert(dawgState, entry[1] :: string, entry[2] :: number)
	end

	local packed, posToCodepoint, reversedict = Dawg.finish(dawgState)
	for _, entry in ucdata do
		local name = entry[1] :: string
		local value = entry[2] :: number
		if lookup(packed, posToCodepoint, name) ~= value then
			error(`dawg lookup check failed for '{name}'`)
		end
		if inverseLookup(packed, reversedict, value) ~= name then
			error(`dawg inverse lookup check failed for '{name}'`)
		end
	end

	return packed, posToCodepoint
end

return {
	Dawg = Dawg,
	buildCompressionDawg = buildCompressionDawg,
	lookup = lookup,
	inverseLookup = inverseLookup,
}
