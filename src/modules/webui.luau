local Signal = require("@eryx/Signal")
local json = require("@eryx/encoding/json")
local wv = require("@eryx/webview")

local WebUi = {}
WebUi.__index = WebUi
export type WebUi = setmetatable<{
	win: wv.WebViewHandle,
	_handlers: { { event: string, sig: Signal.Signal<{}> } },
}, typeof(WebUi)>

function WebUi.new(title: string): WebUi
	local this = {
		win = wv.create({ title = title, hidden = true }),
		_handlers = {},
	}
	this.win:center()

	this.win:onMessage(function(raw)
		local ok, msg = pcall(json.decode, raw)
		if not ok or type(msg) ~= "table" or type(msg.type) ~= "string" then
			return
		end

		local msgType = msg.type
		local msgData = if type(msg.data) == "table" then msg.data else {}

		for _, i in this._handlers do
			if i.event == msgType then
				i.sig:fire(msgData)
			end
		end
	end)

	return setmetatable(this, WebUi)
end

function WebUi.on(self: WebUi, event: string): Signal.Signal<{}>
	local sig = Signal.new()

	table.insert(self._handlers, { event = event, sig = sig })

	return sig
end
function WebUi.fire(self: WebUi, event: string, data: {}?)
	-- self.win:postMessage(json.encode({ type = event, data = data or {} }))
	self.win:postMessage(event, data or {})
end

return table.freeze(WebUi)
