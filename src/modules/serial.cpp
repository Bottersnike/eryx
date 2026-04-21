// serial.cpp — Serial port I/O for Luau
//
//   serial.open(port, options?)      -> SerialPort
//   serial.list()                    -> { PortInfo }
//
//   port:read([n [, timeout_ms]])    -> string / string?
//   port:readSync([n])               -> string
//   port:readBuffer([n [, t]])       -> buffer / buffer?
//   port:readBufferSync([n])         -> buffer
//   port:write(data)                 -> number  (bytes written; accepts string|buffer)
//   port:writeSync(data)             -> number
//   port:flush([direction])          -> ()
//   port:setDTR(value)               -> ()
//   port:setRTS(value)               -> ()
//   port:getSignals()                -> { cts, dsr, dcd, ri }
//   port:close()  / port:closeSync() -> ()
//   port.readable / port.writable    (boolean; false when closed)
//   port.inWaiting                    (number; bytes in RX buffer)
//   port.outWaiting                   (number; bytes in TX buffer)
//
// Async reads use uv_queue_work so the Luau coroutine yields without blocking
// the libuv event loop.  On Windows COMMTIMEOUTS are set to {0,0,0} once at
// open (never changed) so concurrent reads sharing the same HANDLE are safe.
// Timeout control uses WaitForSingleObject + CancelIoEx on per-call OVERLAPPED
// structures; blocking reads use a two-phase strategy (wait for 1 byte, then
// drain the buffer) so read(N) returns 1..N bytes rather than exactly N.
// ---------------------------------------------------------------------------

#include <cctype>
#include <cstring>
#include <string>
#include <vector>

#include "../runtime/lexception.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "uv.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <setupapi.h>
#include <windows.h>

#pragma comment(lib, "setupapi.lib")
#undef min
#undef max
#else
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>
#endif

// ---------------------------------------------------------------------------
// Module info
// ---------------------------------------------------------------------------

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_serial",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Platform error helpers
// ---------------------------------------------------------------------------

#ifdef _WIN32
static std::string serial_strerror(DWORD err) {
    char buf[256] = {};
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, err, 0, buf,
                   sizeof(buf), nullptr);
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = '\0';
    return std::string(buf, len);
}
#define serial_errno() GetLastError()
#else
static std::string serial_strerror(int err) { return strerror(err); }
#define serial_errno() errno
#endif

// ---------------------------------------------------------------------------
// SerialPort userdata
// ---------------------------------------------------------------------------

static const char* SERIAL_METATABLE = "SerialPort";

struct SerialPortState {
#ifdef _WIN32
    HANDLE hPort = INVALID_HANDLE_VALUE;
#else
    int fd = -1;
#endif
    bool closed = false;
    EryxRuntime* rt = nullptr;
};

// Forward declaration — dtor referenced by lua_newuserdatadtor before its definition.
static void serial_port_dtor(void* ud);

static SerialPortState* check_port(lua_State* L, int idx = 1) {
    void* ud = luaL_checkudata(L, idx, SERIAL_METATABLE);
    if (!ud) luaL_error(L, "expected SerialPort");
    auto* s = (SerialPortState*)ud;
    if (s->closed) luaL_error(L, "serial port is closed");
    return s;
}

// ---------------------------------------------------------------------------
// Async read via uv_queue_work
// ---------------------------------------------------------------------------

static constexpr int DEFAULT_READ_SIZE = 65536;

// Result of a single platform read (shared between async and sync paths).
struct PlatformReadResult {
    std::string data;
    bool wouldBlock = false;  // timeout_ms == 0 and no data was ready
    bool timedOut = false;    // timeout_ms > 0 and zero bytes arrived
    bool hasError = false;
    std::string errMsg;
};

// Platform-native read. timeout_ms: <0=block forever, 0=non-blocking, >0=timed.
// Safe to call from any thread — no Lua API access.
#ifdef _WIN32
static PlatformReadResult platform_read(HANDLE hPort, int maxBytes, int timeout_ms) {
#else
static PlatformReadResult platform_read(int fd, int maxBytes, int timeout_ms) {
#endif
    PlatformReadResult r;
#ifdef _WIN32
    // COMMTIMEOUTS are set to {0,0,0} once at open and never changed, so they
    // are safe to use from multiple threads simultaneously.  All timeout logic
    // is handled here via WaitForSingleObject + CancelIoEx on per-call
    // OVERLAPPED structures so the driver IRP queue correctly serialises
    // concurrent reads — each ReadFile gets its own chunk of bytes.
    //
    // Helper: issue ReadFile, wait up to waitMs, return bytes read or -1 on
    // error (with r.hasError/r.errMsg set) or -2 on timeout.
    auto do_overlapped_read = [&](char* dst, DWORD count, DWORD waitMs) -> DWORD {
        OVERLAPPED ov = {};
        ov.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
        if (!ov.hEvent) {
            r.hasError = true;
            r.errMsg = "CreateEvent failed: " + serial_strerror(GetLastError());
            return (DWORD)-1;
        }
        BOOL ok = ReadFile(hPort, dst, count, nullptr, &ov);
        if (!ok && GetLastError() != ERROR_IO_PENDING) {
            r.hasError = true;
            r.errMsg = "ReadFile failed: " + serial_strerror(GetLastError());
            CloseHandle(ov.hEvent);
            return (DWORD)-1;
        }
        DWORD w = WaitForSingleObject(ov.hEvent, waitMs);
        if (w == WAIT_TIMEOUT) {
            CancelIoEx(hPort, &ov);
            DWORD dummy = 0;
            GetOverlappedResult(hPort, &ov, &dummy, TRUE);
            CloseHandle(ov.hEvent);
            return (DWORD)-2;  // timeout sentinel
        }
        DWORD n = 0;
        if (!GetOverlappedResult(hPort, &ov, &n, TRUE)) {
            DWORD err = GetLastError();
            CloseHandle(ov.hEvent);
            if (err == ERROR_OPERATION_ABORTED) return (DWORD)-2;
            r.hasError = true;
            r.errMsg = "GetOverlappedResult failed: " + serial_strerror(err);
            return (DWORD)-1;
        }
        CloseHandle(ov.hEvent);
        return n;
    };

    if (timeout_ms == 0) {
        // Non-blocking: read however many bytes are already in the OS RX buffer.
        COMSTAT cs = {};
        DWORD errs = 0;
        ClearCommError(hPort, &errs, &cs);
        if (cs.cbInQue == 0) {
            r.wouldBlock = true;
            return r;
        }
        DWORD toRead = std::min(cs.cbInQue, (DWORD)maxBytes);
        std::vector<char> buf(toRead);
        // Bytes are already in buffer; allow 50 ms as a safety-valve against a
        // TOCTOU race where another concurrent reader takes them first.
        DWORD n = do_overlapped_read(buf.data(), toRead, 50);
        if (n == (DWORD)-2) {
            r.wouldBlock = true;
            return r;
        }
        if (n == (DWORD)-1) return r;
        if (n == 0) {
            r.wouldBlock = true;
            return r;
        }
        r.data.assign(buf.data(), n);
    } else {
        // Blocking read: two phases.
        // Phase 1 — wait for the first byte to arrive (or timeout).
        DWORD waitMs = (timeout_ms < 0) ? INFINITE : (DWORD)timeout_ms;
        char firstByte = 0;
        DWORD n1 = do_overlapped_read(&firstByte, 1, waitMs);
        if (n1 == (DWORD)-2) {
            r.timedOut = true;
            return r;
        }
        if (n1 == (DWORD)-1) return r;
        if (n1 == 0) {
            r.timedOut = true;
            return r;
        }
        r.data += firstByte;

        // Phase 2 — non-blocking: snap up any additional bytes already buffered.
        if (maxBytes > 1) {
            COMSTAT cs = {};
            DWORD errs = 0;
            ClearCommError(hPort, &errs, &cs);
            if (cs.cbInQue > 0) {
                DWORD toRead = std::min(cs.cbInQue, (DWORD)(maxBytes - 1));
                std::vector<char> buf2(toRead);
                DWORD n2 = do_overlapped_read(buf2.data(), toRead, 50);
                if (n2 != (DWORD)-1 && n2 != (DWORD)-2 && n2 > 0) r.data.append(buf2.data(), n2);
            }
        }
    }
#else
    int pollTimeout = (timeout_ms < 0) ? -1 : timeout_ms;
    struct pollfd pfd = { fd, POLLIN, 0 };
    int ret = poll(&pfd, 1, pollTimeout);
    if (ret < 0) {
        r.hasError = true;
        r.errMsg = "poll failed: " + serial_strerror(errno);
        return r;
    }
    if (ret == 0) {
        if (timeout_ms == 0)
            r.wouldBlock = true;
        else
            r.timedOut = true;
        return r;
    }
    ssize_t n = ::read(fd, buf.data(), (size_t)maxBytes);
    if (n < 0) {
        r.hasError = true;
        r.errMsg = "read failed: " + serial_strerror(errno);
    } else if (n == 0) {
        r.hasError = true;
        r.errMsg = "read failed: device disconnected";
    } else {
        r.data.assign(buf.data(), (size_t)n);
    }
#endif
    return r;
}

struct ReadRequest {
    uv_work_t work;  // must be first member for safe casting
    EryxRuntime* rt;
    lua_State* thread;
    int threadRef;

#ifdef _WIN32
    HANDLE hPort;
#else
    int fd;
#endif

    int maxBytes;
    int timeout_ms;                    // <0 = block forever, 0 = non-blocking, >0 = timeout
    bool returnBuffer = false;         // push Lua buffer instead of string
    bool returnEmptyOnNoData = false;  // push "" / empty-buffer instead of nil on wouldBlock

    // Written by work_cb, read by after_cb
    std::string result;
    bool wouldBlock = false;
    bool timedOut = false;
    bool hasError = false;
    std::string errMsg;
};

static void read_work_cb(uv_work_t* w) {
    auto* req = (ReadRequest*)w;
#ifdef _WIN32
    PlatformReadResult r = platform_read(req->hPort, req->maxBytes, req->timeout_ms);
#else
    PlatformReadResult r = platform_read(req->fd, req->maxBytes, req->timeout_ms);
#endif
    req->result = std::move(r.data);
    req->wouldBlock = r.wouldBlock;
    req->timedOut = r.timedOut;
    req->hasError = r.hasError;
    req->errMsg = std::move(r.errMsg);
}

// ---------------------------------------------------------------------------
// After callback — runs on the main thread; safe to call Lua API.
// ---------------------------------------------------------------------------

static void read_after_cb(uv_work_t* w, int /*status*/) {
    auto* req = (ReadRequest*)w;
    EryxRuntime* rt = req->rt;
    lua_State* L = req->thread;
    int tref = req->threadRef;

    if (req->hasError) {
        eryx_exception_push_exception(L, ETYPE_RUNTIME, req->errMsg.c_str(), nullptr);
        delete req;
        eryx_push_thread(rt, tref, 1, true);
        return;
    }

    if (req->wouldBlock || req->timedOut) {
        if (req->returnEmptyOnNoData && req->wouldBlock) {
            // read() with no args: return "" / empty buffer instead of nil
            if (req->returnBuffer)
                lua_newbuffer(L, 0);
            else
                lua_pushlstring(L, "", 0);
        } else {
            lua_pushnil(L);
        }
        delete req;
        eryx_push_thread(rt, tref, 1, false);
        return;
    }

    if (req->returnBuffer) {
        void* out = lua_newbuffer(L, req->result.size());
        if (!req->result.empty()) memcpy(out, req->result.data(), req->result.size());
    } else {
        lua_pushlstring(L, req->result.data(), req->result.size());
    }
    delete req;
    eryx_push_thread(rt, tref, 1, false);
}

// Caller must return lua_yield(L, 0) immediately after this.
static void schedule_read(lua_State* L, SerialPortState* s, int maxBytes, int timeout_ms,
                          bool returnBuffer = false, bool returnEmptyOnNoData = false) {
    EryxRuntime* rt = eryx_get_runtime(L);

    lua_pushthread(L);
    int ref = lua_ref(L, -1);
    lua_pop(L, 1);

    auto* req = new ReadRequest;
    req->rt = rt;
    req->thread = L;
    req->threadRef = ref;
#ifdef _WIN32
    req->hPort = s->hPort;
#else
    req->fd = s->fd;
#endif
    req->maxBytes = maxBytes;
    req->timeout_ms = timeout_ms;
    req->returnBuffer = returnBuffer;
    req->returnEmptyOnNoData = returnEmptyOnNoData;

    uv_queue_work(rt->loop, &req->work, read_work_cb, read_after_cb);
}

// ---------------------------------------------------------------------------
// Port configuration helpers
// ---------------------------------------------------------------------------

// Parse "none" / "odd" / "even" -> 0 / 1 / 2
static int parse_parity(lua_State* L, const char* s) {
    if (strcmp(s, "odd") == 0) return 1;
    if (strcmp(s, "even") == 0) return 2;
    if (strcmp(s, "none") == 0) return 0;
    luaL_error(L, "invalid parity '%s': expected \"none\", \"odd\", or \"even\"", s);
    return 0;
}

#ifdef _WIN32
static bool apply_dcb(HANDLE hPort, int baud, int dataBits, int stopBits, int parity,
                      std::string& err) {
    DCB dcb = {};
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(hPort, &dcb)) {
        err = "GetCommState failed: " + serial_strerror(GetLastError());
        return false;
    }
    dcb.BaudRate = (DWORD)baud;
    dcb.ByteSize = (BYTE)dataBits;
    dcb.StopBits = (stopBits == 2) ? TWOSTOPBITS : ONESTOPBIT;
    switch (parity) {
        case 1:
            dcb.Parity = ODDPARITY;
            dcb.fParity = TRUE;
            break;
        case 2:
            dcb.Parity = EVENPARITY;
            dcb.fParity = TRUE;
            break;
        default:
            dcb.Parity = NOPARITY;
            dcb.fParity = FALSE;
            break;
    }
    dcb.fBinary = TRUE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fRtsControl = RTS_CONTROL_ENABLE;
    if (!SetCommState(hPort, &dcb)) {
        err = "SetCommState failed: " + serial_strerror(GetLastError());
        return false;
    }
    return true;
}
#else
static speed_t baud_to_speed(int baud) {
    switch (baud) {
        case 50:
            return B50;
        case 75:
            return B75;
        case 110:
            return B110;
        case 134:
            return B134;
        case 150:
            return B150;
        case 200:
            return B200;
        case 300:
            return B300;
        case 600:
            return B600;
        case 1200:
            return B1200;
        case 1800:
            return B1800;
        case 2400:
            return B2400;
        case 4800:
            return B4800;
        case 9600:
            return B9600;
        case 19200:
            return B19200;
        case 38400:
            return B38400;
        case 57600:
            return B57600;
        case 115200:
            return B115200;
        case 230400:
            return B230400;
#ifdef B460800
        case 460800:
            return B460800;
#endif
#ifdef B921600
        case 921600:
            return B921600;
#endif
        default:
            return B0;  // unsupported
    }
}

static bool apply_termios(int fd, int baud, int dataBits, int stopBits, int parity,
                          std::string& err) {
    struct termios tty = {};
    if (tcgetattr(fd, &tty) != 0) {
        err = "tcgetattr failed: " + serial_strerror(errno);
        return false;
    }

    speed_t speed = baud_to_speed(baud);
    if (speed == B0) {
        err = "unsupported baud rate: " + std::to_string(baud);
        return false;
    }
    cfsetispeed(&tty, speed);
    cfsetospeed(&tty, speed);

    // Raw mode — no line processing, no signals
    cfmakeraw(&tty);

    // Data bits
    tty.c_cflag &= ~CSIZE;
    switch (dataBits) {
        case 5:
            tty.c_cflag |= CS5;
            break;
        case 6:
            tty.c_cflag |= CS6;
            break;
        case 7:
            tty.c_cflag |= CS7;
            break;
        default:
            tty.c_cflag |= CS8;
            break;
    }

    // Stop bits
    if (stopBits == 2)
        tty.c_cflag |= CSTOPB;
    else
        tty.c_cflag &= ~CSTOPB;

    // Parity
    switch (parity) {
        case 1:  // odd
            tty.c_cflag |= (PARENB | PARODD);
            tty.c_iflag |= INPCK;
            break;
        case 2:  // even
            tty.c_cflag |= PARENB;
            tty.c_cflag &= ~PARODD;
            tty.c_iflag |= INPCK;
            break;
        default:  // none
            tty.c_cflag &= ~PARENB;
            tty.c_iflag &= ~INPCK;
            break;
    }

    // Enable receiver, ignore modem control lines
    tty.c_cflag |= (CREAD | CLOCAL);

    // VMIN=1: blocking reads return as soon as at least 1 byte arrives.
    // The async layer (poll loop / uv_queue_work) takes care of the rest.
    tty.c_cc[VMIN] = 1;
    tty.c_cc[VTIME] = 0;

    if (tcsetattr(fd, TCSANOW, &tty) != 0) {
        err = "tcsetattr failed: " + serial_strerror(errno);
        return false;
    }
    return true;
}
#endif

// ---------------------------------------------------------------------------
// serial.open(port, options?)
// ---------------------------------------------------------------------------

static int serial_open(lua_State* L) {
    const char* portName = luaL_checkstring(L, 1);
    int baud = 9600;
    int dataBits = 8;
    int stopBits = 1;
    int parity = 0;

    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "baudRate");
        if (!lua_isnil(L, -1)) baud = (int)luaL_checkinteger(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "dataBits");
        if (!lua_isnil(L, -1)) dataBits = (int)luaL_checkinteger(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "stopBits");
        if (!lua_isnil(L, -1)) stopBits = (int)luaL_checkinteger(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "parity");
        if (!lua_isnil(L, -1)) parity = parse_parity(L, luaL_checkstring(L, -1));
        lua_pop(L, 1);
    }

#ifdef _WIN32
    // Win32 requires the \\.\COMn prefix for port numbers >= 10 (and works for all)
    std::string fullPath = portName;
    if (fullPath.rfind("COM", 0) == 0 || fullPath.rfind("com", 0) == 0)
        fullPath = "\\\\.\\" + fullPath;

    HANDLE hPort = CreateFileA(fullPath.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                               OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (hPort == INVALID_HANDLE_VALUE) {
        luaL_error(L, "cannot open %s: %s", portName, serial_strerror(GetLastError()).c_str());
    }

    std::string cfgErr;
    if (!apply_dcb(hPort, baud, dataBits, stopBits, parity, cfgErr)) {
        CloseHandle(hPort);
        luaL_error(L, "%s", cfgErr.c_str());
    }

    // Set COMMTIMEOUTS once to "wait forever" (no driver-managed timeout).
    // All timeout control is done in platform_read via WaitForSingleObject +
    // CancelIoEx so concurrent reads sharing the HANDLE are safe.
    COMMTIMEOUTS ct = { 0, 0, 0, 0, 0 };
    SetCommTimeouts(hPort, &ct);

    auto* s = (SerialPortState*)lua_newuserdatadtor(L, sizeof(SerialPortState), serial_port_dtor);
    new (s) SerialPortState;
    s->hPort = hPort;
    s->closed = false;
    s->rt = eryx_get_runtime(L);
#else
    int fd = ::open(portName, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (fd < 0) luaL_error(L, "cannot open %s: %s", portName, serial_strerror(errno).c_str());

    std::string cfgErr;
    if (!apply_termios(fd, baud, dataBits, stopBits, parity, cfgErr)) {
        ::close(fd);
        luaL_error(L, "%s", cfgErr.c_str());
    }

    auto* s = (SerialPortState*)lua_newuserdatadtor(L, sizeof(SerialPortState), serial_port_dtor);
    new (s) SerialPortState;
    s->fd = fd;
    s->closed = false;
    s->rt = eryx_get_runtime(L);
#endif

    luaL_getmetatable(L, SERIAL_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// serial.list()
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// serial.list() helpers
// ---------------------------------------------------------------------------

#ifdef _WIN32
// Parse VID and PID from a hardware-ID string such as
//   "USB\VID_0403&PID_6001&REV_0600"
// Returns true and sets vid/pid if both are found.
static bool parse_vid_pid(const char* hwid, int* vid, int* pid) {
    const char* v = strstr(hwid, "VID_");
    if (!v) v = strstr(hwid, "vid_");
    const char* p = strstr(hwid, "PID_");
    if (!p) p = strstr(hwid, "pid_");
    if (!v || !p) return false;
    char* end;
    *vid = (int)strtol(v + 4, &end, 16);
    if (end == v + 4) return false;
    *pid = (int)strtol(p + 4, &end, 16);
    if (end == p + 4) return false;
    return true;
}

// Extract the serial number from a device instance ID.
// Instance IDs for USB devices look like:
//   USB\VID_0403&PID_6001\A12345BC
// The third segment is the serial number if it contains no '&'.
static std::string parse_serial_from_instance(const char* instanceId) {
    // Skip first two backslash-delimited segments
    const char* p = instanceId;
    int slashes = 0;
    while (*p) {
        if (*p == '\\') {
            slashes++;
            if (slashes == 2) {
                p++;
                break;
            }
        }
        p++;
    }
    if (!*p) return {};
    // Reject if it contains '&' (composite ID, not a serial number)
    if (strchr(p, '&')) return {};
    return std::string(p);
}

// Push all string values of a multi-sz registry value into a single string
// (first value only, since we just want the most-specific ID).
static std::string reg_get_sz(HKEY hKey, const char* name) {
    char buf[512] = {};
    DWORD size = sizeof(buf);
    DWORD type = 0;
    if (RegQueryValueExA(hKey, name, nullptr, &type, (LPBYTE)buf, &size) != ERROR_SUCCESS)
        return {};
    // REG_MULTI_SZ: take the first null-terminated string
    buf[sizeof(buf) - 1] = '\0';
    return std::string(buf);
}

static void push_str_field(lua_State* L, const char* name, const std::string& s) {
    if (!s.empty()) {
        lua_pushlstring(L, s.data(), s.size());
        lua_setfield(L, -2, name);
    }
}
#endif  // _WIN32

#ifdef __linux__
// Read a single-line text file from sysfs; returns empty string on failure.
static std::string sysfs_read(const std::string& path) {
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return {};
    char buf[256] = {};
    if (!fgets(buf, sizeof(buf), f)) {
        fclose(f);
        return {};
    }
    fclose(f);
    // Strip trailing newline
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = '\0';
    return std::string(buf, len);
}

// Walk up the sysfs device symlink chain to find the USB device directory
// (the one that contains idVendor/idProduct).  Returns empty string if not USB.
static std::string sysfs_find_usb_device(const std::string& devicePath) {
    char resolved[4096] = {};
    if (realpath(devicePath.c_str(), resolved) == nullptr) return {};
    std::string path = resolved;

    // Walk up until we find idVendor
    while (!path.empty() && path != "/") {
        struct stat st;
        std::string probe = path + "/idVendor";
        if (stat(probe.c_str(), &st) == 0) return path;
        size_t slash = path.rfind('/');
        if (slash == std::string::npos) break;
        path = path.substr(0, slash);
    }
    return {};
}
#endif  // __linux__

// ---------------------------------------------------------------------------
// serial.list()
// ---------------------------------------------------------------------------

static int serial_list(lua_State* L) {
    lua_newtable(L);
    int idx = 1;

#ifdef _WIN32
    // Use SetupAPI to enumerate all devices in the Ports device class.
    // This gives us description, hardware ID, manufacturer, and serial number
    // in addition to the COM port name.
    static const GUID GUID_DEVCLASS_PORTS = {
        0x4D36E978, 0xE325, 0x11CE, { 0xBF, 0xC1, 0x08, 0x00, 0x2B, 0xE1, 0x03, 0x18 }
    };

    HDEVINFO devInfo = SetupDiGetClassDevsA(&GUID_DEVCLASS_PORTS, nullptr, nullptr, DIGCF_PRESENT);
    if (devInfo == INVALID_HANDLE_VALUE) return 1;

    SP_DEVINFO_DATA devData = {};
    devData.cbSize = sizeof(devData);

    for (DWORD i = 0; SetupDiEnumDeviceInfo(devInfo, i, &devData); i++) {
        // Get the COM port name from the device's registry key
        HKEY hKey =
            SetupDiOpenDevRegKey(devInfo, &devData, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
        if (hKey == INVALID_HANDLE_VALUE) continue;
        std::string portName = reg_get_sz(hKey, "PortName");
        RegCloseKey(hKey);
        if (portName.empty()) continue;

        lua_newtable(L);
        lua_pushstring(L, portName.c_str());
        lua_setfield(L, -2, "name");

        // Friendly description, e.g. "USB Serial Port (COM3)"
        char desc[256] = {};
        DWORD descSize = sizeof(desc);
        if (SetupDiGetDeviceRegistryPropertyA(devInfo, &devData, SPDRP_DEVICEDESC, nullptr,
                                              (PBYTE)desc, descSize, nullptr)) {
            push_str_field(L, "description", desc);
        }

        // Hardware ID — first value of the multi-sz
        char hwid[512] = {};
        DWORD hwidSize = sizeof(hwid);
        if (SetupDiGetDeviceRegistryPropertyA(devInfo, &devData, SPDRP_HARDWAREID, nullptr,
                                              (PBYTE)hwid, hwidSize, nullptr)) {
            push_str_field(L, "hwid", hwid);
            int vid = 0, pid = 0;
            if (parse_vid_pid(hwid, &vid, &pid)) {
                lua_pushinteger(L, vid);
                lua_setfield(L, -2, "vid");
                lua_pushinteger(L, pid);
                lua_setfield(L, -2, "pid");
            }
        }

        // Manufacturer
        char mfg[256] = {};
        DWORD mfgSize = sizeof(mfg);
        if (SetupDiGetDeviceRegistryPropertyA(devInfo, &devData, SPDRP_MFG, nullptr, (PBYTE)mfg,
                                              mfgSize, nullptr)) {
            push_str_field(L, "manufacturer", mfg);
        }

        // Serial number — third segment of the instance ID (if no '&')
        char instanceId[512] = {};
        if (SetupDiGetDeviceInstanceIdA(devInfo, &devData, instanceId, sizeof(instanceId),
                                        nullptr)) {
            push_str_field(L, "serialNumber", parse_serial_from_instance(instanceId));
        }

        lua_rawseti(L, -2, idx++);
    }

    SetupDiDestroyDeviceInfoList(devInfo);

#elif defined(__linux__)
    // Enumerate /sys/class/tty entries that have a bound driver (real hardware).
    const char* sysPath = "/sys/class/tty";
    DIR* dir = opendir(sysPath);
    if (dir) {
        struct dirent* ent;
        while ((ent = readdir(dir)) != nullptr) {
            if (ent->d_name[0] == '.') continue;
            std::string base = std::string(sysPath) + "/" + ent->d_name;
            // Only include entries with a device/driver symlink (real serial ports)
            std::string driverPath = base + "/device/driver";
            struct stat st = {};
            if (lstat(driverPath.c_str(), &st) != 0) continue;

            std::string devPath = "/dev/" + std::string(ent->d_name);
            lua_newtable(L);
            lua_pushstring(L, devPath.c_str());
            lua_setfield(L, -2, "name");

            // Walk up sysfs to find the USB device root (if this is a USB serial port)
            std::string usbDev = sysfs_find_usb_device(base + "/device");
            if (!usbDev.empty()) {
                std::string idVendor = sysfs_read(usbDev + "/idVendor");
                std::string idProduct = sysfs_read(usbDev + "/idProduct");
                std::string mfg = sysfs_read(usbDev + "/manufacturer");
                std::string product = sysfs_read(usbDev + "/product");
                std::string serial = sysfs_read(usbDev + "/serial");

                if (!idVendor.empty() && !idProduct.empty()) {
                    // hwid in pyserial-style format
                    std::string hwid = "USB VID:PID=" + idVendor + ":" + idProduct;
                    if (!serial.empty()) hwid += " SER=" + serial;
                    if (!mfg.empty()) hwid += " MFG=" + mfg;
                    push_str_field(L, "hwid", hwid);

                    char* end;
                    long v = strtol(idVendor.c_str(), &end, 16);
                    if (end != idVendor.c_str()) {
                        lua_pushinteger(L, v);
                        lua_setfield(L, -2, "vid");
                    }
                    long p = strtol(idProduct.c_str(), &end, 16);
                    if (end != idProduct.c_str()) {
                        lua_pushinteger(L, p);
                        lua_setfield(L, -2, "pid");
                    }
                    push_str_field(L, "manufacturer", mfg);
                    push_str_field(L, "description", product);
                    push_str_field(L, "serialNumber", serial);
                }
            }

            lua_rawseti(L, -2, idx++);
        }
        closedir(dir);
    }
#elif defined(__APPLE__)
    // Scan /dev for cu.* (call-out) devices — the preferred handle for serial communication.
    DIR* dir = opendir("/dev");
    if (dir) {
        struct dirent* ent;
        while ((ent = readdir(dir)) != nullptr) {
            const char* name = ent->d_name;
            if (strncmp(name, "cu.", 3) == 0) {
                std::string devPath = std::string("/dev/") + name;
                lua_newtable(L);
                lua_pushstring(L, devPath.c_str());
                lua_setfield(L, -2, "name");
                lua_rawseti(L, -2, idx++);
            }
        }
        closedir(dir);
    }
#endif

    return 1;
}

// ---------------------------------------------------------------------------
// port:read([n [, timeout_ms]])
//
//   read()          -> string   non-blocking; returns "" if nothing buffered
//   read(n)         -> string   blocks until 1..n bytes arrive
//   read(n, t)      -> string?  blocks up to t ms; nil on timeout
//   read(nil, t)    -> string?  waits up to t ms then drains buffer; nil on timeout
// ---------------------------------------------------------------------------

static int port_read(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool hasSize = !lua_isnoneornil(L, 2);
    bool hasTimeout = !lua_isnoneornil(L, 3);

    int maxBytes = hasSize ? (int)luaL_checkinteger(L, 2) : DEFAULT_READ_SIZE;
    if (hasSize && maxBytes <= 0) luaL_error(L, "size must be positive");

    int timeout_ms;
    bool returnEmptyOnNoData;
    if (!hasSize && !hasTimeout) {
        // read() — non-blocking, return "" if nothing buffered
        timeout_ms = 0;
        returnEmptyOnNoData = true;
    } else if (!hasTimeout) {
        // read(n) — block forever until data arrives
        timeout_ms = -1;
        returnEmptyOnNoData = false;
    } else {
        // read(n?, timeout) — with timeout; return nil if it elapses
        timeout_ms = (int)luaL_checkinteger(L, 3);
        if (timeout_ms < 0) luaL_error(L, "timeout must be >= 0");
        returnEmptyOnNoData = false;
    }

    schedule_read(L, s, maxBytes, timeout_ms, false, returnEmptyOnNoData);
    return lua_yield(L, 0);
}

// ---------------------------------------------------------------------------
// port:readSync([n])
//
//   readSync()   -> string   non-blocking; returns "" if nothing buffered
//   readSync(n)  -> string   blocks the event loop until 1..n bytes arrive
// ---------------------------------------------------------------------------

static int port_readSync(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool hasSize = !lua_isnoneornil(L, 2);
    int maxBytes = hasSize ? (int)luaL_checkinteger(L, 2) : DEFAULT_READ_SIZE;
    if (hasSize && maxBytes <= 0) luaL_error(L, "size must be positive");

    // No size: non-blocking (timeout_ms=0). With size: block forever (timeout_ms=-1).
    int timeout_ms = hasSize ? -1 : 0;

#ifdef _WIN32
    PlatformReadResult r = platform_read(s->hPort, maxBytes, timeout_ms);
#else
    PlatformReadResult r = platform_read(s->fd, maxBytes, timeout_ms);
#endif

    if (r.hasError) luaL_error(L, "%s", r.errMsg.c_str());
    // wouldBlock (no size case) returns "" — matches stream EOF convention
    lua_pushlstring(L, r.data.data(), r.data.size());
    return 1;
}

// ---------------------------------------------------------------------------
// port:readBuffer([n [, timeout_ms]])  — same as read() but returns a buffer
// port:readBufferSync([n])             — same as readSync() but returns a buffer
// ---------------------------------------------------------------------------

static int port_readBuffer(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool hasSize = !lua_isnoneornil(L, 2);
    bool hasTimeout = !lua_isnoneornil(L, 3);

    int maxBytes = hasSize ? (int)luaL_checkinteger(L, 2) : DEFAULT_READ_SIZE;
    if (hasSize && maxBytes <= 0) luaL_error(L, "size must be positive");

    int timeout_ms;
    bool returnEmptyOnNoData;
    if (!hasSize && !hasTimeout) {
        timeout_ms = 0;
        returnEmptyOnNoData = true;
    } else if (!hasTimeout) {
        timeout_ms = -1;
        returnEmptyOnNoData = false;
    } else {
        timeout_ms = (int)luaL_checkinteger(L, 3);
        if (timeout_ms < 0) luaL_error(L, "timeout must be >= 0");
        returnEmptyOnNoData = false;
    }

    schedule_read(L, s, maxBytes, timeout_ms, true, returnEmptyOnNoData);
    return lua_yield(L, 0);
}

static int port_readBufferSync(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool hasSize = !lua_isnoneornil(L, 2);
    int maxBytes = hasSize ? (int)luaL_checkinteger(L, 2) : DEFAULT_READ_SIZE;
    if (hasSize && maxBytes <= 0) luaL_error(L, "size must be positive");

    int timeout_ms = hasSize ? -1 : 0;

#ifdef _WIN32
    PlatformReadResult r = platform_read(s->hPort, maxBytes, timeout_ms);
#else
    PlatformReadResult r = platform_read(s->fd, maxBytes, timeout_ms);
#endif

    if (r.hasError) luaL_error(L, "%s", r.errMsg.c_str());
    void* out = lua_newbuffer(L, r.data.size());
    if (!r.data.empty()) memcpy(out, r.data.data(), r.data.size());
    return 1;
}

// ---------------------------------------------------------------------------
// port:write(data) / port:writeSync(data)
// Accepts string or buffer. Returns number of bytes written.
// ---------------------------------------------------------------------------

static const char* check_write_data(lua_State* L, int idx, size_t* len) {
    if (lua_isstring(L, idx)) return luaL_checklstring(L, idx, len);
    if (lua_isbuffer(L, idx)) return (const char*)lua_tobuffer(L, idx, len);
    luaL_error(L, "expected string or buffer");
    return nullptr;
}

static int port_write(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    size_t len;
    const char* data = check_write_data(L, 2, &len);
    if (len == 0) {
        lua_pushinteger(L, 0);
        return 1;
    }

#ifdef _WIN32
    OVERLAPPED ov = {};
    ov.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    DWORD written = 0;
    BOOL ok = WriteFile(s->hPort, data, (DWORD)len, nullptr, &ov);
    if (!ok && GetLastError() != ERROR_IO_PENDING) {
        CloseHandle(ov.hEvent);
        luaL_error(L, "write failed: %s", serial_strerror(GetLastError()).c_str());
    }
    if (!GetOverlappedResult(s->hPort, &ov, &written, TRUE)) {
        CloseHandle(ov.hEvent);
        luaL_error(L, "write failed: %s", serial_strerror(GetLastError()).c_str());
    }
    CloseHandle(ov.hEvent);
    lua_pushinteger(L, (lua_Integer)written);
#else
    const char* ptr = data;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = ::write(s->fd, ptr, remaining);
        if (n < 0) luaL_error(L, "write failed: %s", serial_strerror(errno).c_str());
        ptr += n;
        remaining -= (size_t)n;
    }
    lua_pushinteger(L, (lua_Integer)len);
#endif
    return 1;
}

// writeSync is the same as write for serial ports (write is already synchronous).
static int port_writeSync(lua_State* L) { return port_write(L); }

// ---------------------------------------------------------------------------
// port:flush([direction])
// ---------------------------------------------------------------------------

static int port_flush(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    const char* dir = luaL_optstring(L, 2, "both");

#ifdef _WIN32
    DWORD flags;
    if (strcmp(dir, "input") == 0)
        flags = PURGE_RXCLEAR;
    else if (strcmp(dir, "output") == 0)
        flags = PURGE_TXCLEAR;
    else
        flags = PURGE_RXCLEAR | PURGE_TXCLEAR;
    if (!PurgeComm(s->hPort, flags))
        luaL_error(L, "flush failed: %s", serial_strerror(GetLastError()).c_str());
#else
    int which;
    if (strcmp(dir, "input") == 0)
        which = TCIFLUSH;
    else if (strcmp(dir, "output") == 0)
        which = TCOFLUSH;
    else
        which = TCIOFLUSH;
    if (tcflush(s->fd, which) != 0)
        luaL_error(L, "flush failed: %s", serial_strerror(errno).c_str());
#endif

    return 0;
}

// ---------------------------------------------------------------------------
// port:setDTR(value)
// ---------------------------------------------------------------------------

static int port_setDTR(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool val = (bool)lua_toboolean(L, 2);

#ifdef _WIN32
    if (!EscapeCommFunction(s->hPort, val ? SETDTR : CLRDTR))
        luaL_error(L, "setDTR failed: %s", serial_strerror(GetLastError()).c_str());
#else
    int cmd = val ? TIOCMBIS : TIOCMBIC;
    int bits = TIOCM_DTR;
    if (ioctl(s->fd, cmd, &bits) != 0)
        luaL_error(L, "setDTR failed: %s", serial_strerror(errno).c_str());
#endif

    return 0;
}

// ---------------------------------------------------------------------------
// port:setRTS(value)
// ---------------------------------------------------------------------------

static int port_setRTS(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool val = (bool)lua_toboolean(L, 2);

#ifdef _WIN32
    if (!EscapeCommFunction(s->hPort, val ? SETRTS : CLRRTS))
        luaL_error(L, "setRTS failed: %s", serial_strerror(GetLastError()).c_str());
#else
    int cmd = val ? TIOCMBIS : TIOCMBIC;
    int bits = TIOCM_RTS;
    if (ioctl(s->fd, cmd, &bits) != 0)
        luaL_error(L, "setRTS failed: %s", serial_strerror(errno).c_str());
#endif

    return 0;
}

// ---------------------------------------------------------------------------
// port:getSignals()
// ---------------------------------------------------------------------------

static int port_getSignals(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    bool cts = false, dsr = false, dcd = false, ri = false;

#ifdef _WIN32
    DWORD status = 0;
    if (!GetCommModemStatus(s->hPort, &status))
        luaL_error(L, "getSignals failed: %s", serial_strerror(GetLastError()).c_str());
    cts = (status & MS_CTS_ON) != 0;
    dsr = (status & MS_DSR_ON) != 0;
    dcd = (status & MS_RLSD_ON) != 0;
    ri = (status & MS_RING_ON) != 0;
#else
    int bits = 0;
    if (ioctl(s->fd, TIOCMGET, &bits) != 0)
        luaL_error(L, "getSignals failed: %s", serial_strerror(errno).c_str());
    cts = (bits & TIOCM_CTS) != 0;
    dsr = (bits & TIOCM_DSR) != 0;
    dcd = (bits & TIOCM_CD) != 0;
    ri = (bits & TIOCM_RI) != 0;
#endif

    lua_newtable(L);
    lua_pushboolean(L, cts);
    lua_setfield(L, -2, "cts");
    lua_pushboolean(L, dsr);
    lua_setfield(L, -2, "dsr");
    lua_pushboolean(L, dcd);
    lua_setfield(L, -2, "dcd");
    lua_pushboolean(L, ri);
    lua_setfield(L, -2, "ri");
    return 1;
}

// ---------------------------------------------------------------------------
// port:close()
// ---------------------------------------------------------------------------

static int port_close(lua_State* L) {
    SerialPortState* s = check_port(L, 1);
    serial_port_dtor(s);
    return 0;
}

// closeSync is the same as close for serial ports.
static int port_closeSync(lua_State* L) { return port_close(L); }

// ---------------------------------------------------------------------------
// Destructor — called by Luau GC via lua_newuserdatadtor
// ---------------------------------------------------------------------------

static void serial_port_dtor(void* ud) {
    auto* s = (SerialPortState*)ud;
    if (s->closed) return;
    s->closed = true;
#ifdef _WIN32
    if (s->hPort != INVALID_HANDLE_VALUE) {
        CloseHandle(s->hPort);
        s->hPort = INVALID_HANDLE_VALUE;
    }
#else
    if (s->fd >= 0) {
        ::close(s->fd);
        s->fd = -1;
    }
#endif
}

// ---------------------------------------------------------------------------
// __index for SerialPort userdata
// Handles readable/writable/closed property fields; falls through to methods table.
// ---------------------------------------------------------------------------

// Upvalue 1 = methods table
static int serial_port_index(lua_State* L) {
    void* ud = luaL_checkudata(L, 1, SERIAL_METATABLE);
    auto* s = (SerialPortState*)ud;
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "readable") == 0) {
        lua_pushboolean(L, !s->closed);
        return 1;
    }
    if (strcmp(key, "writable") == 0) {
        lua_pushboolean(L, !s->closed);
        return 1;
    }
    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, s->closed);
        return 1;
    }
    if (strcmp(key, "inWaiting") == 0) {
        if (s->closed) {
            lua_pushinteger(L, 0);
            return 1;
        }
#ifdef _WIN32
        COMSTAT cs = {};
        DWORD errs = 0;
        ClearCommError(s->hPort, &errs, &cs);
        lua_pushinteger(L, (int)cs.cbInQue);
#else
        int n = 0;
        ioctl(s->fd, TIOCINQ, &n);
        lua_pushinteger(L, n);
#endif
        return 1;
    }
    if (strcmp(key, "outWaiting") == 0) {
        if (s->closed) {
            lua_pushinteger(L, 0);
            return 1;
        }
#ifdef _WIN32
        COMSTAT cs = {};
        DWORD errs = 0;
        ClearCommError(s->hPort, &errs, &cs);
        lua_pushinteger(L, (int)cs.cbOutQue);
#else
        int n = 0;
        ioctl(s->fd, TIOCOUTQ, &n);
        lua_pushinteger(L, n);
#endif
        return 1;
    }

    // Fall through to the methods table (upvalue 1)
    lua_pushvalue(L, 2);
    lua_rawget(L, lua_upvalueindex(1));
    return 1;
}

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------

static void register_port_metatable(lua_State* L) {
    luaL_newmetatable(L, SERIAL_METATABLE);

    // Build methods table; captured as upvalue 1 of serial_port_index.
    lua_newtable(L);

    lua_pushcfunction(L, port_read, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, port_readSync, "readSync");
    lua_setfield(L, -2, "readSync");
    lua_pushcfunction(L, port_readBuffer, "readBuffer");
    lua_setfield(L, -2, "readBuffer");
    lua_pushcfunction(L, port_readBufferSync, "readBufferSync");
    lua_setfield(L, -2, "readBufferSync");
    lua_pushcfunction(L, port_write, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, port_writeSync, "writeSync");
    lua_setfield(L, -2, "writeSync");
    lua_pushcfunction(L, port_flush, "flush");
    lua_setfield(L, -2, "flush");
    lua_pushcfunction(L, port_setDTR, "setDTR");
    lua_setfield(L, -2, "setDTR");
    lua_pushcfunction(L, port_setRTS, "setRTS");
    lua_setfield(L, -2, "setRTS");
    lua_pushcfunction(L, port_getSignals, "getSignals");
    lua_setfield(L, -2, "getSignals");
    lua_pushcfunction(L, port_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, port_closeSync, "closeSync");
    lua_setfield(L, -2, "closeSync");

    // __index = serial_port_index closure with methods table as upvalue
    lua_pushcclosure(L, serial_port_index, "__index", 1);
    lua_setfield(L, -2, "__index");

    lua_pop(L, 1);
}

LUAU_MODULE_EXPORT int luauopen_serial(lua_State* L) {
    register_port_metatable(L);

    lua_newtable(L);
    lua_pushcfunction(L, serial_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, serial_list, "list");
    lua_setfield(L, -2, "list");
    lua_setreadonly(L, -1, true);
    return 1;
}
