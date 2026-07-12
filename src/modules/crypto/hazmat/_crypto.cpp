#include <openssl/bio.h>
#include <openssl/buffer.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/params.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>

#include <climits>
#include <cstdint>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "module_api.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__crypto",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void push_openssl_error(lua_State* L, const char* op) {
    unsigned long err = ERR_get_error();
    if (err != 0) {
        char buf[256];
        ERR_error_string_n(err, buf, sizeof(buf));
        luaL_error(L, "%s failed (%s)", op, buf);
    }

    luaL_error(L, "%s failed", op);
}

static void check_openssl_input_len(lua_State* L, size_t len, const char* arg_name) {
    if (len > INT_MAX) luaL_error(L, "%s is too large for OpenSSL", arg_name);
}

static int check_ccm_tag_len(lua_State* L, int tagLen) {
    if (tagLen < 4 || tagLen > 16 || (tagLen % 2) != 0) {
        luaL_error(L, "AES-CCM tag length must be an even number of bytes between 4 and 16");
    }
    return tagLen;
}

static const EVP_CIPHER* aes_gcm_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_gcm();
        case 24:
            return EVP_aes_192_gcm();
        case 32:
            return EVP_aes_256_gcm();
        default:
            luaL_error(L, "AES-GCM key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_MD* openssl_md_from_name(lua_State* L, const char* hash_name) {
    if (strcmp(hash_name, "md5") == 0) return EVP_md5();
    if (strcmp(hash_name, "sha1") == 0) return EVP_sha1();
    if (strcmp(hash_name, "sha224") == 0) return EVP_sha224();
    if (strcmp(hash_name, "sha256") == 0) return EVP_sha256();
    if (strcmp(hash_name, "sha384") == 0) return EVP_sha384();
    if (strcmp(hash_name, "sha512") == 0) return EVP_sha512();
    if (strcmp(hash_name, "sha3_224") == 0) return EVP_sha3_224();
    if (strcmp(hash_name, "sha3_256") == 0) return EVP_sha3_256();
    if (strcmp(hash_name, "sha3_384") == 0) return EVP_sha3_384();
    if (strcmp(hash_name, "sha3_512") == 0) return EVP_sha3_512();

    luaL_error(L, "unsupported hash '%s'", hash_name);
    return nullptr;
}

static std::string bio_to_string(lua_State* L, BIO* bio, const char* op) {
    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio, &mem);
    if (!mem || !mem->data) luaL_error(L, "%s failed", op);

    return std::string(mem->data, mem->length);
}

static EVP_PKEY* load_private_key_pem(lua_State* L, const char* op, const char* pem) {
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, op);

    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!pkey) push_openssl_error(L, op);

    return pkey;
}

static EVP_PKEY* load_public_key_pem(lua_State* L, const char* op, const char* pem) {
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, op);

    EVP_PKEY* pkey = PEM_read_bio_PUBKEY(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!pkey) push_openssl_error(L, op);

    return pkey;
}

static EVP_PKEY* load_private_key_der(lua_State* L, const char* op, const void* der,
                                      size_t derLen) {
    const unsigned char* der_ptr = (const unsigned char*)der;
    EVP_PKEY* pkey = d2i_AutoPrivateKey(nullptr, &der_ptr, (long)derLen);
    if (!pkey) push_openssl_error(L, op);

    return pkey;
}

static EVP_PKEY* load_public_key_der(lua_State* L, const char* op, const void* der, size_t derLen) {
    const unsigned char* der_ptr = (const unsigned char*)der;
    EVP_PKEY* pkey = d2i_PUBKEY(nullptr, &der_ptr, (long)derLen);
    if (!pkey) push_openssl_error(L, op);

    return pkey;
}

static EVP_PKEY* ensure_ec_key(lua_State* L, const char* op, EVP_PKEY* pkey) {
    if (!EVP_PKEY_is_a(pkey, "EC")) {
        EVP_PKEY_free(pkey);
        luaL_error(L, "%s requires an EC key", op);
    }

    return pkey;
}

static EVP_PKEY* ensure_rsa_key(lua_State* L, const char* op, EVP_PKEY* pkey) {
    if (!EVP_PKEY_is_a(pkey, "RSA")) {
        EVP_PKEY_free(pkey);
        luaL_error(L, "%s requires an RSA key", op);
    }

    return pkey;
}

static EVP_PKEY* load_any_private_or_public_pem(lua_State* L, const char* op, const char* pem) {
    ERR_clear_error();
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, op);

    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (pkey) return pkey;

    ERR_clear_error();
    bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, op);
    pkey = PEM_read_bio_PUBKEY(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!pkey) push_openssl_error(L, op);

    return pkey;
}

static void resize_top_buffer(lua_State* L, size_t actual_len) {
    size_t allocated_len = lua_objlen(L, -1);
    if (actual_len == allocated_len) return;

    const void* src = lua_tobuffer(L, -1, nullptr);
    void* resized = lua_newbuffer(L, actual_len);
    memcpy(resized, src, actual_len);
    lua_replace(L, -2);
}

static void require_block_aligned(lua_State* L, size_t len, size_t block_size, const char* op,
                                  const char* arg_name) {
    if (block_size == 0 || len % block_size == 0) return;

    luaL_error(L, "%s requires %s length to be a multiple of %zu bytes", op, arg_name, block_size);
}

static const EVP_CIPHER* aes_ecb_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_ecb();
        case 24:
            return EVP_aes_192_ecb();
        case 32:
            return EVP_aes_256_ecb();
        default:
            luaL_error(L, "AES-ECB key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* aes_cbc_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_cbc();
        case 24:
            return EVP_aes_192_cbc();
        case 32:
            return EVP_aes_256_cbc();
        default:
            luaL_error(L, "AES-CBC key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* aes_ctr_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_ctr();
        case 24:
            return EVP_aes_192_ctr();
        case 32:
            return EVP_aes_256_ctr();
        default:
            luaL_error(L, "AES-CTR key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* aes_cfb128_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_cfb128();
        case 24:
            return EVP_aes_192_cfb128();
        case 32:
            return EVP_aes_256_cfb128();
        default:
            luaL_error(L, "AES-CFB128 key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* aes_ofb_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_ofb();
        case 24:
            return EVP_aes_192_ofb();
        case 32:
            return EVP_aes_256_ofb();
        default:
            luaL_error(L, "AES-OFB key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* aes_ccm_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_aes_128_ccm();
        case 24:
            return EVP_aes_192_ccm();
        case 32:
            return EVP_aes_256_ccm();
        default:
            luaL_error(L, "AES-CCM key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* camellia_cbc_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_camellia_128_cbc();
        case 24:
            return EVP_camellia_192_cbc();
        case 32:
            return EVP_camellia_256_cbc();
        default:
            luaL_error(L, "Camellia-CBC key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* camellia_ctr_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            return EVP_camellia_128_ctr();
        case 24:
            return EVP_camellia_192_ctr();
        case 32:
            return EVP_camellia_256_ctr();
        default:
            luaL_error(L, "Camellia-CTR key must be 16, 24, or 32 bytes");
            return nullptr;
    }
}

static const EVP_CIPHER* camellia_gcm_cipher_for_key_len(lua_State* L, size_t keyLen) {
    switch (keyLen) {
        case 16:
            break;
        case 24:
            break;
        case 32:
            break;
        default:
            luaL_error(L, "Camellia-GCM key must be 16, 24, or 32 bytes");
            return nullptr;
    }

    const char* cipher_name = keyLen == 16   ? "CAMELLIA-128-GCM"
                              : keyLen == 24 ? "CAMELLIA-192-GCM"
                                             : "CAMELLIA-256-GCM";
    const EVP_CIPHER* cipher = EVP_get_cipherbyname(cipher_name);
    if (!cipher) luaL_error(L, "%s is not available in this OpenSSL build", cipher_name);

    return cipher;
}

static const EVP_CIPHER* des3_cbc_cipher_for_key_len(lua_State* L, size_t keyLen) {
    if (keyLen != 24) luaL_error(L, "3DES-CBC key must be 24 bytes");
    return EVP_des_ede3_cbc();
}

static const EVP_CIPHER* chacha20_cipher_for_key_len(lua_State* L, size_t keyLen) {
    if (keyLen != 32) luaL_error(L, "ChaCha20 key must be 32 bytes");
    return EVP_chacha20();
}

static const EVP_CIPHER* chacha20_poly1305_cipher_for_key_len(lua_State* L, size_t keyLen) {
    if (keyLen != 32) luaL_error(L, "ChaCha20-Poly1305 key must be 32 bytes");
    return EVP_chacha20_poly1305();
}

static const char* normalize_ec_group_name(const char* group_name) {
    if (strcmp(group_name, "prime256v1") == 0) return "secp256r1";
    return group_name;
}

static const char* openssl_ec_group_name_from_curve(lua_State* L, const char* curve) {
    if (strcmp(curve, "secp224r1") == 0 || strcmp(curve, "p224") == 0 ||
        strcmp(curve, "p-224") == 0)
        return "secp224r1";
    if (strcmp(curve, "secp256r1") == 0 || strcmp(curve, "prime256v1") == 0 ||
        strcmp(curve, "p256") == 0 || strcmp(curve, "p-256") == 0)
        return "prime256v1";
    if (strcmp(curve, "secp384r1") == 0 || strcmp(curve, "p384") == 0 ||
        strcmp(curve, "p-384") == 0)
        return "secp384r1";
    if (strcmp(curve, "secp521r1") == 0 || strcmp(curve, "p521") == 0 ||
        strcmp(curve, "p-521") == 0)
        return "secp521r1";
    if (strcmp(curve, "secp256k1") == 0) return "secp256k1";

    luaL_error(L, "unsupported curve '%s'", curve);
    return nullptr;
}

static std::string get_ec_group_name(lua_State* L, EVP_PKEY* pkey, const char* op) {
    char group_name[80];
    size_t out_len = 0;

    if (EVP_PKEY_get_utf8_string_param(pkey, OSSL_PKEY_PARAM_GROUP_NAME, group_name,
                                       sizeof(group_name), &out_len) != 1) {
        push_openssl_error(L, op);
    }

    return normalize_ec_group_name(group_name);
}

udataRef* hashCtxRef;
udataRef* hmacCtxRef;
udataRef* aesCtxRef;
udataRef* camelliaCtxRef;
udataRef* desCtxRef;
udataRef* chacha20CtxRef;

struct LuaHashCtx {
    EVP_MD_CTX* ctx;
    bool closed;
    bool finalized;
};

static void hash_ctx_dtor(lua_State* L, void* ud) {
    auto* ctx = (LuaHashCtx*)ud;
    if (ctx->ctx) {
        EVP_MD_CTX* native = ctx->ctx;
        ctx->ctx = nullptr;
        EVP_MD_CTX_free(native);
    }
    ctx->closed = true;
}

static LuaHashCtx* check_hash_ctx(lua_State* L) {
    auto* ctx = (LuaHashCtx*)eryxUdata_checkudata(L, hashCtxRef, 1);
    if (ctx->closed || !ctx->ctx) luaL_error(L, "hash context is closed");
    return ctx;
}

static int hash_ctx_update(lua_State* L) {
    auto* ctx = check_hash_ctx(L);
    if (ctx->finalized) luaL_error(L, "hash context is already finalized");

    size_t inputLen = 0;
    const void* input = luaL_checkbuffer(L, 2, &inputLen);
    if (EVP_DigestUpdate(ctx->ctx, input, inputLen) != 1) push_openssl_error(L, "hash.update");
    return 0;
}

static int hash_ctx_final(lua_State* L) {
    auto* ctx = check_hash_ctx(L);
    if (ctx->finalized) luaL_error(L, "hash context is already finalized");

    const EVP_MD* md = EVP_MD_CTX_get0_md(ctx->ctx);
    int digest_size_i = md ? EVP_MD_get_size(md) : 0;
    if (digest_size_i <= 0) luaL_error(L, "hash algorithm not available");

    unsigned int digest_size = (unsigned int)digest_size_i;
    void* out = lua_newbuffer(L, digest_size);
    if (EVP_DigestFinal_ex(ctx->ctx, (unsigned char*)out, &digest_size) != 1) {
        push_openssl_error(L, "hash.final");
    }

    ctx->finalized = true;
    EVP_MD_CTX* native = ctx->ctx;
    ctx->ctx = nullptr;
    EVP_MD_CTX_free(native);
    resize_top_buffer(L, digest_size);
    return 1;
}

static int hash_ctx_close(lua_State* L) {
    auto* ctx = (LuaHashCtx*)eryxUdata_checkudata(L, hashCtxRef, 1);
    if (ctx->ctx) {
        EVP_MD_CTX* native = ctx->ctx;
        ctx->ctx = nullptr;
        EVP_MD_CTX_free(native);
    }
    ctx->closed = true;
    return 0;
}

static int hash_ctx_tostring(lua_State* L) {
    auto* ctx = (LuaHashCtx*)eryxUdata_checkudata(L, hashCtxRef, 1);
    const char* state = ctx->closed ? "closed" : (ctx->finalized ? "finalized" : "open");
    lua_pushfstring(L, "crypto.hash(%s)", state);
    return 1;
}

static int hash_new(lua_State* L) {
    const char* hash_name = luaL_checkstring(L, 1);
    const EVP_MD* md = openssl_md_from_name(L, hash_name);

    auto* ctx = (LuaHashCtx*)eryxUdata_pushudata(L, hashCtxRef);
    new (ctx) LuaHashCtx{};
    ctx->ctx = EVP_MD_CTX_new();
    ctx->closed = false;
    ctx->finalized = false;
    if (!ctx->ctx) push_openssl_error(L, "hash.new");

    if (EVP_DigestInit_ex(ctx->ctx, md, nullptr) != 1) {
        hash_ctx_dtor(L, ctx);
        push_openssl_error(L, "hash.new");
    }
    return 1;
}

enum class EvpCipherStreamMode {
    ECB,
    CBC,
    CTR,
    CFB,
    OFB,
    GCM,
};

struct LuaHmacCtx {
    HMAC_CTX* ctx;
    bool closed;
    bool finalized;
};

struct LuaCipherCtx {
    EVP_CIPHER_CTX* ctx;
    EvpCipherStreamMode mode;
    const char* family;
    bool encrypt;
    bool closed;
    bool finalized;
    bool aadLocked;
    bool tagSet;
};

static void hmac_ctx_dtor(lua_State* L, void* ud) {
    auto* ctx = (LuaHmacCtx*)ud;
    if (ctx->ctx) {
        HMAC_CTX* native = ctx->ctx;
        ctx->ctx = nullptr;
        HMAC_CTX_free(native);
    }
    ctx->closed = true;
}

static LuaHmacCtx* check_hmac_ctx(lua_State* L) {
    auto* ctx = (LuaHmacCtx*)eryxUdata_checkudata(L, hmacCtxRef, 1);
    if (ctx->closed || !ctx->ctx) luaL_error(L, "hmac context is closed");
    return ctx;
}

static void cipher_ctx_dtor(lua_State* L, void* ud) {
    auto* ctx = (LuaCipherCtx*)ud;
    if (ctx->ctx) {
        EVP_CIPHER_CTX* native = ctx->ctx;
        ctx->ctx = nullptr;
        EVP_CIPHER_CTX_free(native);
    }
    ctx->closed = true;
}

static LuaCipherCtx* check_cipher_ctx(lua_State* L, udataRef* ref) {
    auto* ctx = (LuaCipherCtx*)eryxUdata_checkudata(L, ref, 1);
    if (ctx->closed || !ctx->ctx) luaL_error(L, "%s context is closed", ctx->family);
    return ctx;
}

static bool cipher_mode_is_aead(EvpCipherStreamMode mode) {
    return mode == EvpCipherStreamMode::GCM;
}

static int cipher_ctx_update(lua_State* L, udataRef* ref) {
    auto* ctx = check_cipher_ctx(L, ref);
    if (ctx->finalized) luaL_error(L, "%s context is already finalized", ctx->family);

    size_t inputLen = 0;
    const void* input = luaL_checkbuffer(L, 2, &inputLen);
    check_openssl_input_len(L, inputLen, ctx->encrypt ? "plaintext" : "ciphertext");

    int block_size = EVP_CIPHER_CTX_get_block_size(ctx->ctx);
    size_t out_max = inputLen + (block_size > 0 ? (size_t)block_size : 0);
    void* out = lua_newbuffer(L, out_max);
    int out_len = 0;

    if ((ctx->encrypt ? EVP_EncryptUpdate(ctx->ctx, (unsigned char*)out, &out_len,
                                          (const unsigned char*)input, (int)inputLen)
                      : EVP_DecryptUpdate(ctx->ctx, (unsigned char*)out, &out_len,
                                          (const unsigned char*)input, (int)inputLen)) != 1) {
        std::string op = std::string(ctx->family) + ".update";
        push_openssl_error(L, op.c_str());
    }

    ctx->aadLocked = true;
    resize_top_buffer(L, (size_t)out_len);
    return 1;
}

static int cipher_ctx_update_aad(lua_State* L, udataRef* ref) {
    auto* ctx = check_cipher_ctx(L, ref);
    if (ctx->finalized) luaL_error(L, "%s context is already finalized", ctx->family);
    if (!cipher_mode_is_aead(ctx->mode))
        luaL_error(L, "%s.updateAAD is only supported for GCM mode", ctx->family);
    if (ctx->aadLocked) luaL_error(L, "%s.updateAAD must be called before update", ctx->family);

    size_t aadLen = 0;
    const void* aad = luaL_checkbuffer(L, 2, &aadLen);
    check_openssl_input_len(L, aadLen, "aad");

    int out_len = 0;
    if ((ctx->encrypt ? EVP_EncryptUpdate(ctx->ctx, nullptr, &out_len, (const unsigned char*)aad,
                                          (int)aadLen)
                      : EVP_DecryptUpdate(ctx->ctx, nullptr, &out_len, (const unsigned char*)aad,
                                          (int)aadLen)) != 1) {
        std::string op = std::string(ctx->family) + ".updateAAD";
        push_openssl_error(L, op.c_str());
    }

    return 0;
}

static int cipher_ctx_set_tag(lua_State* L, udataRef* ref) {
    auto* ctx = check_cipher_ctx(L, ref);
    if (ctx->encrypt) luaL_error(L, "%s.setTag is only supported on decrypt contexts", ctx->family);
    if (!cipher_mode_is_aead(ctx->mode))
        luaL_error(L, "%s.setTag is only supported for GCM mode", ctx->family);
    if (ctx->finalized) luaL_error(L, "%s context is already finalized", ctx->family);

    size_t tagLen = 0;
    const void* tag = luaL_checkbuffer(L, 2, &tagLen);
    if (tagLen == 0) luaL_error(L, "tag must not be empty");
    check_openssl_input_len(L, tagLen, "tag");

    if (EVP_CIPHER_CTX_ctrl(ctx->ctx, EVP_CTRL_AEAD_SET_TAG, (int)tagLen, (void*)tag) != 1) {
        std::string op = std::string(ctx->family) + ".setTag";
        push_openssl_error(L, op.c_str());
    }

    ctx->tagSet = true;
    return 0;
}

static int cipher_ctx_get_tag(lua_State* L, udataRef* ref) {
    auto* ctx = check_cipher_ctx(L, ref);
    if (!ctx->encrypt)
        luaL_error(L, "%s.getTag is only supported on encrypt contexts", ctx->family);
    if (!cipher_mode_is_aead(ctx->mode))
        luaL_error(L, "%s.getTag is only supported for GCM mode", ctx->family);
    if (!ctx->finalized) luaL_error(L, "%s.getTag requires final to be called first", ctx->family);

    constexpr int tagLen = 16;
    void* out = lua_newbuffer(L, tagLen);
    if (EVP_CIPHER_CTX_ctrl(ctx->ctx, EVP_CTRL_AEAD_GET_TAG, tagLen, out) != 1) {
        std::string op = std::string(ctx->family) + ".getTag";
        push_openssl_error(L, op.c_str());
    }

    return 1;
}

static int cipher_ctx_final(lua_State* L, udataRef* ref) {
    auto* ctx = check_cipher_ctx(L, ref);
    if (ctx->finalized) luaL_error(L, "%s context is already finalized", ctx->family);
    if (!ctx->encrypt && cipher_mode_is_aead(ctx->mode) && !ctx->tagSet) {
        luaL_error(L, "%s.final requires setTag to be called first for GCM decryption",
                   ctx->family);
    }

    int block_size = EVP_CIPHER_CTX_get_block_size(ctx->ctx);
    size_t out_max = block_size > 0 ? (size_t)block_size : 16;
    void* out = lua_newbuffer(L, out_max);
    int out_len = 0;
    int ok = ctx->encrypt ? EVP_EncryptFinal_ex(ctx->ctx, (unsigned char*)out, &out_len)
                          : EVP_DecryptFinal_ex(ctx->ctx, (unsigned char*)out, &out_len);
    if (ok != 1) {
        if (!ctx->encrypt && cipher_mode_is_aead(ctx->mode)) {
            luaL_error(L, "%s.final: authentication tag mismatch", ctx->family);
        }
        luaL_error(L, "%s.final failed (input was not aligned to the cipher block size)",
                   ctx->family);
    }

    ctx->finalized = true;
    resize_top_buffer(L, (size_t)out_len);
    return 1;
}

static int cipher_ctx_close(lua_State* L, udataRef* ref) {
    auto* ctx = (LuaCipherCtx*)eryxUdata_checkudata(L, ref, 1);
    if (ctx->ctx) {
        EVP_CIPHER_CTX* native = ctx->ctx;
        ctx->ctx = nullptr;
        EVP_CIPHER_CTX_free(native);
    }
    ctx->closed = true;
    return 0;
}

static int cipher_ctx_tostring(lua_State* L, udataRef* ref) {
    auto* ctx = (LuaCipherCtx*)eryxUdata_checkudata(L, ref, 1);
    const char* state = ctx->closed ? "closed" : (ctx->finalized ? "finalized" : "open");
    const char* op = ctx->encrypt ? "encrypt" : "decrypt";
    lua_pushfstring(L, "crypto.%s(%s,%s)", ctx->family, op, state);
    return 1;
}

static int push_cipher_ctx(lua_State* L, udataRef* ref, const char* family,
                           const EVP_CIPHER* cipher, EvpCipherStreamMode mode, bool encrypt,
                           const void* key, const void* iv, size_t ivLen) {
    if ((size_t)EVP_CIPHER_iv_length(cipher) != ivLen && mode != EvpCipherStreamMode::GCM) {
        luaL_error(L, "invalid IV length");
    }

    auto* ctx = (LuaCipherCtx*)eryxUdata_pushudata(L, ref);
    new (ctx) LuaCipherCtx{};
    ctx->ctx = EVP_CIPHER_CTX_new();
    ctx->mode = mode;
    ctx->family = family;
    ctx->encrypt = encrypt;
    ctx->closed = false;
    ctx->finalized = false;
    ctx->aadLocked = false;
    ctx->tagSet = false;
    if (!ctx->ctx) {
        std::string op = std::string(family) + ".new";
        push_openssl_error(L, op.c_str());
    }

    int ok = 0;
    if (mode == EvpCipherStreamMode::GCM) {
        ok = (encrypt ? EVP_EncryptInit_ex(ctx->ctx, cipher, nullptr, nullptr, nullptr)
                      : EVP_DecryptInit_ex(ctx->ctx, cipher, nullptr, nullptr, nullptr));
        if (ok == 1)
            ok = EVP_CIPHER_CTX_ctrl(ctx->ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)ivLen, nullptr);
        if (ok == 1) {
            ok =
                (encrypt ? EVP_EncryptInit_ex(ctx->ctx, nullptr, nullptr, (const unsigned char*)key,
                                              (const unsigned char*)iv)
                         : EVP_DecryptInit_ex(ctx->ctx, nullptr, nullptr, (const unsigned char*)key,
                                              (const unsigned char*)iv));
        }
    } else {
        ok = (encrypt ? EVP_EncryptInit_ex(ctx->ctx, cipher, nullptr, (const unsigned char*)key,
                                           (const unsigned char*)iv)
                      : EVP_DecryptInit_ex(ctx->ctx, cipher, nullptr, (const unsigned char*)key,
                                           (const unsigned char*)iv));
        if (ok == 1) ok = EVP_CIPHER_CTX_set_padding(ctx->ctx, 0);
    }

    if (ok != 1) {
        cipher_ctx_dtor(L, ctx);
        std::string op = std::string(family) + ".new";
        push_openssl_error(L, op.c_str());
    }
    return 1;
}

static int aes_new(lua_State* L) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    const char* mode_name = luaL_checkstring(L, 2);
    const char* op_name = luaL_checkstring(L, 3);
    size_t ivLen = 0;
    const void* iv = lua_isnoneornil(L, 4) ? nullptr : luaL_checkbuffer(L, 4, &ivLen);

    bool encrypt = false;
    if (strcmp(op_name, "encrypt") == 0) {
        encrypt = true;
    } else if (strcmp(op_name, "decrypt") == 0) {
        encrypt = false;
    } else {
        luaL_error(L, "AES operation must be 'encrypt' or 'decrypt'");
    }

    const EVP_CIPHER* cipher = nullptr;
    EvpCipherStreamMode mode;
    if (strcmp(mode_name, "ecb") == 0) {
        mode = EvpCipherStreamMode::ECB;
        cipher = aes_ecb_cipher_for_key_len(L, keyLen);
        if (iv != nullptr) luaL_error(L, "AES-ECB does not use an IV or nonce");
    } else if (strcmp(mode_name, "cbc") == 0) {
        mode = EvpCipherStreamMode::CBC;
        cipher = aes_cbc_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "AES-CBC requires an IV");
    } else if (strcmp(mode_name, "ctr") == 0) {
        mode = EvpCipherStreamMode::CTR;
        cipher = aes_ctr_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "AES-CTR requires an IV");
    } else if (strcmp(mode_name, "cfb128") == 0) {
        mode = EvpCipherStreamMode::CFB;
        cipher = aes_cfb128_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "AES-CFB128 requires an IV");
    } else if (strcmp(mode_name, "ofb") == 0) {
        mode = EvpCipherStreamMode::OFB;
        cipher = aes_ofb_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "AES-OFB requires an IV");
    } else if (strcmp(mode_name, "gcm") == 0) {
        mode = EvpCipherStreamMode::GCM;
        cipher = aes_gcm_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "AES-GCM requires a nonce");
    } else if (strcmp(mode_name, "ccm") == 0) {
        luaL_error(L, "aes.new does not yet support CCM mode");
    } else {
        luaL_error(L, "unsupported AES mode '%s'", mode_name);
    }

    return push_cipher_ctx(L, aesCtxRef, "aes", cipher, mode, encrypt, key, iv, ivLen);
}

static int camellia_new(lua_State* L) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    const char* mode_name = luaL_checkstring(L, 2);
    const char* op_name = luaL_checkstring(L, 3);
    size_t ivLen = 0;
    const void* iv = lua_isnoneornil(L, 4) ? nullptr : luaL_checkbuffer(L, 4, &ivLen);

    bool encrypt = false;
    if (strcmp(op_name, "encrypt") == 0) {
        encrypt = true;
    } else if (strcmp(op_name, "decrypt") == 0) {
        encrypt = false;
    } else {
        luaL_error(L, "Camellia operation must be 'encrypt' or 'decrypt'");
    }

    const EVP_CIPHER* cipher = nullptr;
    EvpCipherStreamMode mode;
    if (strcmp(mode_name, "cbc") == 0) {
        mode = EvpCipherStreamMode::CBC;
        cipher = camellia_cbc_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "Camellia-CBC requires an IV");
    } else if (strcmp(mode_name, "ctr") == 0) {
        mode = EvpCipherStreamMode::CTR;
        cipher = camellia_ctr_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "Camellia-CTR requires an IV");
    } else if (strcmp(mode_name, "gcm") == 0) {
        mode = EvpCipherStreamMode::GCM;
        cipher = camellia_gcm_cipher_for_key_len(L, keyLen);
        if (iv == nullptr) luaL_error(L, "Camellia-GCM requires a nonce");
    } else {
        luaL_error(L, "unsupported Camellia mode '%s'", mode_name);
    }

    return push_cipher_ctx(L, camelliaCtxRef, "camellia", cipher, mode, encrypt, key, iv, ivLen);
}

static int des_new(lua_State* L) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    const char* mode_name = luaL_checkstring(L, 2);
    const char* op_name = luaL_checkstring(L, 3);
    size_t ivLen = 0;
    const void* iv = luaL_checkbuffer(L, 4, &ivLen);

    bool encrypt = false;
    if (strcmp(op_name, "encrypt") == 0) {
        encrypt = true;
    } else if (strcmp(op_name, "decrypt") == 0) {
        encrypt = false;
    } else {
        luaL_error(L, "3DES operation must be 'encrypt' or 'decrypt'");
    }

    if (strcmp(mode_name, "cbc") != 0) {
        luaL_error(L, "unsupported 3DES mode '%s'", mode_name);
    }

    return push_cipher_ctx(L, desCtxRef, "des", des3_cbc_cipher_for_key_len(L, keyLen),
                           EvpCipherStreamMode::CBC, encrypt, key, iv, ivLen);
}

static int chacha20_new(lua_State* L) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    const char* mode_name = luaL_checkstring(L, 2);
    const char* op_name = luaL_checkstring(L, 3);
    size_t nonceLen = 0;
    const void* nonce = luaL_checkbuffer(L, 4, &nonceLen);

    bool encrypt = false;
    if (strcmp(op_name, "encrypt") == 0) {
        encrypt = true;
    } else if (strcmp(op_name, "decrypt") == 0) {
        encrypt = false;
    } else {
        luaL_error(L, "ChaCha20 operation must be 'encrypt' or 'decrypt'");
    }

    if (strcmp(mode_name, "stream") == 0) {
        if (nonceLen != 12) luaL_error(L, "ChaCha20 nonce must be 12 bytes");

        unsigned char iv[16] = { 0 };
        memcpy(iv + 4, nonce, nonceLen);
        return push_cipher_ctx(L, chacha20CtxRef, "chacha20",
                               chacha20_cipher_for_key_len(L, keyLen), EvpCipherStreamMode::CTR,
                               encrypt, key, iv, sizeof(iv));
    }

    if (strcmp(mode_name, "poly1305") == 0) {
        if (nonceLen != 12) luaL_error(L, "ChaCha20-Poly1305 nonce must be 12 bytes");
        return push_cipher_ctx(L, chacha20CtxRef, "chacha20",
                               chacha20_poly1305_cipher_for_key_len(L, keyLen),
                               EvpCipherStreamMode::GCM, encrypt, key, nonce, nonceLen);
    }

    luaL_error(L, "unsupported ChaCha20 mode '%s'", mode_name);
    return 0;
}

// ---------------------------------------------------------------------------
// HMAC
// ---------------------------------------------------------------------------

static int hmac_ctx_update(lua_State* L) {
    auto* ctx = check_hmac_ctx(L);
    if (ctx->finalized) luaL_error(L, "hmac context is already finalized");

    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    check_openssl_input_len(L, dataLen, "data");

    if (HMAC_Update(ctx->ctx, (const unsigned char*)data, dataLen) != 1) {
        push_openssl_error(L, "hmac.update");
    }

    return 0;
}

static int hmac_ctx_final(lua_State* L) {
    auto* ctx = check_hmac_ctx(L);
    if (ctx->finalized) luaL_error(L, "hmac context is already finalized");

    unsigned int macLen = HMAC_size(ctx->ctx);
    void* out = lua_newbuffer(L, macLen);
    if (HMAC_Final(ctx->ctx, (unsigned char*)out, &macLen) != 1) {
        push_openssl_error(L, "hmac.final");
    }

    ctx->finalized = true;
    HMAC_CTX* native = ctx->ctx;
    ctx->ctx = nullptr;
    HMAC_CTX_free(native);
    resize_top_buffer(L, macLen);
    return 1;
}

static int hmac_ctx_close(lua_State* L) {
    auto* ctx = (LuaHmacCtx*)eryxUdata_checkudata(L, hmacCtxRef, 1);
    if (ctx->ctx) {
        HMAC_CTX* native = ctx->ctx;
        ctx->ctx = nullptr;
        HMAC_CTX_free(native);
    }
    ctx->closed = true;
    return 0;
}

static int hmac_ctx_tostring(lua_State* L) {
    auto* ctx = (LuaHmacCtx*)eryxUdata_checkudata(L, hmacCtxRef, 1);
    const char* state = ctx->closed ? "closed" : (ctx->finalized ? "finalized" : "open");
    lua_pushfstring(L, "crypto.hmac(%s)", state);
    return 1;
}

static int hmac_new(lua_State* L) {
    const char* hash_name = luaL_checkstring(L, 1);
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 2, &keyLen);
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    check_openssl_input_len(L, keyLen, "key");

    auto* ctx = (LuaHmacCtx*)eryxUdata_pushudata(L, hmacCtxRef);
    new (ctx) LuaHmacCtx{};
    ctx->ctx = HMAC_CTX_new();
    ctx->closed = false;
    ctx->finalized = false;
    if (!ctx->ctx) push_openssl_error(L, "hmac.new");

    if (HMAC_Init_ex(ctx->ctx, key, (int)keyLen, md, nullptr) != 1) {
        hmac_ctx_dtor(L, ctx);
        push_openssl_error(L, "hmac.new");
    }
    return 1;
}

static int aes_ctx_update(lua_State* L) { return cipher_ctx_update(L, aesCtxRef); }
static int aes_ctx_update_aad(lua_State* L) { return cipher_ctx_update_aad(L, aesCtxRef); }
static int aes_ctx_set_tag(lua_State* L) { return cipher_ctx_set_tag(L, aesCtxRef); }
static int aes_ctx_get_tag(lua_State* L) { return cipher_ctx_get_tag(L, aesCtxRef); }
static int aes_ctx_final(lua_State* L) { return cipher_ctx_final(L, aesCtxRef); }
static int aes_ctx_close(lua_State* L) { return cipher_ctx_close(L, aesCtxRef); }
static int aes_ctx_tostring(lua_State* L) { return cipher_ctx_tostring(L, aesCtxRef); }

static int camellia_ctx_update(lua_State* L) { return cipher_ctx_update(L, camelliaCtxRef); }
static int camellia_ctx_update_aad(lua_State* L) {
    return cipher_ctx_update_aad(L, camelliaCtxRef);
}
static int camellia_ctx_set_tag(lua_State* L) { return cipher_ctx_set_tag(L, camelliaCtxRef); }
static int camellia_ctx_get_tag(lua_State* L) { return cipher_ctx_get_tag(L, camelliaCtxRef); }
static int camellia_ctx_final(lua_State* L) { return cipher_ctx_final(L, camelliaCtxRef); }
static int camellia_ctx_close(lua_State* L) { return cipher_ctx_close(L, camelliaCtxRef); }
static int camellia_ctx_tostring(lua_State* L) { return cipher_ctx_tostring(L, camelliaCtxRef); }

static int des_ctx_update(lua_State* L) { return cipher_ctx_update(L, desCtxRef); }
static int des_ctx_update_aad(lua_State* L) { return cipher_ctx_update_aad(L, desCtxRef); }
static int des_ctx_set_tag(lua_State* L) { return cipher_ctx_set_tag(L, desCtxRef); }
static int des_ctx_get_tag(lua_State* L) { return cipher_ctx_get_tag(L, desCtxRef); }
static int des_ctx_final(lua_State* L) { return cipher_ctx_final(L, desCtxRef); }
static int des_ctx_close(lua_State* L) { return cipher_ctx_close(L, desCtxRef); }
static int des_ctx_tostring(lua_State* L) { return cipher_ctx_tostring(L, desCtxRef); }

static int chacha20_ctx_update(lua_State* L) { return cipher_ctx_update(L, chacha20CtxRef); }
static int chacha20_ctx_update_aad(lua_State* L) {
    return cipher_ctx_update_aad(L, chacha20CtxRef);
}
static int chacha20_ctx_set_tag(lua_State* L) { return cipher_ctx_set_tag(L, chacha20CtxRef); }
static int chacha20_ctx_get_tag(lua_State* L) { return cipher_ctx_get_tag(L, chacha20CtxRef); }
static int chacha20_ctx_final(lua_State* L) { return cipher_ctx_final(L, chacha20CtxRef); }
static int chacha20_ctx_close(lua_State* L) { return cipher_ctx_close(L, chacha20CtxRef); }
static int chacha20_ctx_tostring(lua_State* L) { return cipher_ctx_tostring(L, chacha20CtxRef); }

// ---------------------------------------------------------------------------
// Symmetric cipher helpers (AES, Camellia, 3DES, ChaCha20)
// ---------------------------------------------------------------------------

static int evp_cipher_crypt(lua_State* L, const char* op, const EVP_CIPHER* cipher, bool encrypt,
                            const void* key, const void* iv, size_t ivLen, const void* input,
                            size_t inputLen, bool use_padding) {
    check_openssl_input_len(L, ivLen, "iv");
    check_openssl_input_len(L, inputLen, encrypt ? "plaintext" : "ciphertext");

    if ((size_t)EVP_CIPHER_iv_length(cipher) != ivLen) luaL_error(L, "invalid IV length");

    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) push_openssl_error(L, op);

    int out_len = 0;
    int total_len = 0;
    size_t out_max = inputLen + (use_padding ? EVP_CIPHER_block_size(cipher) : 0);
    void* out = lua_newbuffer(L, out_max);

    if ((encrypt ? EVP_EncryptInit_ex(ctx, cipher, nullptr, (const unsigned char*)key,
                                      (const unsigned char*)iv)
                 : EVP_DecryptInit_ex(ctx, cipher, nullptr, (const unsigned char*)key,
                                      (const unsigned char*)iv)) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }

    EVP_CIPHER_CTX_set_padding(ctx, use_padding ? 1 : 0);
    if ((encrypt ? EVP_EncryptUpdate(ctx, (unsigned char*)out, &out_len,
                                     (const unsigned char*)input, (int)inputLen)
                 : EVP_DecryptUpdate(ctx, (unsigned char*)out, &out_len,
                                     (const unsigned char*)input, (int)inputLen)) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }
    total_len = out_len;

    if ((encrypt ? EVP_EncryptFinal_ex(ctx, (unsigned char*)out + total_len, &out_len)
                 : EVP_DecryptFinal_ex(ctx, (unsigned char*)out + total_len, &out_len)) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }
    total_len += out_len;

    EVP_CIPHER_CTX_free(ctx);
    resize_top_buffer(L, total_len);
    return 1;
}

static int cipher_encrypt(lua_State* L, const char* op,
                          const EVP_CIPHER* (*cipher_for_key_len)(lua_State*, size_t),
                          bool use_padding) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t ivLen = 0;
    const void* iv = luaL_checkbuffer(L, 2, &ivLen);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 3, &ptLen);
    return evp_cipher_crypt(L, op, cipher_for_key_len(L, keyLen), true, key, iv, ivLen, pt, ptLen,
                            use_padding);
}

static int cipher_decrypt(lua_State* L, const char* op,
                          const EVP_CIPHER* (*cipher_for_key_len)(lua_State*, size_t),
                          bool use_padding) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t ivLen = 0;
    const void* iv = luaL_checkbuffer(L, 2, &ivLen);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 3, &ctLen);
    return evp_cipher_crypt(L, op, cipher_for_key_len(L, keyLen), false, key, iv, ivLen, ct, ctLen,
                            use_padding);
}

// AEAD helpers.
static int aead_encrypt(lua_State* L, const char* op,
                        const EVP_CIPHER* (*cipher_for_key_len)(lua_State*, size_t)) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t nonceLen = 0;
    const void* nonce = luaL_checkbuffer(L, 2, &nonceLen);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 3, &ptLen);
    size_t aadLen = 0;
    const void* aad = lua_isnoneornil(L, 4) ? nullptr : luaL_checkbuffer(L, 4, &aadLen);
    check_openssl_input_len(L, nonceLen, "nonce");
    check_openssl_input_len(L, ptLen, "plaintext");
    check_openssl_input_len(L, aadLen, "aad");

    const EVP_CIPHER* cipher = cipher_for_key_len(L, keyLen);
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) push_openssl_error(L, op);

    constexpr int tagLen = 16;
    int outLen = 0;
    int totalLen = 0;

    void* ct_buf = lua_newbuffer(L, ptLen);
    void* tag_buf = lua_newbuffer(L, tagLen);

    if (EVP_EncryptInit_ex(ctx, cipher, nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)nonceLen, nullptr) != 1 ||
        EVP_EncryptInit_ex(ctx, nullptr, nullptr, (const unsigned char*)key,
                           (const unsigned char*)nonce) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }

    if (aadLen > 0 &&
        EVP_EncryptUpdate(ctx, nullptr, &outLen, (const unsigned char*)aad, (int)aadLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }

    if (ptLen > 0 && EVP_EncryptUpdate(ctx, (unsigned char*)ct_buf, &outLen,
                                       (const unsigned char*)pt, (int)ptLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }
    totalLen = outLen;

    if (EVP_EncryptFinal_ex(ctx, (unsigned char*)ct_buf + totalLen, &outLen) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, tagLen, tag_buf) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }

    totalLen += outLen;
    EVP_CIPHER_CTX_free(ctx);
    resize_top_buffer(L, totalLen);
    return 2;
}

static int aead_decrypt(lua_State* L, const char* op,
                        const EVP_CIPHER* (*cipher_for_key_len)(lua_State*, size_t)) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t nonceLen = 0;
    const void* nonce = luaL_checkbuffer(L, 2, &nonceLen);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 3, &ctLen);
    size_t tagLen = 0;
    const void* tag = luaL_checkbuffer(L, 4, &tagLen);
    size_t aadLen = 0;
    const void* aad = lua_isnoneornil(L, 5) ? nullptr : luaL_checkbuffer(L, 5, &aadLen);
    check_openssl_input_len(L, nonceLen, "nonce");
    check_openssl_input_len(L, ctLen, "ciphertext");
    check_openssl_input_len(L, tagLen, "tag");
    check_openssl_input_len(L, aadLen, "aad");

    const EVP_CIPHER* cipher = cipher_for_key_len(L, keyLen);
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) push_openssl_error(L, op);

    int outLen = 0;
    int totalLen = 0;
    void* pt_buf = lua_newbuffer(L, ctLen);

    if (EVP_DecryptInit_ex(ctx, cipher, nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)nonceLen, nullptr) != 1 ||
        EVP_DecryptInit_ex(ctx, nullptr, nullptr, (const unsigned char*)key,
                           (const unsigned char*)nonce) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, (int)tagLen, (void*)tag) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }

    if (aadLen > 0 &&
        EVP_DecryptUpdate(ctx, nullptr, &outLen, (const unsigned char*)aad, (int)aadLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }

    if (ctLen > 0 && EVP_DecryptUpdate(ctx, (unsigned char*)pt_buf, &outLen,
                                       (const unsigned char*)ct, (int)ctLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, op);
    }
    totalLen = outLen;

    int finalOk = EVP_DecryptFinal_ex(ctx, (unsigned char*)pt_buf + totalLen, &outLen);
    EVP_CIPHER_CTX_free(ctx);

    if (finalOk != 1) luaL_error(L, "aead_decrypt: authentication tag mismatch");
    totalLen += outLen;
    resize_top_buffer(L, totalLen);
    return 1;
}

static int aead_ccm_encrypt(lua_State* L,
                            const EVP_CIPHER* (*cipher_for_key_len)(lua_State*, size_t)) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t nonceLen = 0;
    const void* nonce = luaL_checkbuffer(L, 2, &nonceLen);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 3, &ptLen);
    size_t aadLen = 0;
    const void* aad = lua_isnoneornil(L, 4) ? nullptr : luaL_checkbuffer(L, 4, &aadLen);
    int tagLen = check_ccm_tag_len(L, (int)luaL_optinteger(L, 5, 16));

    check_openssl_input_len(L, nonceLen, "nonce");
    check_openssl_input_len(L, ptLen, "plaintext");
    check_openssl_input_len(L, aadLen, "aad");

    const EVP_CIPHER* cipher = cipher_for_key_len(L, keyLen);
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) push_openssl_error(L, "aead_ccm_encrypt");

    int outLen = 0;
    void* tag_buf = lua_newbuffer(L, tagLen);
    size_t ctCapacity = ptLen == 0 ? 1 : ptLen;
    void* ct_buf = lua_newbuffer(L, ctCapacity);
    unsigned char dummy_pt = 0;
    unsigned char dummy_ct = 0;
    const unsigned char* pt_bytes = ptLen == 0 ? &dummy_pt : static_cast<const unsigned char*>(pt);
    unsigned char* ct_bytes = ptLen == 0 ? &dummy_ct : static_cast<unsigned char*>(ct_buf);

    if (EVP_EncryptInit_ex(ctx, cipher, nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)nonceLen, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, tagLen, nullptr) != 1 ||
        EVP_EncryptInit_ex(ctx, nullptr, nullptr, (const unsigned char*)key,
                           (const unsigned char*)nonce) != 1 ||
        EVP_EncryptUpdate(ctx, nullptr, &outLen, nullptr, (int)ptLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, "aead_ccm_encrypt");
    }

    if (aadLen > 0 &&
        EVP_EncryptUpdate(ctx, nullptr, &outLen, (const unsigned char*)aad, (int)aadLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, "aead_ccm_encrypt");
    }

    if (EVP_EncryptUpdate(ctx, ct_bytes, &outLen, pt_bytes, (int)ptLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, "aead_ccm_encrypt");
    }

    if (EVP_EncryptFinal_ex(ctx, nullptr, &outLen) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, tagLen, tag_buf) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, "aead_ccm_encrypt");
    }

    EVP_CIPHER_CTX_free(ctx);
    resize_top_buffer(L, ptLen);
    lua_insert(L, -2);
    return 2;
}

static int aead_ccm_decrypt(lua_State* L,
                            const EVP_CIPHER* (*cipher_for_key_len)(lua_State*, size_t)) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t nonceLen = 0;
    const void* nonce = luaL_checkbuffer(L, 2, &nonceLen);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 3, &ctLen);
    size_t tagLen = 0;
    const void* tag = luaL_checkbuffer(L, 4, &tagLen);
    size_t aadLen = 0;
    const void* aad = lua_isnoneornil(L, 5) ? nullptr : luaL_checkbuffer(L, 5, &aadLen);

    const EVP_CIPHER* cipher = cipher_for_key_len(L, keyLen);
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) push_openssl_error(L, "aead_ccm_decrypt");

    int outLen = 0;
    void* pt_buf = lua_newbuffer(L, ctLen);

    if (EVP_DecryptInit_ex(ctx, cipher, nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)nonceLen, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, (int)tagLen, (void*)tag) != 1 ||
        EVP_DecryptInit_ex(ctx, nullptr, nullptr, (const unsigned char*)key,
                           (const unsigned char*)nonce) != 1 ||
        EVP_DecryptUpdate(ctx, nullptr, &outLen, nullptr, (int)ctLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, "aead_ccm_decrypt");
    }

    if (aadLen > 0 &&
        EVP_DecryptUpdate(ctx, nullptr, &outLen, (const unsigned char*)aad, (int)aadLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        push_openssl_error(L, "aead_ccm_decrypt");
    }

    int ok = EVP_DecryptUpdate(ctx, (unsigned char*)pt_buf, &outLen, (const unsigned char*)ct,
                               (int)ctLen);
    EVP_CIPHER_CTX_free(ctx);
    if (ok != 1) luaL_error(L, "aead_decrypt: authentication tag mismatch");

    resize_top_buffer(L, outLen);
    return 1;
}

static int aes_ccm_encrypt(lua_State* L) { return aead_ccm_encrypt(L, aes_ccm_cipher_for_key_len); }
static int aes_ccm_decrypt(lua_State* L) { return aead_ccm_decrypt(L, aes_ccm_cipher_for_key_len); }

static void push_aes_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, aes_new, "new");
    lua_setfield(L, -2, "new");
    lua_pushcfunction(L, aes_ccm_encrypt, "ccm_encrypt");
    lua_setfield(L, -2, "ccm_encrypt");
    lua_pushcfunction(L, aes_ccm_decrypt, "ccm_decrypt");
    lua_setfield(L, -2, "ccm_decrypt");
}

static void push_camellia_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, camellia_new, "new");
    lua_setfield(L, -2, "new");
}

static void push_des_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, des_new, "new");
    lua_setfield(L, -2, "new");
}

static void push_chacha20_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, chacha20_new, "new");
    lua_setfield(L, -2, "new");
}

static void push_hmac_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, hmac_new, "new");
    lua_setfield(L, -2, "new");
}

// ---------------------------------------------------------------------------
// KDF - HKDF and PBKDF2
// ---------------------------------------------------------------------------

static int kdf_hkdf(lua_State* L, const EVP_MD* md) {
    size_t ikmLen = 0;
    const void* ikm = luaL_checkbuffer(L, 1, &ikmLen);
    size_t saltLen = 0;
    const void* salt = lua_isnoneornil(L, 2) ? nullptr : luaL_checkbuffer(L, 2, &saltLen);
    size_t infoLen = 0;
    const void* info = lua_isnoneornil(L, 3) ? nullptr : luaL_checkbuffer(L, 3, &infoLen);
    size_t outLen = (size_t)luaL_checkinteger(L, 4);
    EVP_KDF* kdf = EVP_KDF_fetch(nullptr, "HKDF", nullptr);
    EVP_KDF_CTX* ctx = kdf ? EVP_KDF_CTX_new(kdf) : nullptr;
    if (!ctx) {
        EVP_KDF_free(kdf);
        push_openssl_error(L, "hkdf");
    }

    const char* digest_name = EVP_MD_get0_name(md);
    unsigned char empty = 0;
    void* saltParam = const_cast<void*>(salt ? salt : &empty);
    void* infoParam = const_cast<void*>(info ? info : &empty);
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_utf8_string(OSSL_KDF_PARAM_DIGEST, const_cast<char*>(digest_name), 0),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_KEY, const_cast<void*>(ikm), ikmLen),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, saltParam, saltLen),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_INFO, infoParam, infoLen),
        OSSL_PARAM_construct_end(),
    };

    void* out = lua_newbuffer(L, outLen);
    int ok = EVP_KDF_derive(ctx, (unsigned char*)out, outLen, params);
    EVP_KDF_CTX_free(ctx);
    EVP_KDF_free(kdf);
    if (ok != 1) push_openssl_error(L, "hkdf");

    return 1;
}

static int kdf_pbkdf2(lua_State* L, const EVP_MD* md) {
    size_t pwdLen = 0;
    const void* pwd = luaL_checkbuffer(L, 1, &pwdLen);
    size_t saltLen = 0;
    const void* salt = luaL_checkbuffer(L, 2, &saltLen);
    uint64_t iters = (uint64_t)luaL_checkinteger(L, 3);
    size_t outLen = (size_t)luaL_checkinteger(L, 4);
    EVP_KDF* kdf = EVP_KDF_fetch(nullptr, "PBKDF2", nullptr);
    EVP_KDF_CTX* ctx = kdf ? EVP_KDF_CTX_new(kdf) : nullptr;
    if (!ctx) {
        EVP_KDF_free(kdf);
        push_openssl_error(L, "pbkdf2");
    }

    const char* digest_name = EVP_MD_get0_name(md);
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_PASSWORD, const_cast<void*>(pwd), pwdLen),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, const_cast<void*>(salt), saltLen),
        OSSL_PARAM_construct_uint64(OSSL_KDF_PARAM_ITER, &iters),
        OSSL_PARAM_construct_utf8_string(OSSL_KDF_PARAM_DIGEST, const_cast<char*>(digest_name), 0),
        OSSL_PARAM_construct_end(),
    };

    void* out = lua_newbuffer(L, outLen);
    int ok = EVP_KDF_derive(ctx, (unsigned char*)out, outLen, params);
    EVP_KDF_CTX_free(ctx);
    EVP_KDF_free(kdf);
    if (ok != 1) push_openssl_error(L, "pbkdf2");

    return 1;
}

static int kdf_hkdf_sha256(lua_State* L) { return kdf_hkdf(L, EVP_sha256()); }
static int kdf_hkdf_sha512(lua_State* L) { return kdf_hkdf(L, EVP_sha512()); }
static int kdf_pbkdf2_sha256(lua_State* L) { return kdf_pbkdf2(L, EVP_sha256()); }
static int kdf_pbkdf2_sha512(lua_State* L) { return kdf_pbkdf2(L, EVP_sha512()); }

// ---------------------------------------------------------------------------
// ECC
// ---------------------------------------------------------------------------

// generate_key(curve?) -> private_pem: string
static int ecc_generate_key(lua_State* L) {
    const char* curve = luaL_optstring(L, 1, "secp256r1");
    const char* group_name = openssl_ec_group_name_from_curve(L, curve);

    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr);
    if (!ctx) push_openssl_error(L, "ecc_generate_key");

    if (EVP_PKEY_keygen_init(ctx) != 1) {
        EVP_PKEY_CTX_free(ctx);
        push_openssl_error(L, "ecc_generate_key");
    }

    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, const_cast<char*>(group_name),
                                         0),
        OSSL_PARAM_construct_end(),
    };
    if (EVP_PKEY_CTX_set_params(ctx, params) != 1) {
        EVP_PKEY_CTX_free(ctx);
        push_openssl_error(L, "ecc_generate_key");
    }

    EVP_PKEY* pkey = nullptr;
    if (EVP_PKEY_generate(ctx, &pkey) != 1) {
        EVP_PKEY_CTX_free(ctx);
        push_openssl_error(L, "ecc_generate_key");
    }
    EVP_PKEY_CTX_free(ctx);

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_generate_key");
    }

    if (PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_generate_key");
    }

    std::string pem = bio_to_string(L, bio, "ecc_generate_key");
    BIO_free(bio);
    EVP_PKEY_free(pkey);

    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

// get_public_pem(private_pem: string) -> public_pem: string
static int ecc_get_public_pem(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey =
        ensure_ec_key(L, "ecc_get_public_pem", load_private_key_pem(L, "ecc_get_public_pem", pem));

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_get_public_pem");
    }

    if (PEM_write_bio_PUBKEY(bio, pkey) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_get_public_pem");
    }

    std::string public_pem = bio_to_string(L, bio, "ecc_get_public_pem");
    BIO_free(bio);
    EVP_PKEY_free(pkey);

    lua_pushlstring(L, public_pem.data(), public_pem.size());
    return 1;
}

// sign(private_pem, data, hash?) -> signature
static int ecc_sign(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey = ensure_ec_key(L, "ecc_sign", load_private_key_pem(L, "ecc_sign", pem));
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_sign");
    }

    if (EVP_DigestSignInit(ctx, nullptr, md, nullptr, pkey) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_sign");
    }

    if (EVP_DigestSignUpdate(ctx, data, dataLen) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_sign");
    }

    size_t sig_len = 0;
    if (EVP_DigestSignFinal(ctx, nullptr, &sig_len) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_sign");
    }

    void* sig = lua_newbuffer(L, sig_len);
    if (EVP_DigestSignFinal(ctx, (unsigned char*)sig, &sig_len) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_sign");
    }

    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);

    size_t allocated_sig_len = lua_objlen(L, -1);
    if (sig_len != allocated_sig_len) {
        void* resized_sig = lua_newbuffer(L, sig_len);
        memcpy(resized_sig, sig, sig_len);
        lua_replace(L, -2);
    }

    return 1;
}

// verify(public_pem, data, signature, hash?) -> boolean
static int ecc_verify(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    size_t sigLen = 0;
    const void* sig = luaL_checkbuffer(L, 3, &sigLen);
    const char* hash_name = luaL_optstring(L, 4, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey = ensure_ec_key(L, "ecc_verify", load_public_key_pem(L, "ecc_verify", pem));
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_verify");
    }

    if (EVP_DigestVerifyInit(ctx, nullptr, md, nullptr, pkey) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_verify");
    }

    if (EVP_DigestVerifyUpdate(ctx, data, dataLen) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_verify");
    }

    int verify_ok = EVP_DigestVerifyFinal(ctx, (const unsigned char*)sig, sigLen);
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    if (verify_ok < 0) push_openssl_error(L, "ecc_verify");

    lua_pushboolean(L, verify_ok == 1);
    return 1;
}

// derive(private_pem, peer_public_pem) -> shared_secret
static int ecc_derive(lua_State* L) {
    const char* private_pem = luaL_checkstring(L, 1);
    const char* peer_public_pem = luaL_checkstring(L, 2);
    EVP_PKEY* private_key =
        ensure_ec_key(L, "ecc_derive", load_private_key_pem(L, "ecc_derive", private_pem));
    EVP_PKEY* peer_key =
        ensure_ec_key(L, "ecc_derive", load_public_key_pem(L, "ecc_derive", peer_public_pem));

    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new(private_key, nullptr);
    if (!ctx) {
        EVP_PKEY_free(private_key);
        EVP_PKEY_free(peer_key);
        push_openssl_error(L, "ecc_derive");
    }

    if (EVP_PKEY_derive_init(ctx) != 1 || EVP_PKEY_derive_set_peer(ctx, peer_key) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(private_key);
        EVP_PKEY_free(peer_key);
        push_openssl_error(L, "ecc_derive");
    }

    size_t secret_len = 0;
    if (EVP_PKEY_derive(ctx, nullptr, &secret_len) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(private_key);
        EVP_PKEY_free(peer_key);
        push_openssl_error(L, "ecc_derive");
    }

    void* secret = lua_newbuffer(L, secret_len);
    if (EVP_PKEY_derive(ctx, (unsigned char*)secret, &secret_len) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(private_key);
        EVP_PKEY_free(peer_key);
        push_openssl_error(L, "ecc_derive");
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(private_key);
    EVP_PKEY_free(peer_key);
    return 1;
}

// private_to_der(private_pem: string) -> buffer
static int ecc_private_to_der(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey =
        ensure_ec_key(L, "ecc_private_to_der", load_private_key_pem(L, "ecc_private_to_der", pem));

    int der_len = i2d_PrivateKey(pkey, nullptr);
    if (der_len <= 0) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_private_to_der");
    }

    void* out = lua_newbuffer(L, (size_t)der_len);
    unsigned char* der_ptr = (unsigned char*)out;
    if (i2d_PrivateKey(pkey, &der_ptr) != der_len) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_private_to_der");
    }

    EVP_PKEY_free(pkey);
    return 1;
}

// public_to_der(public_pem: string) -> buffer
static int ecc_public_to_der(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey =
        ensure_ec_key(L, "ecc_public_to_der", load_public_key_pem(L, "ecc_public_to_der", pem));

    int der_len = i2d_PUBKEY(pkey, nullptr);
    if (der_len <= 0) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_public_to_der");
    }

    void* out = lua_newbuffer(L, (size_t)der_len);
    unsigned char* der_ptr = (unsigned char*)out;
    if (i2d_PUBKEY(pkey, &der_ptr) != der_len) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_public_to_der");
    }

    EVP_PKEY_free(pkey);
    return 1;
}

// private_from_der(der: buffer) -> private_pem: string
static int ecc_private_from_der(lua_State* L) {
    size_t derLen = 0;
    const void* der = luaL_checkbuffer(L, 1, &derLen);
    EVP_PKEY* pkey = ensure_ec_key(L, "ecc_private_from_der",
                                   load_private_key_der(L, "ecc_private_from_der", der, derLen));

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_private_from_der");
    }

    if (PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_private_from_der");
    }

    std::string pem = bio_to_string(L, bio, "ecc_private_from_der");
    BIO_free(bio);
    EVP_PKEY_free(pkey);

    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

// public_from_der(der: buffer) -> public_pem: string
static int ecc_public_from_der(lua_State* L) {
    size_t derLen = 0;
    const void* der = luaL_checkbuffer(L, 1, &derLen);
    EVP_PKEY* pkey = ensure_ec_key(L, "ecc_public_from_der",
                                   load_public_key_der(L, "ecc_public_from_der", der, derLen));

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_public_from_der");
    }

    if (PEM_write_bio_PUBKEY(bio, pkey) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "ecc_public_from_der");
    }

    std::string pem = bio_to_string(L, bio, "ecc_public_from_der");
    BIO_free(bio);
    EVP_PKEY_free(pkey);

    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

// get_key_bits(pem: string) -> number
static int ecc_get_key_bits(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey = nullptr;

    ERR_clear_error();
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, "ecc_get_key_bits");
    pkey = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!pkey) {
        ERR_clear_error();
        bio = BIO_new_mem_buf(pem, -1);
        if (!bio) push_openssl_error(L, "ecc_get_key_bits");
        pkey = PEM_read_bio_PUBKEY(bio, nullptr, nullptr, nullptr);
        BIO_free(bio);
    }
    if (!pkey) push_openssl_error(L, "ecc_get_key_bits");
    pkey = ensure_ec_key(L, "ecc_get_key_bits", pkey);

    lua_pushnumber(L, (lua_Number)EVP_PKEY_get_bits(pkey));
    EVP_PKEY_free(pkey);
    return 1;
}

// get_curve(pem: string) -> string
static int ecc_get_curve(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey = nullptr;

    ERR_clear_error();
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, "ecc_get_curve");
    pkey = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!pkey) {
        ERR_clear_error();
        bio = BIO_new_mem_buf(pem, -1);
        if (!bio) push_openssl_error(L, "ecc_get_curve");
        pkey = PEM_read_bio_PUBKEY(bio, nullptr, nullptr, nullptr);
        BIO_free(bio);
    }
    if (!pkey) push_openssl_error(L, "ecc_get_curve");
    pkey = ensure_ec_key(L, "ecc_get_curve", pkey);

    std::string curve = get_ec_group_name(L, pkey, "ecc_get_curve");
    EVP_PKEY_free(pkey);
    lua_pushlstring(L, curve.data(), curve.size());
    return 1;
}

static void push_ecc_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, ecc_generate_key, "generate_key");
    lua_setfield(L, -2, "generate_key");
    lua_pushcfunction(L, ecc_get_public_pem, "get_public_pem");
    lua_setfield(L, -2, "get_public_pem");
    lua_pushcfunction(L, ecc_sign, "sign");
    lua_setfield(L, -2, "sign");
    lua_pushcfunction(L, ecc_verify, "verify");
    lua_setfield(L, -2, "verify");
    lua_pushcfunction(L, ecc_derive, "derive");
    lua_setfield(L, -2, "derive");
    lua_pushcfunction(L, ecc_private_to_der, "private_to_der");
    lua_setfield(L, -2, "private_to_der");
    lua_pushcfunction(L, ecc_public_to_der, "public_to_der");
    lua_setfield(L, -2, "public_to_der");
    lua_pushcfunction(L, ecc_private_from_der, "private_from_der");
    lua_setfield(L, -2, "private_from_der");
    lua_pushcfunction(L, ecc_public_from_der, "public_from_der");
    lua_setfield(L, -2, "public_from_der");
    lua_pushcfunction(L, ecc_get_key_bits, "get_key_bits");
    lua_setfield(L, -2, "get_key_bits");
    lua_pushcfunction(L, ecc_get_curve, "get_curve");
    lua_setfield(L, -2, "get_curve");
}

// ---------------------------------------------------------------------------
// RSA
// ---------------------------------------------------------------------------

// generate_key(bits?) -> private_pem: string
static int rsa_generate_key(lua_State* L) {
    int bits = (int)luaL_optinteger(L, 1, 2048);
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_from_name(nullptr, "RSA", nullptr);
    if (!ctx) push_openssl_error(L, "rsa_generate_key");
    if (EVP_PKEY_keygen_init(ctx) != 1 || EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) != 1) {
        EVP_PKEY_CTX_free(ctx);
        push_openssl_error(L, "rsa_generate_key");
    }

    EVP_PKEY* pkey = nullptr;
    if (EVP_PKEY_generate(ctx, &pkey) != 1) {
        EVP_PKEY_CTX_free(ctx);
        push_openssl_error(L, "rsa_generate_key");
    }
    EVP_PKEY_CTX_free(ctx);

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_generate_key");
    }

    if (PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_generate_key");
    }

    std::string pem = bio_to_string(L, bio, "rsa_generate_key");
    BIO_free(bio);
    EVP_PKEY_free(pkey);
    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

// get_public_pem(private_pem: string) -> public_pem: string
static int rsa_get_public_pem(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_get_public_pem", load_private_key_pem(L, "rsa_get_public_pem", pem));

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_get_public_pem");
    }

    if (PEM_write_bio_PUBKEY(bio, pkey) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_get_public_pem");
    }

    std::string public_pem = bio_to_string(L, bio, "rsa_get_public_pem");
    BIO_free(bio);
    EVP_PKEY_free(pkey);
    lua_pushlstring(L, public_pem.data(), public_pem.size());
    return 1;
}

// encrypt_pkcs1(public_pem, data) -> ciphertext
static int rsa_encrypt_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 2, &ptLen);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_encrypt_pkcs1", load_public_key_pem(L, "rsa_encrypt_pkcs1", pem));
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new(pkey, nullptr);
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_pkcs1");
    }
    if (EVP_PKEY_encrypt_init(ctx) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_PADDING) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_pkcs1");
    }

    size_t out_len = 0;
    if (EVP_PKEY_encrypt(ctx, nullptr, &out_len, (const unsigned char*)pt, ptLen) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_pkcs1");
    }

    void* out = lua_newbuffer(L, out_len);
    if (EVP_PKEY_encrypt(ctx, (unsigned char*)out, &out_len, (const unsigned char*)pt, ptLen) !=
        1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_pkcs1");
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    resize_top_buffer(L, out_len);
    return 1;
}

// decrypt_pkcs1(private_pem, ciphertext) -> plaintext
static int rsa_decrypt_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 2, &ctLen);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_decrypt_pkcs1", load_private_key_pem(L, "rsa_decrypt_pkcs1", pem));
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new(pkey, nullptr);
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_pkcs1");
    }
    if (EVP_PKEY_decrypt_init(ctx) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_PADDING) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_pkcs1");
    }

    size_t out_len = 0;
    if (EVP_PKEY_decrypt(ctx, nullptr, &out_len, (const unsigned char*)ct, ctLen) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_pkcs1");
    }

    void* out = lua_newbuffer(L, out_len);
    if (EVP_PKEY_decrypt(ctx, (unsigned char*)out, &out_len, (const unsigned char*)ct, ctLen) !=
        1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_pkcs1");
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    resize_top_buffer(L, out_len);
    return 1;
}

// encrypt_oaep(public_pem, data, hash?) -> ciphertext  (hash: "sha256"|"sha1", default sha256)
static int rsa_encrypt_oaep(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 2, &ptLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_encrypt_oaep", load_public_key_pem(L, "rsa_encrypt_oaep", pem));
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new(pkey, nullptr);
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_oaep");
    }
    if (EVP_PKEY_encrypt_init(ctx) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING) != 1 ||
        EVP_PKEY_CTX_set_rsa_oaep_md(ctx, md) != 1 || EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, md) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_oaep");
    }

    size_t out_len = 0;
    if (EVP_PKEY_encrypt(ctx, nullptr, &out_len, (const unsigned char*)pt, ptLen) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_oaep");
    }

    void* out = lua_newbuffer(L, out_len);
    if (EVP_PKEY_encrypt(ctx, (unsigned char*)out, &out_len, (const unsigned char*)pt, ptLen) !=
        1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_encrypt_oaep");
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    resize_top_buffer(L, out_len);
    return 1;
}

// decrypt_oaep(private_pem, ciphertext, hash?) -> plaintext
static int rsa_decrypt_oaep(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 2, &ctLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_decrypt_oaep", load_private_key_pem(L, "rsa_decrypt_oaep", pem));
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new(pkey, nullptr);
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_oaep");
    }
    if (EVP_PKEY_decrypt_init(ctx) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING) != 1 ||
        EVP_PKEY_CTX_set_rsa_oaep_md(ctx, md) != 1 || EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, md) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_oaep");
    }

    size_t out_len = 0;
    if (EVP_PKEY_decrypt(ctx, nullptr, &out_len, (const unsigned char*)ct, ctLen) != 1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_oaep");
    }

    void* out = lua_newbuffer(L, out_len);
    if (EVP_PKEY_decrypt(ctx, (unsigned char*)out, &out_len, (const unsigned char*)ct, ctLen) !=
        1) {
        EVP_PKEY_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_decrypt_oaep");
    }

    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    resize_top_buffer(L, out_len);
    return 1;
}

// sign_pkcs1(private_pem, data, hash?) -> signature
static int rsa_sign_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_sign_pkcs1", load_private_key_pem(L, "rsa_sign_pkcs1", pem));
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pkcs1");
    }

    EVP_PKEY_CTX* pctx = nullptr;
    if (EVP_DigestSignInit(ctx, &pctx, md, nullptr, pkey) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PADDING) != 1 ||
        EVP_DigestSignUpdate(ctx, data, dataLen) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pkcs1");
    }

    size_t sig_len = 0;
    if (EVP_DigestSignFinal(ctx, nullptr, &sig_len) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pkcs1");
    }

    void* sig = lua_newbuffer(L, sig_len);
    if (EVP_DigestSignFinal(ctx, (unsigned char*)sig, &sig_len) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pkcs1");
    }

    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    resize_top_buffer(L, sig_len);
    return 1;
}

// verify_pkcs1(public_pem, data, signature, hash?) -> boolean
static int rsa_verify_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    size_t sigLen = 0;
    const void* sig = luaL_checkbuffer(L, 3, &sigLen);
    const char* hash_name = luaL_optstring(L, 4, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_verify_pkcs1", load_public_key_pem(L, "rsa_verify_pkcs1", pem));
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_verify_pkcs1");
    }

    EVP_PKEY_CTX* pctx = nullptr;
    if (EVP_DigestVerifyInit(ctx, &pctx, md, nullptr, pkey) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PADDING) != 1 ||
        EVP_DigestVerifyUpdate(ctx, data, dataLen) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_verify_pkcs1");
    }

    int verify_ok = EVP_DigestVerifyFinal(ctx, (const unsigned char*)sig, sigLen);
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    if (verify_ok < 0) push_openssl_error(L, "rsa_verify_pkcs1");

    lua_pushboolean(L, verify_ok == 1);
    return 1;
}

// sign_pss(private_pem, data, hash?) -> signature
static int rsa_sign_pss(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_sign_pss", load_private_key_pem(L, "rsa_sign_pss", pem));
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pss");
    }

    EVP_PKEY_CTX* pctx = nullptr;
    if (EVP_DigestSignInit(ctx, &pctx, md, nullptr, pkey) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) != 1 ||
        EVP_PKEY_CTX_set_rsa_mgf1_md(pctx, md) != 1 ||
        EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) != 1 ||
        EVP_DigestSignUpdate(ctx, data, dataLen) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pss");
    }

    size_t sig_len = 0;
    if (EVP_DigestSignFinal(ctx, nullptr, &sig_len) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pss");
    }

    void* sig = lua_newbuffer(L, sig_len);
    if (EVP_DigestSignFinal(ctx, (unsigned char*)sig, &sig_len) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_sign_pss");
    }

    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    resize_top_buffer(L, sig_len);
    return 1;
}

// verify_pss(public_pem, data, signature, hash?) -> boolean
static int rsa_verify_pss(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    size_t sigLen = 0;
    const void* sig = luaL_checkbuffer(L, 3, &sigLen);
    const char* hash_name = luaL_optstring(L, 4, "sha256");
    const EVP_MD* md = openssl_md_from_name(L, hash_name);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_verify_pss", load_public_key_pem(L, "rsa_verify_pss", pem));
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_verify_pss");
    }

    EVP_PKEY_CTX* pctx = nullptr;
    if (EVP_DigestVerifyInit(ctx, &pctx, md, nullptr, pkey) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) != 1 ||
        EVP_PKEY_CTX_set_rsa_mgf1_md(pctx, md) != 1 ||
        EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) != 1 ||
        EVP_DigestVerifyUpdate(ctx, data, dataLen) != 1) {
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_verify_pss");
    }

    int verify_ok = EVP_DigestVerifyFinal(ctx, (const unsigned char*)sig, sigLen);
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    if (verify_ok < 0) push_openssl_error(L, "rsa_verify_pss");

    lua_pushboolean(L, verify_ok == 1);
    return 1;
}

// private_to_der(private_pem: string) -> buffer
static int rsa_private_to_der(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_private_to_der", load_private_key_pem(L, "rsa_private_to_der", pem));
    int der_len = i2d_PrivateKey(pkey, nullptr);
    if (der_len <= 0) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_private_to_der");
    }
    void* out = lua_newbuffer(L, (size_t)der_len);
    unsigned char* der_ptr = (unsigned char*)out;
    if (i2d_PrivateKey(pkey, &der_ptr) != der_len) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_private_to_der");
    }
    EVP_PKEY_free(pkey);
    return 1;
}

// public_to_der(public_pem: string) -> buffer
static int rsa_public_to_der(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey =
        ensure_rsa_key(L, "rsa_public_to_der", load_public_key_pem(L, "rsa_public_to_der", pem));
    int der_len = i2d_PUBKEY(pkey, nullptr);
    if (der_len <= 0) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_public_to_der");
    }
    void* out = lua_newbuffer(L, (size_t)der_len);
    unsigned char* der_ptr = (unsigned char*)out;
    if (i2d_PUBKEY(pkey, &der_ptr) != der_len) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_public_to_der");
    }
    EVP_PKEY_free(pkey);
    return 1;
}

// private_from_der(der: buffer) -> private_pem: string
static int rsa_private_from_der(lua_State* L) {
    size_t derLen = 0;
    const void* der = luaL_checkbuffer(L, 1, &derLen);
    EVP_PKEY* pkey = ensure_rsa_key(L, "rsa_private_from_der",
                                    load_private_key_der(L, "rsa_private_from_der", der, derLen));
    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_private_from_der");
    }
    if (PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_private_from_der");
    }
    std::string pem = bio_to_string(L, bio, "rsa_private_from_der");
    BIO_free(bio);
    EVP_PKEY_free(pkey);
    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

// public_from_der(der: buffer) -> public_pem: string
static int rsa_public_from_der(lua_State* L) {
    size_t derLen = 0;
    const void* der = luaL_checkbuffer(L, 1, &derLen);
    EVP_PKEY* pkey = ensure_rsa_key(L, "rsa_public_from_der",
                                    load_public_key_der(L, "rsa_public_from_der", der, derLen));
    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_public_from_der");
    }
    if (PEM_write_bio_PUBKEY(bio, pkey) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "rsa_public_from_der");
    }
    std::string pem = bio_to_string(L, bio, "rsa_public_from_der");
    BIO_free(bio);
    EVP_PKEY_free(pkey);
    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

// get_key_bits(pem: string) -> number  (accepts private or public PEM)
static int rsa_get_key_bits(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    EVP_PKEY* pkey = ensure_rsa_key(L, "rsa_get_key_bits",
                                    load_any_private_or_public_pem(L, "rsa_get_key_bits", pem));
    lua_pushnumber(L, (lua_Number)EVP_PKEY_get_bits(pkey));
    EVP_PKEY_free(pkey);
    return 1;
}

// Helper: fill buffer with secure random bytes
static void secure_random_bytes(lua_State* L, void* out, size_t out_len) {
    check_openssl_input_len(L, out_len, "random bytes");
    if (RAND_bytes((unsigned char*)out, (int)out_len) != 1) push_openssl_error(L, "RAND_bytes");
}

// Helper: generate a 64-bit random value
static uint64_t secure_random_u64(lua_State* L) {
    uint64_t v = 0;
    secure_random_bytes(L, &v, sizeof(v));
    return v;
}

// random.randint(N) -> integer in [0, N]
static int random_randint(lua_State* L) {
    lua_Integer n = luaL_checkinteger(L, 1);
    if (n < 0) luaL_error(L, "n must be non-negative");
    if (n == 0) {
        lua_pushinteger(L, 0);
        return 1;
    }

    uint64_t bound = (uint64_t)n + 1ULL;
    uint64_t limit = UINT64_MAX - (UINT64_MAX % bound);
    while (true) {
        uint64_t r = secure_random_u64(L);
        if (r < limit) {
            lua_pushinteger(L, (lua_Integer)(r % bound));
            return 1;
        }
    }
}

// random.choice(tbl) -> element
static int random_choice(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer len = lua_objlen(L, 1);
    if (len <= 0) luaL_error(L, "table is empty");

    // choose index in 1..len
    uint64_t bound = (uint64_t)len;
    uint64_t limit = UINT64_MAX - (UINT64_MAX % bound);
    uint64_t idx;
    while (true) {
        uint64_t r = secure_random_u64(L);
        if (r < limit) {
            idx = (r % bound) + 1;
            break;
        }
    }

    lua_rawgeti(L, 1, (lua_Integer)idx);
    return 1;
}

// random.bits(n) -> non-negative integer with n random bits (n <= 64)
static int random_bits(lua_State* L) {
    int n = (int)luaL_checkinteger(L, 1);
    if (n < 0 || n > 64) luaL_error(L, "bits must be between 0 and 64");
    if (n == 0) {
        lua_pushinteger(L, 0);
        return 1;
    }

    uint64_t v = secure_random_u64(L);
    if (n < 64) v &= ((1ULL << n) - 1ULL);
    lua_pushinteger(L, (lua_Integer)v);
    return 1;
}

// random.bytes(n) -> buffer
static int random_bytes(lua_State* L) {
    size_t n = (size_t)luaL_checkinteger(L, 1);
    void* buf = lua_newbuffer(L, n);
    secure_random_bytes(L, buf, n);
    return 1;
}

// random.hex(n) -> hex string of n bytes
static int random_hex(lua_State* L) {
    size_t n = (size_t)luaL_checkinteger(L, 1);
    std::vector<uint8_t> tmp(n);
    secure_random_bytes(L, tmp.data(), n);

    static const char* hex = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) {
        s.push_back(hex[(tmp[i] >> 4) & 0xF]);
        s.push_back(hex[tmp[i] & 0xF]);
    }

    lua_pushlstring(L, s.c_str(), s.size());
    return 1;
}

static void push_rsa_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, rsa_generate_key, "generate_key");
    lua_setfield(L, -2, "generate_key");
    lua_pushcfunction(L, rsa_get_public_pem, "get_public_pem");
    lua_setfield(L, -2, "get_public_pem");
    lua_pushcfunction(L, rsa_encrypt_pkcs1, "encrypt_pkcs1");
    lua_setfield(L, -2, "encrypt_pkcs1");
    lua_pushcfunction(L, rsa_decrypt_pkcs1, "decrypt_pkcs1");
    lua_setfield(L, -2, "decrypt_pkcs1");
    lua_pushcfunction(L, rsa_encrypt_oaep, "encrypt_oaep");
    lua_setfield(L, -2, "encrypt_oaep");
    lua_pushcfunction(L, rsa_decrypt_oaep, "decrypt_oaep");
    lua_setfield(L, -2, "decrypt_oaep");
    lua_pushcfunction(L, rsa_sign_pkcs1, "sign_pkcs1");
    lua_setfield(L, -2, "sign_pkcs1");
    lua_pushcfunction(L, rsa_verify_pkcs1, "verify_pkcs1");
    lua_setfield(L, -2, "verify_pkcs1");
    lua_pushcfunction(L, rsa_sign_pss, "sign_pss");
    lua_setfield(L, -2, "sign_pss");
    lua_pushcfunction(L, rsa_verify_pss, "verify_pss");
    lua_setfield(L, -2, "verify_pss");
    lua_pushcfunction(L, rsa_private_to_der, "private_to_der");
    lua_setfield(L, -2, "private_to_der");
    lua_pushcfunction(L, rsa_public_to_der, "public_to_der");
    lua_setfield(L, -2, "public_to_der");
    lua_pushcfunction(L, rsa_private_from_der, "private_from_der");
    lua_setfield(L, -2, "private_from_der");
    lua_pushcfunction(L, rsa_public_from_der, "public_from_der");
    lua_setfield(L, -2, "public_from_der");
    lua_pushcfunction(L, rsa_get_key_bits, "get_key_bits");
    lua_setfield(L, -2, "get_key_bits");
}

static void push_kdf_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, kdf_hkdf_sha256, "hkdf_sha256");
    lua_setfield(L, -2, "hkdf_sha256");
    lua_pushcfunction(L, kdf_hkdf_sha512, "hkdf_sha512");
    lua_setfield(L, -2, "hkdf_sha512");
    lua_pushcfunction(L, kdf_pbkdf2_sha256, "pbkdf2_sha256");
    lua_setfield(L, -2, "pbkdf2_sha256");
    lua_pushcfunction(L, kdf_pbkdf2_sha512, "pbkdf2_sha512");
    lua_setfield(L, -2, "pbkdf2_sha512");
}

static void push_hash_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, hash_new, "new");
    lua_setfield(L, -2, "new");

    // Legacy one-shot hash helpers kept commented out during the
    // streaming API transition.
    /*
    lua_pushcfunction(L, hash_md5, "md5");
    lua_setfield(L, -2, "md5");
    lua_pushcfunction(L, hash_sha1, "sha1");
    lua_setfield(L, -2, "sha1");
    lua_pushcfunction(L, hash_sha224, "sha224");
    lua_setfield(L, -2, "sha224");
    lua_pushcfunction(L, hash_sha256, "sha256");
    lua_setfield(L, -2, "sha256");
    lua_pushcfunction(L, hash_sha384, "sha384");
    lua_setfield(L, -2, "sha384");
    lua_pushcfunction(L, hash_sha512, "sha512");
    lua_setfield(L, -2, "sha512");
    lua_pushcfunction(L, hash_sha3_224, "sha3_224");
    lua_setfield(L, -2, "sha3_224");
    lua_pushcfunction(L, hash_sha3_256, "sha3_256");
    lua_setfield(L, -2, "sha3_256");
    lua_pushcfunction(L, hash_sha3_384, "sha3_384");
    lua_setfield(L, -2, "sha3_384");
    lua_pushcfunction(L, hash_sha3_512, "sha3_512");
    lua_setfield(L, -2, "sha3_512");
    */
}

static void push_random_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, random_randint, "randint");
    lua_setfield(L, -2, "randint");
    lua_pushcfunction(L, random_choice, "choice");
    lua_setfield(L, -2, "choice");
    lua_pushcfunction(L, random_bits, "bits");
    lua_setfield(L, -2, "bits");
    lua_pushcfunction(L, random_bytes, "bytes");
    lua_setfield(L, -2, "bytes");
    lua_pushcfunction(L, random_hex, "hex");
    lua_setfield(L, -2, "hex");
}

luaL_Reg hashCtxMethods[] = {
    { "update", hash_ctx_update },
    { "final", hash_ctx_final },
    { "close", hash_ctx_close },
    { nullptr, nullptr },
};

luaL_Reg hashCtxMetamethods[] = {
    { "__tostring", hash_ctx_tostring },
    { nullptr, nullptr },
};

udataDef hashCtxDef = {
    .name = "crypto.hash.ctx",
    .size = sizeof(LuaHashCtx),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = hashCtxMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = hashCtxMethods,
    .destructor = hash_ctx_dtor,
};

luaL_Reg hmacCtxMethods[] = {
    { "update", hmac_ctx_update },
    { "final", hmac_ctx_final },
    { "close", hmac_ctx_close },
    { nullptr, nullptr },
};

luaL_Reg hmacCtxMetamethods[] = {
    { "__tostring", hmac_ctx_tostring },
    { nullptr, nullptr },
};

udataDef hmacCtxDef = {
    .name = "crypto.hmac.ctx",
    .size = sizeof(LuaHmacCtx),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = hmacCtxMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = hmacCtxMethods,
    .destructor = hmac_ctx_dtor,
};

luaL_Reg aesCtxMethods[] = {
    { "update", aes_ctx_update },  { "updateAAD", aes_ctx_update_aad },
    { "setTag", aes_ctx_set_tag }, { "getTag", aes_ctx_get_tag },
    { "final", aes_ctx_final },    { "close", aes_ctx_close },
    { nullptr, nullptr },
};

luaL_Reg aesCtxMetamethods[] = {
    { "__tostring", aes_ctx_tostring },
    { nullptr, nullptr },
};

udataDef aesCtxDef = {
    .name = "crypto.aes.ctx",
    .size = sizeof(LuaCipherCtx),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = aesCtxMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = aesCtxMethods,
    .destructor = cipher_ctx_dtor,
};

luaL_Reg camelliaCtxMethods[] = {
    { "update", camellia_ctx_update },
    { "updateAAD", camellia_ctx_update_aad },
    { "setTag", camellia_ctx_set_tag },
    { "getTag", camellia_ctx_get_tag },
    { "final", camellia_ctx_final },
    { "close", camellia_ctx_close },
    { nullptr, nullptr },
};

luaL_Reg camelliaCtxMetamethods[] = {
    { "__tostring", camellia_ctx_tostring },
    { nullptr, nullptr },
};

udataDef camelliaCtxDef = {
    .name = "crypto.camellia.ctx",
    .size = sizeof(LuaCipherCtx),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = camelliaCtxMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = camelliaCtxMethods,
    .destructor = cipher_ctx_dtor,
};

luaL_Reg desCtxMethods[] = {
    { "update", des_ctx_update },  { "updateAAD", des_ctx_update_aad },
    { "setTag", des_ctx_set_tag }, { "getTag", des_ctx_get_tag },
    { "final", des_ctx_final },    { "close", des_ctx_close },
    { nullptr, nullptr },
};

luaL_Reg desCtxMetamethods[] = {
    { "__tostring", des_ctx_tostring },
    { nullptr, nullptr },
};

udataDef desCtxDef = {
    .name = "crypto.des.ctx",
    .size = sizeof(LuaCipherCtx),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = desCtxMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = desCtxMethods,
    .destructor = cipher_ctx_dtor,
};

luaL_Reg chacha20CtxMethods[] = {
    { "update", chacha20_ctx_update },
    { "updateAAD", chacha20_ctx_update_aad },
    { "setTag", chacha20_ctx_set_tag },
    { "getTag", chacha20_ctx_get_tag },
    { "final", chacha20_ctx_final },
    { "close", chacha20_ctx_close },
    { nullptr, nullptr },
};

luaL_Reg chacha20CtxMetamethods[] = {
    { "__tostring", chacha20_ctx_tostring },
    { nullptr, nullptr },
};

udataDef chacha20CtxDef = {
    .name = "crypto.chacha20.ctx",
    .size = sizeof(LuaCipherCtx),
    .fields = nullptr,
    .indexFallback = nullptr,
    .newindexFallback = nullptr,
    .metamethods = chacha20CtxMetamethods,
    .dotcallMethods = nullptr,
    .namecallMethods = nullptr,
    .bothcallMethods = chacha20CtxMethods,
    .destructor = cipher_ctx_dtor,
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen__crypto(lua_State* L) {
    hashCtxRef = eryxUdata_registerudata(L, &hashCtxDef);
    hmacCtxRef = eryxUdata_registerudata(L, &hmacCtxDef);
    aesCtxRef = eryxUdata_registerudata(L, &aesCtxDef);
    camelliaCtxRef = eryxUdata_registerudata(L, &camelliaCtxDef);
    desCtxRef = eryxUdata_registerudata(L, &desCtxDef);
    chacha20CtxRef = eryxUdata_registerudata(L, &chacha20CtxDef);

    lua_newtable(L);

    push_hash_table(L);
    lua_setfield(L, -2, "hash");

    push_hmac_table(L);
    lua_setfield(L, -2, "hmac");

    push_random_table(L);
    lua_setfield(L, -2, "random");

    push_aes_table(L);
    lua_setfield(L, -2, "aes");

    push_camellia_table(L);
    lua_setfield(L, -2, "camellia");

    push_des_table(L);
    lua_setfield(L, -2, "des");

    push_chacha20_table(L);
    lua_setfield(L, -2, "chacha20");

    push_kdf_table(L);
    lua_setfield(L, -2, "kdf");

    push_ecc_table(L);
    lua_setfield(L, -2, "ecc");

    push_rsa_table(L);
    lua_setfield(L, -2, "rsa");

    return 1;
}
