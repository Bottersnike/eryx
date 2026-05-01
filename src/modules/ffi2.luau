--[=[
	:::warning
	This library is not finished, and should be avoided for now
	:::
]=]

local ffi = {}

export type CallingConvention = "default" | "cdecl" | "stdcall" | "fastcall_ms" | "fastcall_gnu"

export type Type = {
	size: (self: Type) -> number,
	align: (self: Type) -> number,
	name: (self: Type) -> string,
	offsetOf: (self: Type, field: string) -> number,
}

export type Data = {
	read: (self: Data) -> any,
	write: (self: Data, value: any) -> (),
	type: (self: Data) -> Type,
	bytes: (self: Data) -> string,
	buffer: (self: Data) -> buffer,
	ptr: (self: Data) -> Data,
	deref: (self: Data) -> Data,
	offset: (self: Data, n: number) -> Data,
	isNull: (self: Data) -> boolean,
	length: (self: Data) -> number,
	get: (self: Data, index: number) -> Data,
	set: (self: Data, index: number, value: any) -> (),
	asarray: (self: Data) -> { any },
	asdict: (self: Data) -> { [string]: any },
	getField: (self: Data, name: string) -> Data,
	setField: (self: Data, name: string, value: any) -> (),
}

export type FunctionData = setmetatable<Data, {
	__call: (self: FunctionData, ...any) -> Data,
}>

export type Library = {
	get: (self: Library, name: string, ty: Type) -> Data,
	close: (self: Library) -> (),
	isOpen: (self: Library) -> boolean,
}

export type StructFieldSpec = { [number]: string | Type, align: number? }
export type StructOptions = {
	name: string?,
	pack: number?,
}

export type FunctionOptions = {
	convention: CallingConvention?,
	varargs: boolean?,
}

export type CNamespace = {
	new: (ty: Type, init: any?) -> Data,
	ptr: (ty: Type) -> Type,
	array: (element: Type, length: number) -> Type,
	string: (value: string) -> Data,
	func: (result: Type, params: { Type }, options: FunctionOptions | CallingConvention?) -> Type,
	struct: (fields: { StructFieldSpec }, options: StructOptions | string?) -> Type,
	union: (fields: { StructFieldSpec }, options: { name: string? } | string?) -> Type,
	null: (ptrType: Type) -> Data,
	cast: (value: Data, ty: Type) -> Data,

	void: Type,

	int8: Type,
	uint8: Type,
	short: Type,
	ushort: Type,
	int16: Type,
	uint16: Type,
	schar: Type,
	uchar: Type,
	byte: Type,

	int: Type,
	uint: Type,
	long: Type,
	ulong: Type,
	intptr_t: Type,
	uintptr_t: Type,
	size_t: Type,

	int32: Type,
	uint32: Type,
	int64: Type,
	uint64: Type,
	float: Type,
	double: Type,
	char: Type,
}

export type Module = {
	open: (path: string) -> Library,
	process: Library,
	c: CNamespace,
}

return (ffi :: any) :: Module
