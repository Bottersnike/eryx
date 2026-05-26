--[=[
	Serial port I/O library backed by OS serial APIs.

	Supports full-duplex communication over RS-232, USB CDC, and similar
	serial interfaces. Reads are asynchronous and yield the calling
	coroutine without blocking the event loop.

	```luau
	local serial = require("@eryx/serial")

	local port = serial.open("COM3", { baudRate = 115200 })
	port:write("hello\r\n")
	local response = port:read(64, 1000) -- up to 64 bytes, 1 s timeout
	port:close()
	```
]=]
local stream = require("@eryx/stream")

--[=[
	Options passed to `serial.open`.
]=]
export type PortOptions = {
	--[=[
		Baud rate in bits per second. Common values: 9600, 19200, 38400,
		57600, 115200, 230400. Defaults to `9600`.
	]=]
	baudRate: number?,
	--[=[
		Number of data bits per character: 5, 6, 7, or 8. Defaults to `8`.
	]=]
	dataBits: number?,
	--[=[
		Number of stop bits: 1 or 2. Defaults to `1`.
	]=]
	stopBits: number?,
	--[=[
		Parity mode. Defaults to `"none"`.
	]=]
	parity: ("none" | "odd" | "even")?,
}

--[=[
	Information about a serial port returned by `serial.list`.
	Fields beyond `name` are present only when the OS can supply them
	(typically USB-to-serial adapters; native UARTs usually only have `name`).
]=]
export type PortInfo = {
	--[=[
		Device path, e.g. `"COM3"` on Windows or `"/dev/ttyUSB0"` on Linux.
	]=]
	name: string,
	--[=[
		Human-readable product description, e.g. `"USB Serial Port (COM3)"`.
	]=]
	description: string?,
	--[=[
		Raw hardware ID string. On Windows this is the SetupAPI hardware ID;
		on Linux it is a `"USB VID:PID=xxxx:yyyy"` style string.
	]=]
	hwid: string?,
	--- USB vendor ID as an integer.
	vid: number?,
	--- USB product ID as an integer.
	pid: number?,
	--- USB manufacturer string reported by the device.
	manufacturer: string?,
	--- USB serial number reported by the device.
	serialNumber: string?,
}

--[=[
	State of the modem-control input lines on a serial port.
]=]
export type Signals = {
	--- Clear To Send.
	cts: boolean,
	--- Data Set Ready.
	dsr: boolean,
	--- Data Carrier Detect.
	dcd: boolean,
	--- Ring Indicator.
	ri: boolean,
}

--[=[
	An open serial port.
]=]
export type SerialPort = setmetatable<
	{},
	{
		__index: {
			--[=[
				Read bytes from the port.

				- `:read()` — non-blocking; returns all bytes currently in the OS
				receive buffer, or `""` if none are available.
				- `:read(n)` — blocks until between 1 and `n` bytes arrive.
				- `:read(n, timeout)` — blocks up to `timeout` milliseconds; returns
				`nil` if no bytes arrived before the timeout. Pass `0` for an
				instant non-blocking check.
				- `:read(nil, timeout)` — waits up to `timeout` ms for any data, then
				drains the receive buffer (up to 64 KB); returns `nil` on timeout.

				Throws on device errors (e.g. disconnection).
				@param size maximum bytes to read; omit to drain the buffer non-blocking
				@param timeout timeout in milliseconds; 0 = non-blocking
				@yields
			]=]
			read: ((self: stream.StreamThatCanRead, size: number?) -> string)
				& ((self: stream.StreamThatCanRead, size: number?, timeout: number) -> string?),

			--[=[
				Discard buffered data in the OS receive or transmit queue.
				@param direction ("input" | "output" | "both")? -- defaults to `"both"`
			]=]
			flush: (self: SerialPort, direction: ("input" | "output" | "both")?) -> (),

			--[=[
				Set the DTR (Data Terminal Ready) output line.
				@param value boolean
			]=]
			setDTR: (self: SerialPort, value: boolean) -> (),

			--[=[
				Set the RTS (Request To Send) output line.
				@param value boolean
			]=]
			setRTS: (self: SerialPort, value: boolean) -> (),

			--[=[
				Read the state of the modem-control input lines (CTS, DSR, DCD, RI).
			]=]
			getSignals: (self: SerialPort) -> Signals,

			--- Number of bytes currently in the OS receive buffer (available to read).
			read inWaiting: number,
			--- Number of bytes currently in the OS transmit buffer (not yet sent).
			read outWaiting: number,
		},
	}
>

local serial = {}

--[=[
	Open a serial port.

	```luau
	local port = serial.open("/dev/ttyUSB0", { baudRate = 9600, parity = "even" })
	```

	@param port device name, e.g. `"COM3"` or `"/dev/ttyUSB0"`
	@param options port configuration; all fields are optional
]=]
function serial.open(port: string, options: PortOptions?): SerialPort
	return nil :: any
end

--[=[
	Enumerate available serial ports on the system.

	Returns a list of `PortInfo` tables. USB-to-serial adapters typically
	populate the extra fields (`vid`, `pid`, `manufacturer`, etc.); built-in
	UARTs usually only have `name`.

	```luau
	for _, info in serial.list() do
	    print(info.name, info.description)
	end
	```
]=]
function serial.list(): { PortInfo }
	return nil :: any
end

return table.freeze(serial)
