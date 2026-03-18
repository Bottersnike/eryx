#include "Sound.hpp"

#include "LuaUtil.hpp"

// Must be included here to ensure it's only in a single compilation unit!
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"  // IWYU pragma: export

// Audio system with voice pooling
struct Voice {
    ma_sound sound;
    bool active = false;

    Voice() : sound{}, active(false) {}
};

struct LuaSound {
    std::string filename;
    std::vector<Voice> voices;  // Pool of voices for multi-instance playback
    int voice_count = 4;        // Default 4 voices

    LuaSound() : filename(""), voice_count(4) { voices.resize(voice_count); }
};

const char* SOUND_METATABLE = "Sound";

ma_engine audio_engine = {};
bool has_audio_engine = false;

int sound_tostring(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);
    lua_pushfstring(L, "Sound(%s, %d voices)", sound->filename.c_str(), (int)sound->voices.size());
    return 1;
}

int sound_gc(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);
    if (sound) {
        for (auto& voice : sound->voices) {
            ma_sound_uninit(&voice.sound);
        }
        sound->~LuaSound();  // Explicitly call destructor
    }
    return 0;
}

// Sound::Play(loop: boolean?) -> ()
int sound_Play(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);
    if (!sound) {
        luaL_error(L, "Invalid sound object");
        return 0;
    }
    bool loop = false;
    if (luaL_hasarg(L, 2)) {
        loop = luaL_checkboolean(L, 2);
    }

    // Find first available (not playing) voice and play it
    for (int i = 0; i < (int)sound->voices.size(); i++) {
        if (!ma_sound_is_playing(&sound->voices[i].sound)) {
            ma_sound_set_volume(&sound->voices[i].sound, 1.0f);
            ma_sound_start(&sound->voices[i].sound);
            ma_sound_set_looping(&sound->voices[i].sound, loop);
            lua_pushnumber(L, i + 1);  // Return voice index
            return 1;
        }
    }

    lua_pushnumber(L, -1);  // No voice available
    return 1;
}

// Sound::Stop(voice: number?) -> ()
int sound_Stop(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);
    if (!sound) {
        luaL_error(L, "Invalid sound object");
        return 0;
    }

    int voice = -1;
    if (luaL_hasarg(L, 2)) {
        voice = luaL_checkinteger(L, 2);
        if (voice != -1) {
            if (voice < 1 || voice > sound->voice_count) {
                luaL_error(L, "Voice out of range");
                return 0;
            }
            voice -= 1;
        }
    }

    if (voice == -1) {
        // Stop all voices
        for (auto& voice : sound->voices) {
            ma_sound_stop(&voice.sound);
        }
    } else {
        ma_sound_stop(&sound->voices[voice].sound);
    }

    return 0;
}

// Sound::SetVolume(volume: number, voice: number?) -> ()
int sound_SetVolume(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);
    float volume = (float)luaL_checknumber(L, 2);

    if (!sound) {
        luaL_error(L, "Invalid sound object");
        return 0;
    }

    int voice = -1;
    if (luaL_hasarg(L, 3)) {
        voice = luaL_checkinteger(L, 3);
        if (voice != -1) {
            if (voice < 1 || voice > sound->voice_count) {
                luaL_error(L, "Voice out of range");
                return 0;
            }
            voice -= 1;
        }
    }

    if (voice == -1) {
        // Set volume for all voices
        for (auto& voice : sound->voices) {
            ma_sound_set_volume(&voice.sound, volume);
        }
    } else {
        ma_sound_set_volume(&sound->voices[voice].sound, volume);
    }

    return 0;
}

// Sound::SetCursor(seconds: number, voice: number?) -> ()
int sound_SetCursor(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);
    float seconds = (float)luaL_checknumber(L, 2);

    if (!sound) {
        luaL_error(L, "Invalid sound object");
        return 0;
    }

    int voice = -1;
    if (luaL_hasarg(L, 3)) {
        voice = luaL_checkinteger(L, 3);
        if (voice != -1) {
            if (voice < 1 || voice > sound->voice_count) {
                luaL_error(L, "Voice out of range");
                return 0;
            }
            voice -= 1;
        }
    }

    if (voice == -1) {
        // Set cursor for all voices
        for (auto& voice : sound->voices) {
            ma_sound_seek_to_second(&voice.sound, seconds);
        }
    } else {
        ma_sound_seek_to_second(&sound->voices[voice].sound, seconds);
    }

    return 0;
}

// Sound::GetCursor(voice: number) -> number
int sound_GetCursor(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);

    if (!sound) {
        luaL_error(L, "Invalid sound object");
        return 0;
    }

    int voice = 0;
    if (luaL_hasarg(L, 2)) {
        voice = luaL_checkinteger(L, 2);
        if (voice < 1 || voice > sound->voice_count) {
            luaL_error(L, "Voice out of range");
            return 0;
        }
        voice -= 1;
    }

    // Get cursor for the first voice
    float cursor = -1;
    ma_sound_get_cursor_in_seconds(&(sound->voices[voice].sound), &cursor);

    lua_pushnumber(L, cursor);
    return 1;
}

// Sound::GetDuration() -> number
int sound_GetDuration(lua_State* L) {
    LuaSound* sound = (LuaSound*)luaL_checkudata(L, 1, SOUND_METATABLE);

    if (!sound) {
        luaL_error(L, "Invalid sound object");
        return 0;
    }

    float length = -1;
    ma_sound_get_length_in_seconds(&sound->voices[0].sound, &length);

    lua_pushnumber(L, length);
    return 1;
}

// sound.init(channels: number, sample_rate: number) -> ()
int sound_init(lua_State* L) {
    ma_engine_config config = ma_engine_config_init();
    double channels = 2;
    double sampleRate = 48000;
    if (luaL_hasarg(L, 1)) channels = luaL_checknumber(L, 1);
    if (luaL_hasarg(L, 2)) sampleRate = luaL_checknumber(L, 2);

    if (channels != (double)channels || channels < 1) {
        luaL_error(L, "Invalid number of channels");
        return 0;
    }
    if (sampleRate != (double)sampleRate || sampleRate < 1) {
        luaL_error(L, "Invalid number of channels");
        return 0;
    }

    // TODO: Allow configuration of the used audio device
    config.channels = channels;
    config.sampleRate = sampleRate;

    if (ma_engine_init(&config, &audio_engine) != MA_SUCCESS) {
        luaL_error(L, "Failed to initialise audio engine with provided settings");
        return 0;
    }
    has_audio_engine = true;
    return 0;
}

// sound.load(filename: string, voice_count?: number) -> Sound
int sound_load(lua_State* L) {
    if (!has_audio_engine) {
        luaL_error(L, "Audio engine not initialised yet");
        return 0;
    }

    const char* filename = luaL_checkstring(L, 1);
    int voice_count = 4;  // Default

    if (lua_isnumber(L, 2)) {
        voice_count = (int)lua_tonumber(L, 2);
    }

    LuaSound* sound = (LuaSound*)lua_newuserdata(L, sizeof(LuaSound));
    new (sound) LuaSound();
    sound->filename = filename;
    sound->voice_count = voice_count;
    sound->voices.resize(voice_count);

    // Load the sound file into each voice
    for (int i = 0; i < voice_count; i++) {
        ma_result result = ma_sound_init_from_file(&audio_engine, filename, 0, nullptr, nullptr,
                                                   &sound->voices[i].sound);
        if (result != MA_SUCCESS) {
            std::stringstream error;
            error << "Failed to load audio voice ";
            error << i;
            error << " from ";
            error << filename;
            error << " (";
            error << result;
            error << ")";
            luaL_error(L, error.str().c_str());
            // Continue anyway - voices will be silent
        } else {
            // Don't auto-play
            ma_sound_set_looping(&sound->voices[i].sound, false);
        }
    }

    luaL_getmetatable(L, SOUND_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

static const luaL_Reg sound_lib[] = {
    { "init", sound_init },
    { "load", sound_load },
    { NULL, NULL },
};

void sound_lib_register(lua_State* L) {
    // Sound methods
    luaL_newmetatable(L, SOUND_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, sound_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, sound_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, sound_Play, "Play");
    lua_setfield(L, -2, "Play");

    lua_pushcfunction(L, sound_Stop, "Stop");
    lua_setfield(L, -2, "Stop");

    lua_pushcfunction(L, sound_SetVolume, "SetVolume");
    lua_setfield(L, -2, "SetVolume");

    lua_pushcfunction(L, sound_SetCursor, "SetCursor");
    lua_setfield(L, -2, "SetCursor");
    lua_pushcfunction(L, sound_GetCursor, "GetCursor");
    lua_setfield(L, -2, "GetCursor");
    lua_pushcfunction(L, sound_GetDuration, "GetDuration");
    lua_setfield(L, -2, "GetDuration");

    // lua_pushcfunction(L, sound_GetVoice, "GetVoice");
    // lua_setfield(L, -2, "GetVoice");

    lua_pop(L, 1);

    luaL_register(L, "sound", sound_lib);
}

void sound_destroy(void) {
    if (has_audio_engine) {
        ma_engine_uninit(&audio_engine);
        has_audio_engine = false;
    }
}