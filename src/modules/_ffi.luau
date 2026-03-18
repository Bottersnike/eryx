--[=[
	Foreign Function Interface for Luau.

	Loads native shared libraries (DLLs) at runtime and invokes their
	exported C functions directly from Luau.  Values are marshalled through
	typed [[ForeignValue]] wrappers to ensure correct ABI alignment.

	:::caution
	This is a **low-level** API.  Incorrect type declarations or pointer
	arithmetic will crash the process - there are no safety nets once you
	cross the FFI boundary.
	:::

	```luau
	local ffi = require("@eryx/_ffi")

	local user32 = ffi.loadLibrary("user32.dll")
	local msgBox = user32:GetFunction(
		"MessageBoxA",
		ffi.i32,
		{ ffi.u64, ffi.str:Pointer(), ffi.str:Pointer(), ffi.u32 }
	)

	local title = ffi.str("Hello from Luau!")
	local body  = ffi.str("It works!")
	msgBox(ffi.u64(0), body:Pointer(), title:Pointer(), ffi.u32(0))
	```
]=]

--[=[
	A loaded native shared library (DLL).

	Obtained via [[loadLibrary]].  The library remains loaded until the
	value is garbage-collected.
]=]
export type ForeignLibrary = {
	--[=[
		Looks up an exported function by name or ordinal and returns a
		callable [[ForeignFunction]].

		@param name The exported symbol name, or a numeric ordinal.
		@param retType The return type of the function.
		@param argTypes An array of argument types, in order.
		@return ForeignFunction -- A callable wrapper for the native function.
	]=]
	GetFunction: (
		self: ForeignLibrary,
		name: string | number,
		retType: ForeignType,
		argTypes: { ForeignType }
	) -> ForeignFunction,
}

--[=[
	A resolved native function that can be called from Luau.

	Calling the function with the correct number and types of arguments
	returns a [[ForeignValue]] containing the return value.
]=]
export type ForeignFunction = {
	--[=[
		Invokes the native function.

		Arguments may be [[ForeignValue]] userdata *or* plain Luau values
		that are automatically converted according to the declared argument
		types.

		@param ... Arguments matching the declared parameter types.
		@return ForeignValue -- The return value wrapped in a ForeignValue.
	]=]
	__call: (self: ForeignFunction, ...any) -> ForeignValue,
}

--[=[
	A C type descriptor (e.g. `u32`, `str`, `i64`).

	Type objects are callable - invoking one creates a new [[ForeignValue]]
	of that type, optionally initialised with a value.

	```luau
	local n = ffi.u32(42)   -- create a u32 with value 42
	local s = ffi.str("hi") -- create a string value
	```
]=]
export type ForeignType = {
	--[=[
		Returns a new [[ForeignType]] representing a pointer to this type.

		Can be chained: `ffi.u32:pointer():pointer()` yields `u32**`.

		@return ForeignType -- The pointer-to type.
	]=]
	Pointer: (self: ForeignType) -> ForeignType,

	--[=[
		Creates a new [[ForeignValue]] of this type.

		If `initialValue` is provided it is used to initialise the value;
		otherwise the memory is zero-filled.

		@param initialValue An optional initial value.
		@return ForeignValue -- The newly created value.
	]=]
	__call: (self: ForeignType, initialValue: any?) -> ForeignValue,
}

--[=[
	A boxed C value that can be read, written, and passed across the FFI
	boundary.

	Pointer values can be dereferenced with [[ForeignValue.get|get()]] or
	turned into a pointer with [[ForeignValue.pointer|pointer()]].
]=]
export type ForeignValue = {
	--[=[
		Reads the value.

		For scalar types this returns the corresponding Luau primitive
		(number or string).  For pointer types this dereferences the
		pointer and returns a new [[ForeignValue]] one indirection level
		lower.

		@param dereference For pointer values, pass `false` to get the
			raw numeric address instead of dereferencing.  Defaults to
			`true`.
		@return any -- The Luau value, or a new ForeignValue for pointers.
	]=]
	Get: (self: ForeignValue, dereference: boolean?) -> any,

	--[=[
		Overwrites the stored value.

		Only valid for non-pointer scalar types.  Returns `self` for
		method chaining.

		@param value The new value to store.
		@return ForeignValue -- self.
	]=]
	Set: (self: ForeignValue, value: any) -> ForeignValue,

	--[=[
		Returns a new [[ForeignValue]] that is a pointer to this value.

		The returned pointer does **not** own the memory - the original
		value must be kept alive for the pointer to remain valid.

		@return ForeignValue -- A pointer to this value.
	]=]
	Pointer: (self: ForeignValue) -> ForeignValue,
}

local _ffi = {}

--[=[
	Loads a native shared library (DLL) by file name or path.

	The library is kept loaded until the returned [[ForeignLibrary]] is
	garbage-collected.

	```luau
	local kernel32 = _ffi.loadLibrary("kernel32.dll")
	```

	@param path The file name or full path of the library to load.
	@return ForeignLibrary -- A handle to the loaded library.
]=]
function _ffi.loadLibrary(path: string): ForeignLibrary
	return nil :: any
end

--- The `void` type (zero-sized, used only as a return type).
_ffi.void = nil :: ForeignType
--- Unsigned char (`unsigned char`, 1 byte).
_ffi["unsigned char"] = nil :: ForeignType
--- Signed char (`char`, 1 byte).
_ffi.char = nil :: ForeignType
--- Null-terminated C string (`const char*`).
_ffi.str = nil :: ForeignType
--- Unsigned 8-bit integer.
_ffi.u8  = nil :: ForeignType
--- Unsigned 16-bit integer.
_ffi.u16 = nil :: ForeignType
--- Unsigned 32-bit integer.
_ffi.u32 = nil :: ForeignType
--- Unsigned 64-bit integer.
_ffi.u64 = nil :: ForeignType
--- Signed 8-bit integer.
_ffi.i8  = nil :: ForeignType
--- Signed 16-bit integer.
_ffi.i16 = nil :: ForeignType
--- Signed 32-bit integer.
_ffi.i32 = nil :: ForeignType
--- Signed 64-bit integer.
_ffi.i64 = nil :: ForeignType

return _ffi
