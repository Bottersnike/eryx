--[=[
	A single field in a multipart form.

	For file uploads, provide `filename` and optionally `contentType`.
	The `value` is the raw file content as a string.
]=]
export type MultipartField = {
	--- The form field name.
	name: string,
	--- The field value (text or file content).
	value: string,
	--- Optional filename for file upload fields.
	filename: string?,
	--- Optional MIME type. Defaults to `application/octet-stream` for files.
	contentType: string?,
}

export type ParsedMultipartField = {
	name: string,
	value: string,
	filename: string?,
	contentType: string?,
	headers: { [string]: string },
}

local multipart = {}

local util = require("./util")

--[=[
	Encodes a list of form fields as a `multipart/form-data` body.

	Returns the encoded body string and the `Content-Type` header
	(which includes the boundary). Pass both to a request function:

	```luau
	local body, contentType = http.multipart({
	    { name = "username", value = "alice" },
	    { name = "avatar", value = fileContents, filename = "photo.png", contentType = "image/png" },
	})

	local resp = http.post("http://example.com/upload", body, {
	    headers = { ["Content-Type"] = contentType },
	})
	```

	@param fields A list of [[MultipartField]] entries.
	@return string -- The encoded multipart body.
	@return string -- The `Content-Type` header value including boundary.
]=]
function multipart.encodeFields(fields: { MultipartField }): (string, string)
	-- Generate a random boundary that won't appear in any field value
	local boundary = "----EryxBoundary"
	for _ = 1, 4 do
		boundary ..= string.format("%08x", math.random(0, 0x7FFFFFFF))
	end

	local parts: { string } = {}

	for _, field in fields do
		local header = "--" .. boundary .. "\r\n"
		if field.filename then
			header ..= 'Content-Disposition: form-data; name="' .. field.name .. '"; filename="' .. field.filename .. '"\r\n'
			header ..= "Content-Type: " .. (field.contentType or "application/octet-stream") .. "\r\n"
		else
			header ..= 'Content-Disposition: form-data; name="' .. field.name .. '"\r\n'
			if field.contentType then
				header ..= "Content-Type: " .. field.contentType .. "\r\n"
			end
		end
		header ..= "\r\n"

		table.insert(parts, header)
		table.insert(parts, field.value)
		table.insert(parts, "\r\n")
	end

	table.insert(parts, "--" .. boundary .. "--\r\n")

	return table.concat(parts), "multipart/form-data; boundary=" .. boundary
end

local function trimTrailingCrlf(value: string): string
	if string.sub(value, -2) == "\r\n" then
		return string.sub(value, 1, -3)
	end
	return value
end

local function parseContentDisposition(value: string?): { name: string?, filename: string? }
	local result = { name = nil :: string?, filename = nil :: string? }
	if value == nil then
		return result
	end

	for paramName, paramValue in string.gmatch(value, ';%s*([^=]+)="([^"]*)"') do
		local lowered = string.lower(paramName)
		if lowered == "name" then
			result.name = paramValue
		elseif lowered == "filename" then
			result.filename = paramValue
		end
	end

	return result
end

--[=[
	Parses a `multipart/form-data` body into individual fields.

	Pass the raw body and either the full `Content-Type` header value or
	just the boundary string.
]=]
function multipart.parse(body: string, contentTypeOrBoundary: string): { ParsedMultipartField }
	local boundary = contentTypeOrBoundary
	if string.find(contentTypeOrBoundary, "multipart/", 1, true) then
		local parsed = util.parseContentType(contentTypeOrBoundary)
		boundary = parsed.params.boundary or ""
	end

	if boundary == "" then
		error("multipart.parse: missing boundary")
	end

	local delimiter = "--" .. boundary
	local closeDelimiter = delimiter .. "--"
	local fields = {}
	local position = 1

	while true do
		local startPos, endPos = string.find(body, delimiter, position, true)
		if not startPos or not endPos then
			break
		end

		position = endPos + 1
		if string.sub(body, startPos, startPos + #closeDelimiter - 1) == closeDelimiter then
			break
		end

		if string.sub(body, position, position + 1) == "\r\n" then
			position += 2
		end

		local nextDelimiterPos = string.find(body, "\r\n" .. delimiter, position, true)
		if not nextDelimiterPos then
			break
		end

		local part = string.sub(body, position, nextDelimiterPos - 1)
		position = nextDelimiterPos + 2

		local headerEnd = string.find(part, "\r\n\r\n", 1, true)
		if not headerEnd then
			continue
		end

		local headersRaw = string.sub(part, 1, headerEnd - 1)
		local value = trimTrailingCrlf(string.sub(part, headerEnd + 4))
		local headers = util.parseHeaders(headersRaw)
		local disposition = parseContentDisposition(headers["content-disposition"])

		table.insert(fields, {
			name = disposition.name or "",
			value = value,
			filename = disposition.filename,
			contentType = headers["content-type"],
			headers = headers,
		})
	end

	return fields
end

return table.freeze(multipart)
