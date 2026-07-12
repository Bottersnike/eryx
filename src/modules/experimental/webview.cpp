#include <cstring>
#include <string>
#include <unordered_set>

#include "../runtime/lmarshall.hpp"
#include "module_api.h"
#include "uv.h"

// Windows comes first
#include <Windows.h>
#include <wrl.h>
// Then COM
#include <wil/com.h>
// Then WV2
#include <WebView2.h>
#include <dwmapi.h>
#pragma comment(lib, "dwmapi.lib")

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_webview",
};
LUAU_MODULE_INFO()

using namespace Microsoft::WRL;

const wchar_t* WEBVIEW_IPC_SCRIPT =
    LR"V0G0N(
window.eryx = (() => {
	const webview = window.chrome.webview;
	window.chrome.webview = undefined;

	// -- Binary marshalling constants (must match lmarshall.hpp) --
	const ETYPE_NULL = 0x00, ETYPE_TRUE = 0x01, ETYPE_FALSE = 0x02,
		ETYPE_DOUBLE = 0x03, ETYPE_STRING = 0x04, ETYPE_BUFFER = 0x05,
		ETYPE_VECTOR = 0x06, ETYPE_INTEGER = 0x07, ETYPE_TABLE = 0x11,
		ETYPE_TABLE_HASH_DELIM = 0x12;

	// -- Base64 decode --
	const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	const B64_LUT = new Uint8Array(128);
	for (let i = 0; i < B64.length; i++) B64_LUT[B64.charCodeAt(i)] = i;

	function b64decode(str) {
		let n = str.length, pad = 0;
		if (str[n - 1] === "=") { pad++; if (str[n - 2] === "=") pad++; }
		const out = new Uint8Array((n * 3 / 4) - pad);
		let j = 0;
		for (let i = 0; i < n; i += 4) {
			const a = B64_LUT[str.charCodeAt(i)],
				b = B64_LUT[str.charCodeAt(i+1)],
				c = B64_LUT[str.charCodeAt(i+2)],
				d = B64_LUT[str.charCodeAt(i+3)];
			const triple = (a << 18) | (b << 12) | (c << 6) | d;
			out[j++] = (triple >> 16) & 0xFF;
			if (j < out.length) out[j++] = (triple >> 8) & 0xFF;
			if (j < out.length) out[j++] = triple & 0xFF;
		}
		return out;
	}

	// -- Base64 encode --
	function b64encode(bytes) {
		let out = "";
		for (let i = 0; i < bytes.length; i += 3) {
			const a = bytes[i], b = bytes[i+1] || 0, c = bytes[i+2] || 0;
			const triple = (a << 16) | (b << 8) | c;
			out += B64[triple >> 18 & 0x3F];
			out += B64[triple >> 12 & 0x3F];
			out += (i+1 < bytes.length) ? B64[triple >> 6 & 0x3F] : "=";
			out += (i+2 < bytes.length) ? B64[triple & 0x3F] : "=";
		}
		return out;
	}

	// -- Unmarshall (binary -> JS) --
	function readVarint(buf, pos) {
		let val = 0, shift = 0;
		do {
			if (pos.i >= buf.length) throw new Error("Truncated varint");
			const byte = buf[pos.i++];
			val |= (byte & 0x7F) << shift;
			shift += 7;
			if (!(byte & 0x80)) break;
		} while (true);
		return val;
	}

	function readValue(buf, pos) {
		if (pos.i >= buf.length) throw new Error("Truncated data");
		const tag = buf[pos.i++];
		switch (tag) {
			case ETYPE_NULL: return null;
			case ETYPE_TRUE: return true;
			case ETYPE_FALSE: return false;
			case ETYPE_DOUBLE: {
				if (pos.i + 8 > buf.length) throw new Error("Truncated double");
				const view = new DataView(buf.buffer, buf.byteOffset + pos.i, 8);
				pos.i += 8;
				return view.getFloat64(0, true);
			}
			case ETYPE_INTEGER: {
				if (pos.i + 8 > buf.length) throw new Error("Truncated integer");
				const view = new DataView(buf.buffer, buf.byteOffset + pos.i, 8);
				pos.i += 8;
				const value = view.getBigInt64(0, true);
				const minSafe = BigInt(Number.MIN_SAFE_INTEGER);
				const maxSafe = BigInt(Number.MAX_SAFE_INTEGER);
				return value >= minSafe && value <= maxSafe ? Number(value) : value;
			}
			case ETYPE_STRING: {
				const len = readVarint(buf, pos);
				if (pos.i + len > buf.length) throw new Error("Truncated string");
				const str = new TextDecoder().decode(buf.subarray(pos.i, pos.i + len));
				pos.i += len;
				return str;
			}
			case ETYPE_BUFFER: {
				const len = readVarint(buf, pos);
				if (pos.i + len > buf.length) throw new Error("Truncated buffer");
				const slice = buf.slice(pos.i, pos.i + len);
				pos.i += len;
				return slice;
			}
			case ETYPE_VECTOR: {
				const floatCount = 3; // LUA_VECTOR_SIZE default
				const byteLen = floatCount * 4;
				if (pos.i + byteLen > buf.length) throw new Error("Truncated vector");
				const view = new DataView(buf.buffer, buf.byteOffset + pos.i, byteLen);
				const v = [];
				for (let j = 0; j < floatCount; j++) v.push(view.getFloat32(j * 4, true));
				pos.i += byteLen;
				return v;
			}
			case ETYPE_TABLE: return readTable(buf, pos);
			default: throw new Error("Unknown type tag 0x" + tag.toString(16));
		}
	}

	function readTable(buf, pos) {
		const arrLen = readVarint(buf, pos);
		const obj = {};
		// Array part — stored as 1-indexed in Lua, convert to object keys
		for (let i = 1; i <= arrLen; i++) {
			obj[i] = readValue(buf, pos);
		}
		// Hash delimiter
		if (pos.i >= buf.length || buf[pos.i] !== ETYPE_TABLE_HASH_DELIM)
			throw new Error("Expected hash delimiter");
		pos.i++;
		// Hash part
		while (pos.i < buf.length && buf[pos.i] !== ETYPE_TABLE_HASH_DELIM) {
			const key = readValue(buf, pos);
			const val = readValue(buf, pos);
			obj[key] = val;
		}
		if (pos.i >= buf.length || buf[pos.i] !== ETYPE_TABLE_HASH_DELIM)
			throw new Error("Expected closing hash delimiter");
		pos.i++;
		return obj;
	}
)V0G0N"
    LR"V0G0N(

	// -- Marshall (JS -> binary) --
	function writeVarint(out, val) {
		val = val >>> 0;
		if (!val) { out.push(0); return; }
		while (val) {
			let byte = val & 0x7F;
			val >>>= 7;
			if (val) byte |= 0x80;
			out.push(byte);
		}
	}

	function writeDouble(out, num) {
		const buf = new ArrayBuffer(8);
		new DataView(buf).setFloat64(0, num, true);
		const bytes = new Uint8Array(buf);
		for (let i = 0; i < 8; i++) out.push(bytes[i]);
	}

	function writeInteger(out, value) {
		const buf = new ArrayBuffer(8);
		new DataView(buf).setBigInt64(0, BigInt(value), true);
		const bytes = new Uint8Array(buf);
		for (let i = 0; i < 8; i++) out.push(bytes[i]);
	}

	function writeValue(out, val) {
		if (val === null || val === undefined) {
			out.push(ETYPE_NULL);
		} else if (val === true) {
			out.push(ETYPE_TRUE);
		} else if (val === false) {
			out.push(ETYPE_FALSE);
		} else if (typeof val === "bigint") {
			out.push(ETYPE_INTEGER);
			writeInteger(out, val);
		} else if (typeof val === "number") {
			if (Number.isSafeInteger(val)) {
				out.push(ETYPE_INTEGER);
				writeInteger(out, val);
			} else {
				out.push(ETYPE_DOUBLE);
				writeDouble(out, val);
			}
		} else if (typeof val === "string") {
			out.push(ETYPE_STRING);
			const encoded = new TextEncoder().encode(val);
			writeVarint(out, encoded.length);
			for (let i = 0; i < encoded.length; i++) out.push(encoded[i]);
		} else if (val instanceof Uint8Array) {
			out.push(ETYPE_BUFFER);
			writeVarint(out, val.length);
			for (let i = 0; i < val.length; i++) out.push(val[i]);
		} else if (Array.isArray(val) && val.length <= 4 && val.every(v => typeof v === "number")) {
			// Treat small numeric arrays as vectors
			out.push(ETYPE_VECTOR);
			const buf = new ArrayBuffer(4 * 3);
			const view = new DataView(buf);
			for (let i = 0; i < 3; i++) view.setFloat32(i * 4, val[i] || 0, true);
			const bytes = new Uint8Array(buf);
			for (let i = 0; i < bytes.length; i++) out.push(bytes[i]);
		} else if (typeof val === "object") {
			writeTable(out, val);
		} else {
			throw new Error("Cannot marshall value of type " + typeof val);
		}
	}
)V0G0N"
    LR"V0G0N(

	function writeTable(out, obj) {
		out.push(ETYPE_TABLE);
		// Determine array part: consecutive integer keys starting at 1
		let arrLen = 0;
		while (obj.hasOwnProperty(arrLen + 1)) arrLen++;
		writeVarint(out, arrLen);
		for (let i = 1; i <= arrLen; i++) writeValue(out, obj[i]);
		// Hash delimiter
		out.push(ETYPE_TABLE_HASH_DELIM);
		// Hash part: everything that isn't an array key
		const arrKeys = new Set();
		for (let i = 1; i <= arrLen; i++) arrKeys.add(String(i));
		for (const key of Object.keys(obj)) {
			if (arrKeys.has(key)) continue;
			// Attempt to use numeric keys before falling back to strings.
			if (/^-?(0|[1-9]\d*)$/.test(key)) {
				const bigint = BigInt(key);
				const minSafe = BigInt(Number.MIN_SAFE_INTEGER);
				const maxSafe = BigInt(Number.MAX_SAFE_INTEGER);
				writeValue(out, bigint >= minSafe && bigint <= maxSafe ? Number(bigint) : bigint);
			} else {
				const num = Number(key);
				if (isFinite(num) && String(num) === key) {
					writeValue(out, num);
				} else {
					writeValue(out, key);
				}
			}
			writeValue(out, obj[key]);
		}
		out.push(ETYPE_TABLE_HASH_DELIM);
	}

	// -- Public API --
	const eryx = {
		post(type, data) {
			if (typeof type !== "string") throw new Error("eryx.post: type must be a string");
			if (data !== undefined && (typeof data !== "object" || data === null || Array.isArray(data)))
				throw new Error("eryx.post: data must be a plain object");
			const out = [];
			writeValue(out, type);
			writeTable(out, data || {});
			webview.postMessage(b64encode(new Uint8Array(out)));
		},

		_handlers: {},

		on(type, callback) {
			if (typeof type !== "string") throw new Error("eryx.on: type must be a string");
			if (typeof callback !== "function") throw new Error("eryx.on: callback must be a function");
			if (!this._handlers[type]) this._handlers[type] = [];
			this._handlers[type].push(callback);
		},

		off(type, callback) {
			if (!this._handlers[type]) return;
			if (callback) {
				this._handlers[type] = this._handlers[type].filter((cb) => cb !== callback);
			} else {
				delete this._handlers[type];
			}
		},
	};

	// Route incoming messages to registered handlers
	webview.addEventListener("message", function (e) {
		let buf;
		try {
			buf = b64decode(e.data);
		} catch {
			return;
		}
		const pos = { i: 0 };
		let type, data;
		try {
			type = readValue(buf, pos);
			data = readValue(buf, pos);
		} catch {
			return;
		}
		if (typeof type !== "string") return;
		const handlers = eryx._handlers[type];
		if (handlers) {
			for (const cb of handlers) cb(data || {});
		}
	});

	return eryx;
})();
)V0G0N";

// ---------------------------------------------------------------------------
// WebViewHandle -- per-window userdata
// ---------------------------------------------------------------------------
static udataRef* webviewHandleRef;

struct WebViewHandle {
    HWND hWnd;
    wil::com_ptr<ICoreWebView2Controller> controller;
    wil::com_ptr<ICoreWebView2> webview;

    EryxRuntime* rt;
    int messageCallbackRef;  // ref to Lua callback for web messages
    int closeCallbackRef;    // ref to Lua callback for window close
    int selfRef;             // prevent GC while window is alive
    int callerThreadRef;     // ref to yielded coroutine waiting for init
    uv_async_t* keepalive;   // ref'd handle to keep UV loop alive during init
    bool alive;
    bool transparent;  // whether background transparency was requested
};

// All live windows, for message-pump bookkeeping
static std::unordered_set<WebViewHandle*> g_liveWindows;
static bool g_wndclassRegistered = false;
static uv_timer_t* g_msgPumpTimer = nullptr;

// Forward declarations
LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
static void pump_messages(uv_timer_t* handle);
static void ensure_msg_pump(EryxRuntime* rt);
static void stop_msg_pump_if_empty();

static WebViewHandle* check_webview(lua_State* L, int idx = 1) {
    return (WebViewHandle*)eryxUdata_checkudata(L, webviewHandleRef, idx);
}

// ---------------------------------------------------------------------------
// Win32 message pump via UV timer
// ---------------------------------------------------------------------------
static void pump_messages(uv_timer_t* handle) {
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
}

static void ensure_msg_pump(EryxRuntime* rt) {
    if (g_msgPumpTimer) return;

    g_msgPumpTimer = new uv_timer_t;
    uv_timer_init(rt->loop, g_msgPumpTimer);
    g_msgPumpTimer->data = nullptr;
    // Poll at ~60 Hz -- responsive but not busy-spinning
    uv_timer_start(g_msgPumpTimer, pump_messages, 0, 16);
    uv_unref((uv_handle_t*)g_msgPumpTimer);  // don't keep loop alive on its own
}

static void on_pump_timer_close(uv_handle_t* handle) { delete (uv_timer_t*)handle; }

static void deferred_pump_stop(uv_timer_t* handle) {
    // Final drain -- WebView2 may have queued a few last messages
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    uv_timer_stop(handle);
    uv_close((uv_handle_t*)handle, on_pump_timer_close);
    g_msgPumpTimer = nullptr;
}

static void stop_msg_pump_if_empty() {
    if (!g_liveWindows.empty() || !g_msgPumpTimer) return;
    // Don't stop immediately -- give WebView2 time to tear down its internal
    // Chromium windows.  Switch to a one-shot that fires after 500 ms.
    uv_timer_stop(g_msgPumpTimer);
    uv_timer_start(g_msgPumpTimer, deferred_pump_stop, 500, 0);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static std::wstring utf8_to_wide(const char* s) {
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring ws(len - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, s, -1, ws.data(), len);
    return ws;
}

static std::string wide_to_utf8(const wchar_t* ws) {
    int len = WideCharToMultiByte(CP_UTF8, 0, ws, -1, nullptr, 0, nullptr, nullptr);
    std::string s(len - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, ws, -1, s.data(), len, nullptr, nullptr);
    return s;
}

// ---------------------------------------------------------------------------
// Destroy a window handle (shared by :destroy() and the userdata destructor)
// ---------------------------------------------------------------------------
static void destroy_webview(WebViewHandle* wh) {
    if (!wh->alive) return;
    wh->alive = false;
    g_liveWindows.erase(wh);

    // Detach from the HWND so WM_DESTROY won't double-process
    if (wh->hWnd) {
        SetWindowLongPtrA(wh->hWnd, GWLP_USERDATA, 0);
    }

    // Close the WebView2 controller first -- this starts async Chromium teardown
    if (wh->controller) {
        wh->controller->Close();
        wh->controller = nullptr;
    }
    wh->webview = nullptr;

    // Now destroy the host window
    if (wh->hWnd) {
        DestroyWindow(wh->hWnd);
        wh->hWnd = nullptr;
    }

    // Pump messages synchronously so Chromium's internal windows can finish
    // their async teardown.  This works even during GC / process shutdown
    // when the UV loop is no longer running.
    for (int i = 0; i < 20; i++) {
        MSG msg;
        bool hadMessages = false;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
            hadMessages = true;
        }
        if (!hadMessages && i > 0) break;
        Sleep(10);
    }

    if (wh->messageCallbackRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->messageCallbackRef);
        wh->messageCallbackRef = LUA_NOREF;
    }
    if (wh->closeCallbackRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->closeCallbackRef);
        wh->closeCallbackRef = LUA_NOREF;
    }
    if (wh->callerThreadRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->callerThreadRef);
        wh->callerThreadRef = LUA_NOREF;
    }
    if (wh->keepalive) {
        uv_close((uv_handle_t*)wh->keepalive, [](uv_handle_t* h) { delete (uv_async_t*)h; });
        wh->keepalive = nullptr;
    }
    if (wh->selfRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->selfRef);
        wh->selfRef = LUA_NOREF;
    }

    stop_msg_pump_if_empty();
}

// ---------------------------------------------------------------------------
// WebViewHandle methods
// ---------------------------------------------------------------------------

// handle:navigate(url)
static int wv_navigate(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    const char* url = luaL_checkstring(L, 2);

    std::wstring wurl = utf8_to_wide(url);
    HRESULT hr = wh->webview->Navigate(wurl.c_str());
    if (FAILED(hr)) {
        luaL_error(L, "Navigate failed (0x%08X)", hr);
        return 0;
    }
    return 0;
}

// handle:navigateToString(html)
static int wv_navigate_to_string(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    const char* html = luaL_checkstring(L, 2);

    std::wstring whtml = utf8_to_wide(html);
    HRESULT hr = wh->webview->NavigateToString(whtml.c_str());
    if (FAILED(hr)) {
        luaL_error(L, "NavigateToString failed (0x%08X)", hr);
        return 0;
    }
    return 0;
}

// handle:postMessage(msg)
static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
std::string base64_encode(const uint8_t* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);

    for (size_t i = 0; i < len; i += 3) {
        uint32_t octet_a = i < len ? data[i] : 0;
        uint32_t octet_b = (i + 1) < len ? data[i + 1] : 0;
        uint32_t octet_c = (i + 2) < len ? data[i + 2] : 0;

        uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        out.push_back(b64_table[(triple >> 18) & 0x3F]);
        out.push_back(b64_table[(triple >> 12) & 0x3F]);
        out.push_back((i + 1) < len ? b64_table[(triple >> 6) & 0x3F] : '=');
        out.push_back((i + 2) < len ? b64_table[(triple) & 0x3F] : '=');
    }

    return out;
}
static std::vector<uint8_t> base64_decode(const char* str, size_t len) {
    static const uint8_t lut[128] = {
        0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
        0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  62,
        0,  0,  0,  63, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 0,  0,  0,  0,  0,  0,  0,  0,
        1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
        23, 24, 25, 0,  0,  0,  0,  0,  0,  26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
        39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 0,  0,  0,  0,  0,
    };
    size_t pad = 0;
    if (len > 0 && str[len - 1] == '=') {
        pad++;
        if (len > 1 && str[len - 2] == '=') pad++;
    }
    std::vector<uint8_t> out;
    out.reserve((len * 3 / 4) - pad);
    for (size_t i = 0; i + 3 < len; i += 4) {
        uint32_t a = lut[(unsigned char)str[i]], b = lut[(unsigned char)str[i + 1]],
                 c = lut[(unsigned char)str[i + 2]], d = lut[(unsigned char)str[i + 3]];
        uint32_t triple = (a << 18) | (b << 12) | (c << 6) | d;
        out.push_back((triple >> 16) & 0xFF);
        if (str[i + 2] != '=') out.push_back((triple >> 8) & 0xFF);
        if (str[i + 3] != '=') out.push_back(triple & 0xFF);
    }
    return out;
}
static int wv_post_message(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    luaL_checkstring(L, 2);
    if (lua_type(L, 3) != LUA_TTABLE) {
        luaL_typeerrorL(L, 3, lua_typename(L, LUA_TTABLE));
    }

    std::vector<uint8_t> data;
    eryx_marshall(L, 2, data);  // message type (string)
    eryx_marshall(L, 3, data);  // message data (table)

    std::string msg = base64_encode(data.data(), data.size());
    std::wstring wmsg = utf8_to_wide(msg.c_str());

    HRESULT hr = wh->webview->PostWebMessageAsString(wmsg.c_str());
    if (FAILED(hr)) {
        luaL_error(L, "PostWebMessageAsString failed (0x%08X)", hr);
        return 0;
    }
    return 0;
}

// handle:executeScript(script)
static int wv_execute_script(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    const char* script = luaL_checkstring(L, 2);

    std::wstring wscript = utf8_to_wide(script);
    wh->webview->ExecuteScript(wscript.c_str(), nullptr);
    return 0;
}

// handle:addInitScript(script)
// Injects JavaScript that runs before page scripts on every navigation.
static int wv_add_init_script(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    const char* script = luaL_checkstring(L, 2);

    std::wstring wscript = utf8_to_wide(script);
    HRESULT hr = wh->webview->AddScriptToExecuteOnDocumentCreated(wscript.c_str(), nullptr);
    if (FAILED(hr)) {
        luaL_error(L, "AddScriptToExecuteOnDocumentCreated failed (0x%08X)", hr);
        return 0;
    }
    return 0;
}

// handle:setTitle(title)
static int wv_set_title(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    const char* title = luaL_checkstring(L, 2);
    SetWindowTextA(wh->hWnd, title);
    return 0;
}

// handle:show() / handle:hide()
static int wv_show(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    ShowWindow(wh->hWnd, SW_SHOW);
    return 0;
}

static int wv_hide(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    ShowWindow(wh->hWnd, SW_HIDE);
    return 0;
}

// handle:resize(width, height)
static int wv_resize(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    int w = luaL_checkinteger(L, 2);
    int h = luaL_checkinteger(L, 3);
    SetWindowPos(wh->hWnd, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
    return 0;
}

// handle:onMessage(callback)
static int wv_on_message(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // Release old callback if any
    if (wh->messageCallbackRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->messageCallbackRef);
    }

    lua_pushvalue(L, 2);
    wh->messageCallbackRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return 0;
}

// handle:onClose(callback)
static int wv_on_close(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    luaL_checktype(L, 2, LUA_TFUNCTION);

    if (wh->closeCallbackRef != LUA_NOREF) {
        lua_unref(wh->rt->GL, wh->closeCallbackRef);
    }

    lua_pushvalue(L, 2);
    wh->closeCallbackRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return 0;
}

// handle:setBorderless(borderless)
static int wv_set_borderless(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    bool borderless = lua_toboolean(L, 2) != 0;
    LONG_PTR style = GetWindowLongPtrA(wh->hWnd, GWL_STYLE);
    bool visible = (style & WS_VISIBLE) != 0;
    if (borderless) {
        style = WS_POPUP;
    } else {
        style = WS_OVERLAPPEDWINDOW;
    }
    if (visible) style |= WS_VISIBLE;
    SetWindowLongPtrA(wh->hWnd, GWL_STYLE, style);
    SetWindowPos(wh->hWnd, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    return 0;
}

// handle:setResizable(resizable)
static int wv_set_resizable(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    bool resizable = lua_toboolean(L, 2) != 0;
    LONG_PTR style = GetWindowLongPtrA(wh->hWnd, GWL_STYLE);
    if (resizable) {
        style |= (WS_THICKFRAME | WS_MAXIMIZEBOX);
    } else {
        style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    }
    SetWindowLongPtrA(wh->hWnd, GWL_STYLE, style);
    // Redraw frame
    SetWindowPos(wh->hWnd, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    return 0;
}

// handle:move(x, y)
static int wv_move(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    SetWindowPos(wh->hWnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    return 0;
}

// handle:center()
static int wv_center(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    RECT rc;
    GetWindowRect(wh->hWnd, &rc);
    int ww = rc.right - rc.left;
    int wh_ = rc.bottom - rc.top;

    // Get the monitor the window is currently on
    HMONITOR mon = MonitorFromWindow(wh->hWnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = { sizeof(mi) };
    GetMonitorInfoA(mon, &mi);
    int sx = mi.rcWork.right - mi.rcWork.left;
    int sy = mi.rcWork.bottom - mi.rcWork.top;

    int x = mi.rcWork.left + (sx - ww) / 2;
    int y = mi.rcWork.top + (sy - wh_) / 2;
    SetWindowPos(wh->hWnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    return 0;
}

// handle:setTransparent(transparent)
// Enables or disables true per-pixel window transparency.
static int wv_set_transparent(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    bool transparent = lua_toboolean(L, 2) != 0;
    wh->transparent = transparent;

    LONG_PTR exStyle = GetWindowLongPtrA(wh->hWnd, GWL_EXSTYLE);
    if (transparent) {
        exStyle |= WS_EX_NOREDIRECTIONBITMAP;
    } else {
        exStyle &= ~WS_EX_NOREDIRECTIONBITMAP;
    }
    SetWindowLongPtrA(wh->hWnd, GWL_EXSTYLE, exStyle);

    // Per-pixel transparency needs a borderless window (DWM title bar is
    // always opaque), so switch to WS_POPUP / restore WS_OVERLAPPEDWINDOW.
    LONG_PTR style = GetWindowLongPtrA(wh->hWnd, GWL_STYLE);
    if (transparent) {
        style = WS_POPUP | (style & (WS_VISIBLE));
    } else {
        // Restore normal framed style, preserving visibility
        style = WS_OVERLAPPEDWINDOW | (style & (WS_VISIBLE));
    }
    SetWindowLongPtrA(wh->hWnd, GWL_STYLE, style);

    // Extend/retract DWM frame for per-pixel alpha compositing
    MARGINS margins = transparent ? MARGINS{ -1, -1, -1, -1 } : MARGINS{ 0, 0, 0, 0 };
    DwmExtendFrameIntoClientArea(wh->hWnd, &margins);

    // Force a redraw
    SetWindowPos(wh->hWnd, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    return 0;
}

// handle:setOpacity(alpha)  -- 0.0 to 1.0
static int wv_set_opacity(lua_State* L) {
    auto* wh = check_webview(L);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    double alpha = luaL_checknumber(L, 2);
    if (alpha < 0.0) alpha = 0.0;
    if (alpha > 1.0) alpha = 1.0;

    LONG_PTR exStyle = GetWindowLongPtrA(wh->hWnd, GWL_EXSTYLE);
    exStyle |= WS_EX_LAYERED;
    SetWindowLongPtrA(wh->hWnd, GWL_EXSTYLE, exStyle);
    SetLayeredWindowAttributes(wh->hWnd, 0, (BYTE)(alpha * 255), LWA_ALPHA);
    return 0;
}

// handle:destroy()
static int wv_destroy(lua_State* L) {
    auto* wh = check_webview(L);
    destroy_webview(wh);
    return 0;
}

static void wv_dtor(lua_State* L, void* ud) {
    (void)L;
    auto* wh = (WebViewHandle*)ud;
    destroy_webview(wh);
    wh->~WebViewHandle();  // call destructor for placement-new'd COM pointers
}

// ---------------------------------------------------------------------------
// WndProc -- routes WM_SIZE to the correct controller
// ---------------------------------------------------------------------------
LRESULT CALLBACK WndProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam) {
    // Retrieve the WebViewHandle pointer stored with the window
    auto* wh = (WebViewHandle*)GetWindowLongPtrA(hWnd, GWLP_USERDATA);

    switch (message) {
        case WM_SIZE:
            if (wh && wh->controller) {
                RECT bounds;
                GetClientRect(hWnd, &bounds);
                wh->controller->put_Bounds(bounds);
            }
            break;
        case WM_CLOSE:
            // Fire the close callback if set.  The callback runs in a new
            // Luau thread; it can call :destroy() to actually close.
            if (wh && wh->closeCallbackRef != LUA_NOREF) {
                lua_State* GL = wh->rt->GL;
                lua_State* TL = lua_newthread(GL);

                lua_getref(GL, wh->closeCallbackRef);
                lua_xmove(GL, TL, 1);

                int ref = lua_ref(GL, -1);
                lua_pop(GL, 1);
                eryx_push_thread(wh->rt, ref, 0, false);

                return 0;  // suppress default DestroyWindow
            }
            // No callback -- go through destroy_webview which does
            // the synchronous message drain Chromium needs.
            if (wh) {
                destroy_webview(wh);
            }
            return 0;
        case WM_DESTROY:
            // destroy_webview detaches GWLP_USERDATA before calling
            // DestroyWindow, so wh is null when we arrive here from
            // the proper cleanup path.  If it's still set, something
            // else triggered WM_DESTROY -- run cleanup.
            if (wh) {
                destroy_webview(wh);
            }
            break;
        default:
            return DefWindowProc(hWnd, message, wParam, lParam);
    }

    return 0;
}

// ---------------------------------------------------------------------------
// webview.create({ title?, width?, height?, url? }) -> WebViewHandle
// ---------------------------------------------------------------------------
static int wv_create(lua_State* L) {
    const char* title = "WebView";
    int width = 1200;
    int height = 900;
    const char* url = nullptr;
    bool borderless = false;
    bool resizable = true;
    bool hidden = false;
    bool transparent = false;

    // Accept an options table as argument 1 (optional)
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "title");
        if (lua_isstring(L, -1)) title = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 1, "width");
        if (lua_isnumber(L, -1)) width = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 1, "height");
        if (lua_isnumber(L, -1)) height = (int)lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 1, "url");
        if (lua_isstring(L, -1)) url = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 1, "borderless");
        if (lua_isboolean(L, -1)) borderless = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);

        lua_getfield(L, 1, "resizable");
        if (lua_isboolean(L, -1)) resizable = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);

        lua_getfield(L, 1, "hidden");
        if (lua_isboolean(L, -1)) hidden = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);

        lua_getfield(L, 1, "transparent");
        if (lua_isboolean(L, -1)) transparent = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
    }

    HINSTANCE hInstance = GetModuleHandle(NULL);

    // Register the window class once
    if (!g_wndclassRegistered) {
        WNDCLASSEXA wcex = {};
        wcex.cbSize = sizeof(WNDCLASSEXA);
        wcex.style = CS_HREDRAW | CS_VREDRAW;
        wcex.lpfnWndProc = WndProc;
        wcex.hInstance = hInstance;
        wcex.hIcon = LoadIcon(hInstance, IDI_APPLICATION);
        wcex.hCursor = LoadCursor(NULL, IDC_ARROW);
        wcex.hbrBackground = NULL;  // no background brush -- required for per-pixel transparency
        wcex.lpszClassName = "EryxWebView";
        wcex.hIconSm = LoadIcon(hInstance, IDI_APPLICATION);

        if (!RegisterClassExA(&wcex)) {
            luaL_error(L, "RegisterClassEx failed");
            return 0;
        }
        g_wndclassRegistered = true;
    }

    auto* rt = eryx_get_runtime(L);

    auto* wh = (WebViewHandle*)eryxUdata_pushudata(L, webviewHandleRef);
    new (wh) WebViewHandle();  // placement-new for COM pointers

    wh->rt = rt;
    wh->alive = false;
    wh->messageCallbackRef = LUA_NOREF;
    wh->closeCallbackRef = LUA_NOREF;
    wh->selfRef = LUA_NOREF;
    wh->callerThreadRef = LUA_NOREF;
    wh->keepalive = nullptr;
    wh->transparent = transparent;

    // Build the window style
    // Per-pixel transparency requires a borderless window -- the DWM
    // non-client area (title bar / borders) is always opaque.
    if (transparent) borderless = true;

    DWORD style = borderless ? WS_POPUP : WS_OVERLAPPEDWINDOW;
    if (!resizable && !borderless) {
        style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    }
    // WS_EX_NOREDIRECTIONBITMAP lets DWM composite the WebView2 surface
    // directly, which is required for true per-pixel transparency.
    DWORD exStyle = transparent ? WS_EX_NOREDIRECTIONBITMAP : 0;

    // Create the Win32 window
    HWND hWnd = CreateWindowExA(exStyle, "EryxWebView", title, style, CW_USEDEFAULT, CW_USEDEFAULT,
                                width, height, NULL, NULL, hInstance, NULL);
    if (!hWnd) {
        luaL_error(L, "CreateWindow failed");
        return 0;
    }

    wh->hWnd = hWnd;
    wh->alive = true;

    // Store the handle pointer in the window's user data for WndProc dispatch
    SetWindowLongPtrA(hWnd, GWLP_USERDATA, (LONG_PTR)wh);

    // Self-ref to prevent GC while the window is alive
    lua_pushvalue(L, -1);
    wh->selfRef = lua_ref(L, -1);
    lua_pop(L, 1);

    g_liveWindows.insert(wh);

    // For per-pixel transparency, extend the DWM frame over the entire
    // client area so the window itself has no opaque background.
    if (transparent) {
        MARGINS margins = { -1, -1, -1, -1 };
        DwmExtendFrameIntoClientArea(hWnd, &margins);
    }

    // Start the UV message pump (shared across all windows)
    ensure_msg_pump(rt);

    // Create a ref'd keepalive async handle so the UV loop stays alive while
    // we wait for the async WebView2 init callback.  Without this, the loop
    // sees no ref'd handles and exits immediately after the yield.
    wh->keepalive = new uv_async_t;
    uv_async_init(rt->loop, wh->keepalive, [](uv_async_t*) {});

    // Ref the calling thread so we can resume it once WebView2 is ready.
    // The userdata is on L's stack; we ref L itself (the coroutine).
    lua_pushthread(L);
    wh->callerThreadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    // Copy url to a std::string so the lambda capture survives this scope
    std::string initialUrl = url ? url : "";
    bool startHidden = hidden;

    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    // Create the WebView2 environment + controller asynchronously
    CreateCoreWebView2EnvironmentWithOptions(
        nullptr, nullptr, nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [wh, hWnd, initialUrl, startHidden](HRESULT result,
                                                ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result) || !env) return result;

                env->CreateCoreWebView2Controller(
                    hWnd,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [wh, hWnd, initialUrl, startHidden](
                            HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                            if (FAILED(result) || !controller || !wh->alive) return result;

                            controller->put_IsVisible(TRUE);
                            wh->controller = controller;
                            wh->controller->get_CoreWebView2(&wh->webview);

                            // Default settings
                            wil::com_ptr<ICoreWebView2Settings> settings;
                            wh->webview->get_Settings(&settings);
                            settings->put_IsScriptEnabled(TRUE);
                            settings->put_AreDefaultScriptDialogsEnabled(TRUE);
                            settings->put_IsWebMessageEnabled(TRUE);

                            // Always make the WebView2 background transparent
                            // so CSS controls visibility.  For per-pixel window
                            // transparency this is essential; for normal windows
                            // the white page background still shows via CSS defaults.
                            {
                                wil::com_ptr<ICoreWebView2Controller2> controller2;
                                wh->controller->QueryInterface(IID_PPV_ARGS(&controller2));
                                if (controller2) {
                                    COREWEBVIEW2_COLOR bg = { 0, 0, 0, 0 };
                                    controller2->put_DefaultBackgroundColor(bg);
                                }
                            }

                            // Fit to window
                            RECT bounds;
                            GetClientRect(hWnd, &bounds);
                            wh->controller->put_Bounds(bounds);

                            // Register our IPC translation code
                            wh->webview->AddScriptToExecuteOnDocumentCreated(WEBVIEW_IPC_SCRIPT,
                                                                             nullptr);

                            // Route incoming web messages to the Lua callback
                            EventRegistrationToken token;
                            wh->webview->add_WebMessageReceived(
                                Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                    [wh](
                                        ICoreWebView2*,
                                        ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                                        if (wh->messageCallbackRef == LUA_NOREF) return S_OK;

                                        wil::unique_cotaskmem_string wmsg;
                                        args->TryGetWebMessageAsString(&wmsg);
                                        std::string msg = wide_to_utf8(wmsg.get());

                                        // Decode base64 -> binary -> Lua values
                                        std::vector<uint8_t> bin =
                                            base64_decode(msg.c_str(), msg.size());

                                        lua_State* GL = wh->rt->GL;
                                        lua_State* TL = lua_newthread(GL);

                                        lua_getref(GL, wh->messageCallbackRef);
                                        lua_xmove(GL, TL, 1);

                                        // Unmarshall type (string) and data (table) onto TL
                                        size_t pos = eryx_unmarshall(TL, bin.data(), bin.size());
                                        eryx_unmarshall(TL, bin.data() + pos, bin.size() - pos);

                                        int ref = lua_ref(GL, -1);
                                        lua_pop(GL, 1);
                                        eryx_push_thread(wh->rt, ref, 2, false);

                                        return S_OK;
                                    })
                                    .Get(),
                                &token);

                            // Navigate to initial URL if provided
                            if (!initialUrl.empty()) {
                                std::wstring wurl = utf8_to_wide(initialUrl.c_str());
                                wh->webview->Navigate(wurl.c_str());
                            }

                            // We've hidden the window during init, but now we might need to show it
                            if (!startHidden) {
                                ShowWindow(hWnd, SW_SHOW);
                            }

                            // Resume the yielded caller with the userdata
                            if (wh->callerThreadRef != LUA_NOREF) {
                                // Close the keepalive handle -- the loop no longer
                                // needs to stay alive on our behalf.
                                if (wh->keepalive) {
                                    uv_close((uv_handle_t*)wh->keepalive,
                                             [](uv_handle_t* h) { delete (uv_async_t*)h; });
                                    wh->keepalive = nullptr;
                                }

                                int ref = wh->callerThreadRef;
                                wh->callerThreadRef = LUA_NOREF;
                                eryx_push_thread(wh->rt, ref, 1, false);
                            }

                            return S_OK;
                        })
                        .Get());
                return S_OK;
            })
            .Get());

    // Yield -- the coroutine will be resumed with the userdata (1 value on
    // the stack) once CreateCoreWebView2Controller completes.
    return lua_yield(L, 1);
}

// ---------------------------------------------------------------------------
// Module entry
// ---------------------------------------------------------------------------
static luaL_Reg webviewMethods[] = {
    { "navigate", wv_navigate },
    { "navigateToString", wv_navigate_to_string },
    { "postMessage", wv_post_message },
    { "executeScript", wv_execute_script },
    { "addInitScript", wv_add_init_script },
    { "setTitle", wv_set_title },
    { "show", wv_show },
    { "hide", wv_hide },
    { "resize", wv_resize },
    { "onMessage", wv_on_message },
    { "onClose", wv_on_close },
    { "setResizable", wv_set_resizable },
    { "setBorderless", wv_set_borderless },
    { "move", wv_move },
    { "center", wv_center },
    { "setTransparent", wv_set_transparent },
    { "setOpacity", wv_set_opacity },
    { "destroy", wv_destroy },
    { nullptr, nullptr },
};

static udataDef webviewDef = {
    .name = "WebViewHandle",
    .size = sizeof(WebViewHandle),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = nullptr,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = webviewMethods,
    .destructor = wv_dtor,
};

LUAU_MODULE_EXPORT int luauopen_webview(lua_State* L) {
    webviewHandleRef = eryxUdata_registerudata(L, &webviewDef);

    // Build the module table
    lua_newtable(L);

    lua_pushcfunction(L, wv_create, "create");
    lua_setfield(L, -2, "create");

    lua_setreadonly(L, -1, true);
    return 1;
}
