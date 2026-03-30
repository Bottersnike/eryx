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

local multipart = {}

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

return table.freeze(multipart)
