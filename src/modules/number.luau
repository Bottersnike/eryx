--[=[
	This library provides four numeric domains backed by GMP and MPFR:

	- `number.integer`: arbitrary-precision exact integers
	- `number.rational`: arbitrary-precision exact fractions
	- `number.float`: arbitrary-precision floating-point values
	- `number.number`: an ergonomic dynamic wrapper that switches between integer and float

	Use `Integer` when exact whole-number arithmetic matters, such as counters, combinatorics,
	bitwise work, cryptography, IDs, or number theory. Use `Rational` when you need exact
	fractions and want to avoid the rounding behavior of floating point. Use `Float` when you
	want explicit control over precision and floating-point rounding. Use `Number` when you want
	the most ergonomic interface and are happy with Python-like promotion between integer and float.

	`Number` is intentionally only a union of Integer and Float. It does not automatically enter
	the Rational domain, because exact fractions can grow in size quickly and that cost is easy to
	miss if promotion happens implicitly.

	There are a few important behavior rules to keep in mind:

	- `Number / Number` promotes to the floating-point domain.
	- Integer-like whole-result helpers such as `Number:floor()`, `:ceil()`, `:trunc()`,
	  `:round()`, and `//` promote back to integer-kind `Number`.
	- `Integer`, `Float`, and `Number` can all interoperate with plain Luau `number` values in
	  many common arithmetic paths.
	- `Number` uses the same default floating-point precision as `number.float`. If a Number
	  operation needs to create a float and you do not pass an explicit precision, it uses
	  `number.float.defaultPrecision()`.

	Common patterns:

	```luau
	local number = require("@eryx/number")
	local integer = number.integer
	local float = number.float
	local dynamic = number.number

	local huge = integer.fromString("123456789012345678901234567890")
	local exact = huge * 9

	local ratio = number.rational.new(1, 3)
	local approx = ratio:toFloat(128)

	local mixed = dynamic.fromInteger(10) / 4
	print(mixed:kind()) -- "float"
	print(mixed) -- 2.5

	local whole = mixed:floor()
	print(whole:kind()) -- "integer"
	print(whole) -- 2
	```

	If you already know which numeric domain you want, prefer the explicit module for clarity.
	Reach for `number.number` when you want convenience first and explicit domain control second.
]=]

local number = {}

export type RoundingMode = "trunc" | "floor" | "ceil" | "nearest" | "nearest_even" | "nearest_away"
export type IntegerDivMode = "trunc" | "floor" | "ceil"

export type Sign = number -- -1 | 0 | 1

export type IntegerLike = Integer | number | string
export type RationalLike = Rational | number | string
export type FloatLike = Float | number | string
export type NumberLike = Number | Integer | Float | number | string

export type Integer = setmetatable<{}, {
	__index: {
		--[=[
				Returns a new Integer with the same value.
				This is useful when you want an explicit copy before passing the value around or transforming it.
				@return A new Integer equal to `self`.
			]=]
		clone: (self: Integer) -> Integer,

		--[=[
				Returns the absolute value of the integer.
				Negative inputs become positive; zero and positive values are unchanged.
				@return A non-negative Integer with the same magnitude as `self`.
			]=]
		abs: (self: Integer) -> Integer,
		--[=[
				Returns the sign of the integer.
				The result is `-1` for negative values, `0` for zero, and `1` for positive values.
				@return The sign of `self`.
			]=]
		sign: (self: Integer) -> Sign,
		--[=[
				Compares this integer with another integer-like value.
				This is the explicit comparison method behind the ordering operators.
				@param other The value to compare against.
				@return A negative number if `self < other`, zero if `self == other`, or a positive number if `self > other`.
			]=]
		cmp: (self: Integer, other: Integer | number) -> number,

		--[=[
				Checks whether the integer is exactly zero.
				This is a convenience predicate for branchy arithmetic code.
				@return `true` if `self` is zero, otherwise `false`.
			]=]
		isZero: (self: Integer) -> boolean,
		--[=[
				Checks whether the integer is exactly one.
				This is often handy in algorithms with multiplicative identities.
				@return `true` if `self` is one, otherwise `false`.
			]=]
		isOne: (self: Integer) -> boolean,
		--[=[
				Checks whether the integer is even.
				Evenness is determined by the low bit, so this works efficiently even for very large values.
				@return `true` if `self` is evenly divisible by two, otherwise `false`.
			]=]
		isEven: (self: Integer) -> boolean,
		--[=[
				Checks whether the integer is odd.
				This is the complement of `isEven()`.
				@return `true` if `self` is not evenly divisible by two, otherwise `false`.
			]=]
		isOdd: (self: Integer) -> boolean,

		--[=[
				Divides two integers using truncating division.
				The quotient is rounded toward zero.
				@param other The divisor.
				@return The truncated quotient.
			]=]
		divTrunc: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Divides two integers using floor division.
				The quotient is rounded toward negative infinity.
				@param other The divisor.
				@return The floored quotient.
			]=]
		divFloor: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Divides two integers using ceiling division.
				The quotient is rounded toward positive infinity.
				@param other The divisor.
				@return The ceiled quotient.
			]=]
		divCeil: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Divides two integers and returns both the quotient and remainder.
				The quotient rounding rule is controlled by `mode`, and the remainder follows that choice.
				@param other The divisor.
				@param mode The rounding mode to use: `"trunc"`, `"floor"`, or `"ceil"`.
				@return The quotient under the chosen rounding rule.
				@return The corresponding remainder.
			]=]
		divmod: (self: Integer, other: Integer | number, mode: IntegerDivMode?) -> (Integer, Integer),

		--[=[
				Computes the greatest common divisor of two integers.
				The result is always non-negative.
				@param other The other operand.
				@return The greatest common divisor of `self` and `other`.
			]=]
		gcd: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Computes the least common multiple of two integers.
				This is useful for normalising periods, denominators, or modular steps.
				@param other The other operand.
				@return The least common multiple of `self` and `other`.
			]=]
		lcm: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Computes the extended greatest common divisor.
				The returned coefficients satisfy `g = self * x + other * y`.
				@param other The other operand.
				@return The greatest common divisor.
				@return The coefficient multiplying `self`.
				@return The coefficient multiplying `other`.
			]=]
		extendedGcd: (self: Integer, other: Integer | number) -> (Integer, Integer, Integer),

		--[=[
				Raises the integer to a non-negative integral power.
				Use this when you want exact integer exponentiation without leaving the integer domain.
				@param exponent The exponent to raise `self` by.
				@return `self` raised to `exponent`.
			]=]
		pow: (self: Integer, exponent: Integer | number) -> Integer,
		--[=[
				Computes modular exponentiation.
				This evaluates `self^exponent mod modulus` efficiently, even for very large values.
				@param exponent The non-negative exponent.
				@param modulus The non-zero modulus.
				@return The modular power result.
			]=]
		modPow: (self: Integer, exponent: Integer | number, modulus: Integer | number) -> Integer,
		--[=[
				Computes the modular multiplicative inverse.
				If no inverse exists because the values are not coprime, this returns `nil`.
				@param modulus The non-zero modulus.
				@return The modular inverse of `self` modulo `modulus`, or `nil` if none exists.
			]=]
		modInverse: (self: Integer, modulus: Integer | number) -> Integer?,

		--[=[
				Performs a probabilistic primality test.
				More repetitions increase confidence for composite detection.
				@param reps The number of primality test rounds to run.
				@return `true` if the value is probably prime, otherwise `false`.
			]=]
		isProbablePrime: (self: Integer, reps: number?) -> boolean,
		--[=[
				Finds the next probable prime greater than this integer.
				This is useful for search-based number theory and cryptographic helpers.
				@return The next probable prime after `self`.
			]=]
		nextPrime: (self: Integer) -> Integer,

		--[=[
				Returns the number of significant bits required to represent the integer.
				Zero has a bit length of `0`.
				@return The bit length of `self`.
			]=]
		bitLength: (self: Integer) -> number,
		--[=[
				Counts the number of set bits in the integer.
				This is also known as the population count or Hamming weight.
				@return The number of `1` bits in `self`.
			]=]
		popcount: (self: Integer) -> number,
		--[=[
				Checks whether a specific bit is set.
				Bit positions are zero-based, where bit `0` is the least significant bit.
				@param bit The zero-based bit index to inspect.
				@return `true` if the bit is set, otherwise `false`.
			]=]
		testBit: (self: Integer, bit: number) -> boolean,
		--[=[
				Returns a copy of the integer with the given bit set to `1`.
				Bit positions are zero-based.
				@param bit The zero-based bit index to set.
				@return A new Integer with the selected bit set.
			]=]
		setBit: (self: Integer, bit: number) -> Integer,
		--[=[
				Returns a copy of the integer with the given bit cleared to `0`.
				Bit positions are zero-based.
				@param bit The zero-based bit index to clear.
				@return A new Integer with the selected bit cleared.
			]=]
		clearBit: (self: Integer, bit: number) -> Integer,
		--[=[
				Returns a copy of the integer with the given bit toggled.
				Bit positions are zero-based.
				@param bit The zero-based bit index to flip.
				@return A new Integer with the selected bit inverted.
			]=]
		flipBit: (self: Integer, bit: number) -> Integer,

		--[=[
				Computes the bitwise AND of two integers.
				This uses two's-complement style infinite-width semantics, matching GMP's integer bit operations.
				@param other The other operand.
				@return The bitwise AND of `self` and `other`.
			]=]
		band: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Computes the bitwise OR of two integers.
				This uses two's-complement style infinite-width semantics.
				@param other The other operand.
				@return The bitwise OR of `self` and `other`.
			]=]
		bor: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Computes the bitwise XOR of two integers.
				This uses two's-complement style infinite-width semantics.
				@param other The other operand.
				@return The bitwise XOR of `self` and `other`.
			]=]
		bxor: (self: Integer, other: Integer | number) -> Integer,
		--[=[
				Computes the bitwise complement of the integer.
				This uses two's-complement style infinite-width semantics.
				@return The bitwise complement of `self`.
			]=]
		bnot: (self: Integer) -> Integer,
		--[=[
				Shifts the integer left by the given number of bits.
				Negative shift counts reverse direction and behave like a right shift.
				@param bits The number of bit positions to shift.
				@return The shifted Integer.
			]=]
		shl: (self: Integer, bits: number) -> Integer,
		--[=[
				Shifts the integer right by the given number of bits.
				Negative shift counts reverse direction and behave like a left shift.
				@param bits The number of bit positions to shift.
				@return The shifted Integer.
			]=]
		shr: (self: Integer, bits: number) -> Integer,

		--[=[
				Formats the integer as a string in the chosen base.
				Base `10` is the default, and other bases are useful for binary, hexadecimal, and compact serialisation.
				@param base The radix to use when formatting the integer.
				@return A string representation of `self`.
			]=]
		toString: (self: Integer, base: number?) -> string,
		--[=[
				Converts the integer to a Luau number.
				This conversion is intended for ergonomic interop with ordinary numeric code.
				@return The value of `self` as a Luau number.
			]=]
		toNumber: (self: Integer) -> number,
		--[=[
				Converts the integer into an exact Rational with denominator `1`.
				This is useful when you want to move from integer arithmetic into rational arithmetic without losing precision.
				@return A Rational equal to `self / 1`.
			]=]
		toRational: (self: Integer) -> Rational,
		--[=[
				Promotes the integer into the floating-point domain.
				This is useful when you want MPFR-backed operations starting from an exact integer value.
				@param precision The precision to use for the resulting Float, in bits.
				@return A Float equal to `self`.
			]=]
		toFloat: (self: Integer, precision: number?) -> Float,
		--[=[
				Converts the integer to a signed 64-bit integer.
				Use this when you explicitly need a fixed-width signed representation.
				@return The value of `self` as a signed 64-bit integer.
			]=]
		toI64: (self: Integer) -> integer,
		--[=[
				Converts the integer to an unsigned 64-bit integer.
				Use this when you explicitly need a fixed-width unsigned representation.
				@return The value of `self` as an unsigned 64-bit integer.
			]=]
		toU64: (self: Integer) -> integer,

		--[=[
				Checks whether the integer can be represented as a Luau number.
				This is useful before crossing back into APIs that expect ordinary numbers.
				@return `true` if `self` fits within the supported Luau number representation, otherwise `false`.
			]=]
		fitsNumber: (self: Integer) -> boolean,
		--[=[
				Checks whether the integer fits in a signed 64-bit integer.
				This is a non-throwing guard for `toI64()`.
				@return `true` if `self` fits in signed 64-bit range, otherwise `false`.
			]=]
		fitsI64: (self: Integer) -> boolean,
		--[=[
				Checks whether the integer fits in an unsigned 64-bit integer.
				This is a non-throwing guard for `toU64()`.
				@return `true` if `self` fits in unsigned 64-bit range, otherwise `false`.
			]=]
		fitsU64: (self: Integer) -> boolean,
	},

	--[=[
			Formats the integer as a human-readable decimal string.
			This is what powers `tostring(value)` for Integer values.
			@return A decimal string representation of the integer.
		]=]
	__tostring: (self: Integer) -> string,

	--[=[
			Checks whether two Integer values are exactly equal.
			This metamethod powers the `==` operator for Integer values.
		]=]
	__eq: (Integer, Integer) -> boolean,
	--[=[
			Checks whether one integer is strictly less than another.
			This metamethod powers the `<` operator for Integer-to-Integer comparisons.
		]=]
	__lt: (Integer, Integer) -> boolean,
	--[=[
			Checks whether one integer is less than or equal to another.
			This metamethod powers the `<=` operator for Integer-to-Integer comparisons.
		]=]
	__le: (Integer, Integer) -> boolean,

	--[=[
			Negates the integer.
			This metamethod powers unary minus.
		]=]
	__unm: (Integer) -> Integer,

	--[=[
			Adds two integer values.
			This metamethod powers the `+` operator and supports ordinary whole-number `number` values on either side.
		]=]
	__add: ((Integer, Integer) -> Integer) & ((Integer, number) -> Integer) & ((number, Integer) -> Integer),
	--[=[
			Subtracts one integer value from another.
			This metamethod powers the `-` operator and supports ordinary whole-number `number` values on either side.
		]=]
	__sub: ((Integer, Integer) -> Integer) & ((Integer, number) -> Integer) & ((number, Integer) -> Integer),
	--[=[
			Multiplies two integer values.
			This metamethod powers the `*` operator and preserves exact integer arithmetic.
		]=]
	__mul: ((Integer, Integer) -> Integer) & ((Integer, number) -> Integer) & ((number, Integer) -> Integer),

	--[=[
			Performs integer floor division.
			This metamethod powers the `//` operator and follows floor-division semantics.
		]=]
	__idiv: ((Integer, Integer) -> Integer) & ((Integer, number) -> Integer) & ((number, Integer) -> Integer),
	--[=[
			Computes the integer remainder under floor-division semantics.
			This metamethod powers the `%` operator.
		]=]
	__mod: ((Integer, Integer) -> Integer) & ((Integer, number) -> Integer) & ((number, Integer) -> Integer),

	--[=[
			Raises an integer to a non-negative integral power.
			This metamethod powers the `^` operator for integer exponentiation.
		]=]
	__pow: ((Integer, Integer) -> Integer) & ((Integer, number) -> Integer),
}>

export type Rational = setmetatable<{}, {
	__index: {
		--[=[
			Returns a new Rational with the same value.
			This is useful when you want an explicit copy before passing the value into other code.
			@return A new Rational equal to `self`.
		]=]
		clone: (self: Rational) -> Rational,

		--[=[
			Returns the absolute value of the rational.
			Negative inputs become positive; zero and positive values are unchanged.
			@return A non-negative Rational with the same magnitude as `self`.
		]=]
		abs: (self: Rational) -> Rational,
		--[=[
			Returns the sign of the rational.
			The result is `-1` for negative values, `0` for zero, and `1` for positive values.
			@return The sign of `self`.
		]=]
		sign: (self: Rational) -> Sign,
		--[=[
			Compares this rational with another rational-like value.
			This is the explicit comparison method behind the ordering operators.
			@param other The value to compare against.
			@return A negative number if `self < other`, zero if `self == other`, or a positive number if `self > other`.
		]=]
		cmp: (self: Rational, other: Rational | number) -> number,

		--[=[
			Returns the reciprocal of the rational.
			This swaps the numerator and denominator, preserving the sign.
			@return A new Rational equal to `1 / self`.
		]=]
		inverse: (self: Rational) -> Rational,
		--[=[
			Returns the rational in canonical reduced form.
			This normalises the sign and reduces the numerator and denominator by their greatest common divisor.
			@return A canonical Rational equivalent to `self`.
		]=]
		canonical: (self: Rational) -> Rational,

		--[=[
			Returns the numerator of the rational.
			The returned Integer reflects the current exact value of `self`.
			@return The numerator of `self`.
		]=]
		numerator: (self: Rational) -> Integer,
		--[=[
			Returns the denominator of the rational.
			In canonical form, this is always positive.
			@return The denominator of `self`.
		]=]
		denominator: (self: Rational) -> Integer,

		--[=[
			Checks whether the rational is exactly zero.
			This is a convenience predicate for branchy arithmetic code.
			@return `true` if `self` is zero, otherwise `false`.
		]=]
		isZero: (self: Rational) -> boolean,
		--[=[
			Checks whether the rational is exactly one.
			This is often useful in code that works with multiplicative identities.
			@return `true` if `self` is one, otherwise `false`.
		]=]
		isOne: (self: Rational) -> boolean,
		--[=[
			Checks whether the rational is a whole integer value.
			This is true when the denominator is `1` after canonicalisation.
			@return `true` if `self` represents an integer, otherwise `false`.
		]=]
		isInteger: (self: Rational) -> boolean,

		--[=[
			Rounds the rational down to the nearest integer.
			This uses floor semantics, rounding toward negative infinity.
			@return The floored Integer value.
		]=]
		floor: (self: Rational) -> Integer,
		--[=[
			Rounds the rational up to the nearest integer.
			This uses ceiling semantics, rounding toward positive infinity.
			@return The ceiled Integer value.
		]=]
		ceil: (self: Rational) -> Integer,
		--[=[
			Truncates the rational toward zero.
			This is useful when you want integer projection without floor/ceiling behaviour.
			@return The truncated Integer value.
		]=]
		trunc: (self: Rational) -> Integer,
		--[=[
			Rounds the rational to the nearest integer using the chosen mode.
			This supports explicit tie-breaking strategies such as nearest-even.
			@param mode The rounding mode to use.
			@return The rounded Integer value.
		]=]
		round: (self: Rational, mode: RoundingMode?) -> Integer,

		--[=[
			Formats the rational as a string in the chosen base.
			Whole-valued rationals may render without a slash; fractional values render as `numerator/denominator`.
			@param base The radix to use when formatting the rational.
			@return A string representation of `self`.
		]=]
		toString: (self: Rational, base: number?) -> string,
		--[=[
			Formats the rational as a decimal string.
			Exact terminating decimals can be emitted directly; otherwise this rounds to the requested number of digits.
			@param digits The number of digits to keep after the decimal point.
			@param mode The rounding mode to use when rounding is needed.
			@return A decimal string representation of `self`.
		]=]
		toDecimal: (self: Rational, digits: number?, mode: RoundingMode?) -> string,
		--[=[
			Converts the rational to a Luau number.
			This is intended for ergonomic interop with ordinary numeric code when exact rational arithmetic is no longer required.
			@return The value of `self` as a Luau number.
		]=]
		toNumber: (self: Rational) -> number,

		--[=[
			Converts the rational to an Integer using the chosen rounding mode.
			This is useful when you want an explicit and exact integer projection step.
			@param mode The rounding mode to use for the conversion.
			@return The resulting Integer value.
		]=]
		toInteger: (self: Rational, mode: RoundingMode?) -> Integer,
		--[=[
			Converts the rational to a Float using the chosen precision and rounding mode.
			This is useful when you want to leave the exact rational domain with explicit floating-point control.
			@param precision The precision to use for the resulting Float, in bits.
			@param mode The rounding mode to use when conversion is inexact.
			@return The resulting Float approximation of `self`.
		]=]
		toFloat: (self: Rational, precision: number?, mode: RoundingMode?) -> Float,
	},

	--[=[
		Formats the rational as a human-readable string.
		This is what powers `tostring(value)` for Rational values.
	]=]
	__tostring: (self: Rational) -> string,

	--[=[
		Checks whether two Rational values are exactly equal.
		This metamethod powers the `==` operator for Rational values.
	]=]
	__eq: (Rational, Rational) -> boolean,
	--[=[
		Checks whether one rational is strictly less than another.
		This metamethod powers the `<` operator for Rational-to-Rational comparisons.
	]=]
	__lt: (Rational, Rational) -> boolean,
	--[=[
		Checks whether one rational is less than or equal to another.
		This metamethod powers the `<=` operator for Rational-to-Rational comparisons.
	]=]
	__le: (Rational, Rational) -> boolean,

	--[=[
		Negates the rational.
		This metamethod powers unary minus.
	]=]
	__unm: (self: Rational) -> Rational,

	--[=[
		Adds two rational values.
		This metamethod powers the `+` operator and preserves exact rational arithmetic.
	]=]
	__add: ((Rational, Rational) -> Rational) & ((Rational, number) -> Rational) & ((number, Rational) -> Rational),
	--[=[
		Subtracts one rational value from another.
		This metamethod powers the `-` operator and preserves exact rational arithmetic.
	]=]
	__sub: ((Rational, Rational) -> Rational) & ((Rational, number) -> Rational) & ((number, Rational) -> Rational),
	--[=[
		Multiplies two rational values.
		This metamethod powers the `*` operator and preserves exact rational arithmetic.
	]=]
	__mul: ((Rational, Rational) -> Rational) & ((Rational, number) -> Rational) & ((number, Rational) -> Rational),
	--[=[
		Divides one rational value by another.
		This metamethod powers the `/` operator and stays in the exact rational domain.
	]=]
	__div: ((Rational, Rational) -> Rational) & ((Rational, number) -> Rational) & ((number, Rational) -> Rational),

	--[=[
		Performs floor division on rational values.
		This metamethod powers the `//` operator and returns an Integer quotient.
	]=]
	__idiv: ((Rational, Rational) -> Integer) & ((Rational, number) -> Integer) & ((number, Rational) -> Integer),
	--[=[
		Computes the rational remainder under floor-division semantics.
		This metamethod powers the `%` operator.
	]=]
	__mod: ((Rational, Rational) -> Rational) & ((Rational, number) -> Rational) & ((number, Rational) -> Rational),

	--[=[
		Raises a rational value to an integral power.
		This metamethod powers the `^` operator for exact rational exponentiation.
	]=]
	__pow: ((Rational, Integer) -> Rational) & ((Rational, number) -> Rational),
}>

export type Float = setmetatable<{}, {
	__index: {
		--[=[
			Returns a new Float with the same numeric value.
			This is useful when you want an explicit copy, optionally at the same precision as the original.
			@return A new Float equal to `self`.
		]=]
		clone: (self: Float) -> Float,

		--[=[
			Returns the absolute value of the float.
			Negative inputs become positive; zero and positive values are unchanged.
			@return A non-negative Float with the same magnitude as `self`.
		]=]
		abs: (self: Float) -> Float,
		--[=[
			Returns the sign of the float.
			The result is `-1` for negative values, `0` for zero, and `1` for positive values.
			@param self The Float whose sign should be inspected.
			@return The sign of `self`.
		]=]
		sign: (self: Float) -> Sign,
		--[=[
			Compares this float with another float-like value.
			This is the explicit comparison method behind the ordering operators.
			@param other The value to compare against.
			@return A negative number if `self < other`, zero if `self == other`, or a positive number if `self > other`.
		]=]
		cmp: (self: Float, other: Float | number) -> number,

		--[=[
			Computes the square root of the float.
			This stays in the floating-point domain and uses MPFR's rounding behaviour.
			@return The square root of `self`.
		]=]
		sqrt: (self: Float) -> Float,
		--[=[
			Rounds the float down to the nearest integer.
			This uses floor semantics, rounding toward negative infinity.
			@return The floored Integer value.
		]=]
		floor: (self: Float) -> Integer,
		--[=[
			Rounds the float up to the nearest integer.
			This uses ceiling semantics, rounding toward positive infinity.
			@return The ceiled Integer value.
		]=]
		ceil: (self: Float) -> Integer,
		--[=[
			Truncates the float toward zero.
			This is useful when you want integer projection without floor/ceiling behaviour.
			@return The truncated Integer value.
		]=]
		trunc: (self: Float) -> Integer,
		--[=[
			Rounds the float to an Integer using the chosen rounding mode.
			This supports explicit tie-breaking strategies such as nearest-even.
			@param mode The rounding mode to use.
			@return The rounded Integer value.
		]=]
		round: (self: Float, mode: RoundingMode?) -> Integer,

		--[=[
			Returns the precision of the float in bits.
			This is the stored MPFR precision for the current value.
			@return The precision of `self`, in bits.
		]=]
		precision: (self: Float) -> number,
		--[=[
			Returns a copy of the float at a different precision.
			The value is rounded to the requested precision using the chosen rounding mode.
			@param bits The destination precision in bits.
			@param mode The rounding mode to use when precision changes.
			@return A new Float with the requested precision.
		]=]
		withPrecision: (self: Float, bits: number, mode: RoundingMode?) -> Float,

		--[=[
			Checks whether the float is exactly zero.
			This is a convenience predicate for branchy arithmetic code.
			@return `true` if `self` is zero, otherwise `false`.
		]=]
		isZero: (self: Float) -> boolean,
		--[=[
			Checks whether the float is finite.
			This distinguishes ordinary numeric values from `nan`, `inf`, and `-inf`.
			@return `true` if `self` is finite, otherwise `false`.
		]=]
		isFinite: (self: Float) -> boolean,
		--[=[
			Checks whether the float is `nan`.
			This is useful when you need to distinguish invalid or undefined floating-point results.
			@return `true` if `self` is `nan`, otherwise `false`.
		]=]
		isNaN: (self: Float) -> boolean,
		--[=[
			Checks whether the float is positive or negative infinity.
			This is useful when you need to handle overflow-style or unbounded results explicitly.
			@return `true` if `self` is infinite, otherwise `false`.
		]=]
		isInfinite: (self: Float) -> boolean,

		--[=[
			Formats the float as a string in the chosen base.
			When `digits` is omitted, the formatter emits a compact representation suitable for display.
			@param base The radix to use when formatting the float.
			@param digits The number of digits to emit for the significand.
			@return A string representation of `self`.
		]=]
		toString: (self: Float, base: number?, digits: number?) -> string,
		--[=[
			Converts the float to a Luau number.
			This is intended for ergonomic interop with ordinary numeric code.
			@return The value of `self` as a Luau number.
		]=]
		toNumber: (self: Float) -> number,
		--[=[
			Converts the float to an Integer using the chosen rounding mode.
			This is useful when you want an explicit and exact integer projection step.
			@param mode The rounding mode to use for the conversion.
			@return The resulting Integer value.
		]=]
		toInteger: (self: Float, mode: RoundingMode?) -> Integer,
	},

	--[=[
		Formats the float as a human-readable string.
		This is what powers `tostring(value)` for Float values.
	]=]
	__tostring: (self: Float) -> string,

	--[=[
		Checks whether two Float values are exactly equal at their represented values.
		This metamethod powers the `==` operator for Float values.
	]=]
	__eq: (Float, Float) -> boolean,
	--[=[
		Checks whether one float is strictly less than another.
		This metamethod powers the `<` operator for Float-to-Float comparisons.
	]=]
	__lt: (Float, Float) -> boolean,
	--[=[
		Checks whether one float is less than or equal to another.
		This metamethod powers the `<=` operator for Float-to-Float comparisons.
	]=]
	__le: (Float, Float) -> boolean,

	--[=[
		Negates the float.
		This metamethod powers unary minus.
	]=]
	__unm: (self: Float) -> Float,

	--[=[
		Adds two float values.
		This metamethod powers the `+` operator and stays in the floating-point domain.
	]=]
	__add: ((Float, Float) -> Float) & ((Float, number) -> Float) & ((number, Float) -> Float),
	--[=[
		Subtracts one float value from another.
		This metamethod powers the `-` operator and stays in the floating-point domain.
	]=]
	__sub: ((Float, Float) -> Float) & ((Float, number) -> Float) & ((number, Float) -> Float),
	--[=[
		Multiplies two float values.
		This metamethod powers the `*` operator and stays in the floating-point domain.
	]=]
	__mul: ((Float, Float) -> Float) & ((Float, number) -> Float) & ((number, Float) -> Float),
	--[=[
		Divides one float value by another.
		This metamethod powers the `/` operator and stays in the floating-point domain.
	]=]
	__div: ((Float, Float) -> Float) & ((Float, number) -> Float) & ((number, Float) -> Float),

	--[=[
		Performs floor division on float values.
		This metamethod powers the `//` operator and returns an Integer quotient.
	]=]
	__idiv: ((Float, Float) -> Integer) & ((Float, number) -> Integer) & ((number, Float) -> Integer),
	--[=[
		Computes the floating-point remainder under floor-division semantics.
		This metamethod powers the `%` operator.
	]=]
	__mod: ((Float, Float) -> Float) & ((Float, number) -> Float) & ((number, Float) -> Float),
	--[=[
		Raises a float value to another float-like power.
		This metamethod powers the `^` operator in the floating-point domain.
	]=]
	__pow: ((Float, Float) -> Float) & ((Float, number) -> Float) & ((number, Float) -> Float),
}>

export type Number = setmetatable<{}, {
	__index: {
		--[=[
				Returns a new Number with the same value and kind.
				This is useful when you want an explicit copy before passing it into other code.
				@return A new Number equal to `self`.
			]=]
		clone: (self: Number) -> Number,

		--[=[
				Reports whether the dynamic number is currently storing an integer or a float.
				This is useful when you need to branch on the exact runtime representation.
				@return `"integer"` if `self` is backed by an Integer-like value, otherwise `"float"`.
			]=]
		kind: (self: Number) -> "integer" | "float",
		--[=[
				Checks whether the dynamic number is currently backed by an integer value.
				This is a convenience predicate for representation-sensitive code.
				@return `true` if `self` is integer-kind, otherwise `false`.
			]=]
		isInteger: (self: Number) -> boolean,
		--[=[
				Checks whether the dynamic number is currently backed by a float value.
				This is a convenience predicate for representation-sensitive code.
				@return `true` if `self` is float-kind, otherwise `false`.
			]=]
		isFloat: (self: Number) -> boolean,

		--[=[
				Returns the exact Integer view when this Number is integer-kind.
				If the value is float-kind, this returns `nil` instead of rounding implicitly.
				@return The stored Integer value, or `nil` if `self` is float-kind.
			]=]
		integer: (self: Number) -> Integer?,
		--[=[
				Returns the exact Float view when this Number is float-kind.
				If the value is integer-kind, this returns `nil` instead of promoting implicitly.
				@return The stored Float value, or `nil` if `self` is integer-kind.
			]=]
		float: (self: Number) -> Float?,

		--[=[
				Returns the absolute value of the dynamic number.
				The result stays in the same numeric domain as the underlying representation.
				@return A non-negative Number with the same magnitude as `self`.
			]=]
		abs: (self: Number) -> Number,
		--[=[
				Returns the sign of the dynamic number.
				The result is `-1` for negative values, `0` for zero, and `1` for positive values.
				@return The sign of `self`.
			]=]
		sign: (self: Number) -> Sign,
		--[=[
				Compares this dynamic number with another dynamic or plain numeric value.
				This is the explicit comparison method behind the ordering operators.
				@param other The value to compare against.
				@return A negative number if `self < other`, zero if `self == other`, or a positive number if `self > other`.
			]=]
		cmp: (self: Number, other: Number | number) -> number,

		--[=[
				Rounds the dynamic number down to the nearest integer-valued Number.
				This uses floor semantics and always returns integer-kind Number storage.
				@return The floored Number value.
			]=]
		floor: (self: Number) -> Number,
		--[=[
				Rounds the dynamic number up to the nearest integer-valued Number.
				This uses ceiling semantics and always returns integer-kind Number storage.
				@return The ceiled Number value.
			]=]
		ceil: (self: Number) -> Number,
		--[=[
				Truncates the dynamic number toward zero.
				This always returns integer-kind Number storage.
				@return The truncated Number value.
			]=]
		trunc: (self: Number) -> Number,
		--[=[
				Rounds the dynamic number to the nearest integer-valued Number using the chosen mode.
				This supports explicit tie-breaking strategies such as nearest-even.
				@param mode The rounding mode to use.
				@return The rounded Number value, stored as integer-kind.
			]=]
		round: (self: Number, mode: RoundingMode?) -> Number,

		--[=[
				Formats the dynamic number as a string in the chosen base.
				Integer-kind values use integer formatting, while float-kind values use MPFR formatting rules.
				@param base The radix to use when formatting the value.
				@param digits The number of digits to emit for float-kind values.
				@return A string representation of `self`.
			]=]
		toString: (self: Number, base: number?, digits: number?) -> string,
		--[=[
				Converts the dynamic number to a Luau number.
				This is intended for ergonomic interop with ordinary numeric code.
				@return The value of `self` as a Luau number.
			]=]
		toNumber: (self: Number) -> number,
		--[=[
				Converts the dynamic number to an Integer using the chosen rounding mode.
				This is useful when you want an explicit and exact integer projection step.
				@param mode The rounding mode to use for the conversion.
				@return The resulting Integer value.
			]=]
		toInteger: (self: Number, mode: RoundingMode?) -> Integer,
		--[=[
				Converts the dynamic number to a Float, optionally changing its precision.
				Integer-kind values are promoted into the floating-point domain, and float-kind values may be rounded to a new precision.
				@param precision The destination precision in bits.
				@param mode The rounding mode to use when rounding is needed.
				@return The resulting Float value.
			]=]
		toFloat: (self: Number, precision: number?, mode: RoundingMode?) -> Float,
	},

	--[=[
			Formats the dynamic number as a human-readable string.
			This is what powers `tostring(value)` for Number values.
		]=]
	__tostring: (self: Number) -> string,

	--[=[
			Checks whether two Number values are exactly equal.
			This metamethod powers the `==` operator for Number values.
		]=]
	__eq: (Number, Number) -> boolean,
	--[=[
			Checks whether one dynamic number is strictly less than another.
			This metamethod powers the `<` operator for Number comparisons.
		]=]
	__lt: ((Number, Number) -> boolean) & ((Number, number) -> boolean) & ((number, Number) -> boolean),
	--[=[
			Checks whether one dynamic number is less than or equal to another.
			This metamethod powers the `<=` operator for Number comparisons.
		]=]
	__le: ((Number, Number) -> boolean) & ((Number, number) -> boolean) & ((number, Number) -> boolean),

	--[=[
			Negates the dynamic number.
			This metamethod powers unary minus and preserves the current numeric domain.
		]=]
	__unm: (self: Number) -> Number,

	--[=[
			Adds two dynamic numbers.
			This metamethod powers the `+` operator and promotes to float when the operation leaves the integer domain.
		]=]
	__add: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),
	--[=[
			Subtracts one dynamic number from another.
			This metamethod powers the `-` operator and promotes to float when needed.
		]=]
	__sub: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),
	--[=[
			Multiplies two dynamic numbers.
			This metamethod powers the `*` operator and preserves integer results when possible.
		]=]
	__mul: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),

	--[=[
			Divides one dynamic number by another.
			This metamethod powers the `/` operator and promotes into the floating-point domain.
		]=]
	__div: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),
	--[=[
			Performs floor division on dynamic numbers.
			This metamethod powers the `//` operator and returns an integer-valued Number.
		]=]
	__idiv: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),
	--[=[
			Computes the remainder of one dynamic number by another.
			This metamethod powers the `%` operator and follows floor-division semantics.
		]=]
	__mod: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),
	--[=[
			Raises a dynamic number to a power.
			This metamethod powers the `^` operator and promotes to float when integer exponentiation no longer applies.
		]=]
	__pow: ((Number, Number) -> Number) & ((Number, number) -> Number) & ((number, Number) -> Number),
}>

type IntegerModule = {
	--[=[
		Creates a new Integer from an existing integer-like value.
		Numbers are treated as whole-number inputs, and strings may be parsed in the given base.
		@param value The source value to convert into an Integer.
		@param base The radix to use when `value` is a string.
		@return A new Integer instance.
	]=]
	new: (value: IntegerLike?, base: number?) -> Integer,

	--[=[
		Parses an Integer from a string.
		This is the most explicit way to construct very large values without going through a Luau number first.
		@param value The source string to parse.
		@param base The radix to use when parsing the string.
		@return A new Integer parsed from `value`.
	]=]
	fromString: (value: string, base: number?) -> Integer,
	--[=[
		Creates an Integer from a Luau number.
		This is convenient for ordinary whole-number code paths.
		@param value The numeric value to convert.
		@return A new Integer equal to `value`.
	]=]
	fromNumber: (value: number) -> Integer,
	--[=[
		Creates an Integer from a signed 64-bit integer.
		Use this when you want to make the fixed-width signed boundary explicit.
		@param value The signed 64-bit input.
		@return A new Integer equal to `value`.
	]=]
	fromI64: (value: integer) -> Integer,
	--[=[
		Creates an Integer from an unsigned 64-bit integer.
		Use this when you want to make the fixed-width unsigned boundary explicit.
		@param value The unsigned 64-bit input.
		@return A new Integer equal to `value`.
	]=]
	fromU64: (value: integer) -> Integer,

	--[=[
		Returns the additive identity.
		This is equivalent to constructing an Integer with value `0`.
		@return The Integer zero.
	]=]
	zero: () -> Integer,
	--[=[
		Returns the multiplicative identity.
		This is equivalent to constructing an Integer with value `1`.
		@return The Integer one.
	]=]
	one: () -> Integer,

	--[=[
		Computes the factorial of a non-negative integer.
		This is exact and can produce very large results.
		@param n The non-negative input value.
		@return `n!` as an Integer.
	]=]
	factorial: (n: Integer | number) -> Integer,
	--[=[
		Computes a binomial coefficient.
		This is the exact value of "n choose k".
		@param n The upper value in the binomial coefficient.
		@param k The selection count.
		@return The binomial coefficient `C(n, k)` as an Integer.
	]=]
	binomial: (n: Integer | number, k: Integer | number) -> Integer,

	--[=[
		Checks whether a value is an Integer userdata produced by this module.
		This is useful for validation and dynamic dispatch.
		@param value The value to inspect.
		@return `true` if `value` is an Integer, otherwise `false`.
	]=]
	isInteger: (value: unknown) -> boolean,
}

type RationalModule = {
	--[=[
		Creates a new Rational from rational-like input.
		Passing both `numerator` and `denominator` constructs the exact quotient of those values.
		@param numerator The source value or numerator component.
		@param denominator The optional denominator component.
		@return A new Rational instance.
	]=]
	new: (numerator: RationalLike?, denominator: RationalLike?) -> Rational,

	--[=[
		Parses a Rational from a string.
		This accepts integer and fractional forms, including slash-separated values.
		@param value The source string to parse.
		@param base The radix to use when parsing the string.
		@return A new Rational parsed from `value`.
	]=]
	fromString: (value: string, base: number?) -> Rational,
	--[=[
		Parses a decimal string into an exact Rational.
		This is useful when you want to preserve the exact value of textual decimal data.
		@param value The decimal string to parse.
		@return A new Rational equal to the parsed decimal value.
	]=]
	fromDecimal: (value: string) -> Rational,
	--[=[
		Creates a Rational from a Luau number.
		This is convenient for interop with ordinary numeric code, though it reflects the input number's floating-point value.
		@param value The numeric value to convert.
		@return A new Rational equal to `value`.
	]=]
	fromFloat: (value: number) -> Rational,
	--[=[
		Promotes an Integer or whole-number value into the rational domain.
		The resulting Rational has denominator `1`.
		@param value The integer-like value to promote.
		@return A new Rational equal to `value / 1`.
	]=]
	fromInteger: (value: Integer | number) -> Rational,

	--[=[
		Returns the additive identity in the rational domain.
		This is equivalent to constructing the Rational value `0/1`.
		@return The Rational zero.
	]=]
	zero: () -> Rational,
	--[=[
		Returns the multiplicative identity in the rational domain.
		This is equivalent to constructing the Rational value `1/1`.
		@return The Rational one.
	]=]
	one: () -> Rational,

	--[=[
		Checks whether a value is a Rational userdata produced by this module.
		This is useful for validation and dynamic dispatch.
		@param value The value to inspect.
		@return `true` if `value` is a Rational, otherwise `false`.
	]=]
	isRational: (value: unknown) -> boolean,
}

type FloatModule = {
	--[=[
		Creates a new Float from float-like input.
		Passing an existing Float preserves its value, and you may optionally override the stored precision.
		@param value The source value to convert into a Float.
		@param precision The precision to use for the new Float, in bits.
		@return A new Float instance.
	]=]
	new: (value: FloatLike?, precision: number?) -> Float,

	--[=[
		Parses a Float from a string.
		This is the most explicit way to construct high-precision floating-point values from textual data.
		@param value The source string to parse.
		@param base The radix to use when parsing the string.
		@param precision The precision to use for the new Float, in bits.
		@return A new Float parsed from `value`.
	]=]
	fromString: (value: string, base: number?, precision: number?) -> Float,
	--[=[
		Creates a Float from a Luau number.
		This is convenient for interop with ordinary floating-point code.
		@param value The numeric value to convert.
		@param precision The precision to use for the new Float, in bits.
		@return A new Float equal to `value`.
	]=]
	fromNumber: (value: number, precision: number?) -> Float,
	--[=[
		Promotes an Integer or whole-number value into the floating-point domain.
		This is useful when you want MPFR-backed operations on an exact integral input.
		@param value The integer-like value to promote.
		@param precision The precision to use for the new Float, in bits.
		@return A new Float equal to `value`.
	]=]
	fromInteger: (value: Integer | number, precision: number?) -> Float,
	--[=[
		Converts a Rational into a Float using the chosen rounding mode.
		This is useful when you want to leave the exact rational domain with explicit precision control.
		@param value The Rational value to convert.
		@param precision The precision to use for the new Float, in bits.
		@param mode The rounding mode to use when conversion is inexact.
		@return A new Float approximation of `value`.
	]=]
	fromRational: (value: Rational, precision: number?, mode: RoundingMode?) -> Float,

	--[=[
		Returns the module-wide default MPFR precision.
		Dynamic Number promotion into floats also follows this shared precision setting.
		@return The default precision in bits.
	]=]
	defaultPrecision: () -> number,
	--[=[
		Sets the module-wide default MPFR precision.
		This affects newly created floats that do not provide an explicit precision, including dynamic Number promotions.
		@param bits The new default precision in bits.
	]=]
	setDefaultPrecision: (bits: number) -> (),

	--[=[
		Returns the additive identity in the floating-point domain.
		This is equivalent to constructing the Float value `0` at the chosen precision.
		@param precision The precision to use for the new Float, in bits.
		@return The Float zero.
	]=]
	zero: (precision: number?) -> Float,
	--[=[
		Returns the multiplicative identity in the floating-point domain.
		This is equivalent to constructing the Float value `1` at the chosen precision.
		@param precision The precision to use for the new Float, in bits.
		@return The Float one.
	]=]
	one: (precision: number?) -> Float,

	--[=[
		Checks whether a value is a Float userdata produced by this module.
		This is useful for validation and dynamic dispatch.
		@param value The value to inspect.
		@return `true` if `value` is a Float, otherwise `false`.
	]=]
	isFloat: (value: unknown) -> boolean,
}

type NumberModule = {
	--[=[
		Creates a new dynamic Number from number-like input.
		Whole values stay in the integer domain when possible, while fractional values use the floating-point domain.
		@param value The source value to convert into a Number.
		@param precision The precision to use when a float-backed Number must be created.
		@return A new Number instance.
	]=]
	new: (value: NumberLike?, precision: number?) -> Number,

	--[=[
		Parses a dynamic Number from a string.
		Integer-looking strings stay in the integer domain, while fractional strings create float-backed values.
		@param value The source string to parse.
		@param base The radix to use when parsing the string.
		@param precision The precision to use when a float-backed Number must be created.
		@return A new Number parsed from `value`.
	]=]
	fromString: (value: string, base: number?, precision: number?) -> Number,
	--[=[
		Creates a dynamic Number from a Luau number.
		Whole numeric inputs stay integer-kind when possible; fractional inputs become float-kind.
		@param value The numeric value to convert.
		@param precision The precision to use when a float-backed Number must be created.
		@return A new Number equal to `value`.
	]=]
	fromNumber: (value: number, precision: number?) -> Number,
	--[=[
		Promotes an Integer or whole-number value into the dynamic Number domain.
		The resulting value is stored as integer-kind Number.
		@param value The integer-like value to promote.
		@return A new integer-kind Number equal to `value`.
	]=]
	fromInteger: (value: Integer | number) -> Number,
	--[=[
		Promotes a Float or plain numeric value into the dynamic Number domain.
		The resulting value is stored as float-kind Number.
		@param value The float-like value to promote.
		@param precision The precision to use when a new float-backed Number must be created.
		@return A new float-kind Number equal to `value`.
	]=]
	fromFloat: (value: Float | number, precision: number?) -> Number,

	--[=[
		Returns the additive identity in the dynamic Number domain.
		This is represented as integer-kind zero.
		@return The Number zero.
	]=]
	zero: () -> Number,
	--[=[
		Returns the multiplicative identity in the dynamic Number domain.
		This is represented as integer-kind one.
		@return The Number one.
	]=]
	one: () -> Number,

	--[=[
		Checks whether a value is a Number userdata produced by this module.
		This is useful for validation and dynamic dispatch.
		@param value The value to inspect.
		@return `true` if `value` is a Number, otherwise `false`.
	]=]
	isNumber: (value: unknown) -> boolean,
}

number.integer = (nil :: any) :: IntegerModule
number.rational = (nil :: any) :: RationalModule
number.float = (nil :: any) :: FloatModule
number.number = (nil :: any) :: NumberModule

return number
