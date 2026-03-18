#include <chrono>
#include <format>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_date",
};
LUAU_MODULE_INFO()

namespace tzdate {
using SysTime = std::chrono::sys_time<std::chrono::nanoseconds>;
using LocalNs = std::chrono::local_time<std::chrono::nanoseconds>;
using Duration = std::chrono::nanoseconds;

struct ZonedInstant {
    SysTime utc;       // The actual UTC time
    std::string zone;  // IANA zone name; empty when fixed_offset is set
    std::optional<std::chrono::minutes> fixed_offset;  // UTC offset when parsed from ISO string
};

inline const std::chrono::time_zone* resolve_zone(lua_State* L, const std::string& name) {
    try {
        return std::chrono::locate_zone(name);
    } catch (...) {
        luaL_error(L, "Unable to locate time zone: %s", name.c_str());
    }
}
std::string current_timezone() { return std::string(std::chrono::current_zone()->name()); }

// Returns the display name of the zone (IANA name or +HH:MM offset string)
std::string zone_display(const ZonedInstant& z) {
    if (z.fixed_offset) {
        int total = int(z.fixed_offset->count());
        char sign = total >= 0 ? '+' : '-';
        int abs_off = total >= 0 ? total : -total;
        return std::format("{}{:02}:{:02}", sign, abs_off / 60, abs_off % 60);
    }
    return z.zone;
}

// Returns local time as a local_time<nanoseconds>, handling both named zones and fixed offsets
LocalNs to_local_time(lua_State* L, const ZonedInstant& z) {
    if (z.fixed_offset) {
        return LocalNs{ z.utc.time_since_epoch() + *z.fixed_offset };
    }
    return std::chrono::zoned_time{ resolve_zone(L, z.zone), z.utc }.get_local_time();
}

ZonedInstant date_now(const std::string& zone) {
    ZonedInstant z;
    z.utc = std::chrono::system_clock::now();
    z.zone = zone;
    return z;
}
ZonedInstant date_now() { return date_now(current_timezone()); }

// Change display timezone; clears any fixed offset
ZonedInstant set_timezone(const ZonedInstant& z, const std::string& new_zone) {
    ZonedInstant out = z;
    out.zone = new_zone;
    out.fixed_offset = std::nullopt;
    return out;
}

ZonedInstant from_unix(int64_t unix_seconds, const std::string& zone) {
    ZonedInstant z;
    z.utc = SysTime{ std::chrono::seconds{ unix_seconds } };
    z.zone = zone;
    return z;
}

// Duration helpers
Duration nanoseconds(int64_t v) { return std::chrono::nanoseconds(v); }
Duration milliseconds(int64_t v) { return std::chrono::milliseconds(v); }
Duration seconds(int64_t v) { return std::chrono::seconds(v); }
Duration minutes(int64_t v) { return std::chrono::minutes(v); }
Duration hours(int64_t v) { return std::chrono::hours(v); }
Duration days(int64_t v) { return std::chrono::hours(24 * v); }

ZonedInstant add(ZonedInstant z, Duration d) {
    z.utc += d;
    return z;
}
ZonedInstant sub(ZonedInstant z, Duration d) {
    z.utc -= d;
    return z;
}
Duration diff(const ZonedInstant& a, const ZonedInstant& b) { return a.utc - b.utc; }

struct DateFields {
    int year;   // Gregorian year
    int month;  // 1-12
    int day;    // 1-31

    int hour;        // 0-23
    int minute;      // 0-59
    int second;      // 0-59
    int nanosecond;  // 0-999'999'999

    int offset_seconds;  // UTC offset in seconds
};

const char* MONTHS[] = {
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
const char* MONTHS_SHORT[] = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const char* DAYS[] = {
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
};
const char* DAYS_SHORT[] = {
    "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
};

int64_t to_unix_seconds(const ZonedInstant& z) {
    return std::chrono::duration_cast<std::chrono::seconds>(z.utc.time_since_epoch()).count();
}
int64_t to_unix_ms(const ZonedInstant& z) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(z.utc.time_since_epoch()).count();
}

DateFields get_fields(lua_State* L, const ZonedInstant& z) {
    using namespace std::chrono;

    auto local = to_local_time(L, z);
    auto dp = std::chrono::floor<std::chrono::days>(local);
    year_month_day ymd{ dp };
    hh_mm_ss<std::chrono::nanoseconds> hms{ std::chrono::duration_cast<std::chrono::nanoseconds>(
        local - dp) };

    DateFields f;
    f.year = int(ymd.year());
    f.month = unsigned(ymd.month());
    f.day = unsigned(ymd.day());
    f.hour = int(hms.hours().count());
    f.minute = int(hms.minutes().count());
    f.second = int(hms.seconds().count());
    f.nanosecond = int(hms.subseconds().count());

    if (z.fixed_offset) {
        f.offset_seconds =
            int(std::chrono::duration_cast<std::chrono::seconds>(*z.fixed_offset).count());
    } else {
        f.offset_seconds = int(resolve_zone(L, z.zone)->get_info(z.utc).offset.count());
    }

    return f;
}

ZonedInstant from_fields(lua_State* L, const DateFields& f, const std::string& zone) {
    using namespace std::chrono;

    auto tz = resolve_zone(L, zone);

    local_time<std::chrono::nanoseconds> lt =
        local_days{ year{ f.year } / f.month / f.day } + std::chrono::hours{ f.hour } +
        std::chrono::minutes{ f.minute } + std::chrono::seconds{ f.second } +
        std::chrono::nanoseconds{ f.nanosecond };

    std::chrono::zoned_time zt{ tz, lt, choose::latest };

    ZonedInstant out;
    out.utc = zt.get_sys_time();
    out.zone = zone;
    return out;
}

std::string format_iso(lua_State* L, const ZonedInstant& z) {
    using namespace std::chrono;

    if (z.fixed_offset) {
        auto local = to_local_time(L, z);
        auto dp = std::chrono::floor<std::chrono::days>(local);
        year_month_day ymd{ dp };
        hh_mm_ss<std::chrono::nanoseconds> hms{
            std::chrono::duration_cast<std::chrono::nanoseconds>(local - dp)
        };

        int total = int(z.fixed_offset->count());
        char sign = total >= 0 ? '+' : '-';
        int abs_off = total >= 0 ? total : -total;
        int off_h = abs_off / 60, off_m = abs_off % 60;

        auto ns = hms.subseconds().count();
        if (ns != 0) {
            return std::format("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:09}{}{:02}:{:02}",
                               int(ymd.year()), unsigned(ymd.month()), unsigned(ymd.day()),
                               int(hms.hours().count()), int(hms.minutes().count()),
                               int(hms.seconds().count()), ns, sign, off_h, off_m);
        }
        return std::format("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{}{:02}:{:02}", int(ymd.year()),
                           unsigned(ymd.month()), unsigned(ymd.day()), int(hms.hours().count()),
                           int(hms.minutes().count()), int(hms.seconds().count()), sign, off_h,
                           off_m);
    }

    auto tz = resolve_zone(L, z.zone);
    return std::format("{:%FT%T%Ez}", zoned_time{ tz, z.utc });
}

// Parses an ISO 8601 timestamp; timezone is derived from the offset in the string.
// The result has a fixed_offset set; use set_timezone() to convert to a named zone.
ZonedInstant parse_iso(const std::string& s) {
    using namespace std::chrono;

    std::istringstream in(s);

    sys_time<std::chrono::nanoseconds> tp;
    std::chrono::minutes offset;

    in >> parse(std::string("%FT%T%Ez"), tp, offset);
    // parse() into sys_time already converts to UTC; do NOT subtract offset again.

    if (in.fail()) throw std::runtime_error("Invalid ISO timestamp");

    ZonedInstant z;
    z.utc = tp;
    z.fixed_offset = offset;
    return z;
}

// Returns weekday as 1 (Monday) ... 7 (Sunday), ISO 8601 convention
int weekday(lua_State* L, const ZonedInstant& z) {
    using namespace std::chrono;
    auto local = to_local_time(L, z);
    std::chrono::weekday wd{ std::chrono::floor<std::chrono::days>(local) };
    unsigned c = wd.c_encoding();  // 0=Sun, 1=Mon, ..., 6=Sat
    return c == 0 ? 7 : int(c);    // convert to ISO: 1=Mon ... 7=Sun
}

// Returns day of year: 1 = Jan 1
int day_of_year(lua_State* L, const ZonedInstant& z) {
    using namespace std::chrono;
    auto local = to_local_time(L, z);
    auto dp = std::chrono::floor<std::chrono::days>(local);
    year_month_day ymd{ dp };
    auto jan1 = local_days{ ymd.year() / January / 1 };
    return int((dp - jan1).count()) + 1;
}

bool is_leap(int year) { return std::chrono::year{ year }.is_leap(); }

int days_in_month(int year, unsigned int month) {
    using namespace std::chrono;
    year_month_day_last ymdl{ std::chrono::year{ year } / std::chrono::month{ month } / last };
    return unsigned(ymdl.day());
}

std::vector<std::string> timezone_names() {
    std::vector<std::string> out;
    for (auto& tz : std::chrono::get_tzdb().zones) out.push_back(std::string(tz.name()));
    return out;
}

// True if the instant falls within a DST period. Always false for fixed-offset instants.
bool is_dst(lua_State* L, const ZonedInstant& z) {
    if (z.fixed_offset) return false;
    return resolve_zone(L, z.zone)->get_info(z.utc).save != std::chrono::minutes{ 0 };
}

// Build a ZonedInstant from fields with a fixed offset (no IANA zone lookup needed).
ZonedInstant from_fields_fixed(const DateFields& f, std::chrono::minutes offset) {
    using namespace std::chrono;
    local_time<std::chrono::nanoseconds> lt =
        local_days{ year{ f.year } / f.month / f.day } + std::chrono::hours{ f.hour } +
        std::chrono::minutes{ f.minute } + std::chrono::seconds{ f.second } +
        std::chrono::nanoseconds{ f.nanosecond };
    ZonedInstant out;
    out.utc = SysTime{ std::chrono::duration_cast<std::chrono::nanoseconds>(lt.time_since_epoch() -
                                                                            offset) };
    out.fixed_offset = offset;
    return out;
}

// Returns a new instant at midnight of the same local calendar day.
ZonedInstant start_of_day(lua_State* L, const ZonedInstant& z) {
    auto f = get_fields(L, z);
    f.hour = f.minute = f.second = f.nanosecond = 0;
    if (!z.fixed_offset) return from_fields(L, f, z.zone);
    return from_fields_fixed(f, *z.fixed_offset);
}

// Add a number of calendar months (clamping the day when needed, e.g. Jan 31 + 1 = Feb 28).
ZonedInstant add_months(lua_State* L, const ZonedInstant& z, int months) {
    auto f = get_fields(L, z);
    int total = (f.month - 1) + months;
    // floor division so negative months work correctly
    int yr_delta = total >= 0 ? total / 12 : (total - 11) / 12;
    f.year += yr_delta;
    f.month = total - yr_delta * 12 + 1;
    int max_day = days_in_month(f.year, f.month);
    if (f.day > max_day) f.day = max_day;
    if (!z.fixed_offset) return from_fields(L, f, z.zone);
    return from_fields_fixed(f, *z.fixed_offset);
}

ZonedInstant add_years(lua_State* L, const ZonedInstant& z, int years) {
    return add_months(L, z, years * 12);
}

// Format the local time using a std::chrono-compatible format string (%Y, %m, %d, %H, %M, %S …).
// For fixed-offset instants, %z/%Ez/%Z are substituted with the literal offset string.
std::string format_custom(lua_State* L, const ZonedInstant& z, const std::string& fmt) {
    if (!z.fixed_offset) {
        auto zt = std::chrono::zoned_time{ resolve_zone(L, z.zone), z.utc };
        return std::vformat(
            "{:" + fmt + "}",
            std::make_format_args(zt));
    }
    // Preprocess timezone tokens into literal offset strings so local_time can handle the rest.
    int total = int(z.fixed_offset->count());
    char sign = total >= 0 ? '+' : '-';
    int abs_off = total >= 0 ? total : -total;
    std::string ez_str = std::format("{}{:02}:{:02}", sign, abs_off / 60, abs_off % 60);
    std::string z_str = std::format("{}{:02}{:02}", sign, abs_off / 60, abs_off % 60);

    std::string processed;
    processed.reserve(fmt.size() + 16);
    for (size_t i = 0; i < fmt.size(); ++i) {
        if (fmt[i] == '%') {
            if (i + 2 < fmt.size() && fmt[i + 1] == 'E' && fmt[i + 2] == 'z') {
                processed += ez_str;
                i += 2;
            } else if (i + 1 < fmt.size() && fmt[i + 1] == 'z') {
                processed += z_str;
                ++i;
            } else if (i + 1 < fmt.size() && fmt[i + 1] == 'Z') {
                processed += ez_str;
                ++i;
            } else {
                processed += fmt[i];
            }
        } else {
            processed += fmt[i];
        }
    }
    auto lt = to_local_time(L, z);
    return std::vformat("{:" + processed + "}", std::make_format_args(lt));
}

// Format the underlying UTC time using a std::chrono-compatible format string.
std::string format_utc(const ZonedInstant& z, const std::string& fmt) {
    return std::vformat("{:" + fmt + "}", std::make_format_args(z.utc));
}

// Parse a datetime string with a user-supplied format string.
// If zone is non-empty it is used as the display zone; otherwise the parsed offset (if any)
// is stored as fixed_offset, or the local timezone is assumed.
ZonedInstant parse_custom(lua_State* L, const std::string& s, const std::string& fmt,
                          const std::string& zone) {
    using namespace std::chrono;
    std::istringstream in(s);
    sys_time<std::chrono::nanoseconds> tp;
    std::chrono::minutes offset{ 0 };
    in >> parse(fmt, tp, offset);
    if (in.fail()) throw std::runtime_error("Failed to parse datetime string");
    // parse() into sys_time already converts to UTC; do NOT subtract offset again.

    ZonedInstant z;
    z.utc = tp;
    if (!zone.empty()) {
        resolve_zone(L, zone);  // validate
        z.zone = zone;
    } else if (offset.count() != 0) {
        z.fixed_offset = offset;
    } else {
        z.zone = current_timezone();
    }
    return z;
}
}  // namespace tzdate

static const char* DATETIME_METATABLE = "DateTime";
static const char* DURATION_METATABLE = "Duration";

typedef struct {
    tzdate::ZonedInstant instant;
} LuaDateTime;
typedef struct {
    tzdate::Duration duration;
} LuaDuration;

// ── DateTime constructors ─────────────────────────────────────────────────────

static int date_now(lua_State* L) {
    const char* stz = luaL_optstring(L, 1, nullptr);
    LuaDateTime* dt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (dt) LuaDateTime();

    if (stz) {
        tzdate::resolve_zone(L, stz);  // validates; throws on bad name
        dt->instant = tzdate::date_now(stz);
    } else {
        dt->instant = tzdate::date_now();
    }

    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int date_fromiso(lua_State* L) {
    const char* siso = luaL_checkstring(L, 1);

    LuaDateTime* dt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (dt) LuaDateTime();

    try {
        dt->instant = tzdate::parse_iso(siso);
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
    }

    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int date_fromtimestamp(lua_State* L) {
    double ts = luaL_checknumber(L, 1);
    const char* stz = luaL_optstring(L, 2, nullptr);

    LuaDateTime* dt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (dt) LuaDateTime();

    dt->instant.utc = tzdate::SysTime{ std::chrono::nanoseconds{ int64_t(ts * 1e9) } };
    dt->instant.zone = stz ? std::string(stz) : tzdate::current_timezone();

    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// date.fromfields({ year, month, day, hour?, minute?, second?, nanosecond? }, zone?)
static int date_fromfields(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    const char* stz = luaL_optstring(L, 2, nullptr);

    tzdate::DateFields f{};

    auto get_int = [&](const char* key, int def = 0) -> int {
        lua_getfield(L, 1, key);
        int v = int(luaL_optinteger(L, -1, def));
        lua_pop(L, 1);
        return v;
    };

    lua_getfield(L, 1, "year");
    f.year = int(luaL_checkinteger(L, -1));
    lua_pop(L, 1);

    lua_getfield(L, 1, "month");
    f.month = int(luaL_checkinteger(L, -1));
    lua_pop(L, 1);

    lua_getfield(L, 1, "day");
    f.day = int(luaL_checkinteger(L, -1));
    lua_pop(L, 1);

    f.hour = get_int("hour", 0);
    f.minute = get_int("minute", 0);
    f.second = get_int("second", 0);
    f.nanosecond = get_int("nanosecond", 0);
    f.offset_seconds = 0;

    std::string zone = stz ? std::string(stz) : tzdate::current_timezone();

    LuaDateTime* dt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (dt) LuaDateTime();

    try {
        dt->instant = tzdate::from_fields(L, f, zone);
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
    }

    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// ── Duration constructors ─────────────────────────────────────────────────────

static int date_nanoseconds(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::nanoseconds(luaL_checkinteger(L, 1));
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int date_milliseconds(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::milliseconds(luaL_checkinteger(L, 1));
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int date_seconds(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::seconds(luaL_checkinteger(L, 1));
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int date_minutes(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::minutes(luaL_checkinteger(L, 1));
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int date_hours(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::hours(luaL_checkinteger(L, 1));
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int date_days(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::days(luaL_checkinteger(L, 1));
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// ── Module-level utilities ────────────────────────────────────────────────────

static int date_timezone(lua_State* L) {
    lua_pushstring(L, tzdate::current_timezone().c_str());
    return 1;
}
static int date_timezones(lua_State* L) {
    auto names = tzdate::timezone_names();
    lua_newtable(L);
    for (size_t i = 0; i < names.size(); i++) {
        lua_pushstring(L, names[i].c_str());
        lua_rawseti(L, -2, int(i + 1));
    }
    return 1;
}

// ── DateTime metamethods ──────────────────────────────────────────────────────

static int dt_tostring(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    auto f = tzdate::get_fields(L, dt->instant);
    lua_pushfstring(L, "DateTime(%04d-%s-%02d %02d:%02d:%02d %s)", f.year,
                    tzdate::MONTHS_SHORT[f.month - 1], f.day, f.hour, f.minute, f.second,
                    tzdate::zone_display(dt->instant).c_str());
    return 1;
}

static int dt_add(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDuration* dur = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    LuaDateTime* newDt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (newDt) LuaDateTime();
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    newDt->instant = tzdate::add(dt->instant, dur->duration);
    return 1;
}

static int dt_sub(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDuration* dur = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    LuaDateTime* newDt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (newDt) LuaDateTime();
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    newDt->instant = tzdate::sub(dt->instant, dur->duration);
    return 1;
}

static int dt_eq(lua_State* L) {
    LuaDateTime* a = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDateTime* b = (LuaDateTime*)luaL_checkudata(L, 2, DATETIME_METATABLE);
    lua_pushboolean(L, a->instant.utc == b->instant.utc);
    return 1;
}
static int dt_lt(lua_State* L) {
    LuaDateTime* a = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDateTime* b = (LuaDateTime*)luaL_checkudata(L, 2, DATETIME_METATABLE);
    lua_pushboolean(L, a->instant.utc < b->instant.utc);
    return 1;
}
static int dt_le(lua_State* L) {
    LuaDateTime* a = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDateTime* b = (LuaDateTime*)luaL_checkudata(L, 2, DATETIME_METATABLE);
    lua_pushboolean(L, a->instant.utc <= b->instant.utc);
    return 1;
}

// ── DateTime methods (stored on metatable, reached via __index fallback) ──────

static int dt_toisostring(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    lua_pushstring(L, tzdate::format_iso(L, dt->instant).c_str());
    return 1;
}

static int dt_tounix(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    lua_pushnumber(L, double(tzdate::to_unix_seconds(dt->instant)));
    return 1;
}

static int dt_tounixms(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    lua_pushnumber(L, double(tzdate::to_unix_ms(dt->instant)));
    return 1;
}

static int dt_withzone(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    const char* stz = luaL_checkstring(L, 2);
    tzdate::resolve_zone(L, stz);  // validate

    LuaDateTime* newDt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (newDt) LuaDateTime();
    newDt->instant = tzdate::set_timezone(dt->instant, stz);
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int dt_diff(lua_State* L) {
    LuaDateTime* a = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDateTime* b = (LuaDateTime*)luaL_checkudata(L, 2, DATETIME_METATABLE);
    LuaDuration* dur = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (dur) LuaDuration();
    dur->duration = tzdate::diff(a->instant, b->instant);
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int dt_index(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    const char* key = luaL_checkstring(L, 2);

    // Fields that require computing DateFields
    if (strcmp(key, "year") == 0 || strcmp(key, "month") == 0 || strcmp(key, "day") == 0 ||
        strcmp(key, "hour") == 0 || strcmp(key, "minute") == 0 || strcmp(key, "second") == 0 ||
        strcmp(key, "nanosecond") == 0 || strcmp(key, "offset") == 0) {
        auto f = tzdate::get_fields(L, dt->instant);
        if (strcmp(key, "year") == 0)
            lua_pushinteger(L, f.year);
        else if (strcmp(key, "month") == 0)
            lua_pushinteger(L, f.month);
        else if (strcmp(key, "day") == 0)
            lua_pushinteger(L, f.day);
        else if (strcmp(key, "hour") == 0)
            lua_pushinteger(L, f.hour);
        else if (strcmp(key, "minute") == 0)
            lua_pushinteger(L, f.minute);
        else if (strcmp(key, "second") == 0)
            lua_pushinteger(L, f.second);
        else if (strcmp(key, "nanosecond") == 0)
            lua_pushinteger(L, f.nanosecond);
        else /* offset */
            lua_pushinteger(L, f.offset_seconds);
        return 1;
    }

    if (strcmp(key, "zone") == 0) {
        lua_pushstring(L, tzdate::zone_display(dt->instant).c_str());
        return 1;
    }
    if (strcmp(key, "weekday") == 0) {
        lua_pushinteger(L, tzdate::weekday(L, dt->instant));
        return 1;
    }
    if (strcmp(key, "dayOfYear") == 0) {
        lua_pushinteger(L, tzdate::day_of_year(L, dt->instant));
        return 1;
    }
    if (strcmp(key, "isLeap") == 0) {
        auto f = tzdate::get_fields(L, dt->instant);
        lua_pushboolean(L, tzdate::is_leap(f.year));
        return 1;
    }
    if (strcmp(key, "isDst") == 0) {
        lua_pushboolean(L, tzdate::is_dst(L, dt->instant));
        return 1;
    }

    // Fall through to metatable for methods
    lua_getmetatable(L, 1);
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
}

static int dt_format(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    const char* fmt = luaL_checkstring(L, 2);
    try {
        lua_pushstring(L, tzdate::format_custom(L, dt->instant, fmt).c_str());
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
    }
    return 1;
}

static int dt_formatutc(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    const char* fmt = luaL_checkstring(L, 2);
    try {
        lua_pushstring(L, tzdate::format_utc(dt->instant, fmt).c_str());
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
    }
    return 1;
}

static int dt_startofday(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    LuaDateTime* out = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (out) LuaDateTime();
    out->instant = tzdate::start_of_day(L, dt->instant);
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int dt_addmonths(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    int months = (int)luaL_checkinteger(L, 2);
    LuaDateTime* out = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (out) LuaDateTime();
    out->instant = tzdate::add_months(L, dt->instant, months);
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int dt_addyears(lua_State* L) {
    LuaDateTime* dt = (LuaDateTime*)luaL_checkudata(L, 1, DATETIME_METATABLE);
    int years = (int)luaL_checkinteger(L, 2);
    LuaDateTime* out = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (out) LuaDateTime();
    out->instant = tzdate::add_years(L, dt->instant, years);
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// date.parse(str, fmt, zone?) – parse using a std::chrono format string
static int date_parse(lua_State* L) {
    const char* s = luaL_checkstring(L, 1);
    const char* fmt = luaL_checkstring(L, 2);
    const char* stz = luaL_optstring(L, 3, nullptr);
    LuaDateTime* dt = (LuaDateTime*)lua_newuserdata(L, sizeof(LuaDateTime));
    new (dt) LuaDateTime();
    try {
        dt->instant = tzdate::parse_custom(L, s, fmt, stz ? std::string(stz) : std::string{});
    } catch (const std::exception& e) {
        luaL_error(L, "%s", e.what());
    }
    luaL_getmetatable(L, DATETIME_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int date_isleap(lua_State* L) {
    lua_pushboolean(L, tzdate::is_leap((int)luaL_checkinteger(L, 1)));
    return 1;
}

static int date_daysinmonth(lua_State* L) {
    int year = (int)luaL_checkinteger(L, 1);
    int month = (int)luaL_checkinteger(L, 2);
    lua_pushinteger(L, tzdate::days_in_month(year, (unsigned)month));
    return 1;
}

// ── Duration metamethods ──────────────────────────────────────────────────────

static int dur_tostring(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    int h = int(std::chrono::duration_cast<std::chrono::hours>(dur->duration).count());
    int m =
        int(std::chrono::duration_cast<std::chrono::minutes>(dur->duration % std::chrono::hours(1))
                .count());
    int s = int(
        std::chrono::duration_cast<std::chrono::seconds>(dur->duration % std::chrono::minutes(1))
            .count());
    int ns = int((dur->duration % std::chrono::seconds(1)).count());
    lua_pushfstring(L, "Duration(%dh %02dm %02ds %dns)", h, m, s, ns);
    return 1;
}

static int dur_add(lua_State* L) {
    LuaDuration* a = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* b = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    LuaDuration* out = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (out) LuaDuration();
    out->duration = a->duration + b->duration;
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int dur_sub(lua_State* L) {
    LuaDuration* a = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* b = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    LuaDuration* out = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (out) LuaDuration();
    out->duration = a->duration - b->duration;
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int dur_mul(lua_State* L) {
    // Supports dur * number and number * dur
    LuaDuration* dur;
    double factor;
    if (lua_isuserdata(L, 1)) {
        dur = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
        factor = luaL_checknumber(L, 2);
    } else {
        factor = luaL_checknumber(L, 1);
        dur = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    }
    LuaDuration* out = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (out) LuaDuration();
    out->duration = std::chrono::nanoseconds{ int64_t(double(dur->duration.count()) * factor) };
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int dur_div(lua_State* L) {
    LuaDuration* a = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    if (lua_isuserdata(L, 2)) {
        // dur / dur = ratio (number)
        LuaDuration* b = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
        lua_pushnumber(L, double(a->duration.count()) / double(b->duration.count()));
    } else {
        double factor = luaL_checknumber(L, 2);
        LuaDuration* out = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
        new (out) LuaDuration();
        out->duration = std::chrono::nanoseconds{ int64_t(double(a->duration.count()) / factor) };
        luaL_getmetatable(L, DURATION_METATABLE);
        lua_setmetatable(L, -2);
    }
    return 1;
}
static int dur_unm(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* out = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (out) LuaDuration();
    out->duration = -dur->duration;
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}
static int dur_eq(lua_State* L) {
    LuaDuration* a = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* b = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    lua_pushboolean(L, a->duration == b->duration);
    return 1;
}
static int dur_lt(lua_State* L) {
    LuaDuration* a = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* b = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    lua_pushboolean(L, a->duration < b->duration);
    return 1;
}
static int dur_le(lua_State* L) {
    LuaDuration* a = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* b = (LuaDuration*)luaL_checkudata(L, 2, DURATION_METATABLE);
    lua_pushboolean(L, a->duration <= b->duration);
    return 1;
}

// ── Duration methods ──────────────────────────────────────────────────────────

static int dur_abs(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    LuaDuration* out = (LuaDuration*)lua_newuserdata(L, sizeof(LuaDuration));
    new (out) LuaDuration();
    out->duration = dur->duration < tzdate::Duration{} ? -dur->duration : dur->duration;
    luaL_getmetatable(L, DURATION_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

static int dur_index(lua_State* L) {
    LuaDuration* dur = (LuaDuration*)luaL_checkudata(L, 1, DURATION_METATABLE);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "totalNanoseconds") == 0) {
        lua_pushnumber(
            L, std::chrono::duration_cast<std::chrono::duration<double, std::nano>>(dur->duration)
                   .count());
    } else if (strcmp(key, "totalMicroseconds") == 0) {
        lua_pushnumber(
            L, std::chrono::duration_cast<std::chrono::duration<double, std::micro>>(dur->duration)
                   .count());
    } else if (strcmp(key, "totalMilliseconds") == 0) {
        lua_pushnumber(
            L, std::chrono::duration_cast<std::chrono::duration<double, std::milli>>(dur->duration)
                   .count());
    } else if (strcmp(key, "totalSeconds") == 0) {
        lua_pushnumber(L, std::chrono::duration_cast<std::chrono::duration<double, std::ratio<1>>>(
                              dur->duration)
                              .count());
    } else if (strcmp(key, "totalMinutes") == 0) {
        lua_pushnumber(L, std::chrono::duration_cast<std::chrono::duration<double, std::ratio<60>>>(
                              dur->duration)
                              .count());
    } else if (strcmp(key, "totalHours") == 0) {
        lua_pushnumber(L,
                       std::chrono::duration_cast<std::chrono::duration<double, std::ratio<3600>>>(
                           dur->duration)
                           .count());
    } else if (strcmp(key, "totalDays") == 0) {
        lua_pushnumber(L,
                       std::chrono::duration_cast<std::chrono::duration<double, std::ratio<86400>>>(
                           dur->duration)
                           .count());
    } else if (strcmp(key, "days") == 0) {
        lua_pushnumber(L,
                       int(std::chrono::duration_cast<std::chrono::days>(dur->duration).count()));
    } else if (strcmp(key, "hours") == 0) {
        lua_pushnumber(L, int(std::chrono::duration_cast<std::chrono::hours>(dur->duration %
                                                                             std::chrono::days(1))
                                  .count()));
    } else if (strcmp(key, "minutes") == 0) {
        lua_pushnumber(L, int(std::chrono::duration_cast<std::chrono::minutes>(
                                  dur->duration % std::chrono::hours(1))
                                  .count()));
    } else if (strcmp(key, "seconds") == 0) {
        lua_pushnumber(L, int(std::chrono::duration_cast<std::chrono::seconds>(
                                  dur->duration % std::chrono::minutes(1))
                                  .count()));
    } else if (strcmp(key, "milliseconds") == 0) {
        lua_pushnumber(L, int(std::chrono::duration_cast<std::chrono::milliseconds>(
                                  dur->duration % std::chrono::seconds(1))
                                  .count()));
    } else if (strcmp(key, "microseconds") == 0) {
        lua_pushnumber(L, int(std::chrono::duration_cast<std::chrono::microseconds>(
                                  dur->duration % std::chrono::milliseconds(1))
                                  .count()));
    } else if (strcmp(key, "nanoseconds") == 0) {
        lua_pushnumber(L, int((dur->duration % std::chrono::microseconds(1)).count()));
    } else if (strcmp(key, "subSeconds") == 0) {
        auto remainder = dur->duration % std::chrono::seconds(1);
        lua_pushnumber(L, std::chrono::duration<double>(remainder).count());
    } else {
        // Fall through to metatable for methods
        lua_getmetatable(L, 1);
        lua_pushvalue(L, 2);
        lua_rawget(L, -2);
        return 1;
    }

    return 1;
}

// ── Module entry ──────────────────────────────────────────────────────────────

LUAU_MODULE_EXPORT int luauopen_date(lua_State* L) {
    // DateTime metatable
    luaL_newmetatable(L, DATETIME_METATABLE);
    lua_pushcfunction(L, dt_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, dt_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, dt_add, "add");
    lua_setfield(L, -2, "__add");
    lua_pushcfunction(L, dt_sub, "sub");
    lua_setfield(L, -2, "__sub");
    lua_pushcfunction(L, dt_eq, "eq");
    lua_setfield(L, -2, "__eq");
    lua_pushcfunction(L, dt_lt, "lt");
    lua_setfield(L, -2, "__lt");
    lua_pushcfunction(L, dt_le, "le");
    lua_setfield(L, -2, "__le");
    // Methods (reached via __index fallback)
    lua_pushcfunction(L, dt_toisostring, "ToIsoString");
    lua_setfield(L, -2, "ToIsoString");
    lua_pushcfunction(L, dt_tounix, "ToUnix");
    lua_setfield(L, -2, "ToUnix");
    lua_pushcfunction(L, dt_tounixms, "ToUnixMs");
    lua_setfield(L, -2, "ToUnixMs");
    lua_pushcfunction(L, dt_withzone, "WithZone");
    lua_setfield(L, -2, "WithZone");
    lua_pushcfunction(L, dt_diff, "Diff");
    lua_setfield(L, -2, "Diff");
    lua_pushcfunction(L, dt_format, "Format");
    lua_setfield(L, -2, "Format");
    lua_pushcfunction(L, dt_formatutc, "FormatUtc");
    lua_setfield(L, -2, "FormatUtc");
    lua_pushcfunction(L, dt_startofday, "StartOfDay");
    lua_setfield(L, -2, "StartOfDay");
    lua_pushcfunction(L, dt_addmonths, "AddMonths");
    lua_setfield(L, -2, "AddMonths");
    lua_pushcfunction(L, dt_addyears, "AddYears");
    lua_setfield(L, -2, "AddYears");
    lua_pop(L, 1);

    // Duration metatable
    luaL_newmetatable(L, DURATION_METATABLE);
    lua_pushcfunction(L, dur_index, "index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, dur_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, dur_add, "add");
    lua_setfield(L, -2, "__add");
    lua_pushcfunction(L, dur_sub, "sub");
    lua_setfield(L, -2, "__sub");
    lua_pushcfunction(L, dur_mul, "mul");
    lua_setfield(L, -2, "__mul");
    lua_pushcfunction(L, dur_div, "div");
    lua_setfield(L, -2, "__div");
    lua_pushcfunction(L, dur_unm, "unm");
    lua_setfield(L, -2, "__unm");
    lua_pushcfunction(L, dur_eq, "eq");
    lua_setfield(L, -2, "__eq");
    lua_pushcfunction(L, dur_lt, "lt");
    lua_setfield(L, -2, "__lt");
    lua_pushcfunction(L, dur_le, "le");
    lua_setfield(L, -2, "__le");
    // Methods
    lua_pushcfunction(L, dur_abs, "Abs");
    lua_setfield(L, -2, "Abs");
    lua_pop(L, 1);

    // Module table
    lua_newtable(L);
    lua_pushcfunction(L, date_now, "now");
    lua_setfield(L, -2, "now");
    lua_pushcfunction(L, date_fromiso, "fromIso");
    lua_setfield(L, -2, "fromIso");
    lua_pushcfunction(L, date_fromtimestamp, "fromTimestamp");
    lua_setfield(L, -2, "fromTimestamp");
    lua_pushcfunction(L, date_fromfields, "fromFields");
    lua_setfield(L, -2, "fromFields");
    lua_pushcfunction(L, date_timezone, "timezone");
    lua_setfield(L, -2, "timezone");
    lua_pushcfunction(L, date_timezones, "timezones");
    lua_setfield(L, -2, "timezones");
    lua_pushcfunction(L, date_parse, "parse");
    lua_setfield(L, -2, "parse");
    lua_pushcfunction(L, date_isleap, "isLeap");
    lua_setfield(L, -2, "isLeap");
    lua_pushcfunction(L, date_daysinmonth, "daysInMonth");
    lua_setfield(L, -2, "daysInMonth");

    lua_pushcfunction(L, date_nanoseconds, "nanoseconds");
    lua_setfield(L, -2, "nanoseconds");
    lua_pushcfunction(L, date_milliseconds, "milliseconds");
    lua_setfield(L, -2, "milliseconds");
    lua_pushcfunction(L, date_seconds, "seconds");
    lua_setfield(L, -2, "seconds");
    lua_pushcfunction(L, date_minutes, "minutes");
    lua_setfield(L, -2, "minutes");
    lua_pushcfunction(L, date_hours, "hours");
    lua_setfield(L, -2, "hours");
    lua_pushcfunction(L, date_days, "days");
    lua_setfield(L, -2, "days");

    return 1;
}