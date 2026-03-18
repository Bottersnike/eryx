#include <cstring>
#include <vector>

#include "lua.h"
#include "lualib.h"
#include "mbedtls/error.h"
#include "mbedtls/md.h"
#include "mbedtls/pk.h"
#include "module_api.h"
#include "psa/crypto.h"

static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__crypto",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void push_psa_error(lua_State* L, const char* op, psa_status_t status) {
    luaL_error(L, "%s failed (PSA %d)", op, (int)status);
}

// ---------------------------------------------------------------------------
// Hash
// ---------------------------------------------------------------------------

static int hash_impl(lua_State* L, mbedtls_md_type_t type) {
    size_t inputLen = 0;
    const void* input = luaL_checkbuffer(L, 1, &inputLen);

    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(type);
    if (!info) luaL_error(L, "hash algorithm not available");

    unsigned char digestSize = mbedtls_md_get_size(info);
    void* out = lua_newbuffer(L, digestSize);

    int ret = mbedtls_md(info, (const unsigned char*)input, inputLen, (unsigned char*)out);
    if (ret != 0) luaL_error(L, "hash computation failed (%d)", ret);

    return 1;
}

static int hash_md5(lua_State* L) { return hash_impl(L, MBEDTLS_MD_MD5); }
static int hash_sha1(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA1); }
static int hash_sha224(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA224); }
static int hash_sha256(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA256); }
static int hash_sha384(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA384); }
static int hash_sha512(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA512); }
static int hash_sha3_224(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA3_224); }
static int hash_sha3_256(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA3_256); }
static int hash_sha3_384(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA3_384); }
static int hash_sha3_512(lua_State* L) { return hash_impl(L, MBEDTLS_MD_SHA3_512); }

// ---------------------------------------------------------------------------
// HMAC - PSA mac_compute with an ephemeral HMAC key
// ---------------------------------------------------------------------------

static int hmac_impl(lua_State* L, psa_algorithm_t psa_hash_alg, mbedtls_md_type_t md_type) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);

    psa_algorithm_t alg = PSA_ALG_HMAC(psa_hash_alg);
    unsigned char mac_size = (unsigned char)mbedtls_md_get_size_from_type(md_type);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_HMAC);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_SIGN_MESSAGE);
    psa_set_key_algorithm(&attrs, alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "hmac: psa_import_key", st);

    void* out = lua_newbuffer(L, mac_size);
    size_t mac_len = 0;
    st =
        psa_mac_compute(kid, alg, (const uint8_t*)data, dataLen, (uint8_t*)out, mac_size, &mac_len);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "hmac: psa_mac_compute", st);

    return 1;
}

static int hmac_md5(lua_State* L) { return hmac_impl(L, PSA_ALG_MD5, MBEDTLS_MD_MD5); }
static int hmac_sha1(lua_State* L) { return hmac_impl(L, PSA_ALG_SHA_1, MBEDTLS_MD_SHA1); }
static int hmac_sha224(lua_State* L) { return hmac_impl(L, PSA_ALG_SHA_224, MBEDTLS_MD_SHA224); }
static int hmac_sha256(lua_State* L) { return hmac_impl(L, PSA_ALG_SHA_256, MBEDTLS_MD_SHA256); }
static int hmac_sha384(lua_State* L) { return hmac_impl(L, PSA_ALG_SHA_384, MBEDTLS_MD_SHA384); }
static int hmac_sha512(lua_State* L) { return hmac_impl(L, PSA_ALG_SHA_512, MBEDTLS_MD_SHA512); }
static int hmac_sha3_224(lua_State* L) {
    return hmac_impl(L, PSA_ALG_SHA3_224, MBEDTLS_MD_SHA3_224);
}
static int hmac_sha3_256(lua_State* L) {
    return hmac_impl(L, PSA_ALG_SHA3_256, MBEDTLS_MD_SHA3_256);
}
static int hmac_sha3_384(lua_State* L) {
    return hmac_impl(L, PSA_ALG_SHA3_384, MBEDTLS_MD_SHA3_384);
}
static int hmac_sha3_512(lua_State* L) {
    return hmac_impl(L, PSA_ALG_SHA3_512, MBEDTLS_MD_SHA3_512);
}

// ---------------------------------------------------------------------------
// Symmetric cipher helpers (AES, Camellia, 3DES)
// ---------------------------------------------------------------------------

// Non-AEAD: CBC (PKCS7 padding) and CTR.
// psa_cipher_encrypt prepends the IV to the output; psa_cipher_decrypt
// expects it prepended to the input.  Both are one-shot.
static int cipher_encrypt(lua_State* L, psa_key_type_t key_type, psa_algorithm_t alg) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t ivLen = 0;
    const void* iv = luaL_checkbuffer(L, 2, &ivLen);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 3, &ptLen);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, key_type);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_ENCRYPT);
    psa_set_key_algorithm(&attrs, alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "cipher_encrypt: psa_import_key", st);

    // Build iv||plaintext as input so psa_cipher_encrypt can use our IV
    // PSA one-shot encrypt: caller provides iv separately via multi-step,
    // but single-shot generates its own IV. Use multi-step to inject ours.
    psa_cipher_operation_t op = PSA_CIPHER_OPERATION_INIT;
    st = psa_cipher_encrypt_setup(&op, kid, alg);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "cipher_encrypt: setup", st);

    st = psa_cipher_set_iv(&op, (const uint8_t*)iv, ivLen);
    if (st != PSA_SUCCESS) {
        psa_cipher_abort(&op);
        push_psa_error(L, "cipher_encrypt: set_iv", st);
    }

    // Output upper bound: ptLen + one block for padding
    size_t block_size = PSA_BLOCK_CIPHER_BLOCK_LENGTH(key_type);
    size_t outMax = ptLen + block_size;
    void* out = lua_newbuffer(L, outMax);
    size_t written = 0, finished = 0;

    st = psa_cipher_update(&op, (const uint8_t*)pt, ptLen, (uint8_t*)out, outMax, &written);
    if (st != PSA_SUCCESS) {
        psa_cipher_abort(&op);
        push_psa_error(L, "cipher_encrypt: update", st);
    }

    st = psa_cipher_finish(&op, (uint8_t*)out + written, outMax - written, &finished);
    if (st != PSA_SUCCESS) push_psa_error(L, "cipher_encrypt: finish", st);

    size_t total = written + finished;
    // Resize the buffer to actual output length
    void* out2 = lua_newbuffer(L, total);
    memcpy(out2, out, total);
    lua_remove(L, -2);  // remove oversized buffer

    return 1;
}

static int cipher_decrypt(lua_State* L, psa_key_type_t key_type, psa_algorithm_t alg) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t ivLen = 0;
    const void* iv = luaL_checkbuffer(L, 2, &ivLen);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 3, &ctLen);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, key_type);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_DECRYPT);
    psa_set_key_algorithm(&attrs, alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "cipher_decrypt: psa_import_key", st);

    psa_cipher_operation_t op = PSA_CIPHER_OPERATION_INIT;
    st = psa_cipher_decrypt_setup(&op, kid, alg);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "cipher_decrypt: setup", st);

    st = psa_cipher_set_iv(&op, (const uint8_t*)iv, ivLen);
    if (st != PSA_SUCCESS) {
        psa_cipher_abort(&op);
        push_psa_error(L, "cipher_decrypt: set_iv", st);
    }

    void* out = lua_newbuffer(L, ctLen);
    size_t written = 0, finished = 0;

    st = psa_cipher_update(&op, (const uint8_t*)ct, ctLen, (uint8_t*)out, ctLen, &written);
    if (st != PSA_SUCCESS) {
        psa_cipher_abort(&op);
        push_psa_error(L, "cipher_decrypt: update", st);
    }

    st = psa_cipher_finish(&op, (uint8_t*)out + written, ctLen - written, &finished);
    if (st != PSA_SUCCESS) push_psa_error(L, "cipher_decrypt: finish", st);

    size_t total = written + finished;
    void* out2 = lua_newbuffer(L, total);
    memcpy(out2, out, total);
    lua_remove(L, -2);

    return 1;
}

// AEAD: GCM and CCM.
// Returns (ciphertext: buffer, tag: buffer) on encrypt.
// Returns plaintext: buffer on decrypt; errors on tag mismatch.
static int aead_encrypt(lua_State* L, psa_key_type_t key_type, psa_algorithm_t alg) {
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t nonceLen = 0;
    const void* nonce = luaL_checkbuffer(L, 2, &nonceLen);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 3, &ptLen);
    size_t aadLen = 0;
    const void* aad = lua_isnoneornil(L, 4) ? nullptr : luaL_checkbuffer(L, 4, &aadLen);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, key_type);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_ENCRYPT);
    psa_set_key_algorithm(&attrs, alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aead_encrypt: psa_import_key", st);

    size_t tag_len = PSA_AEAD_TAG_LENGTH(key_type, keyLen * 8, alg);
    size_t outMax = PSA_AEAD_ENCRYPT_OUTPUT_SIZE(key_type, alg, ptLen);
    void* out = lua_newbuffer(L, outMax);  // ciphertext + tag together
    size_t out_len = 0;

    st = psa_aead_encrypt(kid, alg, (const uint8_t*)nonce, nonceLen, (const uint8_t*)aad, aadLen,
                          (const uint8_t*)pt, ptLen, (uint8_t*)out, outMax, &out_len);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aead_encrypt: psa_aead_encrypt", st);

    // Split ciphertext and tag (PSA appends tag at end)
    size_t ct_len = out_len - tag_len;
    void* ct_buf = lua_newbuffer(L, ct_len);
    void* tag_buf = lua_newbuffer(L, tag_len);
    memcpy(ct_buf, (uint8_t*)out, ct_len);
    memcpy(tag_buf, (uint8_t*)out + ct_len, tag_len);
    lua_remove(L, -3);  // remove combined out buffer

    return 2;  // ciphertext, tag
}

static int aead_decrypt(lua_State* L, psa_key_type_t key_type, psa_algorithm_t alg) {
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

    // Reconstitute ciphertext||tag for PSA
    std::vector<uint8_t> input(ctLen + tagLen);
    memcpy(input.data(), ct, ctLen);
    memcpy(input.data() + ctLen, tag, tagLen);
    size_t inputLen = input.size();

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, key_type);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_DECRYPT);
    psa_set_key_algorithm(&attrs, alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aead_decrypt: psa_import_key", st);

    size_t outMax = PSA_AEAD_DECRYPT_OUTPUT_SIZE(key_type, alg, inputLen);
    void* out = lua_newbuffer(L, outMax);
    size_t out_len = 0;

    st = psa_aead_decrypt(kid, alg, (const uint8_t*)nonce, nonceLen, (const uint8_t*)aad, aadLen,
                          input.data(), inputLen, (uint8_t*)out, outMax, &out_len);
    psa_destroy_key(kid);
    if (st == PSA_ERROR_INVALID_SIGNATURE)
        luaL_error(L, "aead_decrypt: authentication tag mismatch");
    if (st != PSA_SUCCESS) push_psa_error(L, "aead_decrypt: psa_aead_decrypt", st);

    void* out2 = lua_newbuffer(L, out_len);
    memcpy(out2, out, out_len);
    lua_remove(L, -2);

    return 1;
}

// ---------------------------------------------------------------------------
// AES
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// AES ECB mode (PKCS7 padding)
// ---------------------------------------------------------------------------

static int aes_ecb_encrypt(lua_State* L) {
    // key, data
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 2, &ptLen);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_AES);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_ENCRYPT);
    psa_set_key_algorithm(&attrs, PSA_ALG_ECB_NO_PADDING);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_encrypt: import_key", st);

    psa_cipher_operation_t op = PSA_CIPHER_OPERATION_INIT;
    st = psa_cipher_encrypt_setup(&op, kid, PSA_ALG_ECB_NO_PADDING);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_encrypt: setup", st);

    // ECB does not use IV
    size_t block_size = PSA_BLOCK_CIPHER_BLOCK_LENGTH(PSA_KEY_TYPE_AES);
    size_t outMax = ptLen + block_size;
    void* out = lua_newbuffer(L, outMax);
    size_t written = 0, finished = 0;

    st = psa_cipher_update(&op, (const uint8_t*)pt, ptLen, (uint8_t*)out, outMax, &written);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_encrypt: update", st);

    st = psa_cipher_finish(&op, (uint8_t*)out + written, outMax - written, &finished);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_encrypt: finish", st);

    size_t total = written + finished;
    void* out2 = lua_newbuffer(L, total);
    memcpy(out2, out, total);
    lua_remove(L, -2);

    return 1;
}

static int aes_ecb_decrypt(lua_State* L) {
    // key, data
    size_t keyLen = 0;
    const void* key = luaL_checkbuffer(L, 1, &keyLen);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 2, &ctLen);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_AES);
    psa_set_key_bits(&attrs, keyLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_DECRYPT);
    psa_set_key_algorithm(&attrs, PSA_ALG_ECB_NO_PADDING);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)key, keyLen, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_decrypt: import_key", st);

    psa_cipher_operation_t op = PSA_CIPHER_OPERATION_INIT;
    st = psa_cipher_decrypt_setup(&op, kid, PSA_ALG_ECB_NO_PADDING);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_decrypt: setup", st);

    void* out = lua_newbuffer(L, ctLen);
    size_t written = 0, finished = 0;

    st = psa_cipher_update(&op, (const uint8_t*)ct, ctLen, (uint8_t*)out, ctLen, &written);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_decrypt: update", st);

    st = psa_cipher_finish(&op, (uint8_t*)out + written, ctLen - written, &finished);
    if (st != PSA_SUCCESS) push_psa_error(L, "aes_ecb_decrypt: finish", st);

    size_t total = written + finished;
    void* out2 = lua_newbuffer(L, total);
    memcpy(out2, out, total);
    lua_remove(L, -2);

    return 1;
}

static int aes_cbc_encrypt(lua_State* L) {
    return cipher_encrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_CBC_PKCS7);
}
static int aes_cbc_decrypt(lua_State* L) {
    return cipher_decrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_CBC_PKCS7);
}
static int aes_ctr_encrypt(lua_State* L) {
    return cipher_encrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_CTR);
}
static int aes_ctr_decrypt(lua_State* L) {
    return cipher_decrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_CTR);
}
static int aes_gcm_encrypt(lua_State* L) { return aead_encrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_GCM); }
static int aes_gcm_decrypt(lua_State* L) { return aead_decrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_GCM); }
static int aes_ccm_encrypt(lua_State* L) { return aead_encrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_CCM); }
static int aes_ccm_decrypt(lua_State* L) { return aead_decrypt(L, PSA_KEY_TYPE_AES, PSA_ALG_CCM); }

static void push_aes_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, aes_ecb_encrypt, "ecb_encrypt");
    lua_setfield(L, -2, "ecb_encrypt");
    lua_pushcfunction(L, aes_ecb_decrypt, "ecb_decrypt");
    lua_setfield(L, -2, "ecb_decrypt");
    lua_pushcfunction(L, aes_cbc_encrypt, "cbc_encrypt");
    lua_setfield(L, -2, "cbc_encrypt");
    lua_pushcfunction(L, aes_cbc_decrypt, "cbc_decrypt");
    lua_setfield(L, -2, "cbc_decrypt");
    lua_pushcfunction(L, aes_ctr_encrypt, "ctr_encrypt");
    lua_setfield(L, -2, "ctr_encrypt");
    lua_pushcfunction(L, aes_ctr_decrypt, "ctr_decrypt");
    lua_setfield(L, -2, "ctr_decrypt");
    lua_pushcfunction(L, aes_gcm_encrypt, "gcm_encrypt");
    lua_setfield(L, -2, "gcm_encrypt");
    lua_pushcfunction(L, aes_gcm_decrypt, "gcm_decrypt");
    lua_setfield(L, -2, "gcm_decrypt");
    lua_pushcfunction(L, aes_ccm_encrypt, "ccm_encrypt");
    lua_setfield(L, -2, "ccm_encrypt");
    lua_pushcfunction(L, aes_ccm_decrypt, "ccm_decrypt");
    lua_setfield(L, -2, "ccm_decrypt");
}

// ---------------------------------------------------------------------------
// Camellia (CBC, CTR, GCM)
// ---------------------------------------------------------------------------

static int camellia_cbc_encrypt(lua_State* L) {
    return cipher_encrypt(L, PSA_KEY_TYPE_CAMELLIA, PSA_ALG_CBC_PKCS7);
}
static int camellia_cbc_decrypt(lua_State* L) {
    return cipher_decrypt(L, PSA_KEY_TYPE_CAMELLIA, PSA_ALG_CBC_PKCS7);
}
static int camellia_ctr_encrypt(lua_State* L) {
    return cipher_encrypt(L, PSA_KEY_TYPE_CAMELLIA, PSA_ALG_CTR);
}
static int camellia_ctr_decrypt(lua_State* L) {
    return cipher_decrypt(L, PSA_KEY_TYPE_CAMELLIA, PSA_ALG_CTR);
}
static int camellia_gcm_encrypt(lua_State* L) {
    return aead_encrypt(L, PSA_KEY_TYPE_CAMELLIA, PSA_ALG_GCM);
}
static int camellia_gcm_decrypt(lua_State* L) {
    return aead_decrypt(L, PSA_KEY_TYPE_CAMELLIA, PSA_ALG_GCM);
}

static void push_camellia_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, camellia_cbc_encrypt, "cbc_encrypt");
    lua_setfield(L, -2, "cbc_encrypt");
    lua_pushcfunction(L, camellia_cbc_decrypt, "cbc_decrypt");
    lua_setfield(L, -2, "cbc_decrypt");
    lua_pushcfunction(L, camellia_ctr_encrypt, "ctr_encrypt");
    lua_setfield(L, -2, "ctr_encrypt");
    lua_pushcfunction(L, camellia_ctr_decrypt, "ctr_decrypt");
    lua_setfield(L, -2, "ctr_decrypt");
    lua_pushcfunction(L, camellia_gcm_encrypt, "gcm_encrypt");
    lua_setfield(L, -2, "gcm_encrypt");
    lua_pushcfunction(L, camellia_gcm_decrypt, "gcm_decrypt");
    lua_setfield(L, -2, "gcm_decrypt");
}

// ---------------------------------------------------------------------------
// 3DES - PSA_KEY_TYPE_DES with a 24-byte (192-bit) key
// ECB and CBC only; stream modes are not defined for DES in PSA.
// ---------------------------------------------------------------------------

static int des3_cbc_encrypt(lua_State* L) {
    return cipher_encrypt(L, PSA_KEY_TYPE_DES, PSA_ALG_CBC_PKCS7);
}
static int des3_cbc_decrypt(lua_State* L) {
    return cipher_decrypt(L, PSA_KEY_TYPE_DES, PSA_ALG_CBC_PKCS7);
}

static void push_des_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, des3_cbc_encrypt, "cbc_encrypt");
    lua_setfield(L, -2, "cbc_encrypt");
    lua_pushcfunction(L, des3_cbc_decrypt, "cbc_decrypt");
    lua_setfield(L, -2, "cbc_decrypt");
}

// ---------------------------------------------------------------------------
// ChaCha20 (stream) and ChaCha20-Poly1305 (AEAD)
// ChaCha20 nonce: 12 bytes.  Counter starts at 0 (PSA manages internally).
// ---------------------------------------------------------------------------

static int chacha20_encrypt(lua_State* L) {
    return cipher_encrypt(L, PSA_KEY_TYPE_CHACHA20, PSA_ALG_STREAM_CIPHER);
}
static int chacha20_decrypt(lua_State* L) {
    return cipher_decrypt(L, PSA_KEY_TYPE_CHACHA20, PSA_ALG_STREAM_CIPHER);
}
static int chacha20_poly1305_encrypt(lua_State* L) {
    return aead_encrypt(L, PSA_KEY_TYPE_CHACHA20, PSA_ALG_CHACHA20_POLY1305);
}
static int chacha20_poly1305_decrypt(lua_State* L) {
    return aead_decrypt(L, PSA_KEY_TYPE_CHACHA20, PSA_ALG_CHACHA20_POLY1305);
}

static void push_chacha20_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, chacha20_encrypt, "encrypt");
    lua_setfield(L, -2, "encrypt");
    lua_pushcfunction(L, chacha20_decrypt, "decrypt");
    lua_setfield(L, -2, "decrypt");
    lua_pushcfunction(L, chacha20_poly1305_encrypt, "poly1305_encrypt");
    lua_setfield(L, -2, "poly1305_encrypt");
    lua_pushcfunction(L, chacha20_poly1305_decrypt, "poly1305_decrypt");
    lua_setfield(L, -2, "poly1305_decrypt");
}

static void push_hmac_table(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, hmac_md5, "md5");
    lua_setfield(L, -2, "md5");
    lua_pushcfunction(L, hmac_sha1, "sha1");
    lua_setfield(L, -2, "sha1");
    lua_pushcfunction(L, hmac_sha224, "sha224");
    lua_setfield(L, -2, "sha224");
    lua_pushcfunction(L, hmac_sha256, "sha256");
    lua_setfield(L, -2, "sha256");
    lua_pushcfunction(L, hmac_sha384, "sha384");
    lua_setfield(L, -2, "sha384");
    lua_pushcfunction(L, hmac_sha512, "sha512");
    lua_setfield(L, -2, "sha512");
    lua_pushcfunction(L, hmac_sha3_224, "sha3_224");
    lua_setfield(L, -2, "sha3_224");
    lua_pushcfunction(L, hmac_sha3_256, "sha3_256");
    lua_setfield(L, -2, "sha3_256");
    lua_pushcfunction(L, hmac_sha3_384, "sha3_384");
    lua_setfield(L, -2, "sha3_384");
    lua_pushcfunction(L, hmac_sha3_512, "sha3_512");
    lua_setfield(L, -2, "sha3_512");
}

// ---------------------------------------------------------------------------
// KDF - HKDF and PBKDF2 via PSA key derivation
// ---------------------------------------------------------------------------

// hkdf(ikm, salt, info, length) -> buffer
static int kdf_hkdf(lua_State* L, psa_algorithm_t hash_alg) {
    size_t ikmLen = 0;
    const void* ikm = luaL_checkbuffer(L, 1, &ikmLen);
    size_t saltLen = 0;
    const void* salt = lua_isnoneornil(L, 2) ? nullptr : luaL_checkbuffer(L, 2, &saltLen);
    size_t infoLen = 0;
    const void* info = lua_isnoneornil(L, 3) ? nullptr : luaL_checkbuffer(L, 3, &infoLen);
    size_t outLen = (size_t)luaL_checkinteger(L, 4);

    // Import IKM as a DERIVE key
    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_DERIVE);
    psa_set_key_bits(&attrs, ikmLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_DERIVE);
    psa_set_key_algorithm(&attrs, PSA_ALG_HKDF(hash_alg));

    mbedtls_svc_key_id_t ikm_key;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)ikm, ikmLen, &ikm_key);
    if (st != PSA_SUCCESS) push_psa_error(L, "hkdf: psa_import_key", st);

    psa_key_derivation_operation_t op = PSA_KEY_DERIVATION_OPERATION_INIT;
    st = psa_key_derivation_setup(&op, PSA_ALG_HKDF(hash_alg));
    if (st != PSA_SUCCESS) {
        psa_destroy_key(ikm_key);
        push_psa_error(L, "hkdf: setup", st);
    }

    if (saltLen > 0) {
        st = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SALT,
                                            (const uint8_t*)salt, saltLen);
        if (st != PSA_SUCCESS) {
            psa_key_derivation_abort(&op);
            psa_destroy_key(ikm_key);
            push_psa_error(L, "hkdf: salt", st);
        }
    }

    st = psa_key_derivation_input_key(&op, PSA_KEY_DERIVATION_INPUT_SECRET, ikm_key);
    psa_destroy_key(ikm_key);
    if (st != PSA_SUCCESS) {
        psa_key_derivation_abort(&op);
        push_psa_error(L, "hkdf: secret", st);
    }

    if (infoLen > 0) {
        st = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_INFO,
                                            (const uint8_t*)info, infoLen);
        if (st != PSA_SUCCESS) {
            psa_key_derivation_abort(&op);
            push_psa_error(L, "hkdf: info", st);
        }
    }

    void* out = lua_newbuffer(L, outLen);
    st = psa_key_derivation_output_bytes(&op, (uint8_t*)out, outLen);
    psa_key_derivation_abort(&op);
    if (st != PSA_SUCCESS) push_psa_error(L, "hkdf: output", st);

    return 1;
}

// pbkdf2(password, salt, iterations, length) -> buffer
static int kdf_pbkdf2(lua_State* L, psa_algorithm_t hash_alg) {
    size_t pwdLen = 0;
    const void* pwd = luaL_checkbuffer(L, 1, &pwdLen);
    size_t saltLen = 0;
    const void* salt = luaL_checkbuffer(L, 2, &saltLen);
    uint64_t iters = (uint64_t)luaL_checkinteger(L, 3);
    size_t outLen = (size_t)luaL_checkinteger(L, 4);

    psa_algorithm_t alg = PSA_ALG_PBKDF2_HMAC(hash_alg);

    // Import password as PASSWORD key
    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_PASSWORD);
    psa_set_key_bits(&attrs, pwdLen * 8);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_DERIVE);
    psa_set_key_algorithm(&attrs, alg);

    mbedtls_svc_key_id_t pwd_key;
    psa_status_t st = psa_import_key(&attrs, (const uint8_t*)pwd, pwdLen, &pwd_key);
    if (st != PSA_SUCCESS) push_psa_error(L, "pbkdf2: psa_import_key", st);

    psa_key_derivation_operation_t op = PSA_KEY_DERIVATION_OPERATION_INIT;
    st = psa_key_derivation_setup(&op, alg);
    if (st != PSA_SUCCESS) {
        psa_destroy_key(pwd_key);
        push_psa_error(L, "pbkdf2: setup", st);
    }

    st = psa_key_derivation_input_integer(&op, PSA_KEY_DERIVATION_INPUT_COST, iters);
    if (st != PSA_SUCCESS) {
        psa_key_derivation_abort(&op);
        psa_destroy_key(pwd_key);
        push_psa_error(L, "pbkdf2: cost", st);
    }

    st = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SALT, (const uint8_t*)salt,
                                        saltLen);
    if (st != PSA_SUCCESS) {
        psa_key_derivation_abort(&op);
        psa_destroy_key(pwd_key);
        push_psa_error(L, "pbkdf2: salt", st);
    }

    st = psa_key_derivation_input_key(&op, PSA_KEY_DERIVATION_INPUT_PASSWORD, pwd_key);
    psa_destroy_key(pwd_key);
    if (st != PSA_SUCCESS) {
        psa_key_derivation_abort(&op);
        push_psa_error(L, "pbkdf2: password", st);
    }

    void* out = lua_newbuffer(L, outLen);
    st = psa_key_derivation_output_bytes(&op, (uint8_t*)out, outLen);
    psa_key_derivation_abort(&op);
    if (st != PSA_SUCCESS) push_psa_error(L, "pbkdf2: output", st);

    return 1;
}

static int kdf_hkdf_sha256(lua_State* L) { return kdf_hkdf(L, PSA_ALG_SHA_256); }
static int kdf_hkdf_sha512(lua_State* L) { return kdf_hkdf(L, PSA_ALG_SHA_512); }
static int kdf_pbkdf2_sha256(lua_State* L) { return kdf_pbkdf2(L, PSA_ALG_SHA_256); }
static int kdf_pbkdf2_sha512(lua_State* L) { return kdf_pbkdf2(L, PSA_ALG_SHA_512); }

// ---------------------------------------------------------------------------
// RSA
// ---------------------------------------------------------------------------

static void
#if _WIN32
    __declspec(noreturn)
#else
    __attribute__((noreturn))
#endif
    mbedtls_lua_error(lua_State* L, const char* op, int ret) {
    char buf[256];
    mbedtls_strerror(ret, buf, sizeof(buf));
    luaL_error(L, "%s: %s", op, buf);
}

// generate_key(bits?) -> private_pem: string
static int rsa_generate_key(lua_State* L) {
    int bits = (int)luaL_optinteger(L, 1, 2048);

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_RSA_KEY_PAIR);
    psa_set_key_bits(&attrs, (size_t)bits);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_ENCRYPT | PSA_KEY_USAGE_DECRYPT |
                                        PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_VERIFY_HASH |
                                        PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attrs, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_SHA_256));
    psa_set_key_lifetime(&attrs, PSA_KEY_LIFETIME_VOLATILE);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = psa_generate_key(&attrs, &kid);
    psa_reset_key_attributes(&attrs);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_generate_key", st);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_copy_from_psa(kid, &pk);
    psa_destroy_key(kid);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "rsa_generate_key", ret);
    }

    unsigned char buf[16384];
    ret = mbedtls_pk_write_key_pem(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret != 0) mbedtls_lua_error(L, "rsa_generate_key", ret);

    lua_pushstring(L, (const char*)buf);
    return 1;
}

// get_public_pem(private_pem: string) -> public_pem: string
static int rsa_get_public_pem(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)pem, strlen(pem) + 1, nullptr, 0);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "rsa_get_public_pem", ret);
    }

    unsigned char buf[8192];
    ret = mbedtls_pk_write_pubkey_pem(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret != 0) mbedtls_lua_error(L, "rsa_get_public_pem", ret);

    lua_pushstring(L, (const char*)buf);
    return 1;
}

// Helper: parse PEM (private or public), import into PSA, return key_id.
// Caller must psa_destroy_key() the returned key.
static psa_status_t pk_pem_to_psa(const char* pem, bool is_private, psa_key_usage_t usage,
                                  psa_algorithm_t alg, mbedtls_svc_key_id_t* out_key) {
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret;
    if (is_private)
        ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)pem, strlen(pem) + 1, nullptr, 0);
    else
        ret = mbedtls_pk_parse_public_key(&pk, (const unsigned char*)pem, strlen(pem) + 1);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        return (psa_status_t)ret;
    }

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    ret = mbedtls_pk_get_psa_attributes(&pk, usage, &attrs);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        return (psa_status_t)ret;
    }
    psa_set_key_algorithm(&attrs, alg);
    psa_set_key_lifetime(&attrs, PSA_KEY_LIFETIME_VOLATILE);

    psa_status_t st = mbedtls_pk_import_into_psa(&pk, &attrs, out_key);
    mbedtls_pk_free(&pk);
    return st;
}

// encrypt_pkcs1(public_pem, data) -> ciphertext
static int rsa_encrypt_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 2, &ptLen);

    mbedtls_svc_key_id_t kid;
    psa_status_t st =
        pk_pem_to_psa(pem, false, PSA_KEY_USAGE_ENCRYPT, PSA_ALG_RSA_PKCS1V15_CRYPT, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_encrypt_pkcs1", st);

    size_t outMax = 512;  // covers up to RSA-4096
    void* out = lua_newbuffer(L, outMax);
    size_t out_len = 0;
    st = psa_asymmetric_encrypt(kid, PSA_ALG_RSA_PKCS1V15_CRYPT, (const uint8_t*)pt, ptLen, nullptr,
                                0, (uint8_t*)out, outMax, &out_len);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_encrypt_pkcs1", st);

    void* out2 = lua_newbuffer(L, out_len);
    memcpy(out2, out, out_len);
    lua_remove(L, -2);
    return 1;
}

// decrypt_pkcs1(private_pem, ciphertext) -> plaintext
static int rsa_decrypt_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 2, &ctLen);

    mbedtls_svc_key_id_t kid;
    psa_status_t st =
        pk_pem_to_psa(pem, true, PSA_KEY_USAGE_DECRYPT, PSA_ALG_RSA_PKCS1V15_CRYPT, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_decrypt_pkcs1", st);

    size_t outMax = 512;
    void* out = lua_newbuffer(L, outMax);
    size_t out_len = 0;
    st = psa_asymmetric_decrypt(kid, PSA_ALG_RSA_PKCS1V15_CRYPT, (const uint8_t*)ct, ctLen, nullptr,
                                0, (uint8_t*)out, outMax, &out_len);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_decrypt_pkcs1", st);

    void* out2 = lua_newbuffer(L, out_len);
    memcpy(out2, out, out_len);
    lua_remove(L, -2);
    return 1;
}

// encrypt_oaep(public_pem, data, hash?) -> ciphertext  (hash: "sha256"|"sha1", default sha256)
static int rsa_encrypt_oaep(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ptLen = 0;
    const void* pt = luaL_checkbuffer(L, 2, &ptLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    psa_algorithm_t hash_alg = strcmp(hash_name, "sha1") == 0 ? PSA_ALG_SHA_1 : PSA_ALG_SHA_256;
    psa_algorithm_t alg = PSA_ALG_RSA_OAEP(hash_alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = pk_pem_to_psa(pem, false, PSA_KEY_USAGE_ENCRYPT, alg, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_encrypt_oaep", st);

    size_t outMax = 512;
    void* out = lua_newbuffer(L, outMax);
    size_t out_len = 0;
    st = psa_asymmetric_encrypt(kid, alg, (const uint8_t*)pt, ptLen, nullptr, 0, (uint8_t*)out,
                                outMax, &out_len);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_encrypt_oaep", st);

    void* out2 = lua_newbuffer(L, out_len);
    memcpy(out2, out, out_len);
    lua_remove(L, -2);
    return 1;
}

// decrypt_oaep(private_pem, ciphertext, hash?) -> plaintext
static int rsa_decrypt_oaep(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t ctLen = 0;
    const void* ct = luaL_checkbuffer(L, 2, &ctLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");
    psa_algorithm_t hash_alg = strcmp(hash_name, "sha1") == 0 ? PSA_ALG_SHA_1 : PSA_ALG_SHA_256;
    psa_algorithm_t alg = PSA_ALG_RSA_OAEP(hash_alg);

    mbedtls_svc_key_id_t kid;
    psa_status_t st = pk_pem_to_psa(pem, true, PSA_KEY_USAGE_DECRYPT, alg, &kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_decrypt_oaep", st);

    size_t outMax = 512;
    void* out = lua_newbuffer(L, outMax);
    size_t out_len = 0;
    st = psa_asymmetric_decrypt(kid, alg, (const uint8_t*)ct, ctLen, nullptr, 0, (uint8_t*)out,
                                outMax, &out_len);
    psa_destroy_key(kid);
    if (st != PSA_SUCCESS) push_psa_error(L, "rsa_decrypt_oaep", st);

    void* out2 = lua_newbuffer(L, out_len);
    memcpy(out2, out, out_len);
    lua_remove(L, -2);
    return 1;
}

// sign_pkcs1(private_pem, data, hash?) -> signature
static int rsa_sign_pkcs1(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t dataLen = 0;
    const void* data = luaL_checkbuffer(L, 2, &dataLen);
    const char* hash_name = luaL_optstring(L, 3, "sha256");

    mbedtls_md_type_t md_type = MBEDTLS_MD_SHA256;
    if (strcmp(hash_name, "sha1") == 0) md_type = MBEDTLS_MD_SHA1;
    if (strcmp(hash_name, "sha384") == 0) md_type = MBEDTLS_MD_SHA384;
    if (strcmp(hash_name, "sha512") == 0) md_type = MBEDTLS_MD_SHA512;

    // Hash the data
    const mbedtls_md_info_t* md_info = mbedtls_md_info_from_type(md_type);
    unsigned char hash[64];
    mbedtls_md(md_info, (const unsigned char*)data, dataLen, hash);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)pem, strlen(pem) + 1, nullptr, 0);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "rsa_sign_pkcs1", ret);
    }

    void* sig = lua_newbuffer(L, 512);
    size_t sig_len = 0;
    ret = mbedtls_pk_sign(&pk, md_type, hash, mbedtls_md_get_size(md_info), (unsigned char*)sig,
                          512, &sig_len);
    mbedtls_pk_free(&pk);
    if (ret != 0) mbedtls_lua_error(L, "rsa_sign_pkcs1", ret);

    void* sig2 = lua_newbuffer(L, sig_len);
    memcpy(sig2, sig, sig_len);
    lua_remove(L, -2);
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

    mbedtls_md_type_t md_type = MBEDTLS_MD_SHA256;
    if (strcmp(hash_name, "sha1") == 0) md_type = MBEDTLS_MD_SHA1;
    if (strcmp(hash_name, "sha384") == 0) md_type = MBEDTLS_MD_SHA384;
    if (strcmp(hash_name, "sha512") == 0) md_type = MBEDTLS_MD_SHA512;

    const mbedtls_md_info_t* md_info = mbedtls_md_info_from_type(md_type);
    unsigned char hash[64];
    mbedtls_md(md_info, (const unsigned char*)data, dataLen, hash);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_public_key(&pk, (const unsigned char*)pem, strlen(pem) + 1);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "rsa_verify_pkcs1", ret);
    }

    ret = mbedtls_pk_verify(&pk, md_type, hash, mbedtls_md_get_size(md_info),
                            (const unsigned char*)sig, sigLen);
    mbedtls_pk_free(&pk);
    lua_pushboolean(L, ret == 0);
    return 1;
}

// private_to_der(private_pem: string) -> buffer
static int rsa_private_to_der(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)pem, strlen(pem) + 1, nullptr, 0);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "private_to_der", ret);
    }

    unsigned char buf[16384];
    ret = mbedtls_pk_write_key_der(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret < 0) mbedtls_lua_error(L, "private_to_der", ret);

    // mbedtls_pk_write_key_der writes at the END of buf; ret = bytes written
    void* out = lua_newbuffer(L, (size_t)ret);
    memcpy(out, buf + sizeof(buf) - (size_t)ret, (size_t)ret);
    return 1;
}

// public_to_der(public_pem: string) -> buffer
static int rsa_public_to_der(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_public_key(&pk, (const unsigned char*)pem, strlen(pem) + 1);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "public_to_der", ret);
    }

    unsigned char buf[8192];
    ret = mbedtls_pk_write_pubkey_der(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret < 0) mbedtls_lua_error(L, "public_to_der", ret);

    void* out = lua_newbuffer(L, (size_t)ret);
    memcpy(out, buf + sizeof(buf) - (size_t)ret, (size_t)ret);
    return 1;
}

// private_from_der(der: buffer) -> private_pem: string
static int rsa_private_from_der(lua_State* L) {
    size_t derLen = 0;
    const void* der = luaL_checkbuffer(L, 1, &derLen);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)der, derLen, nullptr, 0);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "private_from_der", ret);
    }

    unsigned char buf[16384];
    ret = mbedtls_pk_write_key_pem(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret != 0) mbedtls_lua_error(L, "private_from_der", ret);

    lua_pushstring(L, (const char*)buf);
    return 1;
}

// public_from_der(der: buffer) -> public_pem: string
static int rsa_public_from_der(lua_State* L) {
    size_t derLen = 0;
    const void* der = luaL_checkbuffer(L, 1, &derLen);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_public_key(&pk, (const unsigned char*)der, derLen);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "public_from_der", ret);
    }

    unsigned char buf[8192];
    ret = mbedtls_pk_write_pubkey_pem(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret != 0) mbedtls_lua_error(L, "public_from_der", ret);

    lua_pushstring(L, (const char*)buf);
    return 1;
}

// get_key_bits(pem: string) -> number  (accepts private or public PEM)
static int rsa_get_key_bits(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);

    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)pem, strlen(pem) + 1, nullptr, 0);
    if (ret != 0)
        ret = mbedtls_pk_parse_public_key(&pk, (const unsigned char*)pem, strlen(pem) + 1);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        mbedtls_lua_error(L, "get_key_bits", ret);
    }

    size_t bits = mbedtls_pk_get_bitlen(&pk);
    mbedtls_pk_free(&pk);
    lua_pushnumber(L, (lua_Number)bits);
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
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

LUAU_MODULE_EXPORT int luauopen__crypto(lua_State* L) {
    psa_crypto_init();

    lua_newtable(L);

    push_hash_table(L);
    lua_setfield(L, -2, "hash");

    push_hmac_table(L);
    lua_setfield(L, -2, "hmac");

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

    push_rsa_table(L);
    lua_setfield(L, -2, "rsa");

    return 1;
}
