#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "gmp.h"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "mpfr.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen_number",
};
LUAU_MODULE_INFO()

namespace {

constexpr const char* INTEGER_METATABLE = "Integer";
constexpr const char* RATIONAL_METATABLE = "Rational";
constexpr const char* FLOAT_METATABLE = "Float";
constexpr const char* NUMBER_METATABLE = "Number";

enum class DivMode {
    Trunc,
    Floor,
    Ceil,
};

enum class NumberKind {
    Integer,
    Float,
};

enum class RoundMode {
    Trunc,
    Floor,
    Ceil,
    Nearest,
    NearestEven,
    NearestAway,
};

struct LuaInteger {
    mpz_t value;
    bool initialized;
};

struct LuaRational {
    mpq_t value;
    bool initialized;
};

struct LuaFloat {
    mpfr_t value;
    bool initialized;
};

struct LuaNumber {
    NumberKind kind;
    mpz_t integerValue;
    mpfr_t floatValue;
    bool integerInitialized;
    bool floatInitialized;
};

struct TempInt {
    mpz_t value;

    TempInt() { mpz_init(value); }
    ~TempInt() { mpz_clear(value); }

    operator mpz_ptr() { return value; }
    operator mpz_srcptr() const { return value; }
};

struct TempRat {
    mpq_t value;

    TempRat() { mpq_init(value); }
    ~TempRat() { mpq_clear(value); }

    operator mpq_ptr() { return value; }
    operator mpq_srcptr() const { return value; }
};

struct TempFloat {
    mpfr_t value;

    explicit TempFloat(mpfr_prec_t precision = mpfr_get_default_prec()) {
        mpfr_init2(value, precision);
    }
    ~TempFloat() { mpfr_clear(value); }

    operator mpfr_ptr() { return value; }
    operator mpfr_srcptr() const { return value; }
};

static udataRef* check_udata_ref(lua_State* L, const char* name) {
    udataRef* ref = eryxUdata_getudata(L, name);
    if (!ref) {
        luaL_error(L, "%s userdata is not registered", name);
        return nullptr;
    }
    return ref;
}

static udataRef* test_udata_ref(lua_State* L, const char* name) {
    return eryxUdata_getudata(L, name);
}

static void integer_dtor(lua_State* L, void* userdata) {
    (void)L;
    auto* integer = static_cast<LuaInteger*>(userdata);
    if (integer->initialized) {
        mpz_clear(integer->value);
        integer->initialized = false;
    }
}

static void rational_dtor(lua_State* L, void* userdata) {
    (void)L;
    auto* rational = static_cast<LuaRational*>(userdata);
    if (rational->initialized) {
        mpq_clear(rational->value);
        rational->initialized = false;
    }
}

static void float_dtor(lua_State* L, void* userdata) {
    (void)L;
    auto* floatValue = static_cast<LuaFloat*>(userdata);
    if (floatValue->initialized) {
        mpfr_clear(floatValue->value);
        floatValue->initialized = false;
    }
}

static void number_dtor(lua_State* L, void* userdata) {
    (void)L;
    auto* number = static_cast<LuaNumber*>(userdata);
    if (number->integerInitialized) {
        mpz_clear(number->integerValue);
        number->integerInitialized = false;
    }
    if (number->floatInitialized) {
        mpfr_clear(number->floatValue);
        number->floatInitialized = false;
    }
}

static LuaInteger* check_integer(lua_State* L, int index) {
    return static_cast<LuaInteger*>(
        eryxUdata_checkudata(L, check_udata_ref(L, INTEGER_METATABLE), index));
}

static LuaRational* check_rational(lua_State* L, int index) {
    return static_cast<LuaRational*>(
        eryxUdata_checkudata(L, check_udata_ref(L, RATIONAL_METATABLE), index));
}

static LuaFloat* check_float(lua_State* L, int index) {
    return static_cast<LuaFloat*>(
        eryxUdata_checkudata(L, check_udata_ref(L, FLOAT_METATABLE), index));
}

static LuaNumber* check_number(lua_State* L, int index) {
    return static_cast<LuaNumber*>(
        eryxUdata_checkudata(L, check_udata_ref(L, NUMBER_METATABLE), index));
}

template <typename T>
static T* test_udata(lua_State* L, int index, const char* name) {
    udataRef* ref = test_udata_ref(L, name);
    return ref ? static_cast<T*>(eryxUdata_testudata(L, ref, index)) : nullptr;
}

static bool is_integer(lua_State* L, int index) {
    return test_udata<LuaInteger>(L, index, INTEGER_METATABLE) != nullptr;
}

static bool is_rational(lua_State* L, int index) {
    return test_udata<LuaRational>(L, index, RATIONAL_METATABLE) != nullptr;
}

static bool is_float(lua_State* L, int index) {
    return test_udata<LuaFloat>(L, index, FLOAT_METATABLE) != nullptr;
}

static bool is_number(lua_State* L, int index) {
    return test_udata<LuaNumber>(L, index, NUMBER_METATABLE) != nullptr;
}

static LuaInteger* push_integer(lua_State* L) {
    auto* integer =
        static_cast<LuaInteger*>(eryxUdata_pushudata(L, check_udata_ref(L, INTEGER_METATABLE)));
    std::memset(integer, 0, sizeof(LuaInteger));

    mpz_init(integer->value);
    integer->initialized = true;
    return integer;
}

static LuaRational* push_rational(lua_State* L) {
    auto* rational =
        static_cast<LuaRational*>(eryxUdata_pushudata(L, check_udata_ref(L, RATIONAL_METATABLE)));
    std::memset(rational, 0, sizeof(LuaRational));

    mpq_init(rational->value);
    rational->initialized = true;
    return rational;
}

static LuaFloat* push_float(lua_State* L, mpfr_prec_t precision = mpfr_get_default_prec()) {
    auto* floatValue =
        static_cast<LuaFloat*>(eryxUdata_pushudata(L, check_udata_ref(L, FLOAT_METATABLE)));
    std::memset(floatValue, 0, sizeof(LuaFloat));

    mpfr_init2(floatValue->value, precision);
    mpfr_set_zero(floatValue->value, 0);
    floatValue->initialized = true;
    return floatValue;
}

static LuaNumber* push_number_integer(lua_State* L) {
    auto* number =
        static_cast<LuaNumber*>(eryxUdata_pushudata(L, check_udata_ref(L, NUMBER_METATABLE)));
    std::memset(number, 0, sizeof(LuaNumber));

    number->kind = NumberKind::Integer;
    mpz_init(number->integerValue);
    number->integerInitialized = true;
    return number;
}

static LuaNumber* push_number_float(lua_State* L, mpfr_prec_t precision = mpfr_get_default_prec()) {
    auto* number =
        static_cast<LuaNumber*>(eryxUdata_pushudata(L, check_udata_ref(L, NUMBER_METATABLE)));
    std::memset(number, 0, sizeof(LuaNumber));

    number->kind = NumberKind::Float;
    mpfr_init2(number->floatValue, precision);
    mpfr_set_zero(number->floatValue, 0);
    number->floatInitialized = true;
    return number;
}

static int push_integer_copy(lua_State* L, mpz_srcptr value) {
    auto* integer = push_integer(L);
    mpz_set(integer->value, value);
    return 1;
}

static int push_rational_copy(lua_State* L, mpq_srcptr value) {
    auto* rational = push_rational(L);
    mpq_set(rational->value, value);
    return 1;
}

static int push_float_copy(lua_State* L, mpfr_srcptr value) {
    auto* floatValue = push_float(L, mpfr_get_prec(value));
    mpfr_set(floatValue->value, value, MPFR_RNDN);
    return 1;
}

static int push_number_integer_copy(lua_State* L, mpz_srcptr value) {
    auto* number = push_number_integer(L);
    mpz_set(number->integerValue, value);
    return 1;
}

static int push_number_float_copy(lua_State* L, mpfr_srcptr value) {
    auto* number = push_number_float(L, mpfr_get_prec(value));
    mpfr_set(number->floatValue, value, MPFR_RNDN);
    return 1;
}

static int push_number_copy(lua_State* L, const LuaNumber* value) {
    return value->kind == NumberKind::Integer ? push_number_integer_copy(L, value->integerValue)
                                              : push_number_float_copy(L, value->floatValue);
}

static void mpz_set_u64(mpz_ptr out, uint64_t value) {
    mpz_import(out, 1, -1, sizeof(value), 0, 0, &value);
}

static void mpz_set_i64(mpz_ptr out, int64_t value) {
    if (value >= 0) {
        mpz_set_u64(out, static_cast<uint64_t>(value));
        return;
    }

    uint64_t magnitude = static_cast<uint64_t>(-(value + 1)) + 1;
    mpz_set_u64(out, magnitude);
    mpz_neg(out, out);
}

static uint64_t mpz_get_u64(mpz_srcptr value) {
    uint64_t out = 0;
    size_t count = 0;
    mpz_export(&out, &count, -1, sizeof(out), 0, 0, value);
    return out;
}

static int mpq_sign(mpq_srcptr value) { return mpz_sgn(mpq_numref(value)); }

static void mpq_set_integer(mpq_ptr out, mpz_srcptr value) {
    mpq_set_z(out, value);
    mpq_canonicalize(out);
}

static bool mpz_fits_i64(mpz_srcptr value) {
    if (mpz_sgn(value) >= 0) return mpz_sizeinbase(value, 2) <= 63;

    TempInt absValue;
    TempInt minValue;
    mpz_abs(absValue.value, value);
    mpz_ui_pow_ui(minValue.value, 2, 63);
    return mpz_cmp(absValue.value, minValue.value) <= 0;
}

static bool mpz_fits_u64(mpz_srcptr value) {
    return mpz_sgn(value) >= 0 && mpz_sizeinbase(value, 2) <= 64;
}

static bool mpz_fits_exact_number(mpz_srcptr value) {
    lua_Number number = mpz_get_d(value);
    if (!std::isfinite(number)) return false;

    TempInt roundTrip;
    mpz_set_d(roundTrip.value, number);
    return mpz_cmp(roundTrip.value, value) == 0;
}

static lua_Number mpz_get_exact_number(lua_State* L, mpz_srcptr value) {
    if (!mpz_fits_exact_number(value))
        luaL_error(L, "integer does not fit exactly in a Luau number");
    return mpz_get_d(value);
}

static bool mpq_is_terminating_decimal(mpq_srcptr value, size_t& digitsOut) {
    TempInt denominator;
    mpz_set(denominator.value, mpq_denref(value));

    size_t twos = 0;
    size_t fives = 0;

    while (mpz_divisible_ui_p(denominator.value, 2)) {
        mpz_divexact_ui(denominator.value, denominator.value, 2);
        twos++;
    }

    while (mpz_divisible_ui_p(denominator.value, 5)) {
        mpz_divexact_ui(denominator.value, denominator.value, 5);
        fives++;
    }

    if (mpz_cmp_ui(denominator.value, 1) != 0) return false;

    digitsOut = twos > fives ? twos : fives;
    return true;
}

static mpfr_prec_t max_precision(mpfr_prec_t lhs, mpfr_prec_t rhs) { return lhs > rhs ? lhs : rhs; }

static bool try_get_whole_number64(lua_State* L, int index, int64_t& out) {
    if (lua_isinteger64(L, index)) {
        out = lua_tointeger64(L, index, nullptr);
        return true;
    }

    if (!lua_isnumber(L, index)) return false;

    lua_Number value = lua_tonumber(L, index);
    if (!std::isfinite(value)) return false;

    lua_Number integerPart = 0;
    if (std::modf(value, &integerPart) != 0.0) return false;

    if (integerPart < static_cast<lua_Number>(std::numeric_limits<int64_t>::min()) ||
        integerPart > static_cast<lua_Number>(std::numeric_limits<int64_t>::max()))
        return false;

    out = static_cast<int64_t>(integerPart);
    return true;
}

static int64_t luaL_checkwholenumber64(lua_State* L, int index) {
    if (lua_isinteger64(L, index)) return lua_tointeger64(L, index, nullptr);

    lua_Number value = luaL_checknumber(L, index);
    if (!std::isfinite(value)) luaL_argerror(L, index, "integer expected");

    lua_Number integerPart = 0;
    if (std::modf(value, &integerPart) != 0.0) luaL_argerror(L, index, "integer expected");

    if (integerPart < static_cast<lua_Number>(std::numeric_limits<int64_t>::min()) ||
        integerPart > static_cast<lua_Number>(std::numeric_limits<int64_t>::max()))
        luaL_argerror(L, index, "integer is out of signed 64-bit range");

    return static_cast<int64_t>(integerPart);
}

static lua_Number luaL_checkfinitenumber(lua_State* L, int index) {
    lua_Number value = luaL_checknumber(L, index);
    if (!std::isfinite(value)) luaL_argerror(L, index, "finite number expected");
    return value;
}

static int64_t luaL_checkexactinteger64(lua_State* L, int index) {
    if (lua_isinteger64(L, index)) return lua_tointeger64(L, index, nullptr);
    return luaL_checkwholenumber64(L, index);
}

static uint64_t luaL_checkwholenonu64(lua_State* L, int index) {
    int64_t value = luaL_checkwholenumber64(L, index);
    if (value < 0) luaL_argerror(L, index, "non-negative integer expected");
    return static_cast<uint64_t>(value);
}

static uint64_t luaL_checkexactu64(lua_State* L, int index) {
    int64_t value = luaL_checkexactinteger64(L, index);
    if (value < 0) luaL_argerror(L, index, "non-negative integer expected");
    return static_cast<uint64_t>(value);
}

static mp_bitcnt_t luaL_checkbitcount(lua_State* L, int index, const char* name) {
    uint64_t value = luaL_checkwholenonu64(L, index);
    if (value > std::numeric_limits<mp_bitcnt_t>::max()) luaL_error(L, "%s is too large", name);
    return static_cast<mp_bitcnt_t>(value);
}

static int luaL_optreps(lua_State* L, int index, int defaultValue) {
    if (lua_isnoneornil(L, index)) return defaultValue;
    int64_t value = luaL_checkwholenumber64(L, index);
    if (value < 0 || value > std::numeric_limits<int>::max())
        luaL_argerror(L, index, "repetitions must be between 0 and INT_MAX");
    return static_cast<int>(value);
}

static int check_parse_base(lua_State* L, int index, int defaultValue) {
    if (lua_isnoneornil(L, index)) return defaultValue;

    int64_t base = luaL_checkwholenumber64(L, index);
    if (base != 0 && (base < 2 || base > 62))
        luaL_argerror(L, index, "base must be 0 or between 2 and 62");
    return static_cast<int>(base);
}

static int check_format_base(lua_State* L, int index, int defaultValue) {
    if (lua_isnoneornil(L, index)) return defaultValue;

    int64_t base = luaL_checkwholenumber64(L, index);
    if (base < 2 || base > 62) luaL_argerror(L, index, "base must be between 2 and 62");
    return static_cast<int>(base);
}

static mpfr_prec_t check_precision(lua_State* L, int index,
                                   mpfr_prec_t defaultValue = mpfr_get_default_prec()) {
    if (lua_isnoneornil(L, index)) return defaultValue;

    uint64_t value = luaL_checkwholenonu64(L, index);
    if (value < static_cast<uint64_t>(MPFR_PREC_MIN) ||
        value > static_cast<uint64_t>(MPFR_PREC_MAX))
        luaL_argerror(L, index, "precision must be within MPFR's supported range");
    return static_cast<mpfr_prec_t>(value);
}

static unsigned long check_ulong_from_size(lua_State* L, size_t value, const char* name) {
    if (value > std::numeric_limits<unsigned long>::max()) luaL_error(L, "%s is too large", name);
    return static_cast<unsigned long>(value);
}

static std::string mpz_to_string(mpz_srcptr value, int base) {
    size_t capacity = mpz_sizeinbase(value, base) + 3;
    std::vector<char> buffer(capacity);
    mpz_get_str(buffer.data(), base, value);
    return std::string(buffer.data());
}

static std::string mpq_to_string(mpq_srcptr value, int base) {
    size_t capacity =
        mpz_sizeinbase(mpq_numref(value), base) + mpz_sizeinbase(mpq_denref(value), base) + 4;
    std::vector<char> buffer(capacity);
    mpq_get_str(buffer.data(), base, value);
    return std::string(buffer.data());
}

static std::string mpfr_to_string(lua_State* L, mpfr_srcptr value, int base, size_t digits,
                                  bool digitsExplicit) {
    if (mpfr_nan_p(value)) return "nan";
    if (mpfr_inf_p(value)) return mpfr_sgn(value) < 0 ? "-inf" : "inf";
    if (mpfr_zero_p(value)) return "0";

    mpfr_exp_t exponent = 0;
    char* raw =
        mpfr_get_str(nullptr, &exponent, base, digitsExplicit ? digits : 0, value, MPFR_RNDN);
    if (raw == nullptr) luaL_error(L, "failed to format float");

    bool negative = raw[0] == '-';
    const char* mantissa = negative ? raw + 1 : raw;
    size_t length = std::strlen(mantissa);

    std::string out;
    if (exponent <= 0) {
        out = "0.";
        out.append(static_cast<size_t>(-exponent), '0');
        out.append(mantissa, length);
    } else if (static_cast<size_t>(exponent) >= length) {
        out.assign(mantissa, length);
        out.append(static_cast<size_t>(exponent) - length, '0');
    } else {
        out.assign(mantissa, static_cast<size_t>(exponent));
        out.push_back('.');
        out.append(mantissa + exponent, length - static_cast<size_t>(exponent));
    }

    mpfr_free_str(raw);

    if (!digitsExplicit) {
        size_t dot = out.find('.');
        if (dot != std::string::npos) {
            while (!out.empty() && out.back() == '0') out.pop_back();
            if (!out.empty() && out.back() == '.') out.pop_back();
        }
    }

    if (negative) out.insert(out.begin(), '-');
    return out;
}

static RoundMode check_round_mode(lua_State* L, int index,
                                  RoundMode defaultMode = RoundMode::Nearest) {
    if (lua_isnoneornil(L, index)) return defaultMode;

    const char* mode = luaL_checkstring(L, index);
    if (std::strcmp(mode, "trunc") == 0) return RoundMode::Trunc;
    if (std::strcmp(mode, "floor") == 0) return RoundMode::Floor;
    if (std::strcmp(mode, "ceil") == 0) return RoundMode::Ceil;
    if (std::strcmp(mode, "nearest") == 0) return RoundMode::Nearest;
    if (std::strcmp(mode, "nearest_even") == 0) return RoundMode::NearestEven;
    if (std::strcmp(mode, "nearest_away") == 0) return RoundMode::NearestAway;

    luaL_argerror(L, index, "invalid rounding mode");
    return defaultMode;
}

static mpfr_rnd_t round_mode_to_mpfr(lua_State* L, RoundMode mode, const char* context) {
    switch (mode) {
        case RoundMode::Trunc:
            return MPFR_RNDZ;
        case RoundMode::Floor:
            return MPFR_RNDD;
        case RoundMode::Ceil:
            return MPFR_RNDU;
        case RoundMode::Nearest:
        case RoundMode::NearestEven:
            return MPFR_RNDN;
        case RoundMode::NearestAway:
            luaL_error(L, "%s does not yet support nearest_away rounding", context);
            return MPFR_RNDN;
    }

    luaL_error(L, "invalid rounding mode");
    return MPFR_RNDN;
}

static mpfr_rnd_t check_mpfr_round_mode(lua_State* L, int index, const char* context,
                                        RoundMode defaultMode = RoundMode::Nearest) {
    return round_mode_to_mpfr(L, check_round_mode(L, index, defaultMode), context);
}

static NumberKind classify_number_operand(lua_State* L, int index, const char* expected) {
    if (auto* number = test_udata<LuaNumber>(L, index, NUMBER_METATABLE)) return number->kind;

    int64_t whole = 0;
    if (try_get_whole_number64(L, index, whole)) return NumberKind::Integer;

    if (!lua_isnumber(L, index)) luaL_typeerror(L, index, expected);
    return NumberKind::Float;
}

static void load_number_integer_operand_no_string(lua_State* L, int index, mpz_ptr out,
                                                  const char* expected) {
    if (auto* number = test_udata<LuaNumber>(L, index, NUMBER_METATABLE)) {
        if (number->kind != NumberKind::Integer) luaL_typeerror(L, index, expected);
        mpz_set(out, number->integerValue);
        return;
    }

    if (!lua_isnumber(L, index)) luaL_typeerror(L, index, expected);
    mpz_set_i64(out, luaL_checkwholenumber64(L, index));
}

static void load_number_float_operand_no_string(lua_State* L, int index, mpfr_ptr out,
                                                mpfr_rnd_t rounding, const char* expected) {
    if (auto* number = test_udata<LuaNumber>(L, index, NUMBER_METATABLE)) {
        if (number->kind == NumberKind::Float) {
            mpfr_set(out, number->floatValue, rounding);
        } else {
            mpfr_set_z(out, number->integerValue, rounding);
        }
        return;
    }

    if (!lua_isnumber(L, index)) luaL_typeerror(L, index, expected);
    mpfr_set_d(out, luaL_checknumber(L, index), rounding);
}

static mpfr_prec_t number_operand_precision(lua_State* L, int index) {
    if (auto* number = test_udata<LuaNumber>(L, index, NUMBER_METATABLE)) {
        if (number->kind == NumberKind::Float) return mpfr_get_prec(number->floatValue);
        return 53;
    }
    return 53;
}

static mpfr_prec_t number_float_result_precision(lua_State* L, int lhsIndex, int rhsIndex) {
    mpfr_prec_t precision =
        max_precision(number_operand_precision(L, lhsIndex), number_operand_precision(L, rhsIndex));

    if (classify_number_operand(L, lhsIndex, "Number or number") == NumberKind::Integer &&
        classify_number_operand(L, rhsIndex, "Number or number") == NumberKind::Integer)
        return max_precision(precision, mpfr_get_default_prec());

    return precision;
}

static void mpq_round_to_integer(mpz_ptr out, mpq_srcptr value, RoundMode mode) {
    mpz_srcptr numerator = mpq_numref(value);
    mpz_srcptr denominator = mpq_denref(value);

    switch (mode) {
        case RoundMode::Trunc:
            mpz_tdiv_q(out, numerator, denominator);
            return;
        case RoundMode::Floor:
            mpz_fdiv_q(out, numerator, denominator);
            return;
        case RoundMode::Ceil:
            mpz_cdiv_q(out, numerator, denominator);
            return;
        case RoundMode::Nearest:
        case RoundMode::NearestEven:
        case RoundMode::NearestAway:
            break;
    }

    TempInt quotient;
    TempInt remainder;
    TempInt twiceRemainder;
    mpz_fdiv_qr(quotient.value, remainder.value, numerator, denominator);
    mpz_mul_ui(twiceRemainder.value, remainder.value, 2);

    int cmp = mpz_cmp(twiceRemainder.value, denominator);
    if (cmp < 0) {
        mpz_set(out, quotient.value);
        return;
    }
    if (cmp > 0) {
        mpz_add_ui(out, quotient.value, 1);
        return;
    }

    if (mode == RoundMode::NearestEven) {
        if (mpz_even_p(quotient.value)) {
            mpz_set(out, quotient.value);
        } else {
            mpz_add_ui(out, quotient.value, 1);
        }
        return;
    }

    if (mpz_sgn(numerator) >= 0) {
        mpz_add_ui(out, quotient.value, 1);
    } else {
        mpz_set(out, quotient.value);
    }
}

static void mpfr_to_exact_rational(lua_State* L, mpq_ptr out, mpfr_srcptr value) {
    if (!mpfr_number_p(value)) luaL_error(L, "cannot convert non-finite float exactly");

    TempInt significand;
    TempInt denominator;
    mpfr_exp_t exponent = mpfr_get_z_2exp(significand.value, value);

    if (exponent >= 0) {
        if (static_cast<uint64_t>(exponent) > std::numeric_limits<mp_bitcnt_t>::max())
            luaL_error(L, "float exponent is too large");
        mpz_mul_2exp(significand.value, significand.value, static_cast<mp_bitcnt_t>(exponent));
        mpq_set_z(out, significand.value);
    } else {
        if (exponent == std::numeric_limits<mpfr_exp_t>::min())
            luaL_error(L, "float exponent is too large");

        uint64_t shift = static_cast<uint64_t>(-(exponent + 1)) + 1;
        if (shift > std::numeric_limits<mp_bitcnt_t>::max())
            luaL_error(L, "float exponent is too large");

        mpq_set_num(out, significand.value);
        mpz_set_ui(denominator.value, 1);
        mpz_mul_2exp(denominator.value, denominator.value, static_cast<mp_bitcnt_t>(shift));
        mpq_set_den(out, denominator.value);
    }

    mpq_canonicalize(out);
}

static void mpfr_round_to_integer(lua_State* L, mpz_ptr out, mpfr_srcptr value, RoundMode mode) {
    if (!mpfr_number_p(value)) luaL_error(L, "cannot convert non-finite float to Integer");

    TempRat exact;
    mpfr_to_exact_rational(L, exact.value, value);
    mpq_round_to_integer(out, exact.value, mode);
}

static void check_nonzero_divisor(lua_State* L, mpq_srcptr divisor) {
    if (mpq_sign(divisor) == 0) luaL_error(L, "division by zero");
}

static void check_nonzero_divisor(lua_State* L, mpfr_srcptr divisor) {
    if (mpfr_zero_p(divisor)) luaL_error(L, "division by zero");
}

static DivMode check_div_mode(lua_State* L, int index, DivMode defaultMode = DivMode::Floor) {
    if (lua_isnoneornil(L, index)) return defaultMode;

    const char* mode = luaL_checkstring(L, index);
    if (std::strcmp(mode, "trunc") == 0) return DivMode::Trunc;
    if (std::strcmp(mode, "floor") == 0) return DivMode::Floor;
    if (std::strcmp(mode, "ceil") == 0) return DivMode::Ceil;
    if (std::strcmp(mode, "nearest") == 0 || std::strcmp(mode, "nearest_even") == 0 ||
        std::strcmp(mode, "nearest_away") == 0)
        luaL_error(L, "integer division currently supports only trunc, floor, and ceil rounding");

    luaL_argerror(L, index, "invalid rounding mode");
    return defaultMode;
}

static void check_nonzero_divisor(lua_State* L, mpz_srcptr divisor) {
    if (mpz_sgn(divisor) == 0) luaL_error(L, "division by zero");
}

static void divmod(mpz_ptr quotient, mpz_ptr remainder, mpz_srcptr lhs, mpz_srcptr rhs,
                   DivMode mode) {
    switch (mode) {
        case DivMode::Trunc:
            mpz_tdiv_qr(quotient, remainder, lhs, rhs);
            return;
        case DivMode::Floor:
            mpz_fdiv_qr(quotient, remainder, lhs, rhs);
            return;
        case DivMode::Ceil:
            mpz_cdiv_qr(quotient, remainder, lhs, rhs);
            return;
    }
}

static void load_integer_operand_no_string(lua_State* L, int index, mpz_ptr out,
                                           const char* expected) {
    if (auto* integer = test_udata<LuaInteger>(L, index, INTEGER_METATABLE)) {
        mpz_set(out, integer->value);
        return;
    }

    if (!lua_isnumber(L, index)) luaL_typeerror(L, index, expected);

    mpz_set_i64(out, luaL_checkwholenumber64(L, index));
}

static void set_rational_from_decimal_string(lua_State* L, mpq_ptr out, const std::string& text,
                                             const char* context) {
    size_t index = 0;
    bool negative = false;

    if (index < text.size() && (text[index] == '+' || text[index] == '-')) {
        negative = text[index] == '-';
        index++;
    }

    std::string digits;
    size_t fractionalDigits = 0;
    bool sawDigit = false;

    while (index < text.size() && std::isdigit(static_cast<unsigned char>(text[index]))) {
        digits.push_back(text[index++]);
        sawDigit = true;
    }

    if (index < text.size() && text[index] == '.') {
        index++;
        while (index < text.size() && std::isdigit(static_cast<unsigned char>(text[index]))) {
            digits.push_back(text[index++]);
            fractionalDigits++;
            sawDigit = true;
        }
    }

    if (!sawDigit) luaL_error(L, "invalid decimal rational string for %s", context);

    int exponent = 0;
    if (index < text.size() && (text[index] == 'e' || text[index] == 'E')) {
        index++;

        bool expNegative = false;
        if (index < text.size() && (text[index] == '+' || text[index] == '-')) {
            expNegative = text[index] == '-';
            index++;
        }

        if (index >= text.size() || !std::isdigit(static_cast<unsigned char>(text[index])))
            luaL_error(L, "invalid decimal rational exponent for %s", context);

        while (index < text.size() && std::isdigit(static_cast<unsigned char>(text[index]))) {
            int digit = text[index++] - '0';
            if (exponent > (std::numeric_limits<int>::max() - digit) / 10)
                luaL_error(L, "decimal exponent for %s is too large", context);
            exponent = exponent * 10 + digit;
        }

        if (expNegative) exponent = -exponent;
    }

    if (index != text.size()) luaL_error(L, "invalid decimal rational string for %s", context);

    if (digits.empty()) digits = "0";

    TempInt numerator;
    if (mpz_set_str(numerator.value, digits.c_str(), 10) != 0)
        luaL_error(L, "invalid decimal rational string for %s", context);

    if (negative) mpz_neg(numerator.value, numerator.value);

    int64_t scale = static_cast<int64_t>(fractionalDigits) - static_cast<int64_t>(exponent);
    if (scale <= 0) {
        if (scale < 0) {
            TempInt pow10;
            mpz_ui_pow_ui(pow10.value, 10,
                          check_ulong_from_size(L, static_cast<size_t>(-scale), "decimal scale"));
            mpz_mul(numerator.value, numerator.value, pow10.value);
        }
        mpq_set_z(out, numerator.value);
        mpq_canonicalize(out);
        return;
    }

    TempInt denominator;
    mpz_ui_pow_ui(denominator.value, 10,
                  check_ulong_from_size(L, static_cast<size_t>(scale), "decimal scale"));
    mpq_set_num(out, numerator.value);
    mpq_set_den(out, denominator.value);
    mpq_canonicalize(out);
}

static void set_rational_from_string(lua_State* L, mpq_ptr out, const std::string& text, int base,
                                     const char* context) {
    if (text.find_first_of(".eE") != std::string::npos) {
        if (base != 0 && base != 10)
            luaL_error(
                L, "%s only supports decimal strings when a fractional part or exponent is used",
                context);
        set_rational_from_decimal_string(L, out, text, context);
        return;
    }

    if (mpq_set_str(out, text.c_str(), base) != 0)
        luaL_error(L, "invalid rational string for %s", context);
    mpq_canonicalize(out);
}

static void load_rational_operand_no_string(lua_State* L, int index, mpq_ptr out,
                                            const char* expected) {
    if (auto* rational = test_udata<LuaRational>(L, index, RATIONAL_METATABLE)) {
        mpq_set(out, rational->value);
        return;
    }

    if (auto* integer = test_udata<LuaInteger>(L, index, INTEGER_METATABLE)) {
        mpq_set_integer(out, integer->value);
        return;
    }

    if (!lua_isnumber(L, index)) luaL_typeerror(L, index, expected);

    mpq_set_d(out, luaL_checkfinitenumber(L, index));
    mpq_canonicalize(out);
}

static void load_rational_like(lua_State* L, int index, mpq_ptr out, const char* expected) {
    if (lua_type(L, index) == LUA_TSTRING) {
        set_rational_from_string(L, out, lua_tostring(L, index), 10, expected);
        return;
    }

    load_rational_operand_no_string(L, index, out, expected);
}

static void load_float_operand_no_string(lua_State* L, int index, mpfr_ptr out, mpfr_rnd_t rounding,
                                         const char* expected) {
    if (auto* floatValue = test_udata<LuaFloat>(L, index, FLOAT_METATABLE)) {
        mpfr_set(out, floatValue->value, rounding);
        return;
    }

    if (!lua_isnumber(L, index)) luaL_typeerror(L, index, expected);

    mpfr_set_d(out, luaL_checknumber(L, index), rounding);
}

static mpfr_prec_t float_operand_precision(lua_State* L, int index) {
    if (auto* floatValue = test_udata<LuaFloat>(L, index, FLOAT_METATABLE))
        return mpfr_get_prec(floatValue->value);
    return 53;
}

static unsigned long check_ulong_from_integer(lua_State* L, mpz_srcptr value, const char* name) {
    if (mpz_sgn(value) < 0) luaL_error(L, "%s must be non-negative", name);
    if (!mpz_fits_ulong_p(value)) luaL_error(L, "%s is too large for GMP", name);
    return mpz_get_ui(value);
}

static int integer_clone(lua_State* L) { return push_integer_copy(L, check_integer(L, 1)->value); }

static int integer_abs(lua_State* L) {
    TempInt out;
    mpz_abs(out.value, check_integer(L, 1)->value);
    return push_integer_copy(L, out.value);
}

static int integer_sign(lua_State* L) {
    lua_pushnumber(L, static_cast<lua_Number>(mpz_sgn(check_integer(L, 1)->value)));
    return 1;
}

static int integer_cmp(lua_State* L) {
    TempInt rhs;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    lua_pushnumber(L, static_cast<lua_Number>(mpz_cmp(check_integer(L, 1)->value, rhs.value)));
    return 1;
}

static int integer_is_zero(lua_State* L) {
    lua_pushboolean(L, mpz_sgn(check_integer(L, 1)->value) == 0);
    return 1;
}

static int integer_is_one(lua_State* L) {
    lua_pushboolean(L, mpz_cmp_ui(check_integer(L, 1)->value, 1) == 0);
    return 1;
}

static int integer_is_even(lua_State* L) {
    lua_pushboolean(L, mpz_even_p(check_integer(L, 1)->value));
    return 1;
}

static int integer_is_odd(lua_State* L) {
    lua_pushboolean(L, mpz_odd_p(check_integer(L, 1)->value));
    return 1;
}

static int integer_div_round(lua_State* L, DivMode mode) {
    TempInt rhs;
    TempInt quotient;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    check_nonzero_divisor(L, rhs.value);

    switch (mode) {
        case DivMode::Trunc:
            mpz_tdiv_q(quotient.value, check_integer(L, 1)->value, rhs.value);
            break;
        case DivMode::Floor:
            mpz_fdiv_q(quotient.value, check_integer(L, 1)->value, rhs.value);
            break;
        case DivMode::Ceil:
            mpz_cdiv_q(quotient.value, check_integer(L, 1)->value, rhs.value);
            break;
    }

    return push_integer_copy(L, quotient.value);
}

static int integer_div_trunc(lua_State* L) { return integer_div_round(L, DivMode::Trunc); }
static int integer_div_floor(lua_State* L) { return integer_div_round(L, DivMode::Floor); }
static int integer_div_ceil(lua_State* L) { return integer_div_round(L, DivMode::Ceil); }

static int integer_divmod(lua_State* L) {
    TempInt rhs;
    TempInt quotient;
    TempInt remainder;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    check_nonzero_divisor(L, rhs.value);

    DivMode mode = check_div_mode(L, 3, DivMode::Floor);
    divmod(quotient.value, remainder.value, check_integer(L, 1)->value, rhs.value, mode);

    push_integer_copy(L, quotient.value);
    push_integer_copy(L, remainder.value);
    return 2;
}

static int integer_gcd(lua_State* L) {
    TempInt rhs;
    TempInt out;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    mpz_gcd(out.value, check_integer(L, 1)->value, rhs.value);
    return push_integer_copy(L, out.value);
}

static int integer_lcm(lua_State* L) {
    TempInt rhs;
    TempInt out;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    mpz_lcm(out.value, check_integer(L, 1)->value, rhs.value);
    return push_integer_copy(L, out.value);
}

static int integer_extended_gcd(lua_State* L) {
    TempInt rhs;
    TempInt gcd;
    TempInt s;
    TempInt t;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    mpz_gcdext(gcd.value, s.value, t.value, check_integer(L, 1)->value, rhs.value);
    push_integer_copy(L, gcd.value);
    push_integer_copy(L, s.value);
    push_integer_copy(L, t.value);
    return 3;
}

static int integer_pow(lua_State* L) {
    TempInt exponent;
    TempInt out;
    load_integer_operand_no_string(L, 2, exponent.value, "Integer or number");
    unsigned long power = check_ulong_from_integer(L, exponent.value, "exponent");
    mpz_pow_ui(out.value, check_integer(L, 1)->value, power);
    return push_integer_copy(L, out.value);
}

static int integer_mod_pow(lua_State* L) {
    TempInt exponent;
    TempInt modulus;
    TempInt out;
    load_integer_operand_no_string(L, 2, exponent.value, "Integer or number");
    load_integer_operand_no_string(L, 3, modulus.value, "Integer or number");
    check_nonzero_divisor(L, modulus.value);
    if (mpz_sgn(exponent.value) < 0) luaL_error(L, "exponent must be non-negative");
    mpz_powm(out.value, check_integer(L, 1)->value, exponent.value, modulus.value);
    return push_integer_copy(L, out.value);
}

static int integer_mod_inverse(lua_State* L) {
    TempInt modulus;
    TempInt out;
    load_integer_operand_no_string(L, 2, modulus.value, "Integer or number");
    check_nonzero_divisor(L, modulus.value);
    if (mpz_invert(out.value, check_integer(L, 1)->value, modulus.value) == 0) {
        lua_pushnil(L);
        return 1;
    }
    return push_integer_copy(L, out.value);
}

static int integer_is_probable_prime(lua_State* L) {
    int reps = luaL_optreps(L, 2, 25);
    lua_pushboolean(L, mpz_probab_prime_p(check_integer(L, 1)->value, reps) > 0);
    return 1;
}

static int integer_next_prime(lua_State* L) {
    TempInt out;
    mpz_nextprime(out.value, check_integer(L, 1)->value);
    return push_integer_copy(L, out.value);
}

static int integer_bit_length(lua_State* L) {
    mpz_srcptr value = check_integer(L, 1)->value;
    mp_bitcnt_t bits = mpz_sgn(value) == 0 ? 0 : mpz_sizeinbase(value, 2);
    lua_pushnumber(L, static_cast<lua_Number>(bits));
    return 1;
}

static int integer_popcount(lua_State* L) {
    mpz_srcptr value = check_integer(L, 1)->value;
    if (mpz_sgn(value) < 0) luaL_error(L, "popcount is undefined for negative integers");
    lua_pushnumber(L, static_cast<lua_Number>(mpz_popcount(value)));
    return 1;
}

static int integer_test_bit(lua_State* L) {
    mp_bitcnt_t bit = luaL_checkbitcount(L, 2, "bit index");
    lua_pushboolean(L, mpz_tstbit(check_integer(L, 1)->value, bit) != 0);
    return 1;
}

static int integer_set_bit(lua_State* L) {
    TempInt out;
    mp_bitcnt_t bit = luaL_checkbitcount(L, 2, "bit index");
    mpz_set(out.value, check_integer(L, 1)->value);
    mpz_setbit(out.value, bit);
    return push_integer_copy(L, out.value);
}

static int integer_clear_bit(lua_State* L) {
    TempInt out;
    mp_bitcnt_t bit = luaL_checkbitcount(L, 2, "bit index");
    mpz_set(out.value, check_integer(L, 1)->value);
    mpz_clrbit(out.value, bit);
    return push_integer_copy(L, out.value);
}

static int integer_flip_bit(lua_State* L) {
    TempInt out;
    mp_bitcnt_t bit = luaL_checkbitcount(L, 2, "bit index");
    mpz_set(out.value, check_integer(L, 1)->value);
    mpz_combit(out.value, bit);
    return push_integer_copy(L, out.value);
}

static int integer_band(lua_State* L) {
    TempInt rhs;
    TempInt out;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    mpz_and(out.value, check_integer(L, 1)->value, rhs.value);
    return push_integer_copy(L, out.value);
}

static int integer_bor(lua_State* L) {
    TempInt rhs;
    TempInt out;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    mpz_ior(out.value, check_integer(L, 1)->value, rhs.value);
    return push_integer_copy(L, out.value);
}

static int integer_bxor(lua_State* L) {
    TempInt rhs;
    TempInt out;
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");
    mpz_xor(out.value, check_integer(L, 1)->value, rhs.value);
    return push_integer_copy(L, out.value);
}

static int integer_bnot(lua_State* L) {
    TempInt out;
    mpz_com(out.value, check_integer(L, 1)->value);
    return push_integer_copy(L, out.value);
}

static int integer_shl(lua_State* L) {
    TempInt out;
    int64_t bits = luaL_checkwholenumber64(L, 2);
    mpz_set(out.value, check_integer(L, 1)->value);

    if (bits >= 0) {
        if (static_cast<uint64_t>(bits) > std::numeric_limits<mp_bitcnt_t>::max())
            luaL_error(L, "shift count is too large");
        mpz_mul_2exp(out.value, out.value, static_cast<mp_bitcnt_t>(bits));
    } else {
        uint64_t absBits = static_cast<uint64_t>(-(bits + 1)) + 1;
        if (absBits > std::numeric_limits<mp_bitcnt_t>::max())
            luaL_error(L, "shift count is too large");
        mpz_fdiv_q_2exp(out.value, out.value, static_cast<mp_bitcnt_t>(absBits));
    }

    return push_integer_copy(L, out.value);
}

static int integer_shr(lua_State* L) {
    TempInt out;
    int64_t bits = luaL_checkwholenumber64(L, 2);
    mpz_set(out.value, check_integer(L, 1)->value);

    if (bits >= 0) {
        if (static_cast<uint64_t>(bits) > std::numeric_limits<mp_bitcnt_t>::max())
            luaL_error(L, "shift count is too large");
        mpz_fdiv_q_2exp(out.value, out.value, static_cast<mp_bitcnt_t>(bits));
    } else {
        uint64_t absBits = static_cast<uint64_t>(-(bits + 1)) + 1;
        if (absBits > std::numeric_limits<mp_bitcnt_t>::max())
            luaL_error(L, "shift count is too large");
        mpz_mul_2exp(out.value, out.value, static_cast<mp_bitcnt_t>(absBits));
    }

    return push_integer_copy(L, out.value);
}

static int integer_to_string(lua_State* L) {
    int base = check_format_base(L, 2, 10);
    std::string text = mpz_to_string(check_integer(L, 1)->value, base);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int integer_to_number(lua_State* L) {
    lua_pushnumber(L, mpz_get_exact_number(L, check_integer(L, 1)->value));
    return 1;
}

static int integer_to_rational(lua_State* L) {
    auto* out = push_rational(L);
    mpq_set_integer(out->value, check_integer(L, 1)->value);
    return 1;
}

static int integer_to_float(lua_State* L) {
    auto* out = push_float(L, check_precision(L, 2));
    mpfr_set_z(out->value, check_integer(L, 1)->value, MPFR_RNDN);
    return 1;
}

static int integer_to_i64(lua_State* L) {
    mpz_srcptr value = check_integer(L, 1)->value;
    if (!mpz_fits_i64(value)) luaL_error(L, "integer does not fit in signed 64-bit range");

    if (mpz_sgn(value) >= 0) {
        lua_pushinteger64(L, mpz_get_u64(value));
        return 1;
    }

    TempInt absValue;
    TempInt minValue;
    mpz_abs(absValue.value, value);
    mpz_ui_pow_ui(minValue.value, 2, 63);

    if (mpz_cmp(absValue.value, minValue.value) == 0) {
        lua_pushinteger64(L, std::numeric_limits<int64_t>::min());
        return 1;
    }

    int64_t out = -static_cast<int64_t>(mpz_get_u64(absValue.value));
    lua_pushinteger64(L, out);
    return 1;
}

static int integer_to_u64(lua_State* L) {
    mpz_srcptr value = check_integer(L, 1)->value;
    if (!mpz_fits_u64(value)) luaL_error(L, "integer does not fit in unsigned 64-bit range");
    lua_pushinteger64(L, mpz_get_u64(value));
    return 1;
}

static int integer_fits_number(lua_State* L) {
    lua_pushboolean(L, mpz_fits_exact_number(check_integer(L, 1)->value));
    return 1;
}

static int integer_fits_i64(lua_State* L) {
    lua_pushboolean(L, mpz_fits_i64(check_integer(L, 1)->value));
    return 1;
}

static int integer_fits_u64(lua_State* L) {
    lua_pushboolean(L, mpz_fits_u64(check_integer(L, 1)->value));
    return 1;
}

static int integer_tostring(lua_State* L) {
    std::string text = mpz_to_string(check_integer(L, 1)->value, 10);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int integer_eq(lua_State* L) {
    if (!is_integer(L, 1) || !is_integer(L, 2)) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, mpz_cmp(check_integer(L, 1)->value, check_integer(L, 2)->value) == 0);
    return 1;
}

static int integer_compare_impl(lua_State* L, bool allowEqual) {
    TempInt lhs;
    TempInt rhs;
    load_integer_operand_no_string(L, 1, lhs.value, "Integer or number");
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");

    int cmp = mpz_cmp(lhs.value, rhs.value);
    lua_pushboolean(L, allowEqual ? cmp <= 0 : cmp < 0);
    return 1;
}

static int integer_lt(lua_State* L) { return integer_compare_impl(L, false); }
static int integer_le(lua_State* L) { return integer_compare_impl(L, true); }

static int integer_unm(lua_State* L) {
    TempInt out;
    mpz_neg(out.value, check_integer(L, 1)->value);
    return push_integer_copy(L, out.value);
}

static int integer_binary_op(lua_State* L, char op) {
    TempInt lhs;
    TempInt rhs;
    TempInt out;
    load_integer_operand_no_string(L, 1, lhs.value, "Integer or number");
    load_integer_operand_no_string(L, 2, rhs.value, "Integer or number");

    switch (op) {
        case '+':
            mpz_add(out.value, lhs.value, rhs.value);
            break;
        case '-':
            mpz_sub(out.value, lhs.value, rhs.value);
            break;
        case '*':
            mpz_mul(out.value, lhs.value, rhs.value);
            break;
        case '%':
            check_nonzero_divisor(L, rhs.value);
            mpz_fdiv_r(out.value, lhs.value, rhs.value);
            break;
        case '/':
            check_nonzero_divisor(L, rhs.value);
            mpz_fdiv_q(out.value, lhs.value, rhs.value);
            break;
        default:
            luaL_error(L, "unsupported integer operator");
    }

    return push_integer_copy(L, out.value);
}

static int integer_add(lua_State* L) { return integer_binary_op(L, '+'); }
static int integer_sub(lua_State* L) { return integer_binary_op(L, '-'); }
static int integer_mul(lua_State* L) { return integer_binary_op(L, '*'); }
static int integer_idiv(lua_State* L) { return integer_binary_op(L, '/'); }
static int integer_mod(lua_State* L) { return integer_binary_op(L, '%'); }
static int integer_pow_metamethod(lua_State* L) { return integer_pow(L); }

static int integer_new(lua_State* L) {
    if (lua_isnoneornil(L, 1)) {
        push_integer(L);
        return 1;
    }

    if (auto* integer = test_udata<LuaInteger>(L, 1, INTEGER_METATABLE)) {
        return push_integer_copy(L, integer->value);
    }

    if (lua_type(L, 1) == LUA_TSTRING) {
        int base = check_parse_base(L, 2, 10);
        const char* value = lua_tostring(L, 1);

        auto* out = push_integer(L);
        if (mpz_set_str(out->value, value, base) != 0) luaL_error(L, "invalid integer string");
        return 1;
    }

    auto* out = push_integer(L);
    mpz_set_i64(out->value, luaL_checkwholenumber64(L, 1));
    return 1;
}

static int integer_from_string(lua_State* L) {
    const char* value = luaL_checkstring(L, 1);
    int base = check_parse_base(L, 2, 10);

    auto* out = push_integer(L);
    if (mpz_set_str(out->value, value, base) != 0) luaL_error(L, "invalid integer string");
    return 1;
}

static int integer_from_number(lua_State* L) {
    auto* out = push_integer(L);
    mpz_set_i64(out->value, luaL_checkwholenumber64(L, 1));
    return 1;
}

static int integer_from_i64(lua_State* L) {
    auto* out = push_integer(L);
    mpz_set_i64(out->value, luaL_checkexactinteger64(L, 1));
    return 1;
}

static int integer_from_u64(lua_State* L) {
    auto* out = push_integer(L);
    mpz_set_u64(out->value, luaL_checkexactu64(L, 1));
    return 1;
}

static int integer_zero(lua_State* L) {
    push_integer(L);
    return 1;
}

static int integer_one(lua_State* L) {
    auto* out = push_integer(L);
    mpz_set_ui(out->value, 1);
    return 1;
}

static int integer_factorial(lua_State* L) {
    TempInt value;
    TempInt out;
    load_integer_operand_no_string(L, 1, value.value, "Integer or number");
    unsigned long n = check_ulong_from_integer(L, value.value, "factorial operand");
    mpz_fac_ui(out.value, n);
    return push_integer_copy(L, out.value);
}

static int integer_binomial(lua_State* L) {
    TempInt n;
    TempInt k;
    TempInt out;
    load_integer_operand_no_string(L, 1, n.value, "Integer or number");
    load_integer_operand_no_string(L, 2, k.value, "Integer or number");

    if (mpz_sgn(n.value) < 0) luaL_error(L, "n must be non-negative");
    unsigned long kValue = check_ulong_from_integer(L, k.value, "k");
    mpz_bin_ui(out.value, n.value, kValue);
    return push_integer_copy(L, out.value);
}

static int integer_is_integer(lua_State* L) {
    lua_pushboolean(L, is_integer(L, 1));
    return 1;
}

static int rational_clone(lua_State* L) {
    return push_rational_copy(L, check_rational(L, 1)->value);
}

static int rational_abs(lua_State* L) {
    TempRat out;
    mpq_abs(out.value, check_rational(L, 1)->value);
    return push_rational_copy(L, out.value);
}

static int rational_sign(lua_State* L) {
    lua_pushnumber(L, static_cast<lua_Number>(mpq_sign(check_rational(L, 1)->value)));
    return 1;
}

static int rational_cmp(lua_State* L) {
    TempRat rhs;
    load_rational_operand_no_string(L, 2, rhs.value, "Rational or number");
    lua_pushnumber(L, static_cast<lua_Number>(mpq_cmp(check_rational(L, 1)->value, rhs.value)));
    return 1;
}

static int rational_inverse(lua_State* L) {
    mpq_srcptr value = check_rational(L, 1)->value;
    if (mpq_sign(value) == 0) luaL_error(L, "cannot invert zero");

    TempRat out;
    mpq_inv(out.value, value);
    return push_rational_copy(L, out.value);
}

static int rational_canonical(lua_State* L) {
    TempRat out;
    mpq_set(out.value, check_rational(L, 1)->value);
    mpq_canonicalize(out.value);
    return push_rational_copy(L, out.value);
}

static int rational_numerator(lua_State* L) {
    return push_integer_copy(L, mpq_numref(check_rational(L, 1)->value));
}

static int rational_denominator(lua_State* L) {
    return push_integer_copy(L, mpq_denref(check_rational(L, 1)->value));
}

static int rational_is_zero(lua_State* L) {
    lua_pushboolean(L, mpq_sign(check_rational(L, 1)->value) == 0);
    return 1;
}

static int rational_is_one(lua_State* L) {
    mpq_srcptr value = check_rational(L, 1)->value;
    lua_pushboolean(L,
                    mpz_cmp_ui(mpq_numref(value), 1) == 0 && mpz_cmp_ui(mpq_denref(value), 1) == 0);
    return 1;
}

static int rational_is_integer(lua_State* L) {
    lua_pushboolean(L, mpz_cmp_ui(mpq_denref(check_rational(L, 1)->value), 1) == 0);
    return 1;
}

static int rational_floor(lua_State* L) {
    TempInt out;
    mpq_round_to_integer(out.value, check_rational(L, 1)->value, RoundMode::Floor);
    return push_integer_copy(L, out.value);
}

static int rational_ceil(lua_State* L) {
    TempInt out;
    mpq_round_to_integer(out.value, check_rational(L, 1)->value, RoundMode::Ceil);
    return push_integer_copy(L, out.value);
}

static int rational_trunc(lua_State* L) {
    TempInt out;
    mpq_round_to_integer(out.value, check_rational(L, 1)->value, RoundMode::Trunc);
    return push_integer_copy(L, out.value);
}

static int rational_round(lua_State* L) {
    TempInt out;
    mpq_round_to_integer(out.value, check_rational(L, 1)->value, check_round_mode(L, 2));
    return push_integer_copy(L, out.value);
}

static int rational_to_string(lua_State* L) {
    int base = check_format_base(L, 2, 10);
    std::string text = mpq_to_string(check_rational(L, 1)->value, base);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int rational_to_decimal(lua_State* L) {
    mpq_srcptr value = check_rational(L, 1)->value;
    size_t digits = 0;

    if (!lua_isnoneornil(L, 2)) {
        digits = static_cast<size_t>(luaL_checkwholenonu64(L, 2));
    } else if (!mpq_is_terminating_decimal(value, digits)) {
        digits = 20;
    }

    TempRat absValue;
    mpq_abs(absValue.value, value);

    TempInt scale;
    mpz_ui_pow_ui(scale.value, 10, check_ulong_from_size(L, digits, "decimal digits"));

    TempRat scaled;
    mpz_mul(mpq_numref(scaled.value), mpq_numref(absValue.value), scale.value);
    mpz_set(mpq_denref(scaled.value), mpq_denref(absValue.value));
    mpq_canonicalize(scaled.value);

    TempInt rounded;
    mpq_round_to_integer(rounded.value, scaled.value, check_round_mode(L, 3, RoundMode::Nearest));

    std::string digitsText = mpz_to_string(rounded.value, 10);
    if (digits == 0) {
        if (mpq_sign(value) < 0 && mpz_cmp_ui(rounded.value, 0) != 0)
            digitsText.insert(digitsText.begin(), '-');
        lua_pushlstring(L, digitsText.data(), digitsText.size());
        return 1;
    }

    if (digitsText.size() <= digits) {
        digitsText.insert(0, digits - digitsText.size() + 1, '0');
    }

    size_t split = digitsText.size() - digits;
    std::string out = digitsText.substr(0, split) + "." + digitsText.substr(split);
    if (mpq_sign(value) < 0 && mpz_cmp_ui(rounded.value, 0) != 0) out.insert(out.begin(), '-');
    lua_pushlstring(L, out.data(), out.size());
    return 1;
}

static int rational_to_number(lua_State* L) {
    lua_pushnumber(L, mpq_get_d(check_rational(L, 1)->value));
    return 1;
}

static int rational_to_integer(lua_State* L) {
    TempInt out;
    mpq_round_to_integer(out.value, check_rational(L, 1)->value,
                         check_round_mode(L, 2, RoundMode::Trunc));
    return push_integer_copy(L, out.value);
}

static int rational_to_float(lua_State* L) {
    mpfr_prec_t precision = check_precision(L, 2);
    mpfr_rnd_t rounding = check_mpfr_round_mode(L, 3, "Rational:toFloat");
    auto* out = push_float(L, precision);
    mpfr_set_q(out->value, check_rational(L, 1)->value, rounding);
    return 1;
}

static int rational_tostring(lua_State* L) {
    std::string text = mpq_to_string(check_rational(L, 1)->value, 10);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int rational_eq(lua_State* L) {
    if (!is_rational(L, 1) || !is_rational(L, 2)) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, mpq_equal(check_rational(L, 1)->value, check_rational(L, 2)->value) != 0);
    return 1;
}

static int rational_compare_impl(lua_State* L, bool allowEqual) {
    TempRat lhs;
    TempRat rhs;
    load_rational_operand_no_string(L, 1, lhs.value, "Rational or number");
    load_rational_operand_no_string(L, 2, rhs.value, "Rational or number");

    int cmp = mpq_cmp(lhs.value, rhs.value);
    lua_pushboolean(L, allowEqual ? cmp <= 0 : cmp < 0);
    return 1;
}

static int rational_lt(lua_State* L) { return rational_compare_impl(L, false); }
static int rational_le(lua_State* L) { return rational_compare_impl(L, true); }

static int rational_unm(lua_State* L) {
    TempRat out;
    mpq_neg(out.value, check_rational(L, 1)->value);
    return push_rational_copy(L, out.value);
}

static int rational_binary_op(lua_State* L, char op) {
    TempRat lhs;
    TempRat rhs;
    TempRat out;
    load_rational_operand_no_string(L, 1, lhs.value, "Rational or number");
    load_rational_operand_no_string(L, 2, rhs.value, "Rational or number");

    switch (op) {
        case '+':
            mpq_add(out.value, lhs.value, rhs.value);
            break;
        case '-':
            mpq_sub(out.value, lhs.value, rhs.value);
            break;
        case '*':
            mpq_mul(out.value, lhs.value, rhs.value);
            break;
        case '/':
            check_nonzero_divisor(L, rhs.value);
            mpq_div(out.value, lhs.value, rhs.value);
            break;
        default:
            luaL_error(L, "unsupported rational operator");
    }

    mpq_canonicalize(out.value);
    return push_rational_copy(L, out.value);
}

static int rational_add(lua_State* L) { return rational_binary_op(L, '+'); }
static int rational_sub(lua_State* L) { return rational_binary_op(L, '-'); }
static int rational_mul(lua_State* L) { return rational_binary_op(L, '*'); }
static int rational_div(lua_State* L) { return rational_binary_op(L, '/'); }

static int rational_idiv(lua_State* L) {
    TempRat lhs;
    TempRat rhs;
    TempRat quotient;
    TempInt out;
    load_rational_operand_no_string(L, 1, lhs.value, "Rational or number");
    load_rational_operand_no_string(L, 2, rhs.value, "Rational or number");
    check_nonzero_divisor(L, rhs.value);
    mpq_div(quotient.value, lhs.value, rhs.value);
    mpq_round_to_integer(out.value, quotient.value, RoundMode::Floor);
    return push_integer_copy(L, out.value);
}

static int rational_mod(lua_State* L) {
    TempRat lhs;
    TempRat rhs;
    TempRat quotient;
    TempRat product;
    TempRat out;
    TempInt floored;
    load_rational_operand_no_string(L, 1, lhs.value, "Rational or number");
    load_rational_operand_no_string(L, 2, rhs.value, "Rational or number");
    check_nonzero_divisor(L, rhs.value);

    mpq_div(quotient.value, lhs.value, rhs.value);
    mpq_round_to_integer(floored.value, quotient.value, RoundMode::Floor);
    mpq_set_integer(product.value, floored.value);
    mpq_mul(product.value, product.value, rhs.value);
    mpq_sub(out.value, lhs.value, product.value);
    mpq_canonicalize(out.value);
    return push_rational_copy(L, out.value);
}

static int rational_pow(lua_State* L) {
    TempInt exponent;
    TempRat out;
    load_integer_operand_no_string(L, 2, exponent.value, "Integer or number");

    TempInt magnitude;
    mpz_abs(magnitude.value, exponent.value);
    unsigned long power = check_ulong_from_integer(L, magnitude.value, "exponent");

    if (mpz_sgn(exponent.value) >= 0) {
        mpz_pow_ui(mpq_numref(out.value), mpq_numref(check_rational(L, 1)->value), power);
        mpz_pow_ui(mpq_denref(out.value), mpq_denref(check_rational(L, 1)->value), power);
    } else {
        if (mpq_sign(check_rational(L, 1)->value) == 0)
            luaL_error(L, "cannot raise zero to a negative power");
        mpz_pow_ui(mpq_numref(out.value), mpq_denref(check_rational(L, 1)->value), power);
        mpz_pow_ui(mpq_denref(out.value), mpq_numref(check_rational(L, 1)->value), power);
    }

    mpq_canonicalize(out.value);
    return push_rational_copy(L, out.value);
}

static int rational_new(lua_State* L) {
    if (lua_isnoneornil(L, 1)) {
        auto* out = push_rational(L);
        mpq_set_si(out->value, 0, 1);
        return 1;
    }

    if (lua_isnoneornil(L, 2)) {
        if (auto* rational = test_udata<LuaRational>(L, 1, RATIONAL_METATABLE)) {
            return push_rational_copy(L, rational->value);
        }

        auto* out = push_rational(L);

        if (auto* integer = test_udata<LuaInteger>(L, 1, INTEGER_METATABLE)) {
            mpq_set_integer(out->value, integer->value);
            return 1;
        }

        if (lua_type(L, 1) == LUA_TSTRING) {
            set_rational_from_string(L, out->value, lua_tostring(L, 1), 10, "rational.new");
            return 1;
        }

        mpq_set_d(out->value, luaL_checkfinitenumber(L, 1));
        mpq_canonicalize(out->value);
        return 1;
    }

    TempRat numerator;
    TempRat denominator;
    load_rational_like(L, 1, numerator.value, "rational.new");
    load_rational_like(L, 2, denominator.value, "rational.new");
    check_nonzero_divisor(L, denominator.value);

    auto* out = push_rational(L);
    mpq_div(out->value, numerator.value, denominator.value);
    mpq_canonicalize(out->value);
    return 1;
}

static int rational_from_string(lua_State* L) {
    const char* value = luaL_checkstring(L, 1);
    int base = check_parse_base(L, 2, 10);

    auto* out = push_rational(L);
    set_rational_from_string(L, out->value, value, base, "rational.fromString");
    return 1;
}

static int rational_from_decimal(lua_State* L) {
    auto* out = push_rational(L);
    set_rational_from_decimal_string(L, out->value, luaL_checkstring(L, 1), "rational.fromDecimal");
    return 1;
}

static int rational_from_float(lua_State* L) {
    auto* out = push_rational(L);
    mpq_set_d(out->value, luaL_checkfinitenumber(L, 1));
    mpq_canonicalize(out->value);
    return 1;
}

static int rational_from_integer(lua_State* L) {
    TempInt value;
    load_integer_operand_no_string(L, 1, value.value, "Integer or number");
    auto* out = push_rational(L);
    mpq_set_integer(out->value, value.value);
    return 1;
}

static int rational_zero(lua_State* L) {
    auto* out = push_rational(L);
    mpq_set_si(out->value, 0, 1);
    return 1;
}

static int rational_one(lua_State* L) {
    auto* out = push_rational(L);
    mpq_set_si(out->value, 1, 1);
    return 1;
}

static int rational_is_rational(lua_State* L) {
    lua_pushboolean(L, is_rational(L, 1));
    return 1;
}

static int float_clone(lua_State* L) { return push_float_copy(L, check_float(L, 1)->value); }

static int float_abs(lua_State* L) {
    mpfr_prec_t precision = mpfr_get_prec(check_float(L, 1)->value);
    auto* out = push_float(L, precision);
    mpfr_abs(out->value, check_float(L, 1)->value, MPFR_RNDN);
    return 1;
}

static int float_sign(lua_State* L) {
    mpfr_srcptr value = check_float(L, 1)->value;
    if (mpfr_nan_p(value)) luaL_error(L, "sign is undefined for NaN");
    lua_pushnumber(L, static_cast<lua_Number>(mpfr_sgn(value)));
    return 1;
}

static int float_cmp(lua_State* L) {
    TempFloat rhs(
        max_precision(mpfr_get_prec(check_float(L, 1)->value), float_operand_precision(L, 2)));
    load_float_operand_no_string(L, 2, rhs.value, MPFR_RNDN, "Float or number");

    mpfr_srcptr lhs = check_float(L, 1)->value;
    if (mpfr_nan_p(lhs) || mpfr_nan_p(rhs.value)) luaL_error(L, "comparison with NaN");

    lua_pushnumber(L, static_cast<lua_Number>(mpfr_cmp(lhs, rhs.value)));
    return 1;
}

static int float_sqrt(lua_State* L) {
    mpfr_prec_t precision = mpfr_get_prec(check_float(L, 1)->value);
    auto* out = push_float(L, precision);
    mpfr_sqrt(out->value, check_float(L, 1)->value, MPFR_RNDN);
    return 1;
}

static int float_floor(lua_State* L) {
    TempInt out;
    mpfr_round_to_integer(L, out.value, check_float(L, 1)->value, RoundMode::Floor);
    return push_integer_copy(L, out.value);
}

static int float_ceil(lua_State* L) {
    TempInt out;
    mpfr_round_to_integer(L, out.value, check_float(L, 1)->value, RoundMode::Ceil);
    return push_integer_copy(L, out.value);
}

static int float_trunc(lua_State* L) {
    TempInt out;
    mpfr_round_to_integer(L, out.value, check_float(L, 1)->value, RoundMode::Trunc);
    return push_integer_copy(L, out.value);
}

static int float_round(lua_State* L) {
    TempInt out;
    mpfr_round_to_integer(L, out.value, check_float(L, 1)->value, check_round_mode(L, 2));
    return push_integer_copy(L, out.value);
}

static int float_precision(lua_State* L) {
    lua_pushnumber(L, static_cast<lua_Number>(mpfr_get_prec(check_float(L, 1)->value)));
    return 1;
}

static int float_with_precision(lua_State* L) {
    mpfr_prec_t precision = check_precision(L, 2);
    mpfr_rnd_t rounding = check_mpfr_round_mode(L, 3, "Float:withPrecision");
    auto* out = push_float(L, precision);
    mpfr_set(out->value, check_float(L, 1)->value, rounding);
    return 1;
}

static int float_is_zero(lua_State* L) {
    lua_pushboolean(L, mpfr_zero_p(check_float(L, 1)->value) != 0);
    return 1;
}

static int float_is_finite(lua_State* L) {
    lua_pushboolean(L, mpfr_number_p(check_float(L, 1)->value) != 0);
    return 1;
}

static int float_is_nan(lua_State* L) {
    lua_pushboolean(L, mpfr_nan_p(check_float(L, 1)->value) != 0);
    return 1;
}

static int float_is_infinite(lua_State* L) {
    lua_pushboolean(L, mpfr_inf_p(check_float(L, 1)->value) != 0);
    return 1;
}

static int float_to_string(lua_State* L) {
    int base = check_format_base(L, 2, 10);
    bool digitsExplicit = !lua_isnoneornil(L, 3);
    size_t digits = digitsExplicit ? static_cast<size_t>(luaL_checkwholenonu64(L, 3)) : 0;
    std::string text = mpfr_to_string(L, check_float(L, 1)->value, base, digits, digitsExplicit);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int float_to_number(lua_State* L) {
    lua_pushnumber(L, mpfr_get_d(check_float(L, 1)->value, MPFR_RNDN));
    return 1;
}

static int float_to_integer(lua_State* L) {
    TempInt out;
    mpfr_round_to_integer(L, out.value, check_float(L, 1)->value,
                          check_round_mode(L, 2, RoundMode::Trunc));
    return push_integer_copy(L, out.value);
}

static int float_tostring(lua_State* L) {
    std::string text = mpfr_to_string(L, check_float(L, 1)->value, 10, 0, false);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int float_eq(lua_State* L) {
    if (!is_float(L, 1) || !is_float(L, 2)) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, mpfr_equal_p(check_float(L, 1)->value, check_float(L, 2)->value) != 0);
    return 1;
}

static int float_compare_impl(lua_State* L, bool allowEqual) {
    mpfr_prec_t precision =
        max_precision(float_operand_precision(L, 1), float_operand_precision(L, 2));
    TempFloat lhs(precision);
    TempFloat rhs(precision);
    load_float_operand_no_string(L, 1, lhs.value, MPFR_RNDN, "Float or number");
    load_float_operand_no_string(L, 2, rhs.value, MPFR_RNDN, "Float or number");

    if (mpfr_nan_p(lhs.value) || mpfr_nan_p(rhs.value)) {
        lua_pushboolean(L, false);
        return 1;
    }

    int cmp = mpfr_cmp(lhs.value, rhs.value);
    lua_pushboolean(L, allowEqual ? cmp <= 0 : cmp < 0);
    return 1;
}

static int float_lt(lua_State* L) { return float_compare_impl(L, false); }
static int float_le(lua_State* L) { return float_compare_impl(L, true); }

static int float_unm(lua_State* L) {
    mpfr_prec_t precision = mpfr_get_prec(check_float(L, 1)->value);
    auto* out = push_float(L, precision);
    mpfr_neg(out->value, check_float(L, 1)->value, MPFR_RNDN);
    return 1;
}

static int float_binary_op(lua_State* L, char op) {
    mpfr_prec_t precision =
        max_precision(float_operand_precision(L, 1), float_operand_precision(L, 2));
    TempFloat lhs(precision);
    TempFloat rhs(precision);
    TempFloat out(precision);
    load_float_operand_no_string(L, 1, lhs.value, MPFR_RNDN, "Float or number");
    load_float_operand_no_string(L, 2, rhs.value, MPFR_RNDN, "Float or number");

    switch (op) {
        case '+':
            mpfr_add(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '-':
            mpfr_sub(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '*':
            mpfr_mul(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '/':
            check_nonzero_divisor(L, rhs.value);
            mpfr_div(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '%': {
            check_nonzero_divisor(L, rhs.value);
            TempFloat quotient(precision);
            TempFloat product(precision);
            TempFloat qFloat(precision);
            TempInt floored;
            mpfr_div(quotient.value, lhs.value, rhs.value, MPFR_RNDN);
            mpfr_round_to_integer(L, floored.value, quotient.value, RoundMode::Floor);
            mpfr_set_z(qFloat.value, floored.value, MPFR_RNDN);
            mpfr_mul(product.value, qFloat.value, rhs.value, MPFR_RNDN);
            mpfr_sub(out.value, lhs.value, product.value, MPFR_RNDN);
            break;
        }
        case '^':
            mpfr_pow(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        default:
            luaL_error(L, "unsupported float operator");
    }

    return push_float_copy(L, out.value);
}

static int float_add(lua_State* L) { return float_binary_op(L, '+'); }
static int float_sub(lua_State* L) { return float_binary_op(L, '-'); }
static int float_mul(lua_State* L) { return float_binary_op(L, '*'); }
static int float_div(lua_State* L) { return float_binary_op(L, '/'); }
static int float_mod(lua_State* L) { return float_binary_op(L, '%'); }
static int float_pow(lua_State* L) { return float_binary_op(L, '^'); }

static int float_idiv(lua_State* L) {
    mpfr_prec_t precision =
        max_precision(float_operand_precision(L, 1), float_operand_precision(L, 2));
    TempFloat lhs(precision);
    TempFloat rhs(precision);
    TempFloat quotient(precision);
    TempInt out;
    load_float_operand_no_string(L, 1, lhs.value, MPFR_RNDN, "Float or number");
    load_float_operand_no_string(L, 2, rhs.value, MPFR_RNDN, "Float or number");
    check_nonzero_divisor(L, rhs.value);
    mpfr_div(quotient.value, lhs.value, rhs.value, MPFR_RNDN);
    mpfr_round_to_integer(L, out.value, quotient.value, RoundMode::Floor);
    return push_integer_copy(L, out.value);
}

static int float_new(lua_State* L) {
    if (lua_isnoneornil(L, 1)) {
        push_float(L, check_precision(L, 2));
        return 1;
    }

    if (auto* existing = test_udata<LuaFloat>(L, 1, FLOAT_METATABLE)) {
        mpfr_prec_t precision =
            lua_isnoneornil(L, 2) ? mpfr_get_prec(existing->value) : check_precision(L, 2);
        auto* out = push_float(L, precision);
        mpfr_set(out->value, existing->value, MPFR_RNDN);
        return 1;
    }

    mpfr_prec_t precision = check_precision(L, 2);
    auto* out = push_float(L, precision);

    if (lua_type(L, 1) == LUA_TSTRING) {
        if (mpfr_set_str(out->value, lua_tostring(L, 1), 10, MPFR_RNDN) != 0)
            luaL_error(L, "invalid float string");
        return 1;
    }

    if (!lua_isnumber(L, 1)) luaL_typeerror(L, 1, "Float, number, or string");
    mpfr_set_d(out->value, luaL_checknumber(L, 1), MPFR_RNDN);
    return 1;
}

static int float_from_string(lua_State* L) {
    const char* value = luaL_checkstring(L, 1);
    int base = check_parse_base(L, 2, 10);
    mpfr_prec_t precision = check_precision(L, 3);

    auto* out = push_float(L, precision);
    if (mpfr_set_str(out->value, value, base, MPFR_RNDN) != 0)
        luaL_error(L, "invalid float string");
    return 1;
}

static int float_from_number(lua_State* L) {
    auto* out = push_float(L, check_precision(L, 2));
    mpfr_set_d(out->value, luaL_checknumber(L, 1), MPFR_RNDN);
    return 1;
}

static int float_from_integer(lua_State* L) {
    TempInt value;
    load_integer_operand_no_string(L, 1, value.value, "Integer or number");
    auto* out = push_float(L, check_precision(L, 2));
    mpfr_set_z(out->value, value.value, MPFR_RNDN);
    return 1;
}

static int float_from_rational(lua_State* L) {
    mpfr_prec_t precision = check_precision(L, 2);
    mpfr_rnd_t rounding = check_mpfr_round_mode(L, 3, "float.fromRational");
    auto* out = push_float(L, precision);
    mpfr_set_q(out->value, check_rational(L, 1)->value, rounding);
    return 1;
}

static int float_default_precision(lua_State* L) {
    lua_pushnumber(L, static_cast<lua_Number>(mpfr_get_default_prec()));
    return 1;
}

static int float_set_default_precision(lua_State* L) {
    mpfr_set_default_prec(check_precision(L, 1));
    return 0;
}

static int float_zero(lua_State* L) {
    push_float(L, check_precision(L, 1));
    return 1;
}

static int float_one(lua_State* L) {
    auto* out = push_float(L, check_precision(L, 1));
    mpfr_set_ui(out->value, 1, MPFR_RNDN);
    return 1;
}

static int float_is_float(lua_State* L) {
    lua_pushboolean(L, is_float(L, 1));
    return 1;
}

static int number_compare(lua_State* L, int lhsIndex, int rhsIndex, bool* sawNaN = nullptr) {
    if (sawNaN != nullptr) *sawNaN = false;

    NumberKind lhsKind = classify_number_operand(L, lhsIndex, "Number or number");
    NumberKind rhsKind = classify_number_operand(L, rhsIndex, "Number or number");

    if (lhsKind == NumberKind::Integer && rhsKind == NumberKind::Integer) {
        TempInt lhs;
        TempInt rhs;
        load_number_integer_operand_no_string(L, lhsIndex, lhs.value, "Number or number");
        load_number_integer_operand_no_string(L, rhsIndex, rhs.value, "Number or number");
        return mpz_cmp(lhs.value, rhs.value);
    }

    if (lhsKind == NumberKind::Float && rhsKind == NumberKind::Float) {
        mpfr_prec_t precision = number_float_result_precision(L, lhsIndex, rhsIndex);
        TempFloat lhs(precision);
        TempFloat rhs(precision);
        load_number_float_operand_no_string(L, lhsIndex, lhs.value, MPFR_RNDN, "Number or number");
        load_number_float_operand_no_string(L, rhsIndex, rhs.value, MPFR_RNDN, "Number or number");

        if (mpfr_nan_p(lhs.value) || mpfr_nan_p(rhs.value)) {
            if (sawNaN != nullptr) *sawNaN = true;
            return 0;
        }

        return mpfr_cmp(lhs.value, rhs.value);
    }

    if (lhsKind == NumberKind::Float) {
        mpfr_prec_t precision = number_float_result_precision(L, lhsIndex, rhsIndex);
        TempFloat lhs(precision);
        TempInt rhs;
        load_number_float_operand_no_string(L, lhsIndex, lhs.value, MPFR_RNDN, "Number or number");
        load_number_integer_operand_no_string(L, rhsIndex, rhs.value, "Number or number");

        if (mpfr_nan_p(lhs.value)) {
            if (sawNaN != nullptr) *sawNaN = true;
            return 0;
        }

        return mpfr_cmp_z(lhs.value, rhs.value);
    }

    mpfr_prec_t precision = number_float_result_precision(L, lhsIndex, rhsIndex);
    TempInt lhs;
    TempFloat rhs(precision);
    load_number_integer_operand_no_string(L, lhsIndex, lhs.value, "Number or number");
    load_number_float_operand_no_string(L, rhsIndex, rhs.value, MPFR_RNDN, "Number or number");

    if (mpfr_nan_p(rhs.value)) {
        if (sawNaN != nullptr) *sawNaN = true;
        return 0;
    }

    return -mpfr_cmp_z(rhs.value, lhs.value);
}

static bool number_binary_uses_float(lua_State* L) {
    return classify_number_operand(L, 1, "Number or number") == NumberKind::Float ||
           classify_number_operand(L, 2, "Number or number") == NumberKind::Float;
}

static int number_clone(lua_State* L) { return push_number_copy(L, check_number(L, 1)); }

static int number_kind(lua_State* L) {
    lua_pushstring(L, check_number(L, 1)->kind == NumberKind::Integer ? "integer" : "float");
    return 1;
}

static int number_is_integer_kind(lua_State* L) {
    lua_pushboolean(L, check_number(L, 1)->kind == NumberKind::Integer);
    return 1;
}

static int number_is_float_kind(lua_State* L) {
    lua_pushboolean(L, check_number(L, 1)->kind == NumberKind::Float);
    return 1;
}

static int number_integer_value(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind != NumberKind::Integer) {
        lua_pushnil(L);
        return 1;
    }

    return push_integer_copy(L, number->integerValue);
}

static int number_float_value(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind != NumberKind::Float) {
        lua_pushnil(L);
        return 1;
    }

    return push_float_copy(L, number->floatValue);
}

static int number_abs(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) {
        TempInt out;
        mpz_abs(out.value, number->integerValue);
        return push_number_integer_copy(L, out.value);
    }

    auto* out = push_number_float(L, mpfr_get_prec(number->floatValue));
    mpfr_abs(out->floatValue, number->floatValue, MPFR_RNDN);
    return 1;
}

static int number_sign(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) {
        lua_pushnumber(L, static_cast<lua_Number>(mpz_sgn(number->integerValue)));
        return 1;
    }

    if (mpfr_nan_p(number->floatValue)) luaL_error(L, "cannot determine the sign of NaN");
    lua_pushnumber(L, static_cast<lua_Number>(mpfr_sgn(number->floatValue)));
    return 1;
}

static int number_cmp(lua_State* L) {
    bool sawNaN = false;
    int cmp = number_compare(L, 1, 2, &sawNaN);
    if (sawNaN) luaL_error(L, "cannot compare NaN");
    lua_pushnumber(L, static_cast<lua_Number>(cmp));
    return 1;
}

static int number_floor(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer)
        return push_number_integer_copy(L, number->integerValue);

    TempInt out;
    mpfr_round_to_integer(L, out.value, number->floatValue, RoundMode::Floor);
    return push_number_integer_copy(L, out.value);
}

static int number_ceil(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer)
        return push_number_integer_copy(L, number->integerValue);

    TempInt out;
    mpfr_round_to_integer(L, out.value, number->floatValue, RoundMode::Ceil);
    return push_number_integer_copy(L, out.value);
}

static int number_trunc(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer)
        return push_number_integer_copy(L, number->integerValue);

    TempInt out;
    mpfr_round_to_integer(L, out.value, number->floatValue, RoundMode::Trunc);
    return push_number_integer_copy(L, out.value);
}

static int number_round(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer)
        return push_number_integer_copy(L, number->integerValue);

    TempInt out;
    mpfr_round_to_integer(L, out.value, number->floatValue, check_round_mode(L, 2));
    return push_number_integer_copy(L, out.value);
}

static int number_to_string(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) {
        int base = check_format_base(L, 2, 10);
        std::string text = mpz_to_string(number->integerValue, base);
        lua_pushlstring(L, text.data(), text.size());
        return 1;
    }

    int base = check_format_base(L, 2, 10);
    bool digitsExplicit = !lua_isnoneornil(L, 3);
    size_t digits = digitsExplicit ? static_cast<size_t>(luaL_checkwholenonu64(L, 3)) : 0;
    std::string text = mpfr_to_string(L, number->floatValue, base, digits, digitsExplicit);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int number_to_number(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) {
        lua_pushnumber(L, mpz_get_exact_number(L, number->integerValue));
    } else {
        lua_pushnumber(L, mpfr_get_d(number->floatValue, MPFR_RNDN));
    }
    return 1;
}

static int number_to_integer(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) return push_integer_copy(L, number->integerValue);

    TempInt out;
    mpfr_round_to_integer(L, out.value, number->floatValue,
                          check_round_mode(L, 2, RoundMode::Trunc));
    return push_integer_copy(L, out.value);
}

static int number_to_float(lua_State* L) {
    auto* number = check_number(L, 1);
    mpfr_rnd_t rounding = check_mpfr_round_mode(L, 3, "Number:toFloat");

    if (number->kind == NumberKind::Float) {
        mpfr_prec_t precision =
            lua_isnoneornil(L, 2) ? mpfr_get_prec(number->floatValue) : check_precision(L, 2);
        auto* out = push_float(L, precision);
        mpfr_set(out->value, number->floatValue, rounding);
        return 1;
    }

    auto* out = push_float(L, check_precision(L, 2));
    mpfr_set_z(out->value, number->integerValue, rounding);
    return 1;
}

static int number_tostring(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) {
        std::string text = mpz_to_string(number->integerValue, 10);
        lua_pushlstring(L, text.data(), text.size());
        return 1;
    }

    std::string text = mpfr_to_string(L, number->floatValue, 10, 0, false);
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int number_eq(lua_State* L) {
    if (!is_number(L, 1) || !is_number(L, 2)) {
        lua_pushboolean(L, false);
        return 1;
    }

    auto* lhs = check_number(L, 1);
    auto* rhs = check_number(L, 2);

    if (lhs->kind == NumberKind::Integer && rhs->kind == NumberKind::Integer) {
        lua_pushboolean(L, mpz_cmp(lhs->integerValue, rhs->integerValue) == 0);
        return 1;
    }

    if (lhs->kind == NumberKind::Float && rhs->kind == NumberKind::Float) {
        lua_pushboolean(L, mpfr_equal_p(lhs->floatValue, rhs->floatValue) != 0);
        return 1;
    }

    if (lhs->kind == NumberKind::Float) {
        if (mpfr_nan_p(lhs->floatValue)) {
            lua_pushboolean(L, false);
            return 1;
        }
        lua_pushboolean(L, mpfr_cmp_z(lhs->floatValue, rhs->integerValue) == 0);
        return 1;
    }

    if (mpfr_nan_p(rhs->floatValue)) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, mpfr_cmp_z(rhs->floatValue, lhs->integerValue) == 0);
    return 1;
}

static int number_compare_impl(lua_State* L, bool allowEqual) {
    bool sawNaN = false;
    int cmp = number_compare(L, 1, 2, &sawNaN);
    if (sawNaN) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, allowEqual ? cmp <= 0 : cmp < 0);
    return 1;
}

static int number_lt(lua_State* L) { return number_compare_impl(L, false); }
static int number_le(lua_State* L) { return number_compare_impl(L, true); }

static int number_unm(lua_State* L) {
    auto* number = check_number(L, 1);
    if (number->kind == NumberKind::Integer) {
        TempInt out;
        mpz_neg(out.value, number->integerValue);
        return push_number_integer_copy(L, out.value);
    }

    auto* out = push_number_float(L, mpfr_get_prec(number->floatValue));
    mpfr_neg(out->floatValue, number->floatValue, MPFR_RNDN);
    return 1;
}

static int number_integer_binary_op(lua_State* L, char op) {
    TempInt lhs;
    TempInt rhs;
    TempInt out;
    load_number_integer_operand_no_string(L, 1, lhs.value, "Number or number");
    load_number_integer_operand_no_string(L, 2, rhs.value, "Number or number");

    switch (op) {
        case '+':
            mpz_add(out.value, lhs.value, rhs.value);
            break;
        case '-':
            mpz_sub(out.value, lhs.value, rhs.value);
            break;
        case '*':
            mpz_mul(out.value, lhs.value, rhs.value);
            break;
        case '/':
            check_nonzero_divisor(L, rhs.value);
            mpz_fdiv_q(out.value, lhs.value, rhs.value);
            break;
        case '%':
            check_nonzero_divisor(L, rhs.value);
            mpz_fdiv_r(out.value, lhs.value, rhs.value);
            break;
        case '^': {
            unsigned long power = check_ulong_from_integer(L, rhs.value, "exponent");
            mpz_pow_ui(out.value, lhs.value, power);
            break;
        }
        default:
            luaL_error(L, "unsupported Number integer operator");
    }

    return push_number_integer_copy(L, out.value);
}

static int number_float_binary_op(lua_State* L, char op) {
    mpfr_prec_t precision = number_float_result_precision(L, 1, 2);
    TempFloat lhs(precision);
    TempFloat rhs(precision);
    TempFloat out(precision);
    load_number_float_operand_no_string(L, 1, lhs.value, MPFR_RNDN, "Number or number");
    load_number_float_operand_no_string(L, 2, rhs.value, MPFR_RNDN, "Number or number");

    switch (op) {
        case '+':
            mpfr_add(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '-':
            mpfr_sub(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '*':
            mpfr_mul(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '/':
            check_nonzero_divisor(L, rhs.value);
            mpfr_div(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case '%': {
            check_nonzero_divisor(L, rhs.value);
            TempFloat quotient(precision);
            TempFloat product(precision);
            TempFloat qFloat(precision);
            TempInt floored;
            mpfr_div(quotient.value, lhs.value, rhs.value, MPFR_RNDN);
            mpfr_round_to_integer(L, floored.value, quotient.value, RoundMode::Floor);
            mpfr_set_z(qFloat.value, floored.value, MPFR_RNDN);
            mpfr_mul(product.value, qFloat.value, rhs.value, MPFR_RNDN);
            mpfr_sub(out.value, lhs.value, product.value, MPFR_RNDN);
            break;
        }
        case '^':
            mpfr_pow(out.value, lhs.value, rhs.value, MPFR_RNDN);
            break;
        case 'Q': {
            check_nonzero_divisor(L, rhs.value);
            TempFloat quotient(precision);
            TempInt floored;
            mpfr_div(quotient.value, lhs.value, rhs.value, MPFR_RNDN);
            mpfr_round_to_integer(L, floored.value, quotient.value, RoundMode::Floor);
            mpfr_set_z(out.value, floored.value, MPFR_RNDN);
            break;
        }
        default:
            luaL_error(L, "unsupported Number float operator");
    }

    return push_number_float_copy(L, out.value);
}

static int number_float_idiv(lua_State* L) {
    mpfr_prec_t precision = number_float_result_precision(L, 1, 2);
    TempFloat lhs(precision);
    TempFloat rhs(precision);
    TempFloat quotient(precision);
    TempInt out;
    load_number_float_operand_no_string(L, 1, lhs.value, MPFR_RNDN, "Number or number");
    load_number_float_operand_no_string(L, 2, rhs.value, MPFR_RNDN, "Number or number");
    check_nonzero_divisor(L, rhs.value);
    mpfr_div(quotient.value, lhs.value, rhs.value, MPFR_RNDN);
    mpfr_round_to_integer(L, out.value, quotient.value, RoundMode::Floor);
    return push_number_integer_copy(L, out.value);
}

static int number_add(lua_State* L) {
    return number_binary_uses_float(L) ? number_float_binary_op(L, '+')
                                       : number_integer_binary_op(L, '+');
}

static int number_sub(lua_State* L) {
    return number_binary_uses_float(L) ? number_float_binary_op(L, '-')
                                       : number_integer_binary_op(L, '-');
}

static int number_mul(lua_State* L) {
    return number_binary_uses_float(L) ? number_float_binary_op(L, '*')
                                       : number_integer_binary_op(L, '*');
}

static int number_div(lua_State* L) { return number_float_binary_op(L, '/'); }

static int number_idiv(lua_State* L) {
    return number_binary_uses_float(L) ? number_float_idiv(L) : number_integer_binary_op(L, '/');
}

static int number_mod(lua_State* L) {
    return number_binary_uses_float(L) ? number_float_binary_op(L, '%')
                                       : number_integer_binary_op(L, '%');
}

static int number_pow(lua_State* L) {
    if (!number_binary_uses_float(L)) {
        TempInt exponent;
        load_number_integer_operand_no_string(L, 2, exponent.value, "Number or number");
        if (mpz_sgn(exponent.value) >= 0) return number_integer_binary_op(L, '^');
    }

    return number_float_binary_op(L, '^');
}

static int number_new(lua_State* L) {
    if (lua_isnoneornil(L, 1)) {
        push_number_integer(L);
        return 1;
    }

    if (auto* number = test_udata<LuaNumber>(L, 1, NUMBER_METATABLE)) {
        if (number->kind == NumberKind::Integer)
            return push_number_integer_copy(L, number->integerValue);

        mpfr_prec_t precision =
            lua_isnoneornil(L, 2) ? mpfr_get_prec(number->floatValue) : check_precision(L, 2);
        auto* out = push_number_float(L, precision);
        mpfr_set(out->floatValue, number->floatValue, MPFR_RNDN);
        return 1;
    }

    if (auto* integer = test_udata<LuaInteger>(L, 1, INTEGER_METATABLE))
        return push_number_integer_copy(L, integer->value);

    if (auto* floatValue = test_udata<LuaFloat>(L, 1, FLOAT_METATABLE)) {
        mpfr_prec_t precision =
            lua_isnoneornil(L, 2) ? mpfr_get_prec(floatValue->value) : check_precision(L, 2);
        auto* out = push_number_float(L, precision);
        mpfr_set(out->floatValue, floatValue->value, MPFR_RNDN);
        return 1;
    }

    if (lua_type(L, 1) == LUA_TSTRING) {
        const char* value = lua_tostring(L, 1);
        TempInt integerValue;
        if (mpz_set_str(integerValue.value, value, 10) == 0)
            return push_number_integer_copy(L, integerValue.value);

        auto* out = push_number_float(L, check_precision(L, 2));
        if (mpfr_set_str(out->floatValue, value, 10, MPFR_RNDN) != 0)
            luaL_error(L, "invalid dynamic number string");
        return 1;
    }

    if (!lua_isnumber(L, 1)) luaL_typeerror(L, 1, "Number, Integer, Float, number, or string");

    int64_t whole = 0;
    if (try_get_whole_number64(L, 1, whole)) {
        auto* out = push_number_integer(L);
        mpz_set_i64(out->integerValue, whole);
        return 1;
    }

    auto* out = push_number_float(L, check_precision(L, 2));
    mpfr_set_d(out->floatValue, luaL_checknumber(L, 1), MPFR_RNDN);
    return 1;
}

static int number_from_string(lua_State* L) {
    const char* value = luaL_checkstring(L, 1);
    int base = check_parse_base(L, 2, 10);

    TempInt integerValue;
    if (mpz_set_str(integerValue.value, value, base) == 0)
        return push_number_integer_copy(L, integerValue.value);

    auto* out = push_number_float(L, check_precision(L, 3));
    if (mpfr_set_str(out->floatValue, value, base, MPFR_RNDN) != 0)
        luaL_error(L, "invalid dynamic number string");
    return 1;
}

static int number_from_number(lua_State* L) {
    int64_t whole = 0;
    if (try_get_whole_number64(L, 1, whole)) {
        auto* out = push_number_integer(L);
        mpz_set_i64(out->integerValue, whole);
        return 1;
    }

    auto* out = push_number_float(L, check_precision(L, 2));
    mpfr_set_d(out->floatValue, luaL_checknumber(L, 1), MPFR_RNDN);
    return 1;
}

static int number_from_integer(lua_State* L) {
    if (auto* integer = test_udata<LuaInteger>(L, 1, INTEGER_METATABLE))
        return push_number_integer_copy(L, integer->value);

    auto* out = push_number_integer(L);
    mpz_set_i64(out->integerValue, luaL_checkwholenumber64(L, 1));
    return 1;
}

static int number_from_float(lua_State* L) {
    if (auto* floatValue = test_udata<LuaFloat>(L, 1, FLOAT_METATABLE)) {
        mpfr_prec_t precision =
            lua_isnoneornil(L, 2) ? mpfr_get_prec(floatValue->value) : check_precision(L, 2);
        auto* out = push_number_float(L, precision);
        mpfr_set(out->floatValue, floatValue->value, MPFR_RNDN);
        return 1;
    }

    auto* out = push_number_float(L, check_precision(L, 2));
    mpfr_set_d(out->floatValue, luaL_checknumber(L, 1), MPFR_RNDN);
    return 1;
}

static int number_zero(lua_State* L) {
    push_number_integer(L);
    return 1;
}

static int number_one(lua_State* L) {
    auto* out = push_number_integer(L);
    mpz_set_ui(out->integerValue, 1);
    return 1;
}

static int number_is_number(lua_State* L) {
    lua_pushboolean(L, is_number(L, 1));
    return 1;
}

static luaL_Reg integerMethods[] = {
    { "clone", integer_clone },
    { "abs", integer_abs },
    { "sign", integer_sign },
    { "cmp", integer_cmp },
    { "isZero", integer_is_zero },
    { "isOne", integer_is_one },
    { "isEven", integer_is_even },
    { "isOdd", integer_is_odd },
    { "divTrunc", integer_div_trunc },
    { "divFloor", integer_div_floor },
    { "divCeil", integer_div_ceil },
    { "divmod", integer_divmod },
    { "gcd", integer_gcd },
    { "lcm", integer_lcm },
    { "extendedGcd", integer_extended_gcd },
    { "pow", integer_pow },
    { "modPow", integer_mod_pow },
    { "modInverse", integer_mod_inverse },
    { "isProbablePrime", integer_is_probable_prime },
    { "nextPrime", integer_next_prime },
    { "bitLength", integer_bit_length },
    { "popcount", integer_popcount },
    { "testBit", integer_test_bit },
    { "setBit", integer_set_bit },
    { "clearBit", integer_clear_bit },
    { "flipBit", integer_flip_bit },
    { "band", integer_band },
    { "bor", integer_bor },
    { "bxor", integer_bxor },
    { "bnot", integer_bnot },
    { "shl", integer_shl },
    { "shr", integer_shr },
    { "toString", integer_to_string },
    { "toNumber", integer_to_number },
    { "toRational", integer_to_rational },
    { "toFloat", integer_to_float },
    { "toI64", integer_to_i64 },
    { "toU64", integer_to_u64 },
    { "fitsNumber", integer_fits_number },
    { "fitsI64", integer_fits_i64 },
    { "fitsU64", integer_fits_u64 },
    { nullptr, nullptr },
};

static luaL_Reg integerMetamethods[] = {
    { "__tostring", integer_tostring },
    { "__eq", integer_eq },
    { "__lt", integer_lt },
    { "__le", integer_le },
    { "__unm", integer_unm },
    { "__add", integer_add },
    { "__sub", integer_sub },
    { "__mul", integer_mul },
    { "__idiv", integer_idiv },
    { "__mod", integer_mod },
    { "__pow", integer_pow_metamethod },
    { nullptr, nullptr },
};

static udataDef integerDef = {
    .name = INTEGER_METATABLE,
    .size = sizeof(LuaInteger),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = integerMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = integerMethods,
    .destructor = integer_dtor,
};

static luaL_Reg rationalMethods[] = {
    { "clone", rational_clone },
    { "abs", rational_abs },
    { "sign", rational_sign },
    { "cmp", rational_cmp },
    { "inverse", rational_inverse },
    { "canonical", rational_canonical },
    { "numerator", rational_numerator },
    { "denominator", rational_denominator },
    { "isZero", rational_is_zero },
    { "isOne", rational_is_one },
    { "isInteger", rational_is_integer },
    { "floor", rational_floor },
    { "ceil", rational_ceil },
    { "trunc", rational_trunc },
    { "round", rational_round },
    { "toString", rational_to_string },
    { "toDecimal", rational_to_decimal },
    { "toNumber", rational_to_number },
    { "toInteger", rational_to_integer },
    { "toFloat", rational_to_float },
    { nullptr, nullptr },
};

static luaL_Reg rationalMetamethods[] = {
    { "__tostring", rational_tostring },
    { "__eq", rational_eq },
    { "__lt", rational_lt },
    { "__le", rational_le },
    { "__unm", rational_unm },
    { "__add", rational_add },
    { "__sub", rational_sub },
    { "__mul", rational_mul },
    { "__div", rational_div },
    { "__idiv", rational_idiv },
    { "__mod", rational_mod },
    { "__pow", rational_pow },
    { nullptr, nullptr },
};

static udataDef rationalDef = {
    .name = RATIONAL_METATABLE,
    .size = sizeof(LuaRational),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = rationalMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = rationalMethods,
    .destructor = rational_dtor,
};

static luaL_Reg floatMethods[] = {
    { "clone", float_clone },
    { "abs", float_abs },
    { "sign", float_sign },
    { "cmp", float_cmp },
    { "sqrt", float_sqrt },
    { "floor", float_floor },
    { "ceil", float_ceil },
    { "trunc", float_trunc },
    { "round", float_round },
    { "precision", float_precision },
    { "withPrecision", float_with_precision },
    { "isZero", float_is_zero },
    { "isFinite", float_is_finite },
    { "isNaN", float_is_nan },
    { "isInfinite", float_is_infinite },
    { "toString", float_to_string },
    { "toNumber", float_to_number },
    { "toInteger", float_to_integer },
    { nullptr, nullptr },
};

static luaL_Reg floatMetamethods[] = {
    { "__tostring", float_tostring },
    { "__eq", float_eq },
    { "__lt", float_lt },
    { "__le", float_le },
    { "__unm", float_unm },
    { "__add", float_add },
    { "__sub", float_sub },
    { "__mul", float_mul },
    { "__div", float_div },
    { "__idiv", float_idiv },
    { "__mod", float_mod },
    { "__pow", float_pow },
    { nullptr, nullptr },
};

static udataDef floatDef = {
    .name = FLOAT_METATABLE,
    .size = sizeof(LuaFloat),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = floatMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = floatMethods,
    .destructor = float_dtor,
};

static luaL_Reg numberMethods[] = {
    { "clone", number_clone },
    { "kind", number_kind },
    { "isInteger", number_is_integer_kind },
    { "isFloat", number_is_float_kind },
    { "integer", number_integer_value },
    { "float", number_float_value },
    { "abs", number_abs },
    { "sign", number_sign },
    { "cmp", number_cmp },
    { "floor", number_floor },
    { "ceil", number_ceil },
    { "trunc", number_trunc },
    { "round", number_round },
    { "toString", number_to_string },
    { "toNumber", number_to_number },
    { "toInteger", number_to_integer },
    { "toFloat", number_to_float },
    { nullptr, nullptr },
};

static luaL_Reg numberMetamethods[] = {
    { "__tostring", number_tostring },
    { "__eq", number_eq },
    { "__lt", number_lt },
    { "__le", number_le },
    { "__unm", number_unm },
    { "__add", number_add },
    { "__sub", number_sub },
    { "__mul", number_mul },
    { "__div", number_div },
    { "__idiv", number_idiv },
    { "__mod", number_mod },
    { "__pow", number_pow },
    { nullptr, nullptr },
};

static udataDef numberDef = {
    .name = NUMBER_METATABLE,
    .size = sizeof(LuaNumber),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = numberMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = numberMethods,
    .destructor = number_dtor,
};

static void set_function(lua_State* L, const char* name, lua_CFunction function) {
    lua_pushcfunction(L, function, name);
    lua_setfield(L, -2, name);
}

}  // namespace

LUAU_MODULE_EXPORT int luauopen_number(lua_State* L) {
    eryxUdata_registerudata(L, &integerDef);
    eryxUdata_registerudata(L, &rationalDef);
    eryxUdata_registerudata(L, &floatDef);
    eryxUdata_registerudata(L, &numberDef);
    lua_newtable(L);

    lua_newtable(L);
    set_function(L, "new", integer_new);
    set_function(L, "fromString", integer_from_string);
    set_function(L, "fromNumber", integer_from_number);
    set_function(L, "fromI64", integer_from_i64);
    set_function(L, "fromU64", integer_from_u64);
    set_function(L, "zero", integer_zero);
    set_function(L, "one", integer_one);
    set_function(L, "factorial", integer_factorial);
    set_function(L, "binomial", integer_binomial);
    set_function(L, "isInteger", integer_is_integer);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "integer");

    lua_newtable(L);
    set_function(L, "new", rational_new);
    set_function(L, "fromString", rational_from_string);
    set_function(L, "fromDecimal", rational_from_decimal);
    set_function(L, "fromFloat", rational_from_float);
    set_function(L, "fromInteger", rational_from_integer);
    set_function(L, "zero", rational_zero);
    set_function(L, "one", rational_one);
    set_function(L, "isRational", rational_is_rational);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "rational");

    lua_newtable(L);
    set_function(L, "new", float_new);
    set_function(L, "fromString", float_from_string);
    set_function(L, "fromNumber", float_from_number);
    set_function(L, "fromInteger", float_from_integer);
    set_function(L, "fromRational", float_from_rational);
    set_function(L, "defaultPrecision", float_default_precision);
    set_function(L, "setDefaultPrecision", float_set_default_precision);
    set_function(L, "zero", float_zero);
    set_function(L, "one", float_one);
    set_function(L, "isFloat", float_is_float);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "float");

    lua_newtable(L);
    set_function(L, "new", number_new);
    set_function(L, "fromString", number_from_string);
    set_function(L, "fromNumber", number_from_number);
    set_function(L, "fromInteger", number_from_integer);
    set_function(L, "fromFloat", number_from_float);
    set_function(L, "zero", number_zero);
    set_function(L, "one", number_one);
    set_function(L, "isNumber", number_is_number);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "number");

    lua_setreadonly(L, -1, true);
    return 1;
}
