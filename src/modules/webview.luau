--[=[
	WebView2 window integration.

	This module is a typed facade over an optional native backend. In
	builds without WebView support, or on unsupported platforms,
	`require("@eryx/webview")` fails immediately with a clear capability
	error.
]=]

local capability = require("@eryx/capability")
local webview = {}

--- Options table for creating a new WebView window.
export type WebViewOptions = {
	--- Window title. Defaults to `"WebView"`.
	title: string?,
	--- Window width in pixels. Defaults to `1200`.
	width: number?,
	--- Window height in pixels. Defaults to `900`.
	height: number?,
	--- Initial URL to navigate to.
	url: string?,
	--- If `true`, the window has no title bar or borders (`WS_POPUP` style). Defaults to `false`.
	borderless: boolean?,
	--- If `false`, the window cannot be resized by the user. Defaults to `true`.
	resizable: boolean?,
	--- If `true`, the window is not shown after creation. Call `handle:show()` to reveal it. Defaults to `false`.
	hidden: boolean?,
	--- If `true`, enables per-pixel window transparency. Areas with no CSS background
	--- (or semi-transparent backgrounds) will show through to whatever is underneath.
	--- Automatically implies `borderless = true` (the DWM title bar is always opaque).
	--- Defaults to `false`.
	transparent: boolean?,
}

--- A handle to a WebView2 window.
export type WebViewHandle = {
	--- Navigates the webview to a URL.
	--- @param url -- The URL to navigate to.
	navigate: (self: WebViewHandle, url: string) -> (),

	--- Renders raw HTML content in the webview.
	--- @param html -- The HTML string to display.
	navigateToString: (self: WebViewHandle, html: string) -> (),

	--- Sends data to the web content. Received via `window.chrome.webview.addEventListener('message', ...)` in JavaScript.
	--- @param event -- The event category.
	--- @param data -- The data to send.
	postMessage: (self: WebViewHandle, event: string, data: { [any]: any }) -> (),

	--- Executes a JavaScript snippet inside the webview. Fire-and-forget; does not return a result.
	--- @param script -- The JavaScript code to execute.
	executeScript: (self: WebViewHandle, script: string) -> (),

	--- Add a JavaScript snippet to run before any page loads
	--- @param script -- The JavaScript code to execute.
	addInitScript: (self: WebViewHandle, script: string) -> (),

	--- Changes the window title.
	--- @param title -- The new window title.
	setTitle: (self: WebViewHandle, title: string) -> (),

	--- Shows the window (e.g. after creating with `hidden = true`).
	show: (self: WebViewHandle) -> (),

	--- Hides the window without destroying it.
	hide: (self: WebViewHandle) -> (),

	--- Resizes the window.
	--- @param width -- New width in pixels.
	--- @param height -- New height in pixels.
	resize: (self: WebViewHandle, width: number, height: number) -> (),

	--- Moves the window to an absolute screen position.
	--- @param x -- X coordinate in pixels.
	--- @param y -- Y coordinate in pixels.
	move: (self: WebViewHandle, x: number, y: number) -> (),

	--- Centers the window on the monitor it currently occupies.
	center: (self: WebViewHandle) -> (),

	--- Registers a callback for messages sent from web content via `window.chrome.webview.postMessage(...)`.
	--- @param callback -- Called with the message string each time a message is received.
	onMessage: (self: WebViewHandle, callback: (event: string, data: { [any]: any }) -> ()) -> (),

	--- Registers a callback invoked when the user attempts to close the window (e.g. clicks the X button).
	--- While a callback is set, the default close is suppressed; call `handle:destroy()` from the callback to actually close the window.
	--- @param callback -- Called when a close is requested.
	onClose: (self: WebViewHandle, callback: () -> ()) -> (),

	--- Toggles whether the window can be resized by the user.
	--- @param resizable -- `true` to allow resizing, `false` to prevent it.
	setResizable: (self: WebViewHandle, resizable: boolean) -> (),

	--- Toggles borderless mode. When borderless, the window has no title bar or borders (`WS_POPUP` style).
	--- @param borderless -- `true` for borderless, `false` to restore the standard window frame.
	setBorderless: (self: WebViewHandle, borderless: boolean) -> (),

	--- Toggles per-pixel window transparency at runtime. When enabled, any area without
	--- a CSS background (or with a semi-transparent one) will show through to windows beneath.
	--- @param transparent -- `true` for transparent, `false` for opaque.
	setTransparent: (self: WebViewHandle, transparent: boolean) -> (),

	--- Sets the overall window opacity using a layered window.
	--- @param alpha -- Opacity from `0.0` (fully transparent) to `1.0` (fully opaque).
	setOpacity: (self: WebViewHandle, alpha: number) -> (),

	--- Destroys the window and releases all resources. The handle becomes invalid after this call.
	destroy: (self: WebViewHandle) -> (),
}

--- Creates a new WebView2 window. Yields until the WebView2 runtime is fully initialised.
--- @param options -- Optional configuration for the window.
--- @return WebViewHandle -- A handle to control the created window.
--- @yields
function webview.create(options: WebViewOptions?): WebViewHandle
	return nil :: any
end

return table.freeze(
	capability.require(
		"@eryx/_native/webview",
		"WebView window support",
		"Use a Windows build with WebView support to require @eryx/webview."
	)
) :: typeof(webview)
