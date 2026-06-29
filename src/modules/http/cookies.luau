local cookies = {}

local MONTHS = {
	jan = 1,
	feb = 2,
	mar = 3,
	apr = 4,
	may = 5,
	jun = 6,
	jul = 7,
	aug = 8,
	sep = 9,
	oct = 10,
	nov = 11,
	dec = 12,
}

local function trim(value: string): string
	return string.match(value, "^%s*(.-)%s*$") or ""
end

local function daysFromCivil(year: number, month: number, day: number): number
	local y = year
	local m = month
	y -= if m <= 2 then 1 else 0
	local era = if y >= 0 then math.floor(y / 400) else math.floor((y - 399) / 400)
	local yoe = y - era * 400
	local monthPrime = m + (if m > 2 then -3 else 9)
	local doy = math.floor((153 * monthPrime + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function toUnixTimestampUtc(
	year: number,
	month: number,
	day: number,
	hour: number,
	minute: number,
	second: number
): number?
	if
		month < 1
		or month > 12
		or day < 1
		or hour < 0
		or hour > 23
		or minute < 0
		or minute > 59
		or second < 0
		or second > 59
	then
		return nil
	end

	local maxDay = if month == 2
		then ((year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)) and 29 or 28
		elseif month == 4 or month == 6 or month == 9 or month == 11 then 30
		else 31
	if day > maxDay then
		return nil
	end

	return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

local function parseCookieExpires(value: string): number?
	local cleaned = trim(value)

	local day, monthName, year, hour, minute, second =
		string.match(cleaned, "^[A-Za-z]+,%s*(%d%d?)%s+([A-Za-z]+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s+GMT$")
	if day and monthName and year and hour and minute and second then
		local month = MONTHS[string.lower(monthName)]
		if month then
			return toUnixTimestampUtc(
				tonumber(year) :: number,
				month,
				tonumber(day) :: number,
				tonumber(hour) :: number,
				tonumber(minute) :: number,
				tonumber(second) :: number
			)
		end
	end

	local day2, monthName2, year2, hour2, minute2, second2 =
		string.match(cleaned, "^[A-Za-z]+,%s*(%d%d?)%-([A-Za-z]+)%-(%d%d)%s+(%d%d):(%d%d):(%d%d)%s+GMT$")
	if day2 and monthName2 and year2 and hour2 and minute2 and second2 then
		local month = MONTHS[string.lower(monthName2)]
		local shortYear = tonumber(year2)
		if month and shortYear then
			local fullYear = if shortYear >= 70 then 1900 + shortYear else 2000 + shortYear
			return toUnixTimestampUtc(
				fullYear,
				month,
				tonumber(day2) :: number,
				tonumber(hour2) :: number,
				tonumber(minute2) :: number,
				tonumber(second2) :: number
			)
		end
	end

	local monthName3, day3, hour3, minute3, second3, year3 =
		string.match(cleaned, "^[A-Za-z]+%s+([A-Za-z]+)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+(%d%d%d%d)$")
	if monthName3 and day3 and hour3 and minute3 and second3 and year3 then
		local month = MONTHS[string.lower(monthName3)]
		if month then
			return toUnixTimestampUtc(
				tonumber(year3) :: number,
				month,
				tonumber(day3) :: number,
				tonumber(hour3) :: number,
				tonumber(minute3) :: number,
				tonumber(second3) :: number
			)
		end
	end

	return nil
end

--[=[
	A single HTTP cookie with its attributes.
]=]
export type Cookie = {
	name: string,
	value: string,
	domain: string,
	path: string,
	expires: number?, -- os.time() timestamp, nil = session cookie
	secure: boolean,
	httpOnly: boolean,
	sameSite: string?, -- "Strict", "Lax", or "None"
}

--- Parse a Set-Cookie header value into a Cookie table.
--- `requestHost` and `requestPath` provide defaults when the cookie
--- does not specify Domain or Path.
function cookies.parseCookie(setCookieStr: string, requestHost: string, requestPath: string): Cookie?
	-- Split on ";" to get name=value and attributes
	local parts: { string } = {}
	for part in string.gmatch(setCookieStr, "([^;]+)") do
		table.insert(parts, part)
	end

	if #parts == 0 then
		return nil
	end

	-- First part is name=value
	local nameValue = parts[1]
	local eqPos = string.find(nameValue, "=", 1, true)
	if not eqPos then
		return nil
	end

	local name = trim(string.sub(nameValue, 1, eqPos - 1))
	local value = trim(string.sub(nameValue, eqPos + 1))
	if not name or #name == 0 then
		return nil
	end

	local cookie: Cookie = {
		name = name :: string,
		value = value or "",
		domain = string.lower(requestHost),
		path = string.match(requestPath, "^(.*/)[^/]*$") or "/",
		expires = nil,
		secure = false,
		httpOnly = false,
		sameSite = nil,
	}

	-- Parse attributes
	for i = 2, #parts do
		local attr = trim(parts[i])
		local attrName, attrValue = string.match(attr, "^([^=]+)=?(.*)$")
		if attrName then
			local lowerAttr = string.lower(trim(attrName))
			attrValue = trim(attrValue or "")

			if lowerAttr == "domain" then
				local d = string.lower(attrValue)
				-- Strip leading dot (RFC 6265 §5.2.3)
				if string.sub(d, 1, 1) == "." then
					d = string.sub(d, 2)
				end
				cookie.domain = d
			elseif lowerAttr == "path" then
				if #attrValue > 0 then
					cookie.path = attrValue
				end
			elseif lowerAttr == "max-age" then
				local seconds = tonumber(attrValue)
				if seconds then
					cookie.expires = os.time() + seconds
				end
			elseif lowerAttr == "expires" then
				local expires = parseCookieExpires(attrValue)
				if expires then
					cookie.expires = expires
				end
			elseif lowerAttr == "secure" then
				cookie.secure = true
			elseif lowerAttr == "httponly" then
				cookie.httpOnly = true
			elseif lowerAttr == "samesite" then
				cookie.sameSite = attrValue
			end
		end
	end

	return cookie
end

--- Check if a cookie's domain matches the request host.
--- Per RFC 6265 §5.1.3: exact match or host ends with ".domain".
function cookies.domainMatches(cookieDomain: string, requestHost: string): boolean
	requestHost = string.lower(requestHost)
	if cookieDomain == requestHost then
		return true
	end
	-- requestHost ends with ".cookieDomain"
	local suffix = "." .. cookieDomain
	if #requestHost > #suffix and string.sub(requestHost, -#suffix) == suffix then
		return true
	end
	return false
end

--- Check if a cookie's path matches the request path.
--- Per RFC 6265 §5.1.4.
function cookies.pathMatches(cookiePath: string, requestPath: string): boolean
	if cookiePath == requestPath then
		return true
	end
	if string.sub(requestPath, 1, #cookiePath) == cookiePath then
		if string.sub(cookiePath, -1) == "/" then
			return true
		end
		if string.sub(requestPath, #cookiePath + 1, #cookiePath + 1) == "/" then
			return true
		end
	end
	return false
end

return table.freeze(cookies)
