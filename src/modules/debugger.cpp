#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <new>
#include <queue>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <vector>

#include "../modules/module_api.h"
#include "../runtime/lexception.hpp"
#include "../runtime/lrequire.hpp"
#include "../runtime/runtime_host.hpp"
#include "Luau/BytecodeBuilder.h"
#include "Luau/Compiler.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_debugger",
};
LUAU_MODULE_INFO()

static const char* DBG_SESSION_MT = "DebugSession";
struct DebugLaunchOptions {
    std::string program;
    std::vector<std::string> args;
    bool stopOnEntry = false;
    bool nativeCodegen = false;
    int optimisationLevel = 0;
};

struct DebugSource {
    std::string name;
    std::string path;
};

struct DebugEvent {
    std::string event;
    std::string reason;
    std::string description;
    std::string text;
    std::string state;
    std::string stream;
    DebugSource source;
    std::vector<int> hitBreakpointIds;
    int line = 0;
    int column = 0;
    int threadId = 1;
    bool hasExitCode = false;
    int exitCode = 0;
};

struct DebugFrame {
    int id = 0;
    int threadId = 1;
    int level = 0;
    std::string name;
    DebugSource source;
    int line = 1;
    int column = 1;
    int pc = 0;
};

struct DebugBreakpoint {
    int id = 0;
    int requestedLine = 0;
    int actualLine = 0;
    int hitCount = 0;
    bool verified = false;
    bool internal = false;
    std::string sourcePath;
    std::string condition;
    std::string hitCondition;
    std::string logMessage;
    std::string message;
};

struct DebugLoadedFunction {
    int ref = LUA_NOREF;
    std::string sourcePath;
};

struct DebugAppliedBreakpoint {
    int functionRef = LUA_NOREF;
    int line = 0;
};

struct DebugBreakpointSnapshot {
    int id = 0;
    bool internal = false;
    std::string sourcePath;
    std::string condition;
    std::string hitCondition;
    std::string logMessage;
};

enum class DebugVariableRefKind {
    Locals,
    Registers,
    Value,
};

enum class DebugStepMode {
    None,
    In,
    Over,
    Out,
};

enum class DebugPauseRequest {
    None = 0,
    Pause,
    Manual,
};

struct DebugVariableRef {
    DebugVariableRefKind kind = DebugVariableRefKind::Value;
    int threadId = 1;
    int frameId = 0;
    int frameLevel = 0;
    int valueRef = LUA_NOREF;
};

struct DebugThread {
    int id = 0;
    lua_State* L = nullptr;
    std::string name;
    std::string state = "running";
    std::string stopReason;
};

struct DebugSession : std::enable_shared_from_this<DebugSession> {
    explicit DebugSession(DebugLaunchOptions options) : options(std::move(options)) {}

    DebugLaunchOptions options;
    std::thread worker;

    std::mutex mutex;
    std::condition_variable commandCv;
    std::condition_variable eventCv;
    std::queue<DebugEvent> events;

    bool startRequested = false;
    bool continueRequested = false;
    DebugStepMode stepMode = DebugStepMode::None;
    int stepStartDepth = 0;
    int stepStartLine = 0;
    std::string stepStartSource;
    bool stepFromEntry = false;
    std::atomic<DebugPauseRequest> pauseRequest = DebugPauseRequest::None;
    std::atomic_int pauseTargetThreadId = 0;
    std::atomic_bool terminateRequested = false;
    bool running = false;
    bool paused = false;
    bool workerDone = false;
    lua_State* controlLua = nullptr;
    lua_State* pausedLua = nullptr;
    int pausedThreadId = 0;
    int framesThreadId = 0;
    int nextThreadId = 1;
    std::unordered_map<lua_State*, int> threadIds;
    std::vector<DebugThread> threads;
    std::string lastStopReason;

    int nextFrameId = 1;
    int nextBreakpointId = 1;
    int breakpointRevision = 0;
    int appliedBreakpointRevision = -1;
    std::vector<DebugFrame> frames;
    std::vector<DebugBreakpoint> breakpoints;
    std::vector<DebugLoadedFunction> loadedFunctions;
    std::vector<DebugAppliedBreakpoint> appliedBreakpoints;

    int nextVariableReference = 1;
    std::unordered_map<int, DebugVariableRef> variableRefs;

    bool hasExceptionInfo = false;
    std::string exceptionId;
    std::string exceptionDescription;
    std::string exceptionMessage;
    std::string exceptionTypeName;
    std::string exceptionStackTrace;
    DebugSource exceptionSource;
    int exceptionLine = 0;
    int exceptionColumn = 0;
};

struct DebugSessionHandle {
    std::shared_ptr<DebugSession> session;
};

struct DebugRuntimeContext {
    std::shared_ptr<DebugSession> session;
    int exitCode = 0;
};

static bool dbg_wait_for_continue(const std::shared_ptr<DebugSession>& session);
static void dbg_apply_all_breakpoints_locked(lua_State* L, DebugSession& session);
static void dbg_capture_stack_locked(DebugSession& session, lua_State* L);
static std::string dbg_format_lua_scalar(lua_State* L, int index);
static bool dbg_lua_value_has_children(lua_State* L, int index);
static bool dbg_source_matches(const std::string& lhs, const std::string& rhs);
static bool dbg_is_file_backed_source_path(const std::string& path);
static void dbg_push_value_locked(lua_State* outL, lua_State* valueL, DebugSession& session,
                                  const std::string& name, int valueIndex, bool hex,
                                  const char* kind = nullptr,
                                  const std::string* evaluateName = nullptr);

struct DebugPausedLuaGuard {
    explicit DebugPausedLuaGuard(lua_State* state) : L(state) {
        active = eryx_debug_begin_paused_state(L, &saved);
    }

    ~DebugPausedLuaGuard() {
        if (active) {
            eryx_debug_end_paused_state(L, &saved);
        }
    }

    lua_State* L = nullptr;
    EryxDebugPausedState saved;
    bool active = false;
};

static bool dbg_read_source_file(const std::string& path, std::string& source) {
    std::ifstream scriptFile(path, std::ios::binary);
    if (!scriptFile.is_open()) {
        return false;
    }

    source.assign((std::istreambuf_iterator<char>(scriptFile)), std::istreambuf_iterator<char>());
    return true;
}

static void dbg_add_unique_source_path(std::vector<std::string>& sources,
                                       const std::string& sourcePath) {
    for (const std::string& existing : sources) {
        if (dbg_source_matches(existing, sourcePath)) {
            return;
        }
    }

    sources.push_back(sourcePath);
}

static int dbg_count_source_lines(const std::string& source) {
    if (source.empty()) {
        return 0;
    }

    int lines = 1;
    for (char ch : source) {
        if (ch == '\n') {
            lines++;
        }
    }
    return lines;
}

static bool dbg_clear_internal_breakpoints_locked(DebugSession& session) {
    std::vector<DebugBreakpoint> kept;
    kept.reserve(session.breakpoints.size());
    bool removed = false;
    for (DebugBreakpoint& breakpoint : session.breakpoints) {
        if (!breakpoint.internal) {
            kept.push_back(std::move(breakpoint));
        } else {
            removed = true;
        }
    }
    session.breakpoints = std::move(kept);
    return removed;
}

static void dbg_cancel_step_state_locked(lua_State* L, DebugSession& session) {
    lua_singlestep(L, 0);
    session.stepMode = DebugStepMode::None;
    session.stepStartDepth = 0;
    session.stepStartLine = 0;
    session.stepStartSource.clear();
    session.stepFromEntry = false;
    if (dbg_clear_internal_breakpoints_locked(session)) {
        session.breakpointRevision++;
    }
}

static void dbg_prepare_step_breakpoints_locked(lua_State* L, DebugSession& session) {
    dbg_clear_internal_breakpoints_locked(session);

    std::vector<std::string> sources;
    if (dbg_is_file_backed_source_path(session.options.program)) {
        dbg_add_unique_source_path(sources, session.options.program);
    }
    for (const DebugLoadedFunction& loaded : session.loadedFunctions) {
        if (dbg_is_file_backed_source_path(loaded.sourcePath)) {
            dbg_add_unique_source_path(sources, loaded.sourcePath);
        }
    }

    for (const std::string& sourcePath : sources) {
        std::string sourceText;
        if (!dbg_read_source_file(sourcePath, sourceText)) {
            continue;
        }

        int lineCount = dbg_count_source_lines(sourceText);
        for (int line = 1; line <= lineCount; line++) {
            if (dbg_source_matches(sourcePath, session.stepStartSource) &&
                line == session.stepStartLine) {
                continue;
            }

            DebugBreakpoint breakpoint;
            breakpoint.id = session.nextBreakpointId++;
            breakpoint.requestedLine = line;
            breakpoint.actualLine = line;
            breakpoint.verified = false;
            breakpoint.internal = true;
            breakpoint.sourcePath = sourcePath;
            breakpoint.message = "Pending verification";
            session.breakpoints.push_back(std::move(breakpoint));
        }
    }

    session.breakpointRevision++;
    dbg_apply_all_breakpoints_locked(L, session);
}

static bool dbg_is_array_index(lua_State* L, int index) {
    if (!lua_isnumber(L, index)) return false;
    double value = lua_tonumber(L, index);
    if (value < 1.0) return false;
    double integral = std::floor(value);
    return integral == value;
}

static void dbg_push_event(const std::shared_ptr<DebugSession>& session, DebugEvent event) {
    {
        std::lock_guard lock(session->mutex);
        session->events.push(std::move(event));
    }
    session->eventCv.notify_all();
}

static bool dbg_is_probably_valid_cstring(const char* source) {
    if (!source) return false;

    uintptr_t ptr = reinterpret_cast<uintptr_t>(source);
    if (ptr == 0 || ptr == UINTPTR_MAX) return false;

#ifdef _WIN32
    if (ptr < 0x10000) return false;
#else
    if (ptr < 4096) return false;
#endif

    return true;
}

static std::string dbg_source_path(const char* source) {
    if (!dbg_is_probably_valid_cstring(source) || !*source) return "";

    std::string value(source);
    if (!value.empty() && value[0] == '@') {
        value.erase(value.begin());
    }
    return value;
}

static lua_Debug* dbg_resolve_hook_debug_info(lua_State* L, lua_Debug* ar, lua_Debug& fallback) {
    if (lua_getinfo(L, 0, "sl", &fallback)) {
        return &fallback;
    }

    if (!ar) return nullptr;
    return dbg_is_probably_valid_cstring(ar->source) ? ar : nullptr;
}

static bool dbg_current_frame_is_source_backed(lua_State* L) {
    lua_Debug fallback = {};
    lua_Debug* ar = dbg_resolve_hook_debug_info(L, nullptr, fallback);
    if (!ar) return false;
    if (ar->currentline <= 0) return false;

    std::string path = dbg_source_path(ar->source);
    return dbg_is_file_backed_source_path(path);
}

static std::string dbg_source_name(const std::string& path) {
    if (path.empty()) return "";
    return std::filesystem::path(path).filename().string();
}

static std::string dbg_normalize_path(const std::string& path) {
    if (path.empty()) return "";

    std::error_code ec;
    std::filesystem::path normalized = std::filesystem::weakly_canonical(path, ec);
    if (ec) {
        normalized = std::filesystem::path(path).lexically_normal();
    }

    std::string value = normalized.string();
#ifdef _WIN32
    std::replace(value.begin(), value.end(), '/', '\\');
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char ch) { return (char)std::tolower(ch); });
#endif
    return value;
}

static bool dbg_source_matches(const std::string& lhs, const std::string& rhs) {
    if (lhs.empty() || rhs.empty()) return lhs.empty() && rhs.empty();
    return dbg_normalize_path(lhs) == dbg_normalize_path(rhs);
}

static bool dbg_is_file_backed_source_path(const std::string& path) {
    return !path.empty() && path[0] != '=';
}

static DebugSource dbg_make_source(const std::string& path) {
    DebugSource source;
    source.path = path;
    source.name = dbg_source_name(path);
    return source;
}

static std::string dbg_source_id(const DebugSource& source) {
    if (!source.path.empty()) return source.path;
    return source.name;
}

static bool dbg_same_source_id(const std::string& lhs, const std::string& rhs) {
    if (lhs.empty() || rhs.empty()) return lhs == rhs;
    return dbg_source_matches(lhs, rhs);
}

static DebugThread* dbg_find_thread_by_id_locked(DebugSession& session, int threadId) {
    for (DebugThread& thread : session.threads) {
        if (thread.id == threadId) {
            return &thread;
        }
    }

    return nullptr;
}

static const DebugThread* dbg_find_thread_by_id_locked(const DebugSession& session, int threadId) {
    for (const DebugThread& thread : session.threads) {
        if (thread.id == threadId) {
            return &thread;
        }
    }

    return nullptr;
}

static int dbg_note_thread_locked(DebugSession& session, lua_State* L, const char* name = nullptr) {
    if (!L) return 0;

    auto found = session.threadIds.find(L);
    if (found != session.threadIds.end()) {
        DebugThread* thread = dbg_find_thread_by_id_locked(session, found->second);
        if (thread && name && *name) {
            thread->name = name;
        }
        return found->second;
    }

    DebugThread thread;
    thread.id = session.nextThreadId++;
    thread.L = L;
    thread.name =
        name && *name ? name : (thread.id == 1 ? "main" : "coroutine " + std::to_string(thread.id));
    session.threadIds[L] = thread.id;
    session.threads.push_back(std::move(thread));
    return session.threads.back().id;
}

static void dbg_mark_thread_state_locked(DebugSession& session, lua_State* L, const char* state,
                                         const char* stopReason = nullptr) {
    int threadId = dbg_note_thread_locked(session, L);
    DebugThread* thread = dbg_find_thread_by_id_locked(session, threadId);
    if (!thread) return;

    thread->state = state ? state : "";
    thread->stopReason = stopReason ? stopReason : "";
}

static const char* dbg_session_state_locked(const DebugSession& session) {
    if (session.workerDone || session.terminateRequested.load()) return "terminated";
    if (session.paused) return "paused";
    if (session.running) return "running";
    if (session.startRequested) return "starting";
    return "idle";
}

static void dbg_push_state_event(const std::shared_ptr<DebugSession>& session, const char* state) {
    DebugEvent event;
    event.event = "state";
    event.state = state ? state : "";
    dbg_push_event(session, std::move(event));
}

static void dbg_clear_variable_refs_locked(DebugSession& session, lua_State* L) {
    if (L) {
        for (const auto& [_, ref] : session.variableRefs) {
            if (ref.valueRef != LUA_NOREF) {
                lua_unref(L, ref.valueRef);
            }
        }
    }
    session.variableRefs.clear();
    session.nextVariableReference = 1;
}

static int dbg_create_variable_ref_locked(DebugSession& session, DebugVariableRef ref) {
    int id = session.nextVariableReference++;
    session.variableRefs[id] = std::move(ref);
    return id;
}

static int dbg_create_value_ref_locked(lua_State* L, DebugSession& session, int valueIndex) {
    valueIndex = lua_absindex(L, valueIndex);
    lua_pushvalue(L, valueIndex);
    int valueRef = lua_ref(L, -1);
    lua_pop(L, 1);

    DebugVariableRef ref;
    ref.kind = DebugVariableRefKind::Value;
    ref.threadId = session.pausedThreadId;
    ref.valueRef = valueRef;
    return dbg_create_variable_ref_locked(session, std::move(ref));
}

static std::string dbg_frame_name(const lua_Debug& ar) {
    if (ar.name && *ar.name) return ar.name;
    if (ar.what && strcmp(ar.what, "main") == 0) return "<main>";
    if (ar.what && strcmp(ar.what, "C") == 0) return "C function";
    return "<anonymous>";
}

static void dbg_capture_stack_locked(DebugSession& session, lua_State* L) {
    session.frames.clear();
    session.nextFrameId = 1;
    session.framesThreadId = dbg_note_thread_locked(session, L);
    bool skippingInternalPrefix = true;

    for (int level = 0; level < 128; level++) {
        lua_Debug ar = {};
        if (!lua_getinfo(L, level, "nsl", &ar)) break;

        std::string path = dbg_source_path(ar.source);
        bool isVisibleSourceFrame = ar.currentline > 0 && dbg_is_file_backed_source_path(path);
        if (skippingInternalPrefix && !isVisibleSourceFrame) {
            continue;
        }
        skippingInternalPrefix = false;

        DebugFrame frame;
        frame.id = session.nextFrameId++;
        frame.threadId = session.framesThreadId;
        frame.level = level;
        frame.name = dbg_frame_name(ar);
        frame.source = dbg_make_source(path);
        frame.line = ar.currentline > 0 ? ar.currentline : 1;
        frame.column = 1;
        frame.pc = eryx_debug_current_instructionpc(L, level);
        session.frames.push_back(std::move(frame));
    }
}

static void dbg_capture_entry_frame_locked(DebugSession& session) {
    session.frames.clear();
    session.nextFrameId = 1;
    session.framesThreadId = dbg_note_thread_locked(session, session.controlLua, "main");

    DebugFrame frame;
    frame.id = session.nextFrameId++;
    frame.threadId = session.framesThreadId;
    frame.level = 0;
    frame.name = "<main>";
    frame.source = dbg_make_source(session.options.program);
    frame.line = 1;
    frame.column = 1;
    frame.pc = 0;
    session.frames.push_back(std::move(frame));
}

static void dbg_fill_stopped_event_location_locked(DebugEvent& stopped,
                                                   const DebugSession& session) {
    if (!session.frames.empty()) {
        stopped.source = session.frames.front().source;
        stopped.line = session.frames.front().line;
        stopped.column = session.frames.front().column;
    }
}

static void dbg_push_source(lua_State* L, const DebugSource& source) {
    lua_createtable(L, 0, 4);
    std::string id = dbg_source_id(source);
    if (!id.empty()) {
        lua_pushlstring(L, id.data(), id.size());
        lua_setfield(L, -2, "id");
    }
    if (!source.name.empty()) {
        lua_pushlstring(L, source.name.data(), source.name.size());
        lua_setfield(L, -2, "name");
    }
    if (!source.path.empty()) {
        lua_pushlstring(L, source.path.data(), source.path.size());
        lua_setfield(L, -2, "path");
        if (dbg_is_file_backed_source_path(source.path)) {
            lua_pushliteral(L, "file");
            lua_setfield(L, -2, "kind");
        }
    }
}

static void dbg_push_frame(lua_State* L, const DebugFrame& frame) {
    lua_createtable(L, 0, 8);
    lua_pushinteger(L, frame.id);
    lua_setfield(L, -2, "id");
    lua_pushinteger(L, frame.threadId);
    lua_setfield(L, -2, "threadId");
    lua_pushlstring(L, frame.name.data(), frame.name.size());
    lua_setfield(L, -2, "name");
    dbg_push_source(L, frame.source);
    lua_setfield(L, -2, "source");
    lua_pushinteger(L, frame.line);
    lua_setfield(L, -2, "line");
    lua_pushinteger(L, frame.column);
    lua_setfield(L, -2, "column");
    lua_pushinteger(L, frame.pc);
    lua_setfield(L, -2, "pc");
    std::string instruction = "luau:" + frame.source.path + ":" + std::to_string(frame.pc);
    lua_pushlstring(L, instruction.data(), instruction.size());
    lua_setfield(L, -2, "instruction");
}

static DebugSession* dbg_session_from_lua(lua_State* L) {
    return static_cast<DebugSession*>(lua_callbacks(L)->userdata);
}

static void dbg_store_session_on_lua(lua_State* L, DebugSession* session) {
    lua_callbacks(L)->userdata = session;
}

static void dbg_pause_on_hook(lua_State* L, const char* reason) {
    DebugSession* session = dbg_session_from_lua(L);
    if (!session) return;

    int stoppedThreadId = 1;
    {
        std::lock_guard lock(session->mutex);
        int threadId = dbg_note_thread_locked(*session, L);
        stoppedThreadId = threadId;
        dbg_cancel_step_state_locked(L, *session);
        dbg_clear_variable_refs_locked(*session, L);
        dbg_apply_all_breakpoints_locked(L, *session);
        dbg_capture_stack_locked(*session, L);
        session->paused = true;
        session->running = false;
        session->pausedLua = L;
        session->pausedThreadId = threadId;
        session->lastStopReason = reason ? reason : "";
        dbg_mark_thread_state_locked(*session, L, "paused", reason);
    }

    DebugEvent stopped;
    stopped.event = "stopped";
    stopped.reason = reason;
    stopped.threadId = stoppedThreadId;
    {
        std::lock_guard lock(session->mutex);
        dbg_fill_stopped_event_location_locked(stopped, *session);
    }
    std::shared_ptr<DebugSession> shared = session->shared_from_this();
    dbg_push_event(shared, std::move(stopped));

    dbg_wait_for_continue(shared);
}

static bool dbg_should_stop_for_step(lua_State* L, lua_Debug* ar, DebugSession& session) {
    DebugStepMode mode = session.stepMode;
    if (mode == DebugStepMode::None) return false;

    if (!ar || ar->currentline <= 0) {
        return false;
    }

    int depth = lua_stackdepth(L);
    bool movedLine = ar->currentline != session.stepStartLine;
    if (session.stepFromEntry) {
        return movedLine;
    }

    switch (mode) {
        case DebugStepMode::In:
            return movedLine;
        case DebugStepMode::Over:
            return depth <= session.stepStartDepth && movedLine;
        case DebugStepMode::Out:
            return depth < session.stepStartDepth;
        case DebugStepMode::None:
            return false;
    }

    return false;
}

static void dbg_step_hook(lua_State* L, lua_Debug* ar) {
    DebugSession* session = dbg_session_from_lua(L);
    if (!session) {
        lua_singlestep(L, 0);
        return;
    }

    DebugPauseRequest pauseRequest = session->pauseRequest.exchange(DebugPauseRequest::None);
    if (pauseRequest == DebugPauseRequest::Manual) {
        dbg_pause_on_hook(L, "manual");
        return;
    }
    if (pauseRequest == DebugPauseRequest::Pause) {
        bool matchesTarget = true;
        int targetThreadId = session->pauseTargetThreadId.load();
        if (targetThreadId != 0) {
            std::lock_guard lock(session->mutex);
            matchesTarget = dbg_note_thread_locked(*session, L) == targetThreadId;
        }
        if (matchesTarget) {
            dbg_pause_on_hook(L, "pause");
            return;
        }
        session->pauseRequest.store(DebugPauseRequest::Pause);
    }

    lua_Debug fallback = {};
    ar = dbg_resolve_hook_debug_info(L, ar, fallback);

    {
        std::lock_guard lock(session->mutex);
        bool shouldStop = dbg_should_stop_for_step(L, ar, *session);
        if (!shouldStop) {
            return;
        }
    }

    dbg_pause_on_hook(L, "step");
}

static std::string dbg_trim(std::string value) {
    size_t start = 0;
    while (start < value.size() && std::isspace((unsigned char)value[start])) start++;

    size_t end = value.size();
    while (end > start && std::isspace((unsigned char)value[end - 1])) end--;

    return value.substr(start, end - start);
}

static std::string dbg_message_from_top(lua_State* L) {
    size_t len = 0;
    const char* text = lua_tolstring(L, -1, &len);
    if (text) return std::string(text, len);
    return eryx_format_exception(L, -1, false);
}

static bool dbg_set_env_field_if_missing(lua_State* L, int envIndex, const char* name) {
    if (!name || !*name || name[0] == '(') return false;

    envIndex = lua_absindex(L, envIndex);
    lua_getfield(L, envIndex, name);
    bool missing = lua_isnil(L, -1);
    lua_pop(L, 1);
    if (!missing) return false;

    lua_pushvalue(L, -1);
    lua_setfield(L, envIndex, name);
    return true;
}

static void dbg_push_frame_environment(lua_State* L, int frameLevel) {
    lua_newtable(L);
    int envIndex = lua_absindex(L, -1);

    lua_Debug ar = {};
    bool hasFunction = lua_getinfo(L, frameLevel, "f", &ar) != 0;
    int functionIndex = hasFunction ? lua_absindex(L, -1) : 0;

    bool hasFallback = false;
    if (hasFunction && lua_isfunction(L, functionIndex)) {
        for (int upvalueIndex = 1;; upvalueIndex++) {
            const char* name = lua_getupvalue(L, functionIndex, upvalueIndex);
            if (!name) break;
            if (strcmp(name, "_ENV") == 0 && lua_istable(L, -1)) {
                hasFallback = true;
                break;
            }
            lua_pop(L, 1);
        }
    }

    if (!hasFallback) {
        lua_getglobal(L, "_G");
    }

    lua_newtable(L);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, envIndex);
    lua_pop(L, 1);

    if (hasFunction && lua_isfunction(L, functionIndex)) {
        for (int upvalueIndex = 1;; upvalueIndex++) {
            const char* name = lua_getupvalue(L, functionIndex, upvalueIndex);
            if (!name) break;
            if (strcmp(name, "_ENV") != 0) {
                dbg_set_env_field_if_missing(L, envIndex, name);
            }
            lua_pop(L, 1);
        }
    }

    for (int localIndex = 1;; localIndex++) {
        const char* name = lua_getlocal(L, frameLevel, localIndex);
        if (!name) break;
        dbg_set_env_field_if_missing(L, envIndex, name);
        lua_pop(L, 1);
    }

    if (hasFunction) {
        lua_remove(L, functionIndex);
    }
}

static bool dbg_load_eval_chunk(lua_State* L, const std::string& source,
                                const std::string& chunkName, std::string& error) {
    Luau::CompileOptions opts;
    opts.optimizationLevel = 1;
    opts.debugLevel = 1;
    opts.typeInfoLevel = 1;

    std::string bytecode = Luau::compile(source, opts);
    int status = luau_load(L, chunkName.c_str(), bytecode.data(), bytecode.size(), 0);
    if (status != 0) {
        error = dbg_message_from_top(L);
        lua_pop(L, 1);
        return false;
    }

    return true;
}

static bool dbg_execute_in_frame(lua_State* L, int frameLevel, const std::string& source,
                                 bool allowStatements, std::string& error, int& resultCount) {
    std::string expression = dbg_trim(source);
    if (expression.empty()) {
        error = "expression is empty";
        return false;
    }

    std::vector<std::string> candidates;
    candidates.push_back("return " + expression);
    if (allowStatements) {
        candidates.push_back(expression);
    }

    std::string lastError;
    for (size_t i = 0; i < candidates.size(); i++) {
        if (!dbg_load_eval_chunk(L, candidates[i], "=(debug-evaluate)", lastError)) {
            continue;
        }

        dbg_push_frame_environment(L, frameLevel);
        lua_setfenv(L, -2);

        int top = lua_gettop(L);
        int status = eryx_pcall(L, 0, LUA_MULTRET, 0);
        if (status == LUA_OK) {
            resultCount = lua_gettop(L) - top + 1;
            return true;
        }

        lastError = dbg_message_from_top(L);
        lua_settop(L, top - 1);
    }

    error = lastError.empty() ? "failed to evaluate expression" : lastError;
    return false;
}

static void dbg_count_value_children(lua_State* L, int index, int& named, int& indexed) {
    named = 0;
    indexed = 0;
    index = lua_absindex(L, index);

    if (!lua_istable(L, index)) return;

    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (dbg_is_array_index(L, -2)) {
            indexed++;
        } else {
            named++;
        }
        lua_pop(L, 1);
    }
}

static void dbg_push_evaluate_success(lua_State* outL, lua_State* valueL, DebugSession& session,
                                      int valueIndex, bool hex) {
    valueIndex = lua_absindex(valueL, valueIndex);

    lua_createtable(outL, 0, 2);
    lua_pushboolean(outL, true);
    lua_setfield(outL, -2, "ok");

    dbg_push_value_locked(outL, valueL, session, "<result>", valueIndex, hex);
    lua_setfield(outL, -2, "value");
}

static void dbg_push_evaluate_error(lua_State* L, const std::string& message) {
    lua_createtable(L, 0, 2);
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "ok");

    lua_createtable(L, 0, 1);
    lua_pushlstring(L, message.data(), message.size());
    lua_setfield(L, -2, "message");
    lua_setfield(L, -2, "error");
}

static bool dbg_evaluate_condition(lua_State* L, const std::string& condition, std::string& error) {
    int resultCount = 0;
    if (!dbg_execute_in_frame(L, 0, condition, false, error, resultCount)) {
        return false;
    }

    if (resultCount == 0) {
        lua_pushnil(L);
        resultCount = 1;
    }

    bool value = lua_toboolean(L, -resultCount) != 0;
    lua_pop(L, resultCount);
    return value;
}

static bool dbg_parse_positive_int(const std::string& text, int& out) {
    std::string value = dbg_trim(text);
    if (value.empty()) return false;

    char* end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (!end || *end != '\0' || parsed <= 0 || parsed > INT32_MAX) {
        return false;
    }

    out = (int)parsed;
    return true;
}

static bool dbg_hit_condition_matches(const std::string& hitCondition, int hitCount) {
    std::string condition = dbg_trim(hitCondition);
    if (condition.empty()) return true;

    struct Op {
        const char* text;
        enum Kind { Eq, Ge, Gt, Le, Lt, Mod } kind;
    };

    static const Op ops[] = {
        { ">=", Op::Ge }, { "<=", Op::Le }, { "==", Op::Eq }, { "=", Op::Eq },
        { ">", Op::Gt },  { "<", Op::Lt },  { "%", Op::Mod },
    };

    Op::Kind kind = Op::Eq;
    std::string numberText = condition;
    for (const Op& op : ops) {
        size_t len = std::strlen(op.text);
        if (condition.rfind(op.text, 0) == 0) {
            kind = op.kind;
            numberText = condition.substr(len);
            break;
        }
    }

    int value = 0;
    if (!dbg_parse_positive_int(numberText, value)) {
        return true;
    }

    switch (kind) {
        case Op::Eq:
            return hitCount == value;
        case Op::Ge:
            return hitCount >= value;
        case Op::Gt:
            return hitCount > value;
        case Op::Le:
            return hitCount <= value;
        case Op::Lt:
            return hitCount < value;
        case Op::Mod:
            return value != 0 && hitCount % value == 0;
    }

    return true;
}

static bool dbg_push_logpoint_expression_value(lua_State* L, const std::string& expression) {
    std::string error;
    int resultCount = 0;
    if (!dbg_execute_in_frame(L, 0, expression, false, error, resultCount)) {
        return false;
    }

    if (resultCount == 0) {
        lua_pushnil(L);
    } else if (resultCount > 1) {
        lua_replace(L, -resultCount);
        lua_pop(L, resultCount - 1);
    }

    return true;
}

static std::string dbg_format_logpoint_message(lua_State* L, const std::string& message) {
    std::string output;

    for (size_t i = 0; i < message.size();) {
        if (message[i] != '{') {
            output.push_back(message[i++]);
            continue;
        }

        size_t end = message.find('}', i + 1);
        if (end == std::string::npos) {
            output.append(message.substr(i));
            break;
        }

        std::string expression = message.substr(i + 1, end - i - 1);
        if (dbg_push_logpoint_expression_value(L, expression)) {
            output.append(dbg_format_lua_scalar(L, -1));
            lua_pop(L, 1);
        } else {
            output.push_back('{');
            output.append(expression);
            output.push_back('}');
        }

        i = end + 1;
    }

    return output;
}

static void dbg_breakpoint_hook(lua_State* L, lua_Debug* ar) {
    DebugSession* session = dbg_session_from_lua(L);
    if (!session) return;

    lua_Debug fallback = {};
    lua_Debug* activeAr = dbg_resolve_hook_debug_info(L, ar, fallback);

    std::string sourcePath = activeAr ? dbg_source_path(activeAr->source) : "";
    int line = activeAr && activeAr->currentline > 0 ? activeAr->currentline : 0;
    std::vector<std::string> logMessages;
    std::vector<int> hitBreakpointIds;
    std::vector<DebugBreakpointSnapshot> candidates;
    bool shouldStopForBreakpoint = false;
    bool hitInternalBreakpoint = false;

    {
        std::lock_guard lock(session->mutex);
        for (const DebugBreakpoint& breakpoint : session->breakpoints) {
            if (!breakpoint.verified || breakpoint.actualLine != line) {
                continue;
            }
            if (!breakpoint.sourcePath.empty() &&
                !dbg_source_matches(breakpoint.sourcePath, sourcePath)) {
                continue;
            }

            DebugBreakpointSnapshot snapshot;
            snapshot.id = breakpoint.id;
            snapshot.internal = breakpoint.internal;
            snapshot.sourcePath = breakpoint.sourcePath;
            snapshot.condition = breakpoint.condition;
            snapshot.hitCondition = breakpoint.hitCondition;
            snapshot.logMessage = breakpoint.logMessage;
            candidates.push_back(std::move(snapshot));
        }
    }

    for (const DebugBreakpointSnapshot& breakpoint : candidates) {
        if (!dbg_trim(breakpoint.condition).empty()) {
            std::string error;
            if (!dbg_evaluate_condition(L, breakpoint.condition, error)) {
                continue;
            }
        }

        int hitCount = 0;
        bool found = false;
        {
            std::lock_guard lock(session->mutex);
            for (DebugBreakpoint& liveBreakpoint : session->breakpoints) {
                if (liveBreakpoint.id != breakpoint.id) {
                    continue;
                }
                liveBreakpoint.hitCount++;
                hitCount = liveBreakpoint.hitCount;
                found = true;
                break;
            }
        }
        if (!found) {
            continue;
        }

        if (!dbg_hit_condition_matches(breakpoint.hitCondition, hitCount)) {
            continue;
        }

        if (!breakpoint.logMessage.empty()) {
            logMessages.push_back(dbg_format_logpoint_message(L, breakpoint.logMessage));
            continue;
        }

        if (breakpoint.internal) {
            hitInternalBreakpoint = true;
        } else {
            hitBreakpointIds.push_back(breakpoint.id);
            shouldStopForBreakpoint = true;
        }
    }

    for (std::string& message : logMessages) {
        DebugEvent output;
        output.event = "output";
        output.stream = "console";
        output.text = std::move(message);
        if (output.text.empty() || output.text.back() != '\n') {
            output.text.push_back('\n');
        }
        output.source.path = sourcePath;
        output.source.name = dbg_source_name(sourcePath);
        output.line = line;
        output.column = 1;
        dbg_push_event(session->shared_from_this(), std::move(output));
    }

    bool shouldStopForStep = false;
    if (hitInternalBreakpoint) {
        std::lock_guard lock(session->mutex);
        shouldStopForStep = dbg_should_stop_for_step(L, activeAr, *session);
    }

    if (shouldStopForBreakpoint || shouldStopForStep) {
        int stoppedThreadId = 1;
        {
            std::lock_guard lock(session->mutex);
            stoppedThreadId = dbg_note_thread_locked(*session, L);
            dbg_cancel_step_state_locked(L, *session);
            dbg_clear_variable_refs_locked(*session, L);
            dbg_apply_all_breakpoints_locked(L, *session);
            dbg_capture_stack_locked(*session, L);
            session->paused = true;
            session->running = false;
            session->pausedLua = L;
            session->pausedThreadId = stoppedThreadId;
            session->lastStopReason = shouldStopForStep ? "step" : "breakpoint";
            dbg_mark_thread_state_locked(*session, L, "paused",
                                         shouldStopForStep ? "step" : "breakpoint");
        }

        DebugEvent stopped;
        stopped.event = "stopped";
        stopped.reason = shouldStopForStep ? "step" : "breakpoint";
        stopped.threadId = stoppedThreadId;
        if (!shouldStopForStep) {
            stopped.hitBreakpointIds = std::move(hitBreakpointIds);
        }
        {
            std::lock_guard lock(session->mutex);
            dbg_fill_stopped_event_location_locked(stopped, *session);
        }
        std::shared_ptr<DebugSession> shared = session->shared_from_this();
        dbg_push_event(shared, std::move(stopped));

        dbg_wait_for_continue(shared);
    }
}

static void dbg_push_breakpoint(lua_State* L, const DebugBreakpoint& breakpoint) {
    lua_createtable(L, 0, 5);
    lua_pushinteger(L, breakpoint.id);
    lua_setfield(L, -2, "id");
    lua_pushboolean(L, breakpoint.verified);
    lua_setfield(L, -2, "verified");
    if (breakpoint.actualLine > 0) {
        lua_pushinteger(L, breakpoint.actualLine);
        lua_setfield(L, -2, "line");
    } else if (breakpoint.requestedLine > 0) {
        lua_pushinteger(L, breakpoint.requestedLine);
        lua_setfield(L, -2, "line");
    }
    if (!breakpoint.sourcePath.empty()) {
        DebugSource source;
        source.path = breakpoint.sourcePath;
        source.name = dbg_source_name(breakpoint.sourcePath);
        dbg_push_source(L, source);
        lua_setfield(L, -2, "source");
    }
    if (!breakpoint.message.empty()) {
        lua_pushlstring(L, breakpoint.message.data(), breakpoint.message.size());
        lua_setfield(L, -2, "message");
    }
}

static void dbg_apply_breakpoints_to_function_locked(lua_State* L, int funcIndex,
                                                     DebugSession& session,
                                                     const DebugLoadedFunction& loaded) {
    funcIndex = lua_absindex(L, funcIndex);

    for (DebugBreakpoint& breakpoint : session.breakpoints) {
        if (!breakpoint.sourcePath.empty() &&
            !dbg_source_matches(breakpoint.sourcePath, loaded.sourcePath)) {
            continue;
        }

        int actual = lua_breakpoint(L, funcIndex, breakpoint.requestedLine, 1);
        if (actual >= 0) {
            breakpoint.actualLine = actual;
            breakpoint.verified = true;
            breakpoint.message.clear();
            session.appliedBreakpoints.push_back({ loaded.ref, actual });
        } else {
            breakpoint.actualLine = 0;
            breakpoint.verified = false;
            breakpoint.message = "No executable code at or after this line";
        }
    }
}

static void dbg_apply_all_breakpoints_locked(lua_State* L, DebugSession& session) {
    if (session.appliedBreakpointRevision == session.breakpointRevision) {
        return;
    }

    for (const DebugAppliedBreakpoint& applied : session.appliedBreakpoints) {
        lua_getref(L, applied.functionRef);
        if (lua_isfunction(L, -1)) {
            lua_breakpoint(L, -1, applied.line, 0);
        }
        lua_pop(L, 1);
    }
    session.appliedBreakpoints.clear();

    for (DebugBreakpoint& breakpoint : session.breakpoints) {
        breakpoint.verified = false;
        breakpoint.actualLine = 0;
        breakpoint.message = "Breakpoint source is not loaded yet";
    }

    for (const DebugLoadedFunction& loaded : session.loadedFunctions) {
        lua_getref(L, loaded.ref);
        if (lua_isfunction(L, -1)) {
            dbg_apply_breakpoints_to_function_locked(L, -1, session, loaded);
        }
        lua_pop(L, 1);
    }

    session.appliedBreakpointRevision = session.breakpointRevision;
}

static void dbg_note_loaded_function(lua_State* L, int funcIndex, const char* chunkName,
                                     void* ctx) {
    auto* session = static_cast<DebugSession*>(ctx);
    if (!session) return;

    funcIndex = lua_absindex(L, funcIndex);
    DebugLoadedFunction loaded;
    loaded.sourcePath = dbg_source_path(chunkName);
    lua_pushvalue(L, funcIndex);
    loaded.ref = lua_ref(L, -1);
    lua_pop(L, 1);

    bool shouldAnnounceSource = dbg_is_file_backed_source_path(loaded.sourcePath);
    {
        std::lock_guard lock(session->mutex);
        if (shouldAnnounceSource) {
            for (const DebugLoadedFunction& existing : session->loadedFunctions) {
                if (dbg_source_matches(existing.sourcePath, loaded.sourcePath)) {
                    shouldAnnounceSource = false;
                    break;
                }
            }
        }
        session->loadedFunctions.push_back(loaded);
        session->appliedBreakpointRevision = -1;
        dbg_apply_all_breakpoints_locked(L, *session);
    }

    if (shouldAnnounceSource) {
        DebugEvent event;
        event.event = "source-added";
        event.source = dbg_make_source(loaded.sourcePath);
        dbg_push_event(session->shared_from_this(), std::move(event));
    }
}

static bool dbg_wait_for_start(const std::shared_ptr<DebugSession>& session) {
    std::unique_lock lock(session->mutex);
    session->commandCv.wait(
        lock, [&] { return session->startRequested || session->terminateRequested.load(); });
    return !session->terminateRequested.load();
}

static bool dbg_wait_for_continue(const std::shared_ptr<DebugSession>& session) {
    std::unique_lock lock(session->mutex);
    session->paused = true;
    session->running = false;
    bool resumingFromException = session->lastStopReason == "exception";
    session->commandCv.wait(
        lock, [&] { return session->continueRequested || session->terminateRequested.load(); });
    if (session->pausedLua && !resumingFromException) {
        if (session->stepMode != DebugStepMode::None) {
            dbg_prepare_step_breakpoints_locked(session->pausedLua, *session);
        } else {
            dbg_cancel_step_state_locked(session->pausedLua, *session);
            dbg_apply_all_breakpoints_locked(session->pausedLua, *session);
        }
        dbg_clear_variable_refs_locked(*session, session->pausedLua);
    }
    session->continueRequested = false;
    session->pauseTargetThreadId.store(0);
    session->paused = false;
    if (session->pausedLua) {
        dbg_mark_thread_state_locked(*session, session->pausedLua,
                                     session->terminateRequested.load() ? "terminated" : "running");
    }
    session->pausedLua = nullptr;
    session->pausedThreadId = 0;
    session->running = !session->terminateRequested.load();
    bool resumed = session->running;
    lock.unlock();
    if (resumed && !resumingFromException) {
        dbg_push_state_event(session, "running");
    }
    return resumed;
}

static void dbg_finish_session(const std::shared_ptr<DebugSession>& session,
                               std::vector<DebugEvent> finalEvents) {
    {
        std::lock_guard lock(session->mutex);
        for (DebugEvent& event : finalEvents) {
            session->events.push(std::move(event));
        }
        session->running = false;
        session->paused = false;
        session->controlLua = nullptr;
        session->pausedLua = nullptr;
        session->pausedThreadId = 0;
        for (DebugThread& thread : session->threads) {
            thread.state = "terminated";
            thread.stopReason.clear();
        }
        session->workerDone = true;
    }
    session->eventCv.notify_all();
    session->commandCv.notify_all();
}

static std::string dbg_exception_stack_trace(const LuaException* exception) {
    if (!exception) return "";

    std::ostringstream ss;
    bool first = true;
    for (int i = (int)exception->traceback.size() - 1; i >= 0; i--) {
        const LuaFrame& frame = exception->traceback[(size_t)i];
        if (frame.line <= 0 || frame.source.empty() || frame.source[0] == '=') continue;

        if (!first) ss << "\n";
        first = false;
        ss << frame.short_src << ":" << frame.line;
        if (!frame.function.empty()) {
            ss << " in " << frame.function;
        }
    }

    return ss.str();
}

static bool dbg_source_backed_exception_frame(const LuaFrame& frame) {
    return frame.line > 0 && !frame.source.empty() && frame.source[0] != '=';
}

static DebugFrame dbg_frame_from_exception_trace(DebugSession& session, const LuaFrame& frame,
                                                 int level) {
    DebugFrame out;
    out.id = session.nextFrameId++;
    out.level = level;
    out.name = frame.function.empty() ? "<anonymous>" : frame.function;
    out.source = dbg_make_source(dbg_source_path(frame.source.c_str()));
    out.line = frame.line;
    out.column = 1;
    out.pc = 0;
    return out;
}

static bool dbg_lua_frame_is_source_backed(const lua_Debug& ar) {
    return ar.currentline > 0 && ar.source && ar.source[0] != '=' &&
           !dbg_source_path(ar.source).empty();
}

static std::vector<DebugFrame> dbg_capture_live_source_frames(lua_State* L) {
    std::vector<DebugFrame> frames;

    for (int level = 0; level < 128; level++) {
        lua_Debug ar = {};
        if (!lua_getinfo(L, level, "nsl", &ar)) break;
        if (!dbg_lua_frame_is_source_backed(ar)) continue;

        std::string path = dbg_source_path(ar.source);

        DebugFrame frame;
        frame.id = 0;
        frame.level = level;
        frame.name = dbg_frame_name(ar);
        frame.source = dbg_make_source(path);
        frame.line = ar.currentline;
        frame.column = 1;
        frame.pc = eryx_debug_current_instructionpc(L, level);
        frames.push_back(std::move(frame));
    }

    return frames;
}

static int dbg_find_live_exception_frame(const std::vector<DebugFrame>& liveFrames,
                                         const std::vector<bool>& used,
                                         const LuaFrame& exceptionFrame, bool exactLine) {
    std::string path = dbg_source_path(exceptionFrame.source.c_str());

    for (int i = 0; i < (int)liveFrames.size(); i++) {
        if (used[(size_t)i]) continue;

        const DebugFrame& liveFrame = liveFrames[(size_t)i];
        if (!dbg_source_matches(liveFrame.source.path, path)) continue;
        if (exactLine && liveFrame.line != exceptionFrame.line) continue;

        return i;
    }

    return -1;
}

static void dbg_capture_exception_stack_locked(DebugSession& session, lua_State* L,
                                               const LuaException* exception) {
    session.frames.clear();
    session.nextFrameId = 1;

    if (!exception) return;

    std::vector<DebugFrame> liveFrames = dbg_capture_live_source_frames(L);
    std::vector<bool> used(liveFrames.size(), false);

    for (const LuaFrame& frame : exception->traceback) {
        if (!dbg_source_backed_exception_frame(frame)) {
            continue;
        }

        int liveIndex = dbg_find_live_exception_frame(liveFrames, used, frame, true);
        if (liveIndex < 0) {
            liveIndex = dbg_find_live_exception_frame(liveFrames, used, frame, false);
        }

        if (liveIndex >= 0) {
            DebugFrame liveFrame = liveFrames[(size_t)liveIndex];
            used[(size_t)liveIndex] = true;
            liveFrame.id = session.nextFrameId++;
            if (!frame.function.empty()) {
                liveFrame.name = frame.function;
            }
            liveFrame.line = frame.line;
            session.frames.push_back(std::move(liveFrame));
        } else {
            session.frames.push_back(dbg_frame_from_exception_trace(session, frame, -1));
        }
    }
}

static void dbg_capture_exception_info_locked(DebugSession& session, lua_State* L,
                                              LuaException* exception) {
    session.hasExceptionInfo = true;
    session.exceptionId = exception && exception->type ? exception->type : "LuauError";
    session.exceptionTypeName = session.exceptionId;
    session.exceptionMessage = exception ? exception->message : eryx_format_exception(L, -1, false);
    session.exceptionDescription = session.exceptionMessage;
    session.exceptionStackTrace =
        exception ? dbg_exception_stack_trace(exception) : eryx_format_exception(L, -1, false);
    session.exceptionSource = {};
    session.exceptionLine = 0;
    session.exceptionColumn = 1;

    if (exception) {
        const LuaFrame* selectedFrame = nullptr;
        for (const LuaFrame& frame : exception->traceback) {
            if (dbg_source_backed_exception_frame(frame)) {
                selectedFrame = &frame;
                break;
            }
        }

        if (!selectedFrame) return;

        const LuaFrame& frame = *selectedFrame;
        session.exceptionSource = dbg_make_source(dbg_source_path(frame.source.c_str()));
        session.exceptionLine = frame.line;
    }
}

static bool dbg_pause_on_exception(const std::shared_ptr<DebugSession>& session, lua_State* L,
                                   LuaException* exception) {
    int stoppedThreadId = 1;
    {
        std::lock_guard lock(session->mutex);
        stoppedThreadId = dbg_note_thread_locked(*session, L);
        dbg_cancel_step_state_locked(L, *session);
        dbg_clear_variable_refs_locked(*session, L);
        dbg_apply_all_breakpoints_locked(L, *session);
        dbg_capture_exception_stack_locked(*session, L, exception);
        dbg_capture_exception_info_locked(*session, L, exception);
        session->paused = true;
        session->running = false;
        session->pausedLua = L;
        session->pausedThreadId = stoppedThreadId;
        session->lastStopReason = "exception";
        dbg_mark_thread_state_locked(*session, L, "paused", "exception");
    }

    DebugEvent stopped;
    stopped.event = "stopped";
    stopped.reason = "exception";
    stopped.description = "Paused on exception";
    stopped.text = exception ? exception->message : eryx_format_exception(L, -1, false);
    stopped.threadId = stoppedThreadId;
    {
        std::lock_guard lock(session->mutex);
        stopped.source = session->exceptionSource;
        stopped.line = session->exceptionLine;
        stopped.column = session->exceptionColumn;
    }
    dbg_push_event(session, std::move(stopped));
    return dbg_wait_for_continue(session);
}

static EryxRuntimeHookResult dbg_runtime_after_init(EryxRuntimeHost* host, void* userdata,
                                                    std::string& error) {
    auto* ctx = static_cast<DebugRuntimeContext*>(userdata);
    if (!ctx || !ctx->session || !host || !host->GL || !host->rt) {
        error = "debug runtime context is invalid";
        return EryxRuntimeHookResult::Fail;
    }

    DebugSession* session = ctx->session.get();
    host->rt->hasCliArgs = true;
    host->rt->cliArgs = session->options.args;
    host->rt->nativeCodegenMode = session->options.nativeCodegen ? EryxNativeCodegenMode::All
                                                                 : EryxNativeCodegenMode::Disabled;
    host->rt->luauOptimizationLevel = session->options.optimisationLevel;
    host->rt->luauDebugLevel = 2;
    host->rt->luauTypeInfoLevel = 1;
    dbg_store_session_on_lua(host->GL, session);
    host->rt->debugFunctionLoaded = dbg_note_loaded_function;
    host->rt->debugFunctionLoadedContext = session;
    lua_callbacks(host->GL)->debugbreak = [](lua_State* L, lua_Debug* ar) {
        dbg_breakpoint_hook(L, ar);
    };
    lua_callbacks(host->GL)->debugstep = [](lua_State* L, lua_Debug* ar) { dbg_step_hook(L, ar); };
    lua_callbacks(host->GL)->interrupt = [](lua_State* L, int gc) {
        if (gc >= 0) return;
        DebugSession* session = dbg_session_from_lua(L);
        if (!session) return;

        if (session->pauseRequest.load() == DebugPauseRequest::Manual &&
            dbg_current_frame_is_source_backed(L)) {
            DebugPauseRequest expected = DebugPauseRequest::Manual;
            if (session->pauseRequest.compare_exchange_strong(expected, DebugPauseRequest::None)) {
                dbg_pause_on_hook(L, "manual");
                return;
            }
        }

        if (session->pauseRequest.load() == DebugPauseRequest::Pause &&
            dbg_current_frame_is_source_backed(L)) {
            bool matchesTarget = true;
            int targetThreadId = session->pauseTargetThreadId.load();
            if (targetThreadId != 0) {
                std::lock_guard lock(session->mutex);
                matchesTarget = dbg_note_thread_locked(*session, L) == targetThreadId;
            }
            if (matchesTarget && session->pauseRequest.exchange(DebugPauseRequest::None) ==
                                     DebugPauseRequest::Pause) {
                dbg_pause_on_hook(L, "pause");
                return;
            }
        }

        std::lock_guard lock(session->mutex);
        dbg_apply_all_breakpoints_locked(L, *session);
    };

    return EryxRuntimeHookResult::Continue;
}

static EryxRuntimeHookResult dbg_runtime_after_load(EryxRuntimeHost*, lua_State* rootThread, int*,
                                                    void* userdata, std::string& error) {
    auto* ctx = static_cast<DebugRuntimeContext*>(userdata);
    if (!ctx || !ctx->session || !rootThread) {
        error = "debug runtime load state is invalid";
        return EryxRuntimeHookResult::Fail;
    }

    std::shared_ptr<DebugSession> session = ctx->session;
    {
        std::lock_guard lock(session->mutex);
        session->controlLua = rootThread;
        dbg_note_thread_locked(*session, rootThread, "main");
    }

    if (!dbg_wait_for_start(session)) {
        return EryxRuntimeHookResult::Stop;
    }

    {
        std::lock_guard lock(session->mutex);
        dbg_apply_all_breakpoints_locked(rootThread, *session);
    }

    {
        std::lock_guard lock(session->mutex);
        dbg_mark_thread_state_locked(*session, rootThread, "running");
        session->running = true;
    }

    if (!session->options.stopOnEntry) {
        dbg_push_state_event(session, "running");
        return EryxRuntimeHookResult::Continue;
    }

    int entryThreadId = 1;
    {
        std::lock_guard lock(session->mutex);
        dbg_clear_variable_refs_locked(*session, rootThread);
        dbg_capture_entry_frame_locked(*session);
        session->paused = true;
        session->running = false;
        session->pausedLua = rootThread;
        session->pausedThreadId = session->framesThreadId;
        entryThreadId = session->pausedThreadId;
        session->lastStopReason = "entry";
        dbg_mark_thread_state_locked(*session, rootThread, "paused", "entry");
    }

    DebugEvent stopped;
    stopped.event = "stopped";
    stopped.reason = "entry";
    stopped.threadId = entryThreadId;
    {
        std::lock_guard lock(session->mutex);
        dbg_fill_stopped_event_location_locked(stopped, *session);
    }
    dbg_push_event(session, std::move(stopped));

    return dbg_wait_for_continue(session) ? EryxRuntimeHookResult::Continue
                                          : EryxRuntimeHookResult::Stop;
}

static EryxRuntimeHookResult dbg_runtime_before_tick(EryxRuntimeHost*, lua_State*, void* userdata,
                                                     std::string&) {
    auto* ctx = static_cast<DebugRuntimeContext*>(userdata);
    if (!ctx || !ctx->session) {
        return EryxRuntimeHookResult::Fail;
    }

    return ctx->session->terminateRequested.load() ? EryxRuntimeHookResult::Stop
                                                   : EryxRuntimeHookResult::Continue;
}

static EryxRuntimeHookResult dbg_runtime_on_no_work(EryxRuntimeHost*, lua_State*, void*,
                                                    std::string&) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return EryxRuntimeHookResult::Continue;
}

static EryxRuntimeHookResult dbg_runtime_on_error(EryxRuntimeHost* host, lua_State*,
                                                  lua_State* runningLua, void* userdata,
                                                  std::string&) {
    auto* ctx = static_cast<DebugRuntimeContext*>(userdata);
    if (!ctx || !ctx->session) {
        return EryxRuntimeHookResult::Fail;
    }

    std::shared_ptr<DebugSession> session = ctx->session;
    ctx->exitCode = 1;

    if (runningLua) {
        LuaException* exception = eryx_get_exception(runningLua, -1);
        if (exception && strcmp(exception->type, ETYPE_SYSTEM_EXIT) == 0) {
            ctx->exitCode = (int)reinterpret_cast<std::intptr_t>(exception->extra);
        } else {
            bool shouldOutput = dbg_pause_on_exception(session, runningLua, exception);
            if (!shouldOutput || session->terminateRequested.load()) {
                return EryxRuntimeHookResult::Stop;
            }

            DebugEvent output;
            output.event = "output";
            output.stream = "stderr";
            output.text = eryx_format_exception(runningLua, -1, false) + "\n";
            dbg_push_event(session, std::move(output));
            return EryxRuntimeHookResult::Stop;
        }
    }

    return eryx_runtime_has_work(host->rt) ? EryxRuntimeHookResult::Continue
                                           : EryxRuntimeHookResult::Stop;
}

static EryxRuntimeHookResult dbg_runtime_on_root_completed(EryxRuntimeHost* host, lua_State*,
                                                           lua_State*, void*, std::string&) {
    if (!host || !host->rt) {
        return EryxRuntimeHookResult::Stop;
    }

    return eryx_runtime_has_work(host->rt) ? EryxRuntimeHookResult::Continue
                                           : EryxRuntimeHookResult::Stop;
}

static void dbg_worker(std::shared_ptr<DebugSession> session) {
    auto fail = [&](const std::string& message) {
        std::vector<DebugEvent> finalEvents;

        DebugEvent output;
        output.event = "output";
        output.stream = "stderr";
        output.text = message + "\n";
        finalEvents.push_back(std::move(output));

        DebugEvent terminated;
        terminated.event = "terminated";
        terminated.hasExitCode = true;
        terminated.exitCode = 1;
        finalEvents.push_back(std::move(terminated));

        dbg_finish_session(session, std::move(finalEvents));
    };

    try {
        DebugRuntimeContext context;
        context.session = session;

        EryxRuntimeEntry entry;
        entry.kind = EryxRuntimeEntryKind::File;
        entry.program = session->options.program;
        entry.chunkName = "@" + session->options.program;

        EryxRuntimeRunHooks hooks;
        hooks.userdata = &context;
        hooks.idleMode = UV_RUN_NOWAIT;
        hooks.afterInit = dbg_runtime_after_init;
        hooks.afterLoad = dbg_runtime_after_load;
        hooks.beforeTick = dbg_runtime_before_tick;
        hooks.onNoWork = dbg_runtime_on_no_work;
        hooks.onRuntimeError = dbg_runtime_on_error;
        hooks.onRootCompleted = dbg_runtime_on_root_completed;

        std::string error;
        if (!eryx_runtime_run_entry(entry, &hooks, error)) {
            fail(error.empty() ? "debuggee worker failed" : error);
            return;
        }

        std::vector<DebugEvent> finalEvents;
        if (session->terminateRequested.load()) {
            DebugEvent terminated;
            terminated.event = "terminated";
            finalEvents.push_back(std::move(terminated));
        } else {
            DebugEvent terminated;
            terminated.event = "terminated";
            terminated.hasExitCode = true;
            terminated.exitCode = context.exitCode;
            finalEvents.push_back(std::move(terminated));
        }

        dbg_finish_session(session, std::move(finalEvents));
    } catch (const std::exception& ex) {
        fail(std::string("debuggee worker failed: ") + ex.what());
    } catch (...) {
        fail("debuggee worker failed");
    }
}

static DebugSessionHandle* dbg_check_session(lua_State* L, int idx) {
    auto* handle = (DebugSessionHandle*)luaL_checkudata(L, idx, DBG_SESSION_MT);
    if (!handle || !handle->session) luaL_error(L, "debug session is closed");
    return handle;
}

static void dbg_request_terminate(const std::shared_ptr<DebugSession>& session) {
    {
        std::lock_guard lock(session->mutex);
        session->terminateRequested.store(true);
        session->startRequested = true;
        session->continueRequested = true;
    }
    session->commandCv.notify_all();
}

static void dbg_join(const std::shared_ptr<DebugSession>& session) {
    if (session && session->worker.joinable()) {
        session->worker.join();
    }
}

static std::vector<std::string> dbg_read_string_array_field(lua_State* L, int idx,
                                                            const char* field) {
    std::vector<std::string> values;
    idx = lua_absindex(L, idx);

    lua_getfield(L, idx, field);
    if (lua_istable(L, -1)) {
        int n = (int)lua_objlen(L, -1);
        values.reserve(n);
        for (int i = 1; i <= n; i++) {
            lua_rawgeti(L, -1, i);
            if (!lua_isnil(L, -1)) values.emplace_back(luaL_checkstring(L, -1));
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    return values;
}

static bool dbg_read_bool_field(lua_State* L, int idx, const char* field, bool defaultValue) {
    idx = lua_absindex(L, idx);
    lua_getfield(L, idx, field);
    bool value = lua_isboolean(L, -1) ? lua_toboolean(L, -1) != 0 : defaultValue;
    lua_pop(L, 1);
    return value;
}

static std::string dbg_read_string_field(lua_State* L, int idx, const char* field) {
    idx = lua_absindex(L, idx);
    lua_getfield(L, idx, field);
    std::string value;
    if (lua_isstring(L, -1)) value = lua_tostring(L, -1);
    lua_pop(L, 1);
    return value;
}

static int dbg_read_int_field(lua_State* L, int idx, const char* field, int defaultValue) {
    idx = lua_absindex(L, idx);
    lua_getfield(L, idx, field);
    int value = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : defaultValue;
    lua_pop(L, 1);
    return value;
}

static DebugLaunchOptions dbg_read_launch_options(lua_State* L, int idx) {
    luaL_checktype(L, idx, LUA_TTABLE);

    DebugLaunchOptions options;
    options.program = dbg_read_string_field(L, idx, "program");
    options.args = dbg_read_string_array_field(L, idx, "args");
    options.stopOnEntry = dbg_read_bool_field(L, idx, "stopOnEntry", false);
    options.nativeCodegen = dbg_read_bool_field(L, idx, "nativeCodegen", false);
    options.optimisationLevel = dbg_read_int_field(L, idx, "optimisationLevel", 0);

    if (options.program.empty()) {
        luaL_error(L, "session options require a program path");
    }

    return options;
}

static std::string dbg_read_source_argument(lua_State* L, int idx) {
    if (lua_isnoneornil(L, idx)) {
        return "";
    }

    idx = lua_absindex(L, idx);
    if (lua_isstring(L, idx)) {
        size_t len = 0;
        const char* value = lua_tolstring(L, idx, &len);
        return std::string(value ? value : "", len);
    }
    if (!lua_istable(L, idx)) {
        return "";
    }

    std::string value = dbg_read_string_field(L, idx, "path");
    if (!value.empty()) return value;
    value = dbg_read_string_field(L, idx, "id");
    if (!value.empty()) return value;
    return dbg_read_string_field(L, idx, "name");
}

static int debugger_open(lua_State* L) {
    DebugLaunchOptions options = dbg_read_launch_options(L, 1);
    auto session = std::make_shared<DebugSession>(std::move(options));

    auto* handle = (DebugSessionHandle*)lua_newuserdata(L, sizeof(DebugSessionHandle));
    new (handle) DebugSessionHandle{ session };
    luaL_getmetatable(L, DBG_SESSION_MT);
    lua_setmetatable(L, -2);

    session->worker = std::thread(dbg_worker, session);
    return 1;
}

static int debugger_breakpoint(lua_State* L) {
    DebugSession* session = dbg_session_from_lua(L);
    if (!session) {
        return 0;
    }

    session->pauseRequest.store(DebugPauseRequest::None);
    dbg_pause_on_hook(L, "manual");
    return 0;
}

static int session_start(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    {
        std::lock_guard lock(handle->session->mutex);
        handle->session->startRequested = true;
    }
    handle->session->commandCv.notify_all();
    dbg_push_state_event(handle->session, "starting");
    return 0;
}

static int session_wait(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::unique_lock lock(handle->session->mutex);
    handle->session->eventCv.wait(
        lock, [&] { return !handle->session->events.empty() || handle->session->workerDone; });

    if (handle->session->events.empty()) {
        lua_pushnil(L);
        return 1;
    }

    DebugEvent event = std::move(handle->session->events.front());
    handle->session->events.pop();
    lock.unlock();

    lua_createtable(L, 0, 8);
    lua_pushlstring(L, event.event.data(), event.event.size());
    lua_setfield(L, -2, "kind");

    if (event.event == "state") {
        lua_pushlstring(L, event.state.data(), event.state.size());
        lua_setfield(L, -2, "state");
        return 1;
    }

    if (event.event == "stopped") {
        lua_pushinteger(L, event.threadId);
        lua_setfield(L, -2, "threadId");
        lua_pushlstring(L, event.reason.data(), event.reason.size());
        lua_setfield(L, -2, "reason");
        if (!event.hitBreakpointIds.empty()) {
            lua_createtable(L, (int)event.hitBreakpointIds.size(), 0);
            for (int i = 0; i < (int)event.hitBreakpointIds.size(); i++) {
                lua_pushinteger(L, event.hitBreakpointIds[(size_t)i]);
                lua_rawseti(L, -2, i + 1);
            }
            lua_setfield(L, -2, "breakpoints");
        }
    } else if (event.event == "output") {
        lua_pushlstring(L, event.stream.data(), event.stream.size());
        lua_setfield(L, -2, "stream");
        lua_pushlstring(L, event.text.data(), event.text.size());
        lua_setfield(L, -2, "text");
    } else if (event.event == "terminated") {
        if (event.hasExitCode) {
            lua_pushinteger(L, event.exitCode);
            lua_setfield(L, -2, "exitCode");
        }
        return 1;
    }

    if (!event.description.empty() && event.event != "output") {
        lua_pushlstring(L, event.description.data(), event.description.size());
        lua_setfield(L, -2, "description");
    }
    if (!event.text.empty() && event.event != "output") {
        lua_pushlstring(L, event.text.data(), event.text.size());
        lua_setfield(L, -2, "text");
    }
    if (!event.source.path.empty() || !event.source.name.empty()) {
        dbg_push_source(L, event.source);
        lua_setfield(L, -2, "source");
    }
    if (event.line > 0) {
        lua_pushinteger(L, event.line);
        lua_setfield(L, -2, "line");
    }
    if (event.column > 0) {
        lua_pushinteger(L, event.column);
        lua_setfield(L, -2, "column");
    }

    return 1;
}

static int session_state(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::lock_guard lock(handle->session->mutex);
    lua_pushstring(L, dbg_session_state_locked(*handle->session));
    return 1;
}

static int session_threads(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::vector<DebugThread> threads;
    {
        std::lock_guard lock(handle->session->mutex);
        threads = handle->session->threads;
    }

    lua_createtable(L, (int)threads.size(), 0);
    for (int i = 0; i < (int)threads.size(); i++) {
        const DebugThread& thread = threads[(size_t)i];
        lua_createtable(L, 0, 4);
        lua_pushinteger(L, thread.id);
        lua_setfield(L, -2, "id");
        lua_pushlstring(L, thread.name.data(), thread.name.size());
        lua_setfield(L, -2, "name");
        lua_pushlstring(L, thread.state.data(), thread.state.size());
        lua_setfield(L, -2, "state");
        if (!thread.stopReason.empty() && thread.state == "paused") {
            lua_pushlstring(L, thread.stopReason.data(), thread.stopReason.size());
            lua_setfield(L, -2, "stopReason");
        }
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

static int session_resume(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    {
        std::lock_guard lock(handle->session->mutex);
        handle->session->continueRequested = true;
        handle->session->stepMode = DebugStepMode::None;
        handle->session->stepFromEntry = false;
        handle->session->pauseTargetThreadId.store(0);
        handle->session->running = true;
        handle->session->paused = false;
    }
    handle->session->commandCv.notify_all();
    return 0;
}

static int session_step_with_mode(lua_State* L, DebugStepMode mode) {
    auto* handle = dbg_check_session(L, 1);
    int threadId = lua_isnumber(L, 3) ? (int)lua_tointeger(L, 3) : 0;
    {
        std::lock_guard lock(handle->session->mutex);
        if (threadId != 0 && handle->session->pausedThreadId != 0 &&
            threadId != handle->session->pausedThreadId) {
            luaL_error(L, "thread is not paused");
        }
        handle->session->continueRequested = true;
        handle->session->stepMode = mode;
        handle->session->stepStartDepth =
            handle->session->pausedLua ? lua_stackdepth(handle->session->pausedLua) : 0;
        handle->session->stepFromEntry = handle->session->stepStartDepth == 0;
        if (!handle->session->frames.empty()) {
            const DebugFrame& frame = handle->session->frames.front();
            handle->session->stepStartLine = frame.line;
            handle->session->stepStartSource = frame.source.path;
        } else {
            handle->session->stepStartLine = 0;
            handle->session->stepStartSource.clear();
        }
        handle->session->running = true;
        handle->session->paused = false;
    }
    handle->session->commandCv.notify_all();
    return 0;
}

static int session_step(lua_State* L) {
    dbg_check_session(L, 1);

    const char* mode = luaL_checkstring(L, 2);
    if (strcmp(mode, "in") == 0) {
        return session_step_with_mode(L, DebugStepMode::In);
    }
    if (strcmp(mode, "over") == 0) {
        return session_step_with_mode(L, DebugStepMode::Over);
    }
    if (strcmp(mode, "out") == 0) {
        return session_step_with_mode(L, DebugStepMode::Out);
    }

    luaL_error(L, "step mode must be 'in', 'over', or 'out'");
    return 0;
}

static int session_pause(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    int threadId = lua_isnumber(L, 2) ? (int)lua_tointeger(L, 2) : 0;
    {
        std::lock_guard lock(handle->session->mutex);
        if (handle->session->paused) {
            return 0;
        }
        handle->session->pauseTargetThreadId.store(threadId);
        handle->session->pauseRequest.store(DebugPauseRequest::Pause);
    }
    return 0;
}

static int session_terminate(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    dbg_request_terminate(handle->session);
    return 0;
}

static int session_close(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    bool terminateDebuggee = lua_isnoneornil(L, 2) || lua_toboolean(L, 2);
    if (terminateDebuggee) {
        dbg_request_terminate(handle->session);
        dbg_join(handle->session);
    } else {
        bool workerDone = false;
        {
            std::lock_guard lock(handle->session->mutex);
            workerDone = handle->session->workerDone;
        }
        if (!workerDone) {
            luaL_error(L, "cannot close a live debug session without terminating the debuggee");
        }
        dbg_join(handle->session);
    }
    handle->session.reset();
    return 0;
}

static int session_sources(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::vector<std::string> sources;
    {
        std::lock_guard lock(handle->session->mutex);
        dbg_add_unique_source_path(sources, handle->session->options.program);
        for (const DebugLoadedFunction& loaded : handle->session->loadedFunctions) {
            if (!dbg_is_file_backed_source_path(loaded.sourcePath)) {
                continue;
            }
            dbg_add_unique_source_path(sources, loaded.sourcePath);
        }
    }

    lua_createtable(L, (int)sources.size(), 0);
    int index = 1;
    for (const std::string& sourcePath : sources) {
        DebugSource source = dbg_make_source(sourcePath);
        dbg_push_source(L, source);
        lua_rawseti(L, -2, index++);
    }
    return 1;
}

static int session_set_breakpoints(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    luaL_checktype(L, 3, LUA_TTABLE);

    std::string sourcePath = dbg_read_source_argument(L, 2);
    if (sourcePath.empty()) {
        luaL_error(L, "setBreakpoints requires a source path or source id");
    }

    int n = (int)lua_objlen(L, 3);
    std::vector<DebugBreakpoint> updated;
    updated.reserve(n);

    {
        std::lock_guard lock(handle->session->mutex);
        std::vector<DebugBreakpoint> kept;
        kept.reserve(handle->session->breakpoints.size());
        for (DebugBreakpoint& breakpoint : handle->session->breakpoints) {
            if (breakpoint.internal || !dbg_source_matches(breakpoint.sourcePath, sourcePath)) {
                kept.push_back(std::move(breakpoint));
            }
        }
        handle->session->breakpoints = std::move(kept);

        for (int i = 1; i <= n; i++) {
            lua_rawgeti(L, 3, i);
            lua_getfield(L, -1, "line");
            int line = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
            lua_pop(L, 1);

            DebugBreakpoint breakpoint;
            breakpoint.id = handle->session->nextBreakpointId++;
            breakpoint.requestedLine = line;
            breakpoint.actualLine = line;
            breakpoint.verified = false;
            breakpoint.sourcePath = sourcePath;
            breakpoint.condition = dbg_read_string_field(L, -1, "condition");
            breakpoint.hitCondition = dbg_read_string_field(L, -1, "hitCondition");
            breakpoint.logMessage = dbg_read_string_field(L, -1, "logMessage");
            breakpoint.message = "Pending verification";
            lua_pop(L, 1);

            handle->session->breakpoints.push_back(breakpoint);
            updated.push_back(std::move(breakpoint));
        }

        handle->session->breakpointRevision++;
        lua_State* applyLua = handle->session->pausedLua;
        if (!applyLua && !handle->session->running && !handle->session->workerDone) {
            applyLua = handle->session->controlLua;
        }
        if (applyLua) {
            dbg_apply_all_breakpoints_locked(applyLua, *handle->session);
            updated.clear();
            for (const DebugBreakpoint& breakpoint : handle->session->breakpoints) {
                if (!breakpoint.internal && dbg_source_matches(breakpoint.sourcePath, sourcePath)) {
                    updated.push_back(breakpoint);
                }
            }
        }
    }

    lua_createtable(L, (int)updated.size(), 0);
    for (int i = 1; i <= (int)updated.size(); i++) {
        dbg_push_breakpoint(L, updated[(size_t)i - 1]);
        lua_rawseti(L, -2, i);
    }
    return 1;
}

static int session_frames(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    int threadId = lua_isnumber(L, 2) ? (int)lua_tointeger(L, 2) : 1;
    int startFrame = lua_isnumber(L, 3) ? (int)lua_tointeger(L, 3) : 0;
    int levels = lua_isnumber(L, 4) ? (int)lua_tointeger(L, 4) : 0;
    if (startFrame < 0) startFrame = 0;
    {
        std::lock_guard lock(handle->session->mutex);
        if (lua_isnoneornil(L, 2) && handle->session->framesThreadId != 0) {
            threadId = handle->session->framesThreadId;
        }
        if (threadId != handle->session->framesThreadId) {
            lua_createtable(L, 0, 2);
            lua_createtable(L, 0, 0);
            lua_setfield(L, -2, "frames");
            lua_pushinteger(L, 0);
            lua_setfield(L, -2, "total");
            return 1;
        }
    }
    if (threadId == 0) {
        lua_createtable(L, 0, 2);
        lua_createtable(L, 0, 0);
        lua_setfield(L, -2, "frames");
        lua_pushinteger(L, 0);
        lua_setfield(L, -2, "total");
        return 1;
    }

    std::vector<DebugFrame> frames;
    {
        std::lock_guard lock(handle->session->mutex);
        frames = handle->session->frames;
    }

    size_t start = std::min((size_t)startFrame, frames.size());
    size_t end = frames.size();
    if (levels > 0) {
        end = std::min(end, start + (size_t)levels);
    }

    lua_createtable(L, 0, 2);
    lua_createtable(L, (int)(end - start), 0);
    int out = 1;
    for (size_t i = start; i < end; i++) {
        dbg_push_frame(L, frames[i]);
        lua_rawseti(L, -2, out++);
    }
    lua_setfield(L, -2, "frames");
    lua_pushinteger(L, (int)frames.size());
    lua_setfield(L, -2, "total");
    return 1;
}

static std::string dbg_format_lua_scalar(lua_State* L, int index) {
    index = lua_absindex(L, index);
    int type = lua_type(L, index);

    switch (type) {
        case LUA_TNIL:
            return "nil";
        case LUA_TBOOLEAN:
            return lua_toboolean(L, index) ? "true" : "false";
        case LUA_TNUMBER: {
            const char* value = lua_tostring(L, index);
            return value ? value : "0";
        }
        case LUA_TSTRING: {
            size_t len = 0;
            const char* value = lua_tolstring(L, index, &len);
            return "\"" + std::string(value ? value : "", len) + "\"";
        }
        default: {
            const void* pointer = lua_topointer(L, index);
            char buffer[64];
            std::snprintf(buffer, sizeof(buffer), "%p", pointer);
            return std::string(lua_typename(L, type)) + ": " + buffer;
        }
    }
}

static std::string dbg_format_lua_key(lua_State* L, int index) {
    index = lua_absindex(L, index);
    int type = lua_type(L, index);

    if (type == LUA_TSTRING) {
        size_t len = 0;
        const char* value = lua_tolstring(L, index, &len);
        return std::string(value ? value : "", len);
    }
    if (type == LUA_TNUMBER) {
        char buffer[64];
        std::snprintf(buffer, sizeof(buffer), "%.17g", lua_tonumber(L, index));
        return buffer;
    }
    if (type == LUA_TBOOLEAN) {
        return lua_toboolean(L, index) ? "true" : "false";
    }
    return "[" + std::string(lua_typename(L, type)) + "]";
}

static bool dbg_lua_value_has_children(lua_State* L, int index) {
    return lua_type(L, index) == LUA_TTABLE;
}

static void dbg_push_table_key(lua_State* L, const std::string& name) {
    int parsed = 0;
    if (dbg_parse_positive_int(name, parsed)) {
        lua_pushinteger(L, parsed);
        return;
    }

    lua_pushlstring(L, name.data(), name.size());
}

static int dbg_register_count(lua_State* L, int frameLevel) {
    return eryx_debug_register_count(L, frameLevel);
}

static std::string dbg_register_local_name(lua_State* L, int frameLevel, int reg) {
    const char* name = eryx_debug_get_register_local_name(L, frameLevel, reg);
    return name ? name : "";
}

static void dbg_push_value_locked(lua_State* outL, lua_State* valueL, DebugSession& session,
                                  const std::string& name, int valueIndex, bool hex,
                                  const char* kind, const std::string* evaluateName) {
    valueIndex = lua_absindex(valueL, valueIndex);
    lua_createtable(outL, 0, 8);
    lua_pushlstring(outL, name.data(), name.size());
    lua_setfield(outL, -2, "name");

    std::string summary = dbg_format_lua_scalar(valueL, valueIndex);
    if (hex && lua_isnumber(valueL, valueIndex)) {
        char buffer[64];
        std::snprintf(buffer, sizeof(buffer), "0x%llx",
                      (unsigned long long)lua_tointeger(valueL, valueIndex));
        summary = buffer;
    }
    lua_pushlstring(outL, summary.data(), summary.size());
    lua_setfield(outL, -2, "summary");

    const char* typeName = lua_typename(valueL, lua_type(valueL, valueIndex));
    lua_pushstring(outL, typeName ? typeName : "unknown");
    lua_setfield(outL, -2, "type");

    int ref = 0;
    int namedCount = 0;
    int indexedCount = 0;
    if (dbg_lua_value_has_children(valueL, valueIndex)) {
        ref = dbg_create_value_ref_locked(valueL, session, valueIndex);
        dbg_count_value_children(valueL, valueIndex, namedCount, indexedCount);
    }
    lua_pushinteger(outL, ref);
    lua_setfield(outL, -2, "ref");
    if (kind && *kind) {
        lua_pushstring(outL, kind);
        lua_setfield(outL, -2, "kind");
    }
    if (namedCount > 0) {
        lua_pushinteger(outL, namedCount);
        lua_setfield(outL, -2, "namedCount");
    }
    if (indexedCount > 0) {
        lua_pushinteger(outL, indexedCount);
        lua_setfield(outL, -2, "indexedCount");
    }
    if (evaluateName && !evaluateName->empty()) {
        lua_pushlstring(outL, evaluateName->data(), evaluateName->size());
        lua_setfield(outL, -2, "evaluateName");
    }
}

static int session_scopes(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    int frameId = luaL_checkinteger(L, 2);
    int frameLevel = -1;
    int registerCount = 0;
    {
        std::lock_guard lock(handle->session->mutex);
        for (const DebugFrame& frame : handle->session->frames) {
            if (frame.id == frameId) {
                frameLevel = frame.level;
                break;
            }
        }

        if (frameLevel < 0 || !handle->session->pausedLua) {
            lua_createtable(L, 0, 0);
            return 1;
        }

        DebugPausedLuaGuard pausedGuard(handle->session->pausedLua);
        registerCount = dbg_register_count(handle->session->pausedLua, frameLevel);
    }

    lua_createtable(L, registerCount > 0 ? 2 : 1, 0);
    lua_createtable(L, 0, 5);
    lua_pushliteral(L, "Locals");
    lua_setfield(L, -2, "name");

    int variablesReference = 0;
    {
        std::lock_guard lock(handle->session->mutex);
        DebugVariableRef ref;
        ref.kind = DebugVariableRefKind::Locals;
        ref.threadId = handle->session->framesThreadId;
        ref.frameId = frameId;
        ref.frameLevel = frameLevel;
        variablesReference = dbg_create_variable_ref_locked(*handle->session, std::move(ref));
    }

    lua_pushinteger(L, variablesReference);
    lua_setfield(L, -2, "ref");
    lua_pushliteral(L, "locals");
    lua_setfield(L, -2, "kind");
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "expensive");
    lua_rawseti(L, -2, 1);

    if (registerCount > 0) {
        lua_createtable(L, 0, 5);
        lua_pushliteral(L, "Registers");
        lua_setfield(L, -2, "name");

        int registerReference = 0;
        {
            std::lock_guard lock(handle->session->mutex);
            DebugVariableRef ref;
            ref.kind = DebugVariableRefKind::Registers;
            ref.threadId = handle->session->framesThreadId;
            ref.frameId = frameId;
            ref.frameLevel = frameLevel;
            registerReference = dbg_create_variable_ref_locked(*handle->session, std::move(ref));
        }

        lua_pushinteger(L, registerReference);
        lua_setfield(L, -2, "ref");
        lua_pushliteral(L, "registers");
        lua_setfield(L, -2, "kind");
        lua_pushinteger(L, registerCount);
        lua_setfield(L, -2, "indexedCount");
        lua_pushboolean(L, false);
        lua_setfield(L, -2, "expensive");
        lua_rawseti(L, -2, 2);
    }

    return 1;
}

static int session_inspect(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_getfield(L, 2, "ref");
    int variablesReference = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
    lua_pop(L, 1);
    lua_getfield(L, 2, "start");
    int start = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
    lua_pop(L, 1);
    lua_getfield(L, 2, "count");
    int limit = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
    lua_pop(L, 1);
    lua_getfield(L, 2, "filter");
    std::string filter = lua_isstring(L, -1) ? lua_tostring(L, -1) : "all";
    lua_pop(L, 1);
    lua_getfield(L, 2, "hex");
    bool hex = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    if (start < 0) start = 0;

    std::lock_guard lock(handle->session->mutex);
    lua_State* pausedLua = handle->session->pausedLua;
    auto refIt = handle->session->variableRefs.find(variablesReference);
    if (!pausedLua || refIt == handle->session->variableRefs.end()) {
        lua_createtable(L, 0, 0);
        return 1;
    }
    DebugPausedLuaGuard pausedGuard(pausedLua);

    DebugVariableRef ref = refIt->second;
    auto includeKind = [&](bool indexed) {
        if (filter == "indexed") return indexed;
        if (filter == "named") return !indexed;
        return true;
    };

    if (ref.kind == DebugVariableRefKind::Locals) {
        lua_createtable(L, 0, 0);
        int outputIndex = 1;
        int seen = 0;
        for (int localIndex = 1; localIndex < 256; localIndex++) {
            const char* name = lua_getlocal(pausedLua, ref.frameLevel, localIndex);
            if (!name) break;
            if (!includeKind(false)) {
                lua_pop(pausedLua, 1);
                continue;
            }
            if (seen++ < start) {
                lua_pop(pausedLua, 1);
                continue;
            }
            std::string evaluateName(name);
            dbg_push_value_locked(L, pausedLua, *handle->session, name, -1, hex, nullptr,
                                  &evaluateName);
            lua_rawseti(L, -2, outputIndex++);
            lua_pop(pausedLua, 1);
            if (limit > 0 && outputIndex > limit) break;
        }
        return 1;
    }

    if (ref.kind == DebugVariableRefKind::Registers) {
        int registerCount = dbg_register_count(pausedLua, ref.frameLevel);
        if (registerCount <= 0) {
            lua_createtable(L, 0, 0);
            return 1;
        }

        lua_createtable(L, registerCount, 0);
        int outputIndex = 1;
        int seen = 0;
        for (int reg = 0; reg < registerCount; reg++) {
            if (!eryx_debug_get_register(pausedLua, ref.frameLevel, reg)) {
                continue;
            }
            if (!includeKind(true)) {
                lua_pop(pausedLua, 1);
                continue;
            }
            std::string localName = dbg_register_local_name(pausedLua, ref.frameLevel, reg);
            std::string name = "R" + std::to_string(reg);
            if (!localName.empty()) {
                name += " (" + localName + ")";
            }

            if (seen++ < start) {
                lua_pop(pausedLua, 1);
                continue;
            }
            dbg_push_value_locked(L, pausedLua, *handle->session, name, -1, hex, nullptr, nullptr);
            lua_rawseti(L, -2, outputIndex++);
            lua_pop(pausedLua, 1);
            if (limit > 0 && outputIndex > limit) break;
        }
        return 1;
    }

    if (ref.valueRef == LUA_NOREF) {
        lua_createtable(L, 0, 0);
        return 1;
    }

    lua_getref(pausedLua, ref.valueRef);
    if (!lua_istable(pausedLua, -1)) {
        lua_pop(pausedLua, 1);
        lua_createtable(L, 0, 0);
        return 1;
    }

    lua_createtable(L, 0, 0);
    int outputIndex = 1;
    int seen = 0;
    lua_pushnil(pausedLua);
    while (lua_next(pausedLua, -2)) {
        bool indexed = dbg_is_array_index(pausedLua, -2);
        if (!includeKind(indexed)) {
            lua_pop(pausedLua, 1);
            continue;
        }
        std::string name = dbg_format_lua_key(pausedLua, -2);
        if (seen++ < start) {
            lua_pop(pausedLua, 1);
            continue;
        }
        dbg_push_value_locked(L, pausedLua, *handle->session, name, -1, hex, nullptr, nullptr);
        lua_rawseti(L, -2, outputIndex++);
        lua_pop(pausedLua, 1);
        if (limit > 0 && outputIndex > limit) {
            lua_pop(pausedLua, 2);
            return 1;
        }
    }
    lua_pop(pausedLua, 1);
    return 1;
}

static int session_evaluate(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    size_t expressionLength = 0;
    const char* expressionData = luaL_checklstring(L, 2, &expressionLength);
    std::string expression(expressionData, expressionLength);
    int frameId = 0;
    std::string context;
    bool hex = false;
    bool allowStatements = false;
    if (lua_istable(L, 3)) {
        frameId = dbg_read_int_field(L, 3, "frame", 0);
        context = dbg_read_string_field(L, 3, "context");
        hex = dbg_read_bool_field(L, 3, "hex", false);
        allowStatements = dbg_read_bool_field(L, 3, "allowStatements", false);
    }
    if (!allowStatements && context == "repl") {
        allowStatements = true;
    }

    int frameLevel = 0;
    lua_State* pausedLua = nullptr;
    {
        std::lock_guard lock(handle->session->mutex);
        pausedLua = handle->session->pausedLua;
        if (!pausedLua) {
            dbg_push_evaluate_error(L, "debuggee is not paused");
            return 1;
        }

        if (frameId != 0) {
            bool found = false;
            for (const DebugFrame& frame : handle->session->frames) {
                if (frame.id == frameId) {
                    frameLevel = frame.level;
                    found = true;
                    break;
                }
            }

            if (!found) {
                dbg_push_evaluate_error(L, "unknown stack frame");
                return 1;
            }
        }
    }

    DebugPausedLuaGuard pausedGuard(pausedLua);
    int top = lua_gettop(pausedLua);
    int resultCount = 0;
    std::string error;
    if (!dbg_execute_in_frame(pausedLua, frameLevel, expression, allowStatements, error,
                              resultCount)) {
        lua_settop(pausedLua, top);
        dbg_push_evaluate_error(L, error);
        return 1;
    }

    if (resultCount == 0) {
        lua_pushnil(pausedLua);
        resultCount = 1;
    }

    {
        std::lock_guard lock(handle->session->mutex);
        if (handle->session->pausedLua != pausedLua) {
            lua_settop(pausedLua, top);
            dbg_push_evaluate_error(L, "debuggee is no longer paused");
            return 1;
        }

        dbg_push_evaluate_success(L, pausedLua, *handle->session, -resultCount, hex);
    }

    lua_settop(pausedLua, top);
    return 1;
}

static int session_set_variable(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    int variablesReference = luaL_checkinteger(L, 2);
    size_t nameLength = 0;
    const char* nameData = luaL_checklstring(L, 3, &nameLength);
    std::string name(nameData ? nameData : "", nameLength);
    size_t expressionLength = 0;
    const char* expressionData = luaL_checklstring(L, 4, &expressionLength);
    std::string expression(expressionData ? expressionData : "", expressionLength);
    bool hex = false;
    if (lua_istable(L, 5)) {
        hex = dbg_read_bool_field(L, 5, "hex", false);
    }

    lua_State* pausedLua = nullptr;
    DebugVariableRef ref;
    {
        std::lock_guard lock(handle->session->mutex);
        pausedLua = handle->session->pausedLua;
        auto refIt = handle->session->variableRefs.find(variablesReference);
        if (!pausedLua || refIt == handle->session->variableRefs.end()) {
            dbg_push_evaluate_error(L, "unknown variable reference");
            return 1;
        }

        ref = refIt->second;
        if (ref.threadId != 0 && handle->session->pausedThreadId != 0 &&
            ref.threadId != handle->session->pausedThreadId) {
            dbg_push_evaluate_error(L, "thread is not paused");
            return 1;
        }
    }

    DebugPausedLuaGuard pausedGuard(pausedLua);
    int top = lua_gettop(pausedLua);
    int resultCount = 0;
    std::string error;
    int frameLevel = ref.frameLevel;
    if (!dbg_execute_in_frame(pausedLua, frameLevel, expression, true, error, resultCount)) {
        lua_settop(pausedLua, top);
        dbg_push_evaluate_error(L, error);
        return 1;
    }

    if (resultCount == 0) {
        lua_pushnil(pausedLua);
        resultCount = 1;
    } else if (resultCount > 1) {
        lua_replace(pausedLua, -resultCount);
        lua_pop(pausedLua, resultCount - 1);
        resultCount = 1;
    }

    {
        std::lock_guard lock(handle->session->mutex);
        if (handle->session->pausedLua != pausedLua) {
            lua_settop(pausedLua, top);
            dbg_push_evaluate_error(L, "debuggee is no longer paused");
            return 1;
        }
    }

    if (ref.kind == DebugVariableRefKind::Locals) {
        bool assigned = false;
        for (int localIndex = 1; localIndex < 256; localIndex++) {
            const char* localName = lua_getlocal(pausedLua, ref.frameLevel, localIndex);
            if (!localName) break;
            lua_pop(pausedLua, 1);
            if (name != localName) {
                continue;
            }

            lua_pushvalue(pausedLua, -1);
            const char* assignedName = lua_setlocal(pausedLua, ref.frameLevel, localIndex);
            assigned = assignedName != nullptr;
            break;
        }

        if (!assigned) {
            lua_settop(pausedLua, top);
            dbg_push_evaluate_error(L, "unknown local variable");
            return 1;
        }

        {
            std::lock_guard lock(handle->session->mutex);
            dbg_push_evaluate_success(L, pausedLua, *handle->session, -1, hex);
        }
        lua_settop(pausedLua, top);
        return 1;
    }

    if (ref.kind == DebugVariableRefKind::Value) {
        if (ref.valueRef == LUA_NOREF) {
            lua_settop(pausedLua, top);
            dbg_push_evaluate_error(L, "unknown variable reference");
            return 1;
        }

        lua_getref(pausedLua, ref.valueRef);
        if (!lua_istable(pausedLua, -1)) {
            lua_settop(pausedLua, top);
            dbg_push_evaluate_error(L, "variable reference is not assignable");
            return 1;
        }

        int tableIndex = lua_absindex(pausedLua, -1);
        lua_pushvalue(pausedLua, -2);
        dbg_push_table_key(pausedLua, name);
        lua_pushvalue(pausedLua, -2);
        lua_rawset(pausedLua, tableIndex);

        {
            std::lock_guard lock(handle->session->mutex);
            dbg_push_evaluate_success(L, pausedLua, *handle->session, -1, hex);
        }
        lua_settop(pausedLua, top);
        return 1;
    }

    lua_settop(pausedLua, top);
    dbg_push_evaluate_error(L, "variable reference is not assignable");
    return 1;
}

static int session_read_source(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::string sourcePath = dbg_read_source_argument(L, 2);
    if (sourcePath.empty()) {
        sourcePath = handle->session->options.program;
    }

    std::string source;
    if (!dbg_read_source_file(sourcePath, source)) {
        lua_pushliteral(L, "");
        return 1;
    }
    lua_pushlstring(L, source.data(), source.size());
    return 1;
}

static int session_disassemble(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::string sourcePath;
    int frameId = 0;
    bool showLocals = false;
    bool showRemarks = false;
    bool showTypes = false;

    if (lua_istable(L, 2)) {
        sourcePath = dbg_read_source_argument(L, 2);
        if (sourcePath.empty()) {
            lua_getfield(L, 2, "source");
            sourcePath = dbg_read_source_argument(L, -1);
            lua_pop(L, 1);
        }
        frameId = dbg_read_int_field(L, 2, "frame", 0);
        showLocals = dbg_read_bool_field(L, 2, "showLocals", false);
        showRemarks = dbg_read_bool_field(L, 2, "showRemarks", false);
        showTypes = dbg_read_bool_field(L, 2, "showTypes", false);
    } else {
        sourcePath = dbg_read_source_argument(L, 2);
    }

    if (sourcePath.empty() && frameId != 0) {
        std::lock_guard lock(handle->session->mutex);
        for (const DebugFrame& frame : handle->session->frames) {
            if (frame.id == frameId) {
                sourcePath = frame.source.path;
                break;
            }
        }
    }

    if (sourcePath.empty()) {
        sourcePath = handle->session->options.program;
    }

    std::string sourceText;
    if (!dbg_read_source_file(sourcePath, sourceText)) {
        luaL_error(L, "failed to read source for disassembly");
    }

    uint32_t dumpFlags = Luau::BytecodeBuilder::Dump_Code | Luau::BytecodeBuilder::Dump_Source |
                         Luau::BytecodeBuilder::Dump_Lines;
    if (showLocals) dumpFlags |= Luau::BytecodeBuilder::Dump_Locals;
    if (showRemarks) dumpFlags |= Luau::BytecodeBuilder::Dump_Remarks;
    if (showTypes) dumpFlags |= Luau::BytecodeBuilder::Dump_Types;

    Luau::CompileOptions compileOpts;
    compileOpts.optimizationLevel = handle->session->options.optimisationLevel;
    compileOpts.debugLevel = 2;
    compileOpts.typeInfoLevel = 1;

    Luau::BytecodeBuilder bcb;
    bcb.setDumpFlags(dumpFlags);
    bcb.setDumpSource(sourceText);

    try {
        Luau::compileOrThrow(bcb, sourceText, compileOpts);
    } catch (const Luau::CompileError& e) {
        luaL_error(L, "compile error: %s", e.what());
    }

    std::string listing = bcb.dumpEverything();
    lua_pushlstring(L, listing.data(), listing.size());
    return 1;
}

static int session_exception(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);

    std::lock_guard lock(handle->session->mutex);
    if (!handle->session->hasExceptionInfo) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 7);
    lua_pushlstring(L, handle->session->exceptionId.data(), handle->session->exceptionId.size());
    lua_setfield(L, -2, "id");
    lua_pushlstring(L, handle->session->exceptionMessage.data(),
                    handle->session->exceptionMessage.size());
    lua_setfield(L, -2, "message");
    lua_pushlstring(L, handle->session->exceptionTypeName.data(),
                    handle->session->exceptionTypeName.size());
    lua_setfield(L, -2, "typeName");
    lua_pushlstring(L, handle->session->exceptionDescription.data(),
                    handle->session->exceptionDescription.size());
    lua_setfield(L, -2, "description");
    lua_pushlstring(L, handle->session->exceptionStackTrace.data(),
                    handle->session->exceptionStackTrace.size());
    lua_setfield(L, -2, "stackTrace");
    if (!handle->session->exceptionSource.path.empty()) {
        dbg_push_source(L, handle->session->exceptionSource);
        lua_setfield(L, -2, "source");
    }
    if (handle->session->exceptionLine > 0) {
        lua_pushinteger(L, handle->session->exceptionLine);
        lua_setfield(L, -2, "line");
    }
    if (handle->session->exceptionColumn > 0) {
        lua_pushinteger(L, handle->session->exceptionColumn);
        lua_setfield(L, -2, "column");
    }

    return 1;
}

static int session_clear_breakpoints(lua_State* L) {
    auto* handle = dbg_check_session(L, 1);
    std::string sourcePath = lua_isnoneornil(L, 2) ? "" : dbg_read_source_argument(L, 2);

    lua_State* applyLua = nullptr;
    {
        std::lock_guard lock(handle->session->mutex);
        if (sourcePath.empty()) {
            std::vector<DebugBreakpoint> kept;
            kept.reserve(handle->session->breakpoints.size());
            for (DebugBreakpoint& breakpoint : handle->session->breakpoints) {
                if (breakpoint.internal) {
                    kept.push_back(std::move(breakpoint));
                }
            }
            handle->session->breakpoints = std::move(kept);
        } else {
            std::vector<DebugBreakpoint> kept;
            kept.reserve(handle->session->breakpoints.size());
            for (DebugBreakpoint& breakpoint : handle->session->breakpoints) {
                if (breakpoint.internal || !dbg_source_matches(breakpoint.sourcePath, sourcePath)) {
                    kept.push_back(std::move(breakpoint));
                }
            }
            handle->session->breakpoints = std::move(kept);
        }

        handle->session->breakpointRevision++;
        applyLua = handle->session->pausedLua;
        if (!applyLua && !handle->session->running && !handle->session->workerDone) {
            applyLua = handle->session->controlLua;
        }
    }

    if (applyLua) {
        std::lock_guard lock(handle->session->mutex);
        dbg_apply_all_breakpoints_locked(applyLua, *handle->session);
    }
    return 0;
}

static int session_gc(lua_State* L) {
    auto* handle = (DebugSessionHandle*)luaL_checkudata(L, 1, DBG_SESSION_MT);
    if (handle && handle->session) {
        dbg_request_terminate(handle->session);
        dbg_join(handle->session);
        handle->session.reset();
    }
    handle->~DebugSessionHandle();
    return 0;
}

static void register_session_metatable(lua_State* L) {
    if (luaL_newmetatable(L, DBG_SESSION_MT)) {
        lua_pushcfunction(L, session_gc, "__gc");
        lua_setfield(L, -2, "__gc");
        lua_pushstring(L, DBG_SESSION_MT);
        lua_setfield(L, -2, "__type");

        lua_newtable(L);
        lua_pushcfunction(L, session_start, "start");
        lua_setfield(L, -2, "start");
        lua_pushcfunction(L, session_wait, "wait");
        lua_setfield(L, -2, "wait");
        lua_pushcfunction(L, session_state, "state");
        lua_setfield(L, -2, "state");
        lua_pushcfunction(L, session_threads, "threads");
        lua_setfield(L, -2, "threads");
        lua_pushcfunction(L, session_resume, "resume");
        lua_setfield(L, -2, "resume");
        lua_pushcfunction(L, session_pause, "pause");
        lua_setfield(L, -2, "pause");
        lua_pushcfunction(L, session_step, "step");
        lua_setfield(L, -2, "step");
        lua_pushcfunction(L, session_terminate, "terminate");
        lua_setfield(L, -2, "terminate");
        lua_pushcfunction(L, session_close, "close");
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, session_sources, "sources");
        lua_setfield(L, -2, "sources");
        lua_pushcfunction(L, session_set_breakpoints, "setBreakpoints");
        lua_setfield(L, -2, "setBreakpoints");
        lua_pushcfunction(L, session_clear_breakpoints, "clearBreakpoints");
        lua_setfield(L, -2, "clearBreakpoints");
        lua_pushcfunction(L, session_frames, "frames");
        lua_setfield(L, -2, "frames");
        lua_pushcfunction(L, session_scopes, "scopes");
        lua_setfield(L, -2, "scopes");
        lua_pushcfunction(L, session_inspect, "inspect");
        lua_setfield(L, -2, "inspect");
        lua_pushcfunction(L, session_evaluate, "evaluate");
        lua_setfield(L, -2, "evaluate");
        lua_pushcfunction(L, session_set_variable, "setVariable");
        lua_setfield(L, -2, "setVariable");
        lua_pushcfunction(L, session_read_source, "readSource");
        lua_setfield(L, -2, "readSource");
        lua_pushcfunction(L, session_disassemble, "disassemble");
        lua_setfield(L, -2, "disassemble");
        lua_pushcfunction(L, session_exception, "exception");
        lua_setfield(L, -2, "exception");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

LUAU_MODULE_EXPORT int luauopen_debugger(lua_State* L) {
    register_session_metatable(L);

    lua_newtable(L);
    lua_pushcfunction(L, debugger_open, "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, debugger_breakpoint, "breakpoint");
    lua_setfield(L, -2, "breakpoint");

    lua_setreadonly(L, -1, true);
    return 1;
}
