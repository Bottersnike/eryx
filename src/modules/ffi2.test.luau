local ffi = require("@eryx/ffi2")
local os = require("@eryx/os")
local test = require("@eryx/test")

local suite = test.Suite.new("ffi2")

local platform = os.platform()
local dllPath = "src/modules/ffi2.test.dll"

local c = ffi.c
local lib

local Point = c.struct({
	{ "x", c.int32 },
	{ "y", c.int32 },
}, { name = "Point" })

local Pair = c.struct({
	{ "a", c.int32 },
	{ "b", c.int32 },
}, { name = "Pair" })

local Mixed = c.struct({
	{ "tag", c.uint8 },
	{ "count", c.int32 },
	{ "value", c.double },
}, { name = "Mixed" })

local Vec3 = c.struct({
	{ "x", c.float },
	{ "y", c.float },
	{ "z", c.float },
}, { name = "Vec3" })

local IntOrFloat = c.union({
	{ "i", c.int32 },
	{ "f", c.float },
}, { name = "IntOrFloat" })

local Packed = c.struct({
	{ "a", c.uint8 },
	{ "b", c.uint32 },
	{ "c", c.uint16 },
}, { name = "Packed", pack = 1 })

local addI32
local addU64
local addDouble
local boolNot
local noop
local writeI32
local readI32
local swapI32
local sumI32Array
local strlenAscii
local getStaticString
local streq
local makePair
local addPairsByValue
local makeMixed
local makeVec3
local makeUnionI32
local makeUnionFloat
local makePacked
local sumPairByValue
local mixedScoreByValue
local dotVec3ByValue
local unionReadI32
local unionReadFloat
local sumPackedByValue
local sizeofUnionIntOrFloat
local sumVarargsI32
local sumVarargsI64
local sumVarargsDouble
local sumVarargsStrlen
local captureVarargsI32_4
local debugVarargCount
local debugVarargI0
local debugVarargI1
local debugVarargI2
local debugVarargI3
local sizeofPacked
local offsetofPackedB
local sizeofPair
local sizeofMixed
local offsetofMixedTag
local offsetofMixedCount
local offsetofMixedValue
local allocBytes
local freeBytes
local allocI32
local freeI32

suite.beforeAll = function()
	test.skipIf(platform ~= "windows", "ffi2.test.dll is only built for Windows right now")

	lib = ffi.open(dllPath)

	addI32 = lib:get("ffi_add_i32", c.func(c.int32, { c.int32, c.int32 }))
	addU64 = lib:get("ffi_add_u64", c.func(c.uint64, { c.uint64, c.uint64 }))
	addDouble = lib:get("ffi_add_double", c.func(c.double, { c.double, c.double }))
	boolNot = lib:get("ffi_bool_not", c.func(c.int32, { c.int32 }))
	noop = lib:get("ffi_noop", c.func(c.void, {}))

	writeI32 = lib:get("ffi_write_i32", c.func(c.void, { c.ptr(c.int32), c.int32 }))
	readI32 = lib:get("ffi_read_i32", c.func(c.int32, { c.ptr(c.int32) }))
	swapI32 = lib:get("ffi_swap_i32", c.func(c.void, { c.ptr(c.int32), c.ptr(c.int32) }))
	sumI32Array = lib:get("ffi_sum_i32_array", c.func(c.size_t, { c.ptr(c.int32), c.size_t }))

	strlenAscii = lib:get("ffi_strlen_ascii", c.func(c.size_t, { c.ptr(c.char) }))
	getStaticString = lib:get("ffi_get_static_string", c.func(c.ptr(c.char), {}))
	streq = lib:get("ffi_streq", c.func(c.int32, { c.ptr(c.char), c.ptr(c.char) }))

	makePair = lib:get("ffi_make_pair", c.func(Pair, { c.int32, c.int32 }))
	addPairsByValue = lib:get("ffi_add_pairs_by_value", c.func(Pair, { Pair, Pair }))
	makeMixed = lib:get("ffi_make_mixed", c.func(Mixed, { c.uint8, c.int32, c.double }))
	makeVec3 = lib:get("ffi_make_vec3", c.func(Vec3, { c.float, c.float, c.float }))
	makeUnionI32 = lib:get("ffi_make_union_i32", c.func(IntOrFloat, { c.int32 }))
	makeUnionFloat = lib:get("ffi_make_union_float", c.func(IntOrFloat, { c.float }))
	makePacked = lib:get("ffi_make_packed", c.func(Packed, { c.uint8, c.uint32, c.uint16 }))
	sumPairByValue = lib:get("ffi_sum_pair_by_value", c.func(c.int32, { Pair }))
	mixedScoreByValue = lib:get("ffi_mixed_score_by_value", c.func(c.double, { Mixed }))
	dotVec3ByValue = lib:get("ffi_dot_vec3_by_value", c.func(c.float, { Vec3, Vec3 }))
	unionReadI32 = lib:get("ffi_union_read_i32", c.func(c.int32, { IntOrFloat }))
	unionReadFloat = lib:get("ffi_union_read_float", c.func(c.float, { IntOrFloat }))
	sumPackedByValue = lib:get("ffi_sum_packed_by_value", c.func(c.uint32, { Packed }))
	sizeofUnionIntOrFloat = lib:get("ffi_sizeof_union_int_or_float", c.func(c.size_t, {}))
	sumVarargsI32 = lib:get("ffi_sum_varargs_i32", c.func(c.int32, { c.int32 }, { varargs = true }))
	sumVarargsI64 = lib:get("ffi_sum_varargs_i64", c.func(c.int64, { c.int32 }, { varargs = true }))
	sumVarargsDouble =
		lib:get("ffi_sum_varargs_double", c.func(c.double, { c.int32 }, { varargs = true }))
	sumVarargsStrlen =
		lib:get("ffi_sum_varargs_strlen", c.func(c.size_t, { c.int32 }, { varargs = true }))
	captureVarargsI32_4 =
		lib:get("ffi_capture_varargs_i32_4", c.func(c.void, { c.int32 }, { varargs = true }))
	debugVarargCount = lib:get("ffi_debug_vararg_count", c.int32)
	debugVarargI0 = lib:get("ffi_debug_vararg_i0", c.int32)
	debugVarargI1 = lib:get("ffi_debug_vararg_i1", c.int32)
	debugVarargI2 = lib:get("ffi_debug_vararg_i2", c.int32)
	debugVarargI3 = lib:get("ffi_debug_vararg_i3", c.int32)

	sizeofPacked = lib:get("ffi_sizeof_packed", c.func(c.size_t, {}))
	offsetofPackedB = lib:get("ffi_offsetof_packed_b", c.func(c.size_t, {}))
	sizeofPair = lib:get("ffi_sizeof_pair", c.func(c.size_t, {}))
	sizeofMixed = lib:get("ffi_sizeof_mixed", c.func(c.size_t, {}))
	offsetofMixedTag = lib:get("ffi_offsetof_mixed_tag", c.func(c.size_t, {}))
	offsetofMixedCount = lib:get("ffi_offsetof_mixed_count", c.func(c.size_t, {}))
	offsetofMixedValue = lib:get("ffi_offsetof_mixed_value", c.func(c.size_t, {}))

	allocBytes = lib:get("ffi_alloc_bytes", c.func(c.ptr(c.void), { c.size_t }))
	freeBytes = lib:get("ffi_free_bytes", c.func(c.void, { c.ptr(c.void) }))
	allocI32 = lib:get("ffi_alloc_i32", c.func(c.ptr(c.int32), { c.int32 }))
	freeI32 = lib:get("ffi_free_i32", c.func(c.void, { c.ptr(c.int32) }))
end

suite:test("open: process library exists", function()
	test.expect(ffi.process:isOpen()):toBeTrue()
end)

suite:test("type introspection: primitive, pointer, array, struct", function()
	test.expect(c.int32:name()):toBe("int32")
	test.expect(c.int32:size()):toBe(4i)
	test.expect(c.int32:align()):toBe(4i)

	test.expect(c.ptr(c.int32):name()):toContain("int32*")
	test.expect(c.array(c.char, 4):name()):toContain("char[4]")
	test.expect(Pair:name()):toBe("Pair")
	test.expect(Pair:offsetOf("a")):toBe(0i)
	test.expect(Pair:offsetOf("b")):toBe(4i)
	test.expect(IntOrFloat:offsetOf("i")):toBe(0i)
	test.expect(IntOrFloat:offsetOf("f")):toBe(0i)
end)

suite:test("primitive aliases: common aliases have sane sizes", function()
	test.expect(c.byte:size()):toBe(1i)
	test.expect(c.uchar:size()):toBe(1i)
	test.expect(c.short:size()):toBe(2i)
	test.expect(c.ushort:size()):toBe(2i)
	test.expect(c.int:size()):toBe(c.int32:size())
	test.expect(c.uint:size()):toBe(c.uint32:size())
	test.expect(c.size_t:size()):toBe(c.uintptr_t:size())
	test.expect(c.intptr_t:size()):toBe(c.ptr(c.void):size())
end)

suite:test("tostring: type data and library are informative", function()
	local value = c.new(c.int32, 7)
	local localLib = ffi.open(dllPath)

	test.expect(tostring(c.int32)):toContain("Type<")
	test.expect(tostring(c.int32)):toContain("int32")
	test.expect(tostring(value)):toContain("Data<")
	test.expect(tostring(value)):toContain("int32")
	test.expect(tostring(localLib)):toContain("Library(")
	test.expect(tostring(localLib)):toContain("open")

	localLib:close()
	test.expect(tostring(localLib)):toContain("closed")
end)

suite:test("primitive data: read write type bytes buffer", function()
	local value = c.new(c.int32, 123)

	test.expect(value:read()):toBe(123)
	test.expect(value:type():name()):toBe("int32")
	test.expect(value:bytes()):toBeType("string")
	test.expect(#value:bytes()):toBe(4)
	test.expect(value:buffer()):toBeType("buffer")

	value:write(456)
	test.expect(value:read()):toBe(456)
end)

suite:test("casts: primitive conversions and array-to-pointer", function()
	local i = c.new(c.int32, -12)
	local d = c.cast(i, c.double)
	test.expect(d:read()):toBeCloseTo(-12)

	local pi = c.cast(c.new(c.double, 12.75), c.int32)
	test.expect(pi:read()):toBe(12)

	local arr = c.new(c.array(c.int32, 2), { 44, 55 })
	local p = c.cast(arr, c.ptr(c.int32))
	test.expect(p:deref():read()):toBe(44)
end)

suite:test("exported data symbols: primitives pointer and struct", function()
	local i32Const = lib:get("ffi_i32_constant", c.int32)
	local u64Const = lib:get("ffi_u64_constant", c.uint64)
	local dblConst = lib:get("ffi_double_constant", c.double)
	local strConst = lib:get("ffi_string_constant", c.ptr(c.char))
	local pointConst = lib:get("ffi_point_constant", Point)

	test.expect(i32Const:read()):toBe(123456)
	test.expect(u64Const:read()):toBe(0x1122334455667788i)
	test.expect(dblConst:read()):toBeCloseTo(3.141592653589793)
	test.expect(strlenAscii(strConst):read()):toBe(24i)

	local point = pointConst:asdict()
	test.expect(point.x, point.y):toBe(10, 20)
end)

suite:test("pointer lifetime: pointer chains keep owned data alive", function()
	local x = c.new(c.int32, 123)
	local p = x:ptr()
	local pp = p:ptr()

	x = nil
	p = nil
	collectgarbage("collect")

	test.expect(pp:deref():deref():read()):toBe(123)
end)

suite:test("pointer writes: data nil and raw address", function()
	local x = c.new(c.int32, 321)
	local holder = c.new(c.ptr(c.int32))
	local addr = x:ptr():read()

	holder:write(x:ptr())
	test.expect(holder:isNull()):toBeFalse()
	test.expect(holder:deref():read()):toBe(321)

	holder:write(nil)
	test.expect(holder:isNull()):toBeTrue()

	holder:write(addr)
	test.expect(holder:deref():read()):toBe(321)
end)

suite:test("array: init get set length asarray and whole-number length", function()
	local arr = c.new(c.array(c.int32, 3), { 10, 20, 30 })

	test.expect(arr:length()):toBe(3i)
	test.expect(arr:get(0):read()):toBe(10)
	test.expect(arr:get(1):read()):toBe(20)
	test.expect(arr:get(2):read()):toBe(30)

	arr:set(1, 99)
	test.expect(arr:get(1):read()):toBe(99)

	local asArray = arr:asarray()
	test.expect(asArray):toBeType("table")
	test.expect(asArray[1], asArray[2], asArray[3]):toBe(10, 99, 30)

	local arr2 = c.new(c.array(c.int32, 3), { 1, 2, 3 })
	test.expect(arr2:length()):toBe(3i)
end)

suite:test("array and pointer APIs accept whole numbers", function()
	local arr = c.new(c.array(c.int32, 3.0), { 10, 20, 30 })
	local p = arr:ptr()

	test.expect(arr:get(1.0):read()):toBe(20)
	arr:set(2.0, 77)
	test.expect(arr:get(2):read()):toBe(77)
	test.expect(p:offset(1.0):deref():read()):toBe(20)
end)

suite:test("array lifetime: element view keeps backing storage alive", function()
	local arr = c.new(c.array(c.int32, 3), { 10, 20, 30 })
	local elem = arr:get(1)

	arr = nil
	collectgarbage("collect")

	test.expect(elem:read()):toBe(20)
end)

suite:test("string helper and string interop", function()
	local s = c.string("hello")
	test.expect(s:length()):toBe(6i)
	test.expect(s:get(0):read()):toBe(string.byte("h"))
	test.expect(s:get(4):read()):toBe(string.byte("o"))
	test.expect(s:get(5):read()):toBe(0)
	test.expect(strlenAscii(s):read()):toBe(5i)
	test.expect(streq("hello", s):read()):toBe(1)
	test.expect(streq("hello", "world"):read()):toBe(0)
end)

suite:test("struct: init fields asdict bytes buffer", function()
	local v = c.new(Vec3, { x = 1.5, y = 2.5, z = 3.5 })
	test.expect(v:getField("x"):read()):toBeCloseTo(1.5)
	test.expect(v:getField("y"):read()):toBeCloseTo(2.5)
	test.expect(v:getField("z"):read()):toBeCloseTo(3.5)

	v:setField("x", 4.5)
	test.expect(v:getField("x"):read()):toBeCloseTo(4.5)

	local asDict = v:asdict()
	test.expect(asDict):toBeType("table")
	test.expect(asDict.x):toBeCloseTo(4.5)
	test.expect(asDict.y):toBeCloseTo(2.5)
	test.expect(asDict.z):toBeCloseTo(3.5)

	test.expect(v:bytes()):toBeType("string")
	test.expect(v:buffer()):toBeType("buffer")
end)

suite:test("struct: nested aggregate init and asdict", function()
	local Nested = c.struct({
		{ "pair", Pair },
		{ "ids", c.array(c.int32, 2) },
	}, { name = "Nested" })

	local nested = c.new(Nested, {
		pair = { a = 11, b = 22 },
		ids = { 33, 44 },
	})

	test.expect(nested:getField("pair"):getField("a"):read()):toBe(11)
	test.expect(nested:getField("pair"):getField("b"):read()):toBe(22)
	test.expect(nested:getField("ids"):get(0):read()):toBe(33)
	test.expect(nested:getField("ids"):get(1):read()):toBe(44)

	local asDict = nested:asdict()
	test.expect(asDict.pair.a, asDict.pair.b):toBe(11, 22)
	test.expect(asDict.ids[1], asDict.ids[2]):toBe(33, 44)
end)

suite:test("union: init fields asdict and native roundtrip", function()
	local u = c.new(IntOrFloat, { i = 1065353216 })
	test.expect(u:getField("i"):read()):toBe(1065353216)
	test.expect(u:getField("f"):read()):toBeCloseTo(1.0)

	u:setField("f", 2.5)
	test.expect(u:getField("f"):read()):toBeCloseTo(2.5)
	test.expect(unionReadFloat(u):read()):toBeCloseTo(2.5)

	local fromInt = makeUnionI32(42)
	local fromFloat = makeUnionFloat(3.5)
	test.expect(unionReadI32(fromInt):read()):toBe(42)
	test.expect(unionReadFloat(fromFloat):read()):toBeCloseTo(3.5)

	local asDict = fromInt:asdict()
	test.expect(asDict):toBeType("table")
	test.expect(IntOrFloat:size()):toBe(sizeofUnionIntOrFloat():read())
end)

suite:test("struct layout matches native code", function()
	test.expect(Packed:size()):toBe(sizeofPacked():read())
	test.expect(Packed:offsetOf("b")):toBe(offsetofPackedB():read())
	test.expect(Pair:size()):toBe(sizeofPair():read())
	test.expect(Mixed:size()):toBe(sizeofMixed():read())
	test.expect(Mixed:offsetOf("tag")):toBe(offsetofMixedTag():read())
	test.expect(Mixed:offsetOf("count")):toBe(offsetofMixedCount():read())
	test.expect(Mixed:offsetOf("value")):toBe(offsetofMixedValue():read())
end)

suite:test("function type options: conventions are named and validated", function()
	local f1 = c.func(c.int32, { c.int32 }, "cdecl")
	local f2 = c.func(c.int32, { c.int32 }, { convention = "stdcall" })

	test.expect(f1:name()):toContain("cdecl")
	test.expect(f2:name()):toContain("stdcall")

	test.expect(function()
		c.func(c.int32, { c.int32 }, "definitely_not_real")
	end):toError("unknown calling convention")

	test.expect(function()
		c.func(c.int32, { c.int32 }, { convention = false })
	end):toError("must be a string")
end)

suite:test("pointer bounds and null deref errors", function()
	local arr = c.new(c.array(c.int32, 3), { 10, 20, 30 })
	local p = arr:ptr()

	test.expect(p:deref():read()):toBe(10)
	test.expect(p:offset(1):deref():read()):toBe(20)
	test.expect(p:offset(2):deref():read()):toBe(30)
	test.expect(function()
		p:offset(3)
	end):toError("out of bounds")

	local nullPtr = c.null(c.ptr(c.int32))
	test.expect(nullPtr:isNull()):toBeTrue()
	test.expect(function()
		nullPtr:deref()
	end):toError("null pointer")
end)

suite:test("function calls: primitive args and returns", function()
	test.expect(addI32(-123, 23):read()):toBe(-100)
	test.expect(addU64(9, 33):read()):toBe(42i)
	test.expect(addDouble(1.25, 2.5):read()):toBeCloseTo(3.75)
	test.expect(boolNot(0):read()):toBe(1)
	test.expect(boolNot(7):read()):toBe(0)
	test.expect(noop()):toBeNil()
end)

suite:test("function calls: varargs with ints doubles and strings", function()
	captureVarargsI32_4(4, 10, 20, 30, 40)
	test.expect(debugVarargCount:read()):toBe(4)
	test.expect(debugVarargI0:read(), debugVarargI1:read(), debugVarargI2:read(), debugVarargI3:read()):toBe(
		10,
		20,
		30,
		40
	)

	test.expect(sumVarargsI32(4, 10, 20, 30, 40):read()):toBe(100)
	test.expect(sumVarargsDouble(3, 1.25, 2.5, 4.0):read()):toBeCloseTo(7.75)
	test.expect(sumVarargsStrlen(3, "ab", "cde", "f"):read()):toBe(6i)

	local bigA = c.new(c.int64, 10000000000)
	local bigB = c.new(c.int64, 20000000000)
	test.expect(sumVarargsI64(2, bigA, bigB):read()):toBe(30000000000)
end)

suite:test("function calls: pointer arguments and outputs", function()
	local value = c.new(c.int32, 5)
	writeI32(value:ptr(), 99)
	test.expect(value:read()):toBe(99)
	test.expect(readI32(value:ptr()):read()):toBe(99)
	test.expect(readI32(c.null(c.ptr(c.int32))):read()):toBe(-1)

	local a = c.new(c.int32, 10)
	local b = c.new(c.int32, 20)
	swapI32(a:ptr(), b:ptr())
	test.expect(a:read(), b:read()):toBe(20, 10)
end)

suite:test("function calls: array decays to pointer argument", function()
	local arr = c.new(c.array(c.int32, 4), { 10, 20, 30, 40 })
	test.expect(sumI32Array(arr, 4):read()):toBe(100i)
end)

suite:test("function calls: pointer return", function()
	local p = getStaticString()

	test.expect(p:isNull()):toBeFalse()
	test.expect(strlenAscii(p):read()):toBe(27i)
	test.expect(p:deref():read()):toBe(string.byte("s"))
end)

suite:test("function calls: struct by value", function()
	local pair = c.new(Pair, { a = 12, b = 30 })
	local mixed = c.new(Mixed, { tag = 2, count = 7, value = 1.5 })
	local v1 = c.new(Vec3, { x = 1, y = 2, z = 3 })
	local v2 = c.new(Vec3, { x = 4, y = 5, z = 6 })
	local packed = c.new(Packed, { a = 1, b = 20, c = 3 })

	test.expect(sumPairByValue(pair):read()):toBe(42)
	test.expect(mixedScoreByValue(mixed):read()):toBeCloseTo(10.5)
	test.expect(dotVec3ByValue(v1, v2):read()):toBeCloseTo(32)
	test.expect(sumPackedByValue(packed):read()):toBe(24)
end)

suite:test("function calls: struct returns", function()
	local pair = makePair(7, 35)
	local pairSum = addPairsByValue(c.new(Pair, { a = 1, b = 2 }), c.new(Pair, { a = 3, b = 4 }))
	local mixed = makeMixed(2, 7, 1.5)
	local vec3 = makeVec3(1, 2, 3)
	local packed = makePacked(1, 20, 3)

	test.expect(pair:getField("a"):read(), pair:getField("b"):read()):toBe(7, 35)
	test.expect(pair:asdict().a, pair:asdict().b):toBe(7, 35)

	test.expect(pairSum:getField("a"):read(), pairSum:getField("b"):read()):toBe(4, 6)

	test.expect(mixed:getField("tag"):read()):toBe(2)
	test.expect(mixed:getField("count"):read()):toBe(7)
	test.expect(mixed:getField("value"):read()):toBeCloseTo(1.5)

	test.expect(vec3:getField("x"):read()):toBeCloseTo(1)
	test.expect(vec3:getField("y"):read()):toBeCloseTo(2)
	test.expect(vec3:getField("z"):read()):toBeCloseTo(3)

	test.expect(packed:getField("a"):read()):toBe(1)
	test.expect(packed:getField("b"):read()):toBe(20)
	test.expect(packed:getField("c"):read()):toBe(3)
end)

suite:test("function signatures: top-level array params decay like C pointers", function()
	local sumArrayByArraySig =
		lib:get("ffi_sum_i32_array", c.func(c.size_t, { c.array(c.int32, 4), c.size_t }))
	local strlenByArraySig =
		lib:get("ffi_strlen_ascii", c.func(c.size_t, { c.array(c.char, 6) }))

	local arr = c.new(c.array(c.int32, 4), { 10, 20, 30, 40 })
	test.expect(sumArrayByArraySig(arr, 4):read()):toBe(100i)

	local s = c.new(c.array(c.char, 6), {
		string.byte("h"),
		string.byte("e"),
		string.byte("l"),
		string.byte("l"),
		string.byte("o"),
		0,
	})
	test.expect(strlenByArraySig(s):read()):toBe(5i)
	test.expect(strlenByArraySig("hello"):read()):toBe(5i)
end)

suite:test("allocated pointers from native code can be read and freed", function()
	local ptr = allocI32(77)
	test.expect(ptr:isNull()):toBeFalse()
	test.expect(ptr:deref():read()):toBe(77)
	freeI32(ptr)
end)

suite:test("closed libraries invalidate previously resolved values", function()
	local localLib = ffi.open(dllPath)
	local localAdd = localLib:get("ffi_add_i32", c.func(c.int32, { c.int32, c.int32 }))
	local localConst = localLib:get("ffi_i32_constant", c.int32)
	localLib:close()

	test.expect(function()
		localAdd(1, 2)
	end):toError("closed library")

	test.expect(function()
		localConst:read()
	end):toError("closed library")
end)

suite:test("library: close and isOpen", function()
	local localLib = ffi.open(dllPath)
	test.expect(localLib:isOpen()):toBeTrue()
	localLib:close()
	test.expect(localLib:isOpen()):toBeFalse()
	test.expect(function()
		localLib:get("ffi_add_i32", c.int32)
	end):toError("closed")
end)

suite:test("library: process handle cannot be closed", function()
	test.expect(function()
		ffi.process:close()
	end):toError("cannot close process library")
end)

suite:test("errors: invalid construction and lookup", function()
	test.expect(function()
		c.new(c.void)
	end):toError("cannot allocate void")

	test.expect(function()
		c.new(c.array(c.int32, 0))
	end):toError("greater than zero")

	test.expect(function()
		c.null(c.int32)
	end):toError("requires pointer type")

	test.expect(function()
		c.new(c.int32):deref()
	end):toError("requires pointer")

	test.expect(function()
		c.new(c.array(c.int32, 1)):get(1)
	end):toError("out of bounds")

	test.expect(function()
		lib:get("definitely_not_a_symbol", c.int32)
	end):toError("resolve symbol")

	test.expect(function()
		addI32(1)
	end):toError("expected 2 arguments")

	test.expect(function()
		c.int32:offsetOf("x")
	end):toError("requires struct")

	test.expect(function()
		c.new(c.int32, 1):asarray()
	end):toError("requires array")

	test.expect(function()
		c.new(c.int32, 1):asdict()
	end):toError("requires struct")

	test.expect(function()
		c.new(c.int32, 1):getField("x")
	end):toError("requires struct")

	test.expect(function()
		c.new(c.int32, 1):setField("x", 2)
	end):toError("requires struct")

	test.expect(function()
		c.new(c.struct({ { "x", c.int32 } }), {}):getField("y")
	end):toError("unknown struct field")

	test.expect(function()
		c.cast(c.new(c.int32, 1), c.struct({ { "x", c.int32 } }))
	end):toError("unsupported cast")
end)

return suite
