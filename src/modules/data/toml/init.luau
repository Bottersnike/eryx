local encoder = require("@self/encoder")
local decoder = require("@self/decoder")
local cst = require("@self/cst")

local toml = {}

export type EncodeOptions = {
	sortKeys: boolean?,
}

function toml.encode(value: any, options: EncodeOptions?): string
	return encoder.encode(value, options)
end

function toml.decode(source: string): { [string]: any }
	return decoder.decode(source)
end

function toml.parse(source: string): { [string]: any }
	return decoder.parse(source)
end

function toml.decodeCST(source: string): any
	local decoded, cstData = decoder.decodeWithCST(source)
	return cst.fromDecoded(source, decoded, cstData)
end

function toml.newCST(): any
	return cst.newEmpty()
end

function toml.isCSTObject(value: any): boolean
	return cst.isCSTObject(value)
end

function toml.cstToTable(value: any): { [any]: any }
	return cst.toTable(value)
end

function toml.cstSetStyle(value: any, path: any, style: string)
	cst.setStyle(value, path, style)
end

function toml.cstGetStyle(value: any, path: any): string?
	return cst.getStyle(value, path)
end

function toml.cstSetComment(value: any, path: any, comment: string, where: string?)
	cst.setComment(value, path, comment, where)
end

function toml.cstGetComment(value: any, path: any, where: string?): string?
	return cst.getComment(value, path, where)
end

return toml
