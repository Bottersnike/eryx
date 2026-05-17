-- @eryx/math
-- Type stub for GMP-backed numeric types.

local mathx = {}

export type RoundingMode = "trunc" | "floor" | "ceil" | "nearest" | "nearest_even" | "nearest_away"

export type Sign = number -- -1 | 0 | 1

export type IntegerLike = Integer | number | string
export type RationalLike = Rational | number | string
export type FloatLike = Float | number | string
export type NumberLike = Number | Integer | Float | number | string

export type Integer = setmetatable<
	{
		_kind: "integer",
	},
	{
		clone: (self: Integer) -> Integer,

		abs: (self: Integer) -> Integer,
		sign: (self: Integer) -> Sign,
		cmp: (self: Integer, other: Integer | number) -> number,

		isZero: (self: Integer) -> boolean,
		isOne: (self: Integer) -> boolean,
		isEven: (self: Integer) -> boolean,
		isOdd: (self: Integer) -> boolean,

		divTrunc: (self: Integer, other: Integer | number) -> Integer,
		divFloor: (self: Integer, other: Integer | number) -> Integer,
		divCeil: (self: Integer, other: Integer | number) -> Integer,
		divmod: (self: Integer, other: Integer | number, mode: RoundingMode?) -> (Integer, Integer),

		gcd: (self: Integer, other: Integer | number) -> Integer,
		lcm: (self: Integer, other: Integer | number) -> Integer,
		extendedGcd: (self: Integer, other: Integer | number) -> (Integer, Integer, Integer),

		pow: (self: Integer, exponent: Integer | number) -> Integer,
		modPow: (self: Integer, exponent: Integer | number, modulus: Integer | number) -> Integer,
		modInverse: (self: Integer, modulus: Integer | number) -> Integer?,

		isProbablePrime: (self: Integer, reps: number?) -> boolean,
		nextPrime: (self: Integer) -> Integer,

		bitLength: (self: Integer) -> number,
		popcount: (self: Integer) -> number,
		testBit: (self: Integer, bit: number) -> boolean,
		setBit: (self: Integer, bit: number) -> Integer,
		clearBit: (self: Integer, bit: number) -> Integer,
		flipBit: (self: Integer, bit: number) -> Integer,

		band: (self: Integer, other: Integer | number) -> Integer,
		bor: (self: Integer, other: Integer | number) -> Integer,
		bxor: (self: Integer, other: Integer | number) -> Integer,
		bnot: (self: Integer) -> Integer,
		shl: (self: Integer, bits: number) -> Integer,
		shr: (self: Integer, bits: number) -> Integer,

		toString: (self: Integer, base: number?) -> string,
		toNumber: (self: Integer) -> number,
		toI64: (self: Integer) -> integer,
		toU64: (self: Integer) -> integer,

		fitsNumber: (self: Integer) -> boolean,
		fitsI64: (self: Integer) -> boolean,
		fitsU64: (self: Integer) -> boolean,

		toRational: (self: Integer) -> Rational,
		toFloat: (self: Integer, precision: number?) -> Float,
		toDynamicNumber: (self: Integer) -> Number,

		__tostring: (self: Integer) -> string,

		__eq: (a: Integer, b: Integer) -> boolean,
		__lt: ((a: Integer, b: Integer) -> boolean)
			& ((a: Integer, b: number) -> boolean)
			& ((a: number, b: Integer) -> boolean),
		__le: ((a: Integer, b: Integer) -> boolean)
			& ((a: Integer, b: number) -> boolean)
			& ((a: number, b: Integer) -> boolean),

		__unm: (self: Integer) -> Integer,

		__add: ((a: Integer, b: Integer) -> Integer)
			& ((a: Integer, b: number) -> Integer)
			& ((a: number, b: Integer) -> Integer),
		__sub: ((a: Integer, b: Integer) -> Integer)
			& ((a: Integer, b: number) -> Integer)
			& ((a: number, b: Integer) -> Integer),
		__mul: ((a: Integer, b: Integer) -> Integer)
			& ((a: Integer, b: number) -> Integer)
			& ((a: number, b: Integer) -> Integer),

		-- True division is intentionally not provided for Integer.
		-- Use :divTrunc, :divFloor, :divCeil, :toRational, or :toFloat.
		__idiv: ((a: Integer, b: Integer) -> Integer)
			& ((a: Integer, b: number) -> Integer)
			& ((a: number, b: Integer) -> Integer),
		__mod: ((a: Integer, b: Integer) -> Integer)
			& ((a: Integer, b: number) -> Integer)
			& ((a: number, b: Integer) -> Integer),

		-- Exponent must be integral and non-negative unless explicitly documented otherwise.
		__pow: ((a: Integer, b: Integer) -> Integer) & ((a: Integer, b: number) -> Integer),
	}
>

export type Rational = setmetatable<
	{
		_kind: "rational",
	},
	{
		clone: (self: Rational) -> Rational,

		abs: (self: Rational) -> Rational,
		sign: (self: Rational) -> Sign,
		cmp: (self: Rational, other: Rational | number) -> number,

		inverse: (self: Rational) -> Rational,
		canonical: (self: Rational) -> Rational,

		numerator: (self: Rational) -> Integer,
		denominator: (self: Rational) -> Integer,

		isZero: (self: Rational) -> boolean,
		isOne: (self: Rational) -> boolean,
		isInteger: (self: Rational) -> boolean,

		floor: (self: Rational) -> Integer,
		ceil: (self: Rational) -> Integer,
		trunc: (self: Rational) -> Integer,
		round: (self: Rational, mode: RoundingMode?) -> Integer,

		toString: (self: Rational, base: number?) -> string,
		toDecimal: (self: Rational, digits: number?, mode: RoundingMode?) -> string,
		toNumber: (self: Rational) -> number,

		toInteger: (self: Rational, mode: RoundingMode?) -> Integer,
		toFloat: (self: Rational, precision: number?, mode: RoundingMode?) -> Float,

		__tostring: (self: Rational) -> string,

		__eq: (a: Rational, b: Rational) -> boolean,
		__lt: ((a: Rational, b: Rational) -> boolean)
			& ((a: Rational, b: number) -> boolean)
			& ((a: number, b: Rational) -> boolean),
		__le: ((a: Rational, b: Rational) -> boolean)
			& ((a: Rational, b: number) -> boolean)
			& ((a: number, b: Rational) -> boolean),

		__unm: (self: Rational) -> Rational,

		__add: ((a: Rational, b: Rational) -> Rational)
			& ((a: Rational, b: number) -> Rational)
			& ((a: number, b: Rational) -> Rational),
		__sub: ((a: Rational, b: Rational) -> Rational)
			& ((a: Rational, b: number) -> Rational)
			& ((a: number, b: Rational) -> Rational),
		__mul: ((a: Rational, b: Rational) -> Rational)
			& ((a: Rational, b: number) -> Rational)
			& ((a: number, b: Rational) -> Rational),
		__div: ((a: Rational, b: Rational) -> Rational)
			& ((a: Rational, b: number) -> Rational)
			& ((a: number, b: Rational) -> Rational),

		__idiv: ((a: Rational, b: Rational) -> Integer)
			& ((a: Rational, b: number) -> Integer)
			& ((a: number, b: Rational) -> Integer),
		__mod: ((a: Rational, b: Rational) -> Rational)
			& ((a: Rational, b: number) -> Rational)
			& ((a: number, b: Rational) -> Rational),

		__pow: ((a: Rational, b: Integer) -> Rational) & ((a: Rational, b: number) -> Rational),
	}
>

export type Float = setmetatable<{
	_kind: "float",
}, {
	clone: (self: Float) -> Float,

	abs: (self: Float) -> Float,
	sign: (self: Float) -> Sign,
	cmp: (self: Float, other: Float | number) -> number,

	sqrt: (self: Float) -> Float,
	floor: (self: Float) -> Integer,
	ceil: (self: Float) -> Integer,
	trunc: (self: Float) -> Integer,
	round: (self: Float, mode: RoundingMode?) -> Integer,

	precision: (self: Float) -> number,
	withPrecision: (self: Float, bits: number, mode: RoundingMode?) -> Float,

	isZero: (self: Float) -> boolean,
	isFinite: (self: Float) -> boolean,

	toString: (self: Float, base: number?, digits: number?) -> string,
	toNumber: (self: Float) -> number,
	toInteger: (self: Float, mode: RoundingMode?) -> Integer,
	toDynamicNumber: (self: Float) -> Number,

	__tostring: (self: Float) -> string,

	__eq: (a: Float, b: Float) -> boolean,
	__lt: ((a: Float, b: Float) -> boolean) & ((a: Float, b: number) -> boolean) & ((a: number, b: Float) -> boolean),
	__le: ((a: Float, b: Float) -> boolean) & ((a: Float, b: number) -> boolean) & ((a: number, b: Float) -> boolean),

	__unm: (self: Float) -> Float,

	__add: ((a: Float, b: Float) -> Float) & ((a: Float, b: number) -> Float) & ((a: number, b: Float) -> Float),
	__sub: ((a: Float, b: Float) -> Float) & ((a: Float, b: number) -> Float) & ((a: number, b: Float) -> Float),
	__mul: ((a: Float, b: Float) -> Float) & ((a: Float, b: number) -> Float) & ((a: number, b: Float) -> Float),
	__div: ((a: Float, b: Float) -> Float) & ((a: Float, b: number) -> Float) & ((a: number, b: Float) -> Float),

	__idiv: ((a: Float, b: Float) -> Integer) & ((a: Float, b: number) -> Integer) & ((a: number, b: Float) -> Integer),
	__mod: ((a: Float, b: Float) -> Float) & ((a: Float, b: number) -> Float) & ((a: number, b: Float) -> Float),
	__pow: ((a: Float, b: Float) -> Float) & ((a: Float, b: number) -> Float) & ((a: number, b: Float) -> Float),
}>

export type Number = setmetatable<
	{
		_kind: "number",
	},
	{
		clone: (self: Number) -> Number,

		kind: (self: Number) -> "integer" | "float",
		isInteger: (self: Number) -> boolean,
		isFloat: (self: Number) -> boolean,

		integer: (self: Number) -> Integer?,
		float: (self: Number) -> Float?,

		abs: (self: Number) -> Number,
		sign: (self: Number) -> Sign,
		cmp: (self: Number, other: Number | number) -> number,

		toString: (self: Number, base: number?, digits: number?) -> string,
		toNumber: (self: Number) -> number,
		toInteger: (self: Number, mode: RoundingMode?) -> Integer,
		toFloat: (self: Number, precision: number?, mode: RoundingMode?) -> Float,

		__tostring: (self: Number) -> string,

		__eq: (a: Number, b: Number) -> boolean,
		__lt: ((a: Number, b: Number) -> boolean)
			& ((a: Number, b: number) -> boolean)
			& ((a: number, b: Number) -> boolean),
		__le: ((a: Number, b: Number) -> boolean)
			& ((a: Number, b: number) -> boolean)
			& ((a: number, b: Number) -> boolean),

		__unm: (self: Number) -> Number,

		__add: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),
		__sub: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),
		__mul: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),

		-- Dynamic number division promotes to float.
		__div: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),
		__idiv: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),
		__mod: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),
		__pow: ((a: Number, b: Number) -> Number)
			& ((a: Number, b: number) -> Number)
			& ((a: number, b: Number) -> Number),
	}
>

export type IntegerModule = {
	new: (value: IntegerLike?, base: number?) -> Integer,

	fromString: (value: string, base: number?) -> Integer,
	fromNumber: (value: number) -> Integer,
	fromI64: (value: integer) -> Integer,
	fromU64: (value: integer) -> Integer,

	zero: () -> Integer,
	one: () -> Integer,

	factorial: (n: Integer | number) -> Integer,
	binomial: (n: Integer | number, k: Integer | number) -> Integer,

	isInteger: (value: unknown) -> boolean,
}

export type RationalModule = {
	new: (numerator: RationalLike?, denominator: RationalLike?) -> Rational,

	fromString: (value: string, base: number?) -> Rational,
	fromDecimal: (value: string) -> Rational,
	fromFloat: (value: number) -> Rational,
	fromInteger: (value: Integer | number) -> Rational,

	zero: () -> Rational,
	one: () -> Rational,

	isRational: (value: unknown) -> boolean,
}

export type FloatModule = {
	new: (value: FloatLike?, precision: number?) -> Float,

	fromString: (value: string, base: number?, precision: number?) -> Float,
	fromNumber: (value: number, precision: number?) -> Float,
	fromInteger: (value: Integer | number, precision: number?) -> Float,
	fromRational: (value: Rational, precision: number?, mode: RoundingMode?) -> Float,

	defaultPrecision: () -> number,
	setDefaultPrecision: (bits: number) -> (),

	zero: (precision: number?) -> Float,
	one: (precision: number?) -> Float,

	isFloat: (value: unknown) -> boolean,
}

export type NumberModule = {
	new: (value: NumberLike?, precision: number?) -> Number,

	fromString: (value: string, base: number?, precision: number?) -> Number,
	fromNumber: (value: number, precision: number?) -> Number,
	fromInteger: (value: Integer | number) -> Number,
	fromFloat: (value: Float | number, precision: number?) -> Number,

	zero: () -> Number,
	one: () -> Number,

	isNumber: (value: unknown) -> boolean,
}

mathx.integer = (nil :: any) :: IntegerModule
mathx.rational = (nil :: any) :: RationalModule
mathx.float = (nil :: any) :: FloatModule
mathx.number = (nil :: any) :: NumberModule

return mathx
