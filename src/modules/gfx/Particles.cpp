#include "Particles.hpp"

#include "LL_Render.hpp"
#include "LuaUtil.hpp"
#include "Texture.hpp"
#include "Window.hpp"

const char* PARTICLE_SYSTEM_METATABLE = "ParticleSystem";

struct Range {
    float min;
    float max;
};
struct HSVA {
    float h;
    float s;
    float v;
    float a;
};
struct HSVARange {
    Range h;
    Range s;
    Range v;
    Range a;
};
struct SizeRange {
    Range start;
    Range end;
};

struct Particle {
    float x, y;
    float vx, vy;
    float life;
    float lifeStart;
    float sizeStart;
    HSVA colorStart;
    HSVA colorEnd;
    float sizeEnd;
};

// Particles userdata type
struct LuaParticles {
    Range life;
    Range speed;
    Range angle;
    SizeRange size;
    HSVARange colorStart;
    HSVARange colorEnd;
    LuaTexture* tex;
    double gravity[2];

    std::vector<Particle> particles;

    LuaParticles() = default;
};

int particles_tostring(lua_State* L) {
    LuaParticles* particles = (LuaParticles*)luaL_checkudata(L, 1, PARTICLE_SYSTEM_METATABLE);
    lua_pushfstring(L, "ParticleSystem()");
    return 1;
}

int particles_gc(lua_State* L) {
    LuaParticles* particles = (LuaParticles*)luaL_checkudata(L, 1, PARTICLE_SYSTEM_METATABLE);
    if (particles) {
        particles->~LuaParticles();  // Explicitly call destructor to free inner memory
    }
    return 0;
}

// ParticleSystem:Update(dt: number)
int particles_Update(lua_State* L) {
    LuaParticles* particles = (LuaParticles*)luaL_checkudata(L, 1, PARTICLE_SYSTEM_METATABLE);

    double dt = luaL_checknumber(L, 2);

    const double gx = particles->gravity[0];
    const double gy = particles->gravity[1];
    for (size_t i = 0; i < particles->particles.size();) {
        Particle& p = particles->particles[i];

        p.life -= dt;
        if (p.life <= 0.0f) {
            particles->particles[i] = std::move(particles->particles.back());
            particles->particles.pop_back();
            continue;  // Don't increment i
        }

        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.vx += gx * dt;
        p.vy += gy * dt;

        ++i;
    }

    return 0;
}

uint32_t HsvaToArgb(uint8_t h, uint8_t s, uint8_t v, uint8_t a) {
    uint8_t r, g, b;
    unsigned char region, remainder, p, q, t;

    if (s == 0) {
        r = v;
        g = v;
        b = v;
        return (a << 24) | (r << 16) | (b << 8) | g;
    }

    region = h / 43;
    remainder = (h - (region * 43)) * 6;

    p = (v * (255 - s)) >> 8;
    q = (v * (255 - ((s * remainder) >> 8))) >> 8;
    t = (v * (255 - ((s * (255 - remainder)) >> 8))) >> 8;

    switch (region) {
        case 0:
            r = v;
            g = t;
            b = p;
            break;
        case 1:
            r = q;
            g = v;
            b = p;
            break;
        case 2:
            r = p;
            g = v;
            b = t;
            break;
        case 3:
            r = p;
            g = q;
            b = v;
            break;
        case 4:
            r = t;
            g = p;
            b = v;
            break;
        default:
            r = v;
            g = p;
            b = q;
            break;
    }

    return (a << 24) | (r << 16) | (b << 8) | g;
}

// ParticleSystem:Draw(window: Window)
int particles_Draw(lua_State* L) {
    LuaParticles* particles = (LuaParticles*)luaL_checkudata(L, 1, PARTICLE_SYSTEM_METATABLE);

    LuaWindow* lua_window = (LuaWindow*)luaL_checkudata(L, 2, WINDOW_METATABLE);
    if (!lua_window || !lua_window->window) {
        luaL_error(L, "Invalid window object");
        return 0;
    }

    // TODO: More than just white circles
    for (Particle& p : particles->particles) {
        float t = p.life / p.lifeStart;

        float size = p.sizeStart + (p.sizeEnd - p.sizeStart) * (1 - t);

        float h = p.colorStart.h + (p.colorEnd.h - p.colorStart.h) * (1 - t);
        float s = p.colorStart.s + (p.colorEnd.s - p.colorStart.s) * (1 - t);
        float v = p.colorStart.v + (p.colorEnd.v - p.colorStart.v) * (1 - t);
        float a = p.colorStart.a + (p.colorEnd.a - p.colorStart.a) * (1 - t);

        uint32_t color = HsvaToArgb(h, s, v, a);

        if (particles->tex) {
            queueTexturedQuad(lua_window, nullptr, particles->tex, p.x - size / 2, p.y - size / 2, size, size,
                              0.0, 0.0, 1.0, 1.0, color);

        } else {
            queueFilledCircle(lua_window, p.x, p.y, size, color);
        }
    }

    return 0;
}

// ParticleSystem:SpawnParticle(x: number, y: number, count: number?)
int particles_SpawnParticles(lua_State* L) {
    LuaParticles* particles = (LuaParticles*)luaL_checkudata(L, 1, PARTICLE_SYSTEM_METATABLE);

    double x = luaL_checknumber(L, 2);
    double y = luaL_checknumber(L, 3);
    int count = 1;
    if (luaL_hasarg(L, 4)) {
        count = luaL_checkinteger(L, 4);
    }

    for (int i = 0; i < count; i++) {
        Particle p;
        p.x = x;
        p.y = y;

        p.life = ((double)rand() / RAND_MAX) * (particles->life.max - particles->life.min) +
                 particles->life.min;
        p.lifeStart = p.life;

        p.sizeStart =
            ((double)rand() / RAND_MAX) * (particles->size.start.max - particles->size.start.min) +
            particles->size.start.min;
        p.sizeEnd =
            ((double)rand() / RAND_MAX) * (particles->size.end.max - particles->size.end.min) +
            particles->size.end.min;

        double speed = ((double)rand() / RAND_MAX) * (particles->speed.max - particles->speed.min) +
                       particles->speed.min;
        double angle = ((double)rand() / RAND_MAX) * (particles->angle.max - particles->angle.min) +
                       particles->angle.min;

        p.colorStart.h = ((double)rand() / RAND_MAX) *
                             (particles->colorStart.h.max - particles->colorStart.h.min) +
                         particles->colorStart.h.min;
        p.colorStart.s = ((double)rand() / RAND_MAX) *
                             (particles->colorStart.s.max - particles->colorStart.s.min) +
                         particles->colorStart.s.min;
        p.colorStart.v = ((double)rand() / RAND_MAX) *
                             (particles->colorStart.v.max - particles->colorStart.v.min) +
                         particles->colorStart.v.min;
        p.colorStart.a = ((double)rand() / RAND_MAX) *
                             (particles->colorStart.a.max - particles->colorStart.a.min) +
                         particles->colorStart.a.min;

        p.colorEnd.h =
            ((double)rand() / RAND_MAX) * (particles->colorEnd.h.max - particles->colorEnd.h.min) +
            particles->colorEnd.h.min;
        p.colorEnd.s =
            ((double)rand() / RAND_MAX) * (particles->colorEnd.s.max - particles->colorEnd.s.min) +
            particles->colorEnd.s.min;
        p.colorEnd.v =
            ((double)rand() / RAND_MAX) * (particles->colorEnd.v.max - particles->colorEnd.v.min) +
            particles->colorEnd.v.min;
        p.colorEnd.a =
            ((double)rand() / RAND_MAX) * (particles->colorEnd.a.max - particles->colorEnd.a.min) +
            particles->colorEnd.a.min;

        // Degrees to radians
        angle *= (3.141592 / 180);

        p.vx = cos(angle) * speed;
        p.vy = sin(angle) * speed;

        particles->particles.push_back(p);
    }

    return 0;
}

static Range readRange(lua_State* L, int idx, const char* name) {
    Range r{};

    if (lua_isnumber(L, idx)) {
        float v = (float)lua_tonumber(L, idx);
        r.min = v;
        r.max = v;
        return r;
    }

    if (!lua_istable(L, idx)) {
        luaL_error(L, "'%s' must be a number or {min, max}", name);
    }

    lua_getfield(L, idx, "min");
    if (!lua_isnumber(L, -1)) luaL_error(L, "'%s.min' must be a number", name);
    r.min = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "max");
    if (!lua_isnumber(L, -1)) luaL_error(L, "'%s.max' must be a number", name);
    r.max = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    if (r.min > r.max) luaL_error(L, "'%s.min' cannot be greater than '%s.max'", name, name);

    return r;
}
static SizeRange readSize(lua_State* L, int idx, const char* name) {
    SizeRange s{};

    lua_getfield(L, idx, "from");
    if (lua_isnil(L, -1)) luaL_error(L, "'from' is required");
    s.start = readRange(L, -1, "from");
    lua_pop(L, 1);

    lua_getfield(L, idx, "to");
    if (lua_isnil(L, -1)) luaL_error(L, "'to' is required");
    s.end = readRange(L, -1, "to");
    lua_pop(L, 1);

    return s;
}
static HSVARange readHsva(lua_State* L, int idx, const char* name) {
    HSVARange hsv{};

    if (!lua_istable(L, idx)) {
        luaL_error(L, "'%s' must be {h, s, v}", name);
    }

    lua_getfield(L, idx, "h");
    if (lua_isnil(L, -1)) luaL_error(L, "'h' is required");
    hsv.h = readRange(L, -1, "h");
    lua_pop(L, 1);

    lua_getfield(L, idx, "s");
    if (lua_isnil(L, -1)) luaL_error(L, "'s' is required");
    if (!lua_isnumber(L, -1)) luaL_error(L, "'s' must be number");
    hsv.s = readRange(L, -1, "s");
    lua_pop(L, 1);

    lua_getfield(L, idx, "v");
    if (lua_isnil(L, -1)) luaL_error(L, "'v' is required");
    if (!lua_isnumber(L, -1)) luaL_error(L, "'v' must be number");
    hsv.v = readRange(L, -1, "v");
    lua_pop(L, 1);

    lua_getfield(L, idx, "a");
    if (lua_isnil(L, -1)) {
        hsv.a = Range(255, 255);
    } else {
        if (!lua_isnumber(L, -1)) luaL_error(L, "'a' must be number");
        hsv.a = readRange(L, -1, "a");
    }
    lua_pop(L, 1);

    return hsv;
}

// particles.createSystem({
//     life: number | {min: number, max: number},
//     speed: number | {min: number, max: number},
//     angle: number | {min: number, max: number},
//     size: number | {min: number, max: number},
//     gravity: Vec2?,
// })
int particles_createSystem(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    LuaParticles* lua_particles = (LuaParticles*)lua_newuserdata(L, sizeof(LuaParticles));
    new (lua_particles) LuaParticles();
    lua_particles->particles.clear();

    // life
    lua_getfield(L, 1, "life");
    if (lua_isnil(L, -1)) luaL_error(L, "'life' is required");
    lua_particles->life = readRange(L, -1, "life");
    lua_pop(L, 1);

    // speed
    lua_getfield(L, 1, "speed");
    if (lua_isnil(L, -1)) luaL_error(L, "'speed' is required");
    lua_particles->speed = readRange(L, -1, "speed");
    lua_pop(L, 1);

    // angle
    lua_getfield(L, 1, "angle");
    if (lua_isnil(L, -1)) luaL_error(L, "'angle' is required");
    lua_particles->angle = readRange(L, -1, "angle");
    lua_pop(L, 1);

    // size
    lua_getfield(L, 1, "size");
    if (lua_isnil(L, -1)) luaL_error(L, "'size' is required");
    lua_particles->size = readSize(L, -1, "size");
    lua_pop(L, 1);

    // colour
    lua_getfield(L, 1, "color");
    if (lua_isnil(L, -1)) luaL_error(L, "'color' is required");
    if (!lua_istable(L, -1)) {
        luaL_error(L, "color must be hsva or {from: hsva, to: hsva}");
    }
    lua_getfield(L, -1, "from");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);

        lua_particles->colorStart = readHsva(L, -1, "color");
        lua_particles->colorEnd = lua_particles->colorStart;
        lua_pop(L, 1);
    } else {
        lua_particles->colorStart = readHsva(L, -1, "from");
        lua_pop(L, 1);

        lua_getfield(L, -1, "to");
        lua_particles->colorEnd = readHsva(L, -1, "to");
        lua_pop(L, 1);
    }
    lua_pop(L, 1);

    // texture
    lua_getfield(L, 1, "texture");
    if (!lua_isnil(L, -1)) {
        lua_particles->tex = (LuaTexture*)luaL_checkudata(L, -1, TEXTURE_METATABLE);
    } else {
        lua_particles->tex = nullptr;
    }
    lua_pop(L, 1);

    // gravity (optional)
    lua_getfield(L, 1, "gravity");
    if (!lua_isnil(L, -1)) {
        luaL_checkvec2(L, -1, lua_particles->gravity);
    }
    lua_pop(L, 1);

    luaL_getmetatable(L, PARTICLE_SYSTEM_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

static const luaL_Reg particles_lib[] = {
    { "createSystem", particles_createSystem },
    { NULL, NULL },
};

void particles_lib_register(lua_State* L) {
    luaL_newmetatable(L, PARTICLE_SYSTEM_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, particles_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, particles_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, particles_Update, "Update");
    lua_setfield(L, -2, "Update");

    lua_pushcfunction(L, particles_Draw, "Draw");
    lua_setfield(L, -2, "Draw");

    lua_pushcfunction(L, particles_SpawnParticles, "SpawnParticles");
    lua_setfield(L, -2, "SpawnParticles");

    lua_pop(L, 1);

    luaL_register(L, "particles", particles_lib);
}
