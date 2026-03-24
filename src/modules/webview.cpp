#include <cstring>
#include <string>
#include <unordered_set>

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

	// Safe IPC interface - all messages are {type, data}
	const eryx = {
		post(type, data) {
			if (typeof type !== "string") throw new Error("eryx.post: type must be a string");
			if (data !== undefined && (typeof data !== "object" || data === null || Array.isArray(data))) throw new Error("eryx.post: data must be a plain object");
			webview.postMessage(JSON.stringify({ type, data: data || {} }));
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
        console.log("Got data", e.data)

		let msg;
		try {
			msg = JSON.parse(e.data);
		} catch {
			return;
		}
		if (!msg || typeof msg.type !== "string") return;
		const handlers = eryx._handlers[msg.type];
		if (handlers) {
			for (const cb of handlers) cb(msg.data || {});
		}
	});

	return eryx
})();
)V0G0N";

// ---------------------------------------------------------------------------
// WebViewHandle -- per-window userdata
// ---------------------------------------------------------------------------
static const char* WEBVIEW_HANDLE_MT = "WebViewHandle";

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
// Destroy a window handle (shared by :destroy() and __gc)
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
enum {
    ETYPE_NULL = 0x00,
    ETYPE_TRUE = 0x01,
    ETYPE_FALSE = 0x02,
    ETYPE_DOUBLE = 0x03,
    ETYPE_STRING = 0x04,
    ETYPE_BUFFER = 0x05,

    ETYPE_TABLE = 0x11,
    ETYPE_TABLE_HASH_DELIM = 0x12,
};
static void encode_varint(std::vector<uint8_t>& data, unsigned int val) {
    if (!val) {
        data.push_back(0);
        return;
    }
    while (val) {
        uint8_t byte = val & 0x7F;
        val >>= 7;
        if (val) byte |= 0x80;
        data.push_back(byte);
    }
}
static void encode_lua_table(lua_State* L, int idx, std::vector<uint8_t>& data, int visited);
static void encode_lua_value(lua_State* L, int idx, std::vector<uint8_t>& data, int visited) {
    switch ((lua_Type)lua_type(L, idx)) {
        case LUA_TNIL:
            data.push_back(ETYPE_NULL);
            break;
        case LUA_TBOOLEAN:
            if (lua_toboolean(L, idx))
                data.push_back(ETYPE_TRUE);
            else
                data.push_back(ETYPE_FALSE);
            break;
        case LUA_TNUMBER: {
            lua_Number k = lua_tonumber(L, idx);
            data.push_back(ETYPE_DOUBLE);
            auto ptr = reinterpret_cast<const uint8_t*>(&k);
            data.insert(data.end(), ptr, ptr + sizeof(double));
            break;
        }
        case LUA_TSTRING: {
            const char* s = lua_tostring(L, idx);
            data.push_back(ETYPE_STRING);
            encode_varint(data, strlen(s));
            if (strlen(s)) data.insert(data.end(), s, s + strlen(s));
            break;
        }
        case LUA_TBUFFER: {
            size_t nBuffer;
            const void* buf = lua_tobuffer(L, idx, &nBuffer);
            data.push_back(ETYPE_BUFFER);
            encode_varint(data, nBuffer);
            if (nBuffer) data.insert(data.end(), (uint8_t*)buf, (uint8_t*)buf + nBuffer);
            break;
        }
        case LUA_TTABLE:
            // TODO: Use visited
            encode_lua_table(L, idx, data, visited);
            break;

        case LUA_TUSERDATA:
        case LUA_TLIGHTUSERDATA:
            luaL_error(L, "Cannot exchange userdata in IPC transactions");
            break;
        case LUA_TFUNCTION:
            luaL_error(L, "Cannot exchange functions in IPC transactions");
            break;
        case LUA_TTHREAD:
            luaL_error(L, "Cannot exchange functions in IPC transactions");
            break;
        case LUA_TVECTOR:
            luaL_error(
                L, "Cannot exchange vectors in IPC transactions. Use an array of numbers instead");
            break;

        // These aren't "real" values, but they're present to satisfy enum checks
        case LUA_TPROTO:
        case LUA_TUPVAL:
        case LUA_TDEADKEY:
            luaL_error(L, "Something has gone fatally wrong with your Luau runtime.");
            break;
    }
}
static int already_seen(lua_State* L, int t, int visited) {
    lua_pushvalue(L, t);
    lua_rawget(L, visited);
    int seen = !lua_isnil(L, -1);
    lua_pop(L, 1);
    return seen;
}
static void mark_seen(lua_State* L, int t, int visited) {
    lua_pushvalue(L, t);
    lua_pushboolean(L, 1);
    lua_rawset(L, visited);
}
static void encode_lua_table(lua_State* L, int idx, std::vector<uint8_t>& data, int visited) {
    if (already_seen(L, idx, visited)) {
        luaL_error(L, "Cannot exchange recursive tables in IPC transactions");
        return;
    }
    mark_seen(L, idx, visited);

    data.push_back(ETYPE_TABLE);

    // Array part
    lua_Integer n = lua_objlen(L, idx);
    encode_varint(data, n);
    for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, idx, i);
        if (!lua_isnil(L, -1)) {
            encode_lua_value(L, -1, data, visited);
        }

        lua_pop(L, 1);
    }
    // Hash part
    data.push_back(ETYPE_TABLE_HASH_DELIM);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        // Skip array keys we already printed
        if (lua_type(L, -2) == LUA_TNUMBER) {
            lua_Number k = lua_tonumber(L, -2);
            if (k >= 1 && k <= n && (lua_Integer)k == k) {
                lua_pop(L, 1);
                continue;
            }
        }

        encode_lua_value(L, -2, data, visited);
        encode_lua_value(L, -1, data, visited);
        lua_pop(L, 1);
    }
    data.push_back(ETYPE_TABLE_HASH_DELIM);
}
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
static int wv_post_message(lua_State* L) {
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    luaL_checkstring(L, 2);
    if (lua_type(L, 3) != LUA_TTABLE) {
        luaL_typeerrorL(L, 3, lua_typename(L, LUA_TTABLE));
    }

    std::vector<uint8_t> data;
    lua_newtable(L);
    int visited = lua_gettop(L);
    // Argument 2 first, which we now know is a string
    encode_lua_value(L, 2, data, visited);
    // Then argument 3, which is a table
    encode_lua_table(L, 3, data, visited);
    // Then remove our visitor tracker
    lua_pop(L, 1);

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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    ShowWindow(wh->hWnd, SW_SHOW);
    return 0;
}

static int wv_hide(lua_State* L) {
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
    if (!wh->alive) {
        luaL_error(L, "webview is destroyed");
        return 0;
    }
    ShowWindow(wh->hWnd, SW_HIDE);
    return 0;
}

// handle:resize(width, height)
static int wv_resize(lua_State* L) {
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
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
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
    destroy_webview(wh);
    return 0;
}

// handle.__gc
static int wv_gc(lua_State* L) {
    auto* wh = (WebViewHandle*)luaL_checkudata(L, 1, WEBVIEW_HANDLE_MT);
    destroy_webview(wh);
    wh->~WebViewHandle();  // call destructor for placement-new'd COM pointers
    return 0;
}

// Destructor called by Luau GC (lua_newuserdatadtor).
// rt->GL is used for lua_unref so refs are released during normal GC,
// not just lua_close.
static void wv_dtor(void* ud) {
    auto* wh = (WebViewHandle*)ud;
    if (wh->alive) {
        wh->alive = false;
        g_liveWindows.erase(wh);

        if (wh->hWnd) {
            SetWindowLongPtrA(wh->hWnd, GWLP_USERDATA, 0);
        }
        if (wh->controller) {
            wh->controller->Close();
            wh->controller = nullptr;
        }
        wh->webview = nullptr;
        if (wh->hWnd) {
            DestroyWindow(wh->hWnd);
            wh->hWnd = nullptr;
        }
        // Synchronous message drain for Chromium teardown
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
    }

    // Release Lua refs via rt->GL (safe during normal GC and lua_close)
    lua_State* GL = wh->rt->GL;
    if (wh->messageCallbackRef != LUA_NOREF) {
        lua_unref(GL, wh->messageCallbackRef);
        wh->messageCallbackRef = LUA_NOREF;
    }
    if (wh->closeCallbackRef != LUA_NOREF) {
        lua_unref(GL, wh->closeCallbackRef);
        wh->closeCallbackRef = LUA_NOREF;
    }
    if (wh->callerThreadRef != LUA_NOREF) {
        lua_unref(GL, wh->callerThreadRef);
        wh->callerThreadRef = LUA_NOREF;
    }
    if (wh->selfRef != LUA_NOREF) {
        lua_unref(GL, wh->selfRef);
        wh->selfRef = LUA_NOREF;
    }

    wh->~WebViewHandle();  // COM pointers
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

    // Allocate the userdata with a destructor for GC cleanup
    auto* wh = (WebViewHandle*)lua_newuserdatadtor(L, sizeof(WebViewHandle), wv_dtor);
    new (wh) WebViewHandle();  // placement-new for COM pointers
    luaL_getmetatable(L, WEBVIEW_HANDLE_MT);
    lua_setmetatable(L, -2);

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

                                        lua_State* GL = wh->rt->GL;
                                        lua_State* TL = lua_newthread(GL);

                                        lua_getref(GL, wh->messageCallbackRef);
                                        lua_xmove(GL, TL, 1);
                                        lua_pushstring(TL, msg.c_str());

                                        int ref = lua_ref(GL, -1);
                                        lua_pop(GL, 1);
                                        eryx_push_thread(wh->rt, ref, 1, false);

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
LUAU_MODULE_EXPORT int luauopen_webview(lua_State* L) {
    // Register the WebViewHandle metatable
    luaL_newmetatable(L, WEBVIEW_HANDLE_MT);

    lua_pushcfunction(L, wv_navigate, "navigate");
    lua_setfield(L, -2, "navigate");

    lua_pushcfunction(L, wv_navigate_to_string, "navigateToString");
    lua_setfield(L, -2, "navigateToString");

    lua_pushcfunction(L, wv_post_message, "postMessage");
    lua_setfield(L, -2, "postMessage");

    lua_pushcfunction(L, wv_execute_script, "executeScript");
    lua_setfield(L, -2, "executeScript");

    lua_pushcfunction(L, wv_add_init_script, "addInitScript");
    lua_setfield(L, -2, "addInitScript");

    lua_pushcfunction(L, wv_set_title, "setTitle");
    lua_setfield(L, -2, "setTitle");

    lua_pushcfunction(L, wv_show, "show");
    lua_setfield(L, -2, "show");

    lua_pushcfunction(L, wv_hide, "hide");
    lua_setfield(L, -2, "hide");

    lua_pushcfunction(L, wv_resize, "resize");
    lua_setfield(L, -2, "resize");

    lua_pushcfunction(L, wv_on_message, "onMessage");
    lua_setfield(L, -2, "onMessage");

    lua_pushcfunction(L, wv_on_close, "onClose");
    lua_setfield(L, -2, "onClose");

    lua_pushcfunction(L, wv_set_resizable, "setResizable");
    lua_setfield(L, -2, "setResizable");

    lua_pushcfunction(L, wv_set_borderless, "setBorderless");
    lua_setfield(L, -2, "setBorderless");

    lua_pushcfunction(L, wv_move, "move");
    lua_setfield(L, -2, "move");

    lua_pushcfunction(L, wv_center, "center");
    lua_setfield(L, -2, "center");

    lua_pushcfunction(L, wv_set_transparent, "setTransparent");
    lua_setfield(L, -2, "setTransparent");

    lua_pushcfunction(L, wv_set_opacity, "setOpacity");
    lua_setfield(L, -2, "setOpacity");

    lua_pushcfunction(L, wv_destroy, "destroy");
    lua_setfield(L, -2, "destroy");

    // Note: __gc is not supported in Luau; cleanup uses lua_newuserdatadtor

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pop(L, 1);  // pop metatable

    // Build the module table
    lua_newtable(L);

    lua_pushcfunction(L, wv_create, "create");
    lua_setfield(L, -2, "create");

    lua_setreadonly(L, -1, true);
    return 1;
}
