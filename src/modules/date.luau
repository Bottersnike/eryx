--[=[
Lightweight datetime module backed by C++20 `std::chrono`.

Two core types are exposed:
- [[DateTime]]: a specific instant in time, paired with a display timezone.
- [[Duration]]: a signed span of time at nanosecond precision.

## Timezone semantics

A DateTime always stores the true UTC instant internally. The `zone` field only
controls how that instant is *displayed* (local date/time fields, ISO string, etc.).

Instants produced by `fromIso()` or `parse()` carry a **fixed UTC offset** from the
string (e.g. `+05:30`). Fixed-offset instants are unaware of DST. Call `WithZone()`
to attach a named IANA zone so that DST-aware arithmetic and display work correctly.

## Format strings
`Format()`, `FormatUtc()`, and `parse()` accept C++20 `std::chrono` format tokens:

| Token | Meaning                        |
| ----- | ------------------------------ |
| `%Y`  | Four-digit year                |
| `%m`  | Month (01-12)                  |
| `%d`  | Day (01-31)                    |
| `%F`  | `%Y-%m-%d`                     |
| `%H`  | Hour (00-23)                   |
| `%M`  | Minute (00-59)                 |
| `%S`  | Second (00-59) (+ sub-seconds) |
| `%I`  | Hour (01-12)                   |
| `%p`  | AM / PM                        |
| `%T`  | `%H:%M:%S`                     |
| `%R`  | `%H:%M`                        |
| `%A`  | Full weekday name              |
| `%B`  | Full month name                |
| `%j`  | Day of year                    |
| `%a`  | Abbreviated weekday            |
| `%b`  | Abbreviated month              |
| `%Z`  | Timezone name / offset         |
| `%z`  | UTC offset +HHMM               |
| `%Ez` | UTC offset +HH:MM              |

Literal `{` or `}` in a format string must be escaped as `{{` or `}}`.
]=]

local date = {}

--[=[
	A signed span of time stored at nanosecond precision.

	**Component fields** give the *remainder* at each unit after larger units are
	subtracted (e.g. for a 90-second duration, `minutes` = 1 and `seconds` = 30).

	**Total fields** give the entire duration expressed as a floating-point count
	of the named unit (e.g. for 90 seconds, `totalMinutes` ≈ 1.5).

	Supported operators: `+`, `-`, `*` (scale by number), `/` (scale by number;
	dividing two Durations yields a `number` ratio), unary `-`, `==`, `<`, `<=`.
]=]
export type Duration = setmetatable<
	{
		--- Days component
		days: number,
		--- Hours component
		hours: number,
		--- Minutes component
		minutes: number,
		--- Seconds component
		seconds: number,
		--- Milliseconds component
		milliseconds: number,
		--- Microseconds component
		microseconds: number,
		--- Nanoseconds component
		nanoseconds: number,
		--- Sub-second remainder as a floating-point fraction of a second.
		subSeconds: number,

		--- Total days
		totalDays: number,
		--- Total hours
		totalHours: number,
		--- Total minutes
		totalMinutes: number,
		--- Total seconds
		totalSeconds: number,
		--- Total milliseconds
		totalMilliseconds: number,
		--- Total microseconds
		totalMicroseconds: number,
		--- Total nanoseconds
		totalNanoseconds: number,

		--- Returns a new Duration with the same magnitude but always non-negative.
		Abs: (self: Duration) -> Duration,
	},
	{
		__add: (self: Duration, delta: Duration) -> Duration,
		__sub: (self: Duration, delta: Duration) -> Duration,
		--- Multiply by a scalar. Also works as `number * Duration`.
		__mul: (self: Duration, other: number) -> Duration,
		--- Divide by a scalar number. Dividing by another Duration yields a `number` ratio.
		__div: (self: Duration, other: number) -> Duration,
		__unm: (self: Duration) -> Duration,
		__eq: (self: Duration, other: Duration) -> boolean,
		__lt: (self: Duration, other: Duration) -> boolean,
		__le: (self: Duration, other: Duration) -> boolean,
		__tostring: (self: Duration) -> string,
	}
>

--[=[
A specific instant in time paired with a display timezone.

All calendar fields (`year`, `month`, ...) reflect **local time** in the
associated `zone`. The underlying UTC instant is unchanged by `WithZone()`.

Supported operators: `+` / `-` with a Duration (shifts the instant),
`==`, `<`, `<=` (compare UTC instants regardless of zone).
Subtracting two DateTimes is not supported via `-`; use `Diff()` instead.
]=]
export type DateTime = setmetatable<
	{
		--- Gregorian year (e.g. 2024)
		year: number,
		--- Month of year, 1 = January, 12 = December
		month: number,
		--- Day of month, 1–31
		day: number,
		--- Hour of day, 0–23
		hour: number,
		--- Minute of hour, 0–59
		minute: number,
		--- Second of minute, 0–59
		second: number,
		--- Nanosecond of second, 0–999999999
		nanosecond: number,

		--- IANA timezone name (e.g. `"America/New_York"`) for named-zone instants,
		--- or a fixed UTC offset string (e.g. `"+05:30"`) for fixed-offset instants.
		zone: string,
		--- UTC offset in **seconds** for the instant (accounts for DST when using a
		--- named zone).
		offset: number,
		--- ISO 8601 weekday: 1 = Monday, 7 = Sunday.
		weekday: number,
		--- Day of the year: 1 = January 1, 365/366 = December 31.
		dayOfYear: number,
		--- `true` when the year of this instant is a leap year.
		isLeap: boolean,
		--- `true` when this instant falls within a DST period.
		--- Always `false` for fixed-offset instants (they have no DST concept).
		isDst: boolean,

		--- Returns an ISO 8601 string such as `"2024-03-15T10:30:00+05:30"`.
		--- Sub-seconds are included only when non-zero.
		ToIsoString: (self: DateTime) -> string,

		--- Returns the UTC Unix timestamp as a **whole number of seconds**.
		ToUnix: (self: DateTime) -> number,

		--- Returns the UTC Unix timestamp as a **whole number of milliseconds**.
		ToUnixMs: (self: DateTime) -> number,

		--- Returns a new DateTime representing the same UTC instant displayed in
		--- `zone`. Converts a fixed-offset instant into a DST-aware named-zone one.
		--- Throws if `zone` is not a valid IANA timezone name.
		WithZone: (self: DateTime, zone: string) -> DateTime,

		--- Returns a Duration equal to `self − other` (positive when `self` is later).
		Diff: (self: DateTime, other: DateTime) -> Duration,

		--- Formats local time using a chrono format string (see module docs for tokens).
		--- For fixed-offset instants, `%z`/`%Ez`/`%Z` expand to the literal offset.
		--- Example: `dt:Format("%Y-%m-%d %H:%M")` -> `"2024-03-15 10:30"`
		Format: (self: DateTime, fmt: string) -> string,

		--- Formats the underlying **UTC** time using a chrono format string.
		--- `%z` will always output `+0000`.
		FormatUtc: (self: DateTime, fmt: string) -> string,

		--- Returns a new DateTime at midnight (00:00:00.000000000) of the same
		--- local calendar day, preserving the zone/offset.
		StartOfDay: (self: DateTime) -> DateTime,

		--- Returns a new DateTime shifted by `n` calendar months (may be negative).
		--- The day is clamped to the last valid day of the target month
		--- (e.g. Jan 31 + 1 month -> Feb 28/29).
		AddMonths: (self: DateTime, n: number) -> DateTime,

		--- Returns a new DateTime shifted by `n` calendar years (may be negative).
		--- Equivalent to `AddMonths(n * 12)`.
		AddYears: (self: DateTime, n: number) -> DateTime,
	},
	{
		--- Shift the instant forward by a Duration.
		__add: (self: DateTime, delta: Duration) -> DateTime,
		--- Shift the instant backward by a Duration.
		__sub: (self: DateTime, delta: Duration) -> DateTime,
		--- Compare UTC instants for equality (zone is ignored).
		__eq: (self: DateTime, other: DateTime) -> boolean,
		__lt: (self: DateTime, other: DateTime) -> boolean,
		__le: (self: DateTime, other: DateTime) -> boolean,
		__tostring: (self: DateTime) -> string,
	}
>

--[=[
	Returns the current instant.
	@param zone  Optional IANA timezone name. Defaults to the system local zone.
	@error Throws if `zone` is not a recognised IANA timezone name.
]=]
function date.now(zone: string?): DateTime
	return nil :: any
end

--[=[
	Parses an ISO 8601 timestamp string (e.g. `"2024-03-15T10:30:00+05:30"`).
	The UTC offset embedded in the string is stored as a fixed offset; call
	`WithZone()` on the result if you need DST-aware behaviour.
	@error Throws if the string is not a valid ISO 8601 timestamp.
]=]
function date.fromIso(s: string): DateTime
	return nil :: any
end

--[=[
	Creates a DateTime from a Unix timestamp (seconds since 1970-01-01T00:00:00Z).
	Fractional seconds are supported (nanosecond precision).
	@param ts    Seconds since the Unix epoch (may be fractional).
	@param zone  Optional IANA timezone name. Defaults to the system local zone.
]=]
function date.fromTimestamp(ts: number, zone: string?): DateTime
	return nil :: any
end

--[=[
	Creates a DateTime from individual calendar fields in the given timezone.
	Missing optional fields default to 0. The day is not clamped – passing an
	invalid date (e.g. February 30) raises an error.
	@param fields  Table with required keys `year`, `month`, `day` and optional
				keys `hour`, `minute`, `second`, `nanosecond`.
	@param zone    IANA timezone name. Defaults to the system local zone.
	@error Throws if `zone` is invalid or the date fields are out of range.
]=]
function date.fromFields(
	fields: {
		year: number,
		month: number,
		day: number,
		hour: number?,
		minute: number?,
		second: number?,
		nanosecond: number?,
	},
	zone: string?
): DateTime
	return nil :: any
end

--[=[
	Parses a datetime string using a chrono format string (see module docs for tokens).
	@param s    The input string to parse.
	@param fmt  A chrono format string, e.g. `"%Y-%m-%d %H:%M:%S"`.
	@param zone Optional IANA timezone name. If omitted, the UTC offset parsed from
				the string is stored as a fixed offset; if no offset was parsed, the
				system local zone is assumed.
	@error Throws if the string does not match the format.
]=]
function date.parse(s: string, fmt: string, zone: string?): DateTime
	return nil :: any
end

--- Returns the IANA name of the system's local timezone (e.g. `"America/New_York"`).
function date.timezone(): string
	return nil :: any
end

--- Returns a list of all recognised IANA timezone names in the embedded TZ database.
function date.timezones(): { string }
	return nil :: any
end

--- Returns `true` when `year` is a leap year.
function date.isLeap(year: number): boolean
	return nil :: any
end

--- Returns the number of days in `month` of `year` (accounts for leap years).
--- `month` is 1-based (1 = January).
function date.daysInMonth(year: number, month: number): number
	return nil :: any
end

--- Returns a Duration of exactly `n` nanoseconds.
function date.nanoseconds(n: number): Duration
	return nil :: any
end

--- Returns a Duration of exactly `n` milliseconds.
function date.milliseconds(n: number): Duration
	return nil :: any
end

--- Returns a Duration of exactly `n` seconds.
function date.seconds(n: number): Duration
	return nil :: any
end

--- Returns a Duration of exactly `n` minutes.
function date.minutes(n: number): Duration
	return nil :: any
end

--- Returns a Duration of exactly `n` hours.
function date.hours(n: number): Duration
	return nil :: any
end

--- Returns a Duration of exactly `n` days (always 24 × 3600 seconds; not
--- calendar-aware – use `adddays` on DateTime for wall-clock days).
function date.days(n: number): Duration
	return nil :: any
end

return date
