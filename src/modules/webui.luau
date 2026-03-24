--[=[
WebUi is a simple wrapper on top of [[webview]] that provides utilities
for message passing and event binding.

```luau
local ui = webui.new("IPC Demo")

ui.win:navigateToString(fs.open("web.html")):read())
ui.win:show()

ui:on("chat"):connect(function(data)
	ui:post("chat", { message = `Echo: {data.message}` })
end)

ui:onJsEvent("#clickme", "click"):connect(function()
	print("Button clicked")
end)
```
]=]

local Signal = require("@eryx/Signal")
local json = require("@eryx/encoding/json")
local wv = require("@eryx/webview")

local WebUi = {}
WebUi.__index = WebUi

export type WebUi = setmetatable<
	{
		--- The WebView window
		win: wv.WebViewHandle,
		_handlers: { { event: string, sig: Signal.Signal<{}> } },
		_eventHandlers: { Signal.Signal<()> },
	},
	typeof(WebUi)
>

--- Create a new WebUi
--- @param title The window title
function WebUi.new(title: string): WebUi
	local this = {
		win = wv.create({ title = title, hidden = true }),
		_handlers = {},
		_eventHandlers = {},
	}
	this.win:center()

	this.win:onMessage(function(event, data)
		if event == "__webui_event" then
			for n, i in this._eventHandlers do
				if n == data.key then
					i:fire()
				end
			end
		else
			for _, i in this._handlers do
				if i.event == event then
					i.sig:fire(data)
				end
			end
		end
	end)

	return setmetatable(this, WebUi)
end

--- Bind to a JavaScript event
--- @param selector CSS element selector, such as `"#foo"`
--- @param event JavaScript event, such as `"click"`
--- @return A signal that fires every time the event occurs
function WebUi.onJsEvent(self: WebUi, selector: string, event: string): Signal.Signal<()>
	local sig = Signal.new()

	local key = #self._eventHandlers + 1

	self.win:executeScript("document.addEventListener(" .. json.encode(event) .. [[, (e) => {
	if (!e.target.matches(]] .. json.encode(selector) .. [[)) return;
	eryx.post("__webui_event", {key:]] .. tostring(key) .. [[})
})]])

	table.insert(self._eventHandlers, sig)

	return sig
end

--- Bind to an `eryx.post` event
--- @param event The event to bind to
--- @return A signal that fires every time the event is posted
function WebUi.on(self: WebUi, event: string): Signal.Signal<{}>
	local sig = Signal.new()

	table.insert(self._handlers, { event = event, sig = sig })

	return sig
end

--- Post a message to an `eryx.on` listener
--- @param event The event to send
--- @param data The data to post
function WebUi.post(self: WebUi, event: string, data: { [any]: any }?)
	self.win:postMessage(event, data or {})
end

return table.freeze(WebUi)
