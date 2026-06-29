// _ssl.cpp  -  TLS wrapper for _socket, using OpenSSL
//
//   ssl.wrap_socket(sock [, hostname]) -> SSLSocket
//   ssl.create_default_context()       -> SSLContext   (client)
//   ssl.create_server_context(certfile, keyfile [, password]) -> SSLContext (server)
//
//   SSLContext:wrap_socket(sock [, server_hostname]) -> SSLSocket
//   SSLContext:load_verify_locations(cafile)
//   SSLContext:set_verify(mode)
//
//   SSLSocket:send(buf)        -> bytes_sent
//   SSLSocket:sendall(buf)
//   SSLSocket:recv(bufsize)    -> buffer
//   SSLSocket:close()
//   SSLSocket:getpeername()    -> host, port
//   SSLSocket:getsockname()    -> host, port
//   SSLSocket:fileno()         -> number
//
// Constants: VERIFY_NONE, VERIFY_REQUIRED
// ---------------------------------------------------------------------------
#include <sys/stat.h>

#include "../LuaUtil.hpp"

// ---------------------------------------------------------------------------
// Platform socket compatibility (mirrors _socket.hpp)
// ---------------------------------------------------------------------------
#ifndef _WIN32
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>
using SOCKET = int;
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR (-1)
#define sock_fd_close(fd) close(fd)
#else
#include <ws2tcpip.h>
#define sock_fd_close(fd) closesocket(fd)
#endif

#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/buffer.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

#include <climits>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../runtime/_wrapper_lib.hpp"
#include "../runtime/lexception.hpp"
#include "_socket.hpp"
#include "lua.h"
#include "lualib.h"
#include "module_api.h"

// ---------------------------------------------------------------------------
// Module metadata
// ---------------------------------------------------------------------------
static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__ssl",
};
LUAU_MODULE_INFO()

static const char* SSLCTX_METATABLE = "SSLContext";
static const char* SSLSOCKET_METATABLE = "SSLSocket";

static constexpr int SSL_VERIFY_NONE_LUA = 0;
static constexpr int SSL_VERIFY_REQUIRED_LUA = 2;

struct LuaSSLContext {
    SSL_CTX* ctx;
    bool use_system_verify;
    int verify_mode;
    bool is_server;
};

struct LuaSSLSocket {
    SSL* ssl;
    SOCKET fd;
    LuaSSLContext* ctx;
    int ctx_ref;
    bool connected;
    bool closed;
    double timeout;
    std::string hostname;
    lua_State* L;
};

enum class SSLOpType {
    Handshake,
    Read,
    Write,
    WriteAll,
};

struct SSLPendingOp {
    lua_State* thread;
    int threadRef;
    EryxRuntime* runtime;
    SSLOpType op;
    SSL* ssl;
    SOCKET fd;
    LuaSSLSocket* socket;
    void* raw_socket_ud;
    LuaSSLContext* ctx;
    int ctx_ref;
    bool verify_system;
    double timeout;
    int bufsize;
    size_t data_sent;
    std::string hostname;
    std::string data;
    uv_poll_t poll;
    uv_timer_t timer;
    bool has_timer;
    bool finished;
    int handles_closing;
};

static std::unordered_map<EryxRuntime*, std::unordered_map<int, SSLPendingOp*>> g_pendingSslOps;
static std::unordered_set<EryxRuntime*> g_registeredSslRuntimes;

static LuaSSLContext* check_sslctx(lua_State* L, int idx) {
    return (LuaSSLContext*)luaL_checkudata(L, idx, SSLCTX_METATABLE);
}

static LuaSSLSocket* check_sslsocket(lua_State* L, int idx) {
    return (LuaSSLSocket*)luaL_checkudata(L, idx, SSLSOCKET_METATABLE);
}

static const char* sslsock_check_bytes_arg(lua_State* L, int idx, size_t* len) {
    const void* bufData = lua_tobuffer(L, idx, len);
    if (bufData) return (const char*)bufData;
    return luaL_checklstring(L, idx, len);
}

static void sslctx_dtor(void* ud);
static void sslsock_dtor(void* ud);

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

static int ssl_lua_error_code(lua_State* L, const char* op, int ssl_err);

static int ssl_lua_error(lua_State* L, const char* op, SSL* ssl, int ret) {
    int ssl_err = SSL_get_error(ssl, ret);
    return ssl_lua_error_code(L, op, ssl_err);
}

static int ssl_lua_error_code(lua_State* L, const char* op, int ssl_err) {
    unsigned long err = ERR_get_error();
    if (err != 0) {
        char buf[256];
        ERR_error_string_n(err, buf, sizeof(buf));
        luaL_error(L, "%s failed (%s)", op, buf);
        return 0;
    }

    if (ssl_err == SSL_ERROR_SYSCALL) {
#ifdef _WIN32
        luaL_error(L, "%s failed (syscall error %d)", op, (int)WSAGetLastError());
#else
        luaL_error(L, "%s failed (syscall error %d)", op, errno);
#endif
        return 0;
    }

    luaL_error(L, "%s failed (ssl error %d)", op, ssl_err);
    return 0;
}

static std::string vformat_string(const char* fmt, va_list args) {
    char stackbuf[512];
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(stackbuf, sizeof(stackbuf), fmt, copy);
    va_end(copy);

    if (needed < 0) return std::string("format error");
    if ((size_t)needed < sizeof(stackbuf)) return std::string(stackbuf, (size_t)needed);

    std::string out((size_t)needed, '\0');
    vsnprintf(out.data(), out.size() + 1, fmt, args);
    return out;
}

static std::string format_string(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::string out = vformat_string(fmt, args);
    va_end(args);
    return out;
}

static std::string openssl_error_message(const char* op) {
    unsigned long err = ERR_get_error();
    if (err != 0) {
        char buf[256];
        ERR_error_string_n(err, buf, sizeof(buf));
        return format_string("%s failed (%s)", op, buf);
    }

    return format_string("%s failed", op);
}

static std::string ssl_error_message(const char* op, int ssl_err) {
    unsigned long err = ERR_get_error();
    if (err != 0) {
        char buf[256];
        ERR_error_string_n(err, buf, sizeof(buf));
        return format_string("%s failed (%s)", op, buf);
    }

    if (ssl_err == SSL_ERROR_SYSCALL) {
#ifdef _WIN32
        return format_string("%s failed (syscall error %d)", op, (int)WSAGetLastError());
#else
        return format_string("%s failed (syscall error %d)", op, errno);
#endif
    }

    return format_string("%s failed (ssl error %d)", op, ssl_err);
}

static void check_openssl_input_len(lua_State* L, size_t len, const char* arg_name) {
    if (len > INT_MAX) luaL_error(L, "%s is too large for OpenSSL", arg_name);
}

static std::string bio_to_string(lua_State* L, BIO* bio, const char* op) {
    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio, &mem);
    if (!mem || !mem->data) luaL_error(L, "%s failed", op);

    return std::string(mem->data, mem->length);
}

static bool looks_like_ipv4(const char* s) {
    int dots = 0;
    for (const char* p = s; *p; ++p) {
        if (*p == '.')
            dots++;
        else if (*p < '0' || *p > '9')
            return false;
    }
    return dots == 3;
}

static std::string trim_copy(const std::string& value) {
    size_t start = 0;
    size_t end = value.size();
    while (start < end && (value[start] == ' ' || value[start] == '\t')) start++;
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) end--;
    return value.substr(start, end - start);
}

static std::string format_asn1_time(lua_State* L, const ASN1_TIME* value, const char* op) {
    struct tm tm_value {};
    if (ASN1_TIME_to_tm(value, &tm_value) != 1) push_openssl_error(L, op);

    char buf[32];
    snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02d", tm_value.tm_year + 1900,
             tm_value.tm_mon + 1, tm_value.tm_mday, tm_value.tm_hour, tm_value.tm_min,
             tm_value.tm_sec);
    return std::string(buf);
}

static std::string format_x509_name(lua_State* L, X509_NAME* name, const char* op) {
    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) push_openssl_error(L, op);

    if (X509_NAME_print_ex(bio, name, 0, XN_FLAG_RFC2253) < 0) {
        BIO_free(bio);
        push_openssl_error(L, op);
    }

    std::string out = bio_to_string(L, bio, op);
    BIO_free(bio);
    return out;
}

static std::string format_cert_info(lua_State* L, X509* cert, const char* op) {
    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) push_openssl_error(L, op);

    if (X509_print_ex(bio, cert, 0, X509_FLAG_COMPAT) != 1) {
        BIO_free(bio);
        push_openssl_error(L, op);
    }

    std::string out = bio_to_string(L, bio, op);
    BIO_free(bio);
    return out;
}

static std::string format_serial_hex(X509* cert) {
    ASN1_INTEGER* serial = X509_get_serialNumber(cert);
    const unsigned char* data = ASN1_STRING_get0_data((ASN1_STRING*)serial);
    int len = ASN1_STRING_length((ASN1_STRING*)serial);

    std::string hex;
    for (int i = 0; i < len; i++) {
        char part[4];
        snprintf(part, sizeof(part), "%02X", data[i]);
        if (i > 0) hex += ':';
        hex += part;
    }

    return hex;
}

static int pem_password_callback(char* buf, int size, int, void* userdata) {
    const char* password = (const char*)userdata;
    if (!password) return 0;

    int len = (int)strlen(password);
    if (len > size) len = size;
    memcpy(buf, password, len);
    return len;
}

static EVP_PKEY* load_private_key_pem(lua_State* L, const char* op, const char* pem,
                                      const char* password) {
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, op);

    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(
        bio, nullptr, password ? pem_password_callback : nullptr, (void*)password);
    BIO_free(bio);
    if (!pkey) push_openssl_error(L, op);

    return pkey;
}

static void apply_ctx_verify_mode(LuaSSLContext* ctx) {
    int mode = SSL_VERIFY_NONE;
    if (!ctx->use_system_verify && ctx->verify_mode == SSL_VERIFY_REQUIRED_LUA) {
        mode =
            ctx->is_server ? (SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT) : SSL_VERIFY_PEER;
    }

    SSL_CTX_set_verify(ctx->ctx, mode, nullptr);
}

static LuaSSLContext* new_sslctx_userdata(lua_State* L) {
    LuaSSLContext* ctx = (LuaSSLContext*)lua_newuserdatadtor(L, sizeof(LuaSSLContext), sslctx_dtor);
    new (ctx) LuaSSLContext();
    ctx->ctx = nullptr;
    ctx->use_system_verify = true;
    ctx->verify_mode = SSL_VERIFY_REQUIRED_LUA;
    ctx->is_server = false;

    luaL_getmetatable(L, SSLCTX_METATABLE);
    lua_setmetatable(L, -2);
    return ctx;
}

static LuaSSLSocket* new_sslsocket_userdata(lua_State* L) {
    LuaSSLSocket* ss = (LuaSSLSocket*)lua_newuserdatadtor(L, sizeof(LuaSSLSocket), sslsock_dtor);
    new (ss) LuaSSLSocket();
    ss->ssl = nullptr;
    ss->fd = INVALID_SOCKET;
    ss->ctx = nullptr;
    ss->ctx_ref = LUA_NOREF;
    ss->connected = false;
    ss->closed = true;
    ss->timeout = -1.0;
    ss->L = L;
    return ss;
}

static SSL_CTX* make_base_context(lua_State* L, bool is_server) {
    SSL_CTX* ssl_ctx = SSL_CTX_new(is_server ? TLS_server_method() : TLS_client_method());
    if (!ssl_ctx) push_openssl_error(L, "SSL_CTX_new");

    if (SSL_CTX_set_min_proto_version(ssl_ctx, TLS1_2_VERSION) != 1) {
        SSL_CTX_free(ssl_ctx);
        push_openssl_error(L, "SSL_CTX_set_min_proto_version");
    }

    return ssl_ctx;
}

static LuaSSLContext* create_client_context(lua_State* L) {
    LuaSSLContext* ctx = new_sslctx_userdata(L);
    ctx->ctx = make_base_context(L, false);
    ctx->use_system_verify = true;
    ctx->verify_mode = SSL_VERIFY_REQUIRED_LUA;
    ctx->is_server = false;
    apply_ctx_verify_mode(ctx);
    return ctx;
}

static void load_cert_chain_from_memory(lua_State* L, SSL_CTX* ctx, const char* pem,
                                        const char* op) {
    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, op);

    X509* cert = PEM_read_bio_X509_AUX(bio, nullptr, nullptr, nullptr);
    if (!cert) {
        BIO_free(bio);
        push_openssl_error(L, op);
    }

    if (SSL_CTX_use_certificate(ctx, cert) != 1) {
        X509_free(cert);
        BIO_free(bio);
        push_openssl_error(L, op);
    }
    X509_free(cert);

    while (true) {
        X509* extra = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
        if (!extra) {
            ERR_clear_error();
            break;
        }

        if (SSL_CTX_add_extra_chain_cert(ctx, extra) != 1) {
            X509_free(extra);
            BIO_free(bio);
            push_openssl_error(L, op);
        }
    }

    BIO_free(bio);
}

static LuaSSLContext* create_server_context_common(lua_State* L) {
    LuaSSLContext* ctx = new_sslctx_userdata(L);
    ctx->ctx = make_base_context(L, true);
    ctx->use_system_verify = false;
    ctx->verify_mode = SSL_VERIFY_NONE_LUA;
    ctx->is_server = true;
    apply_ctx_verify_mode(ctx);
    return ctx;
}

static LuaSSLContext* create_server_context_from_files(lua_State* L, const std::string& certfile,
                                                       const std::string& keyfile,
                                                       const char* password) {
    {
        FILE* f = fopen(certfile.c_str(), "rb");
        if (!f)
            luaL_error(L, "ssl: certificate file not found: %s", certfile.c_str());
        else
            fclose(f);
    }
    {
        FILE* f = fopen(keyfile.c_str(), "rb");
        if (!f)
            luaL_error(L, "ssl: private key file not found: %s", keyfile.c_str());
        else
            fclose(f);
    }

    LuaSSLContext* ctx = create_server_context_common(L);
    SSL_CTX_set_default_passwd_cb(ctx->ctx, pem_password_callback);
    SSL_CTX_set_default_passwd_cb_userdata(ctx->ctx, (void*)password);

    if (SSL_CTX_use_certificate_chain_file(ctx->ctx, certfile.c_str()) != 1) {
        push_openssl_error(L, "load server certificate");
    }
    if (SSL_CTX_use_PrivateKey_file(ctx->ctx, keyfile.c_str(), SSL_FILETYPE_PEM) != 1) {
        push_openssl_error(L, "load server private key");
    }
    if (SSL_CTX_check_private_key(ctx->ctx) != 1) {
        push_openssl_error(L, "server certificate/private key mismatch");
    }

    return ctx;
}

static LuaSSLContext* create_server_context_from_memory(lua_State* L, const char* cert_pem,
                                                        const char* key_pem, const char* password) {
    LuaSSLContext* ctx = create_server_context_common(L);
    load_cert_chain_from_memory(L, ctx->ctx, cert_pem, "parse server certificate PEM");

    EVP_PKEY* pkey = load_private_key_pem(L, "parse server private key PEM", key_pem, password);
    if (SSL_CTX_use_PrivateKey(ctx->ctx, pkey) != 1) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "parse server private key PEM");
    }
    EVP_PKEY_free(pkey);

    if (SSL_CTX_check_private_key(ctx->ctx) != 1) {
        push_openssl_error(L, "server certificate/private key mismatch");
    }

    return ctx;
}

static STACK_OF(X509) * ssl_get_peer_chain(SSL* ssl) {
#if defined(OPENSSL_VERSION_NUMBER) && OPENSSL_VERSION_NUMBER >= 0x10100000L
    return SSL_get_peer_cert_chain(ssl);
#else
    return SSL_get_peer_cert_chain(ssl);
#endif
}

#ifdef _WIN32
#include <wincrypt.h>
#ifdef X509_NAME
#undef X509_NAME
#endif
#pragma comment(lib, "crypt32.lib")

static bool verify_cert_system_impl(SSL* ssl, const char* hostname, std::string& error) {
    X509* leaf = SSL_get1_peer_certificate(ssl);
    if (!leaf) {
        error = "ssl: server sent no certificate";
        return false;
    }

    int cert_len = i2d_X509(leaf, nullptr);
    if (cert_len <= 0) {
        X509_free(leaf);
        error = openssl_error_message("i2d_X509");
        return false;
    }

    std::vector<unsigned char> cert_buf((size_t)cert_len);
    unsigned char* cert_ptr = cert_buf.data();
    i2d_X509(leaf, &cert_ptr);

    PCCERT_CONTEXT pCert = CertCreateCertificateContext(X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                                                        cert_buf.data(), (DWORD)cert_buf.size());
    if (!pCert) {
        X509_free(leaf);
        error = format_string("ssl: CertCreateCertificateContext failed (%lu)", GetLastError());
        return false;
    }

    HCERTSTORE hStore =
        CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, nullptr);
    if (!hStore) {
        CertFreeCertificateContext(pCert);
        X509_free(leaf);
        error = "ssl: CertOpenStore failed";
        return false;
    }

    auto add_cert = [&](X509* cert) {
        int len = i2d_X509(cert, nullptr);
        if (len <= 0) return;
        std::vector<unsigned char> der((size_t)len);
        unsigned char* der_ptr = der.data();
        i2d_X509(cert, &der_ptr);
        CertAddEncodedCertificateToStore(hStore, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                                         der.data(), (DWORD)der.size(), CERT_STORE_ADD_USE_EXISTING,
                                         nullptr);
    };

    add_cert(leaf);
    STACK_OF(X509)* chain = ssl_get_peer_chain(ssl);
    if (chain) {
        int count = sk_X509_num(chain);
        for (int i = 0; i < count; i++) {
            X509* cert = sk_X509_value(chain, i);
            if (X509_cmp(cert, leaf) == 0) continue;
            add_cert(cert);
        }
    }

    CERT_CHAIN_PARA chainPara{};
    chainPara.cbSize = sizeof(chainPara);
    PCCERT_CHAIN_CONTEXT pChainCtx = nullptr;
    BOOL chainOk = CertGetCertificateChain(nullptr, pCert, nullptr, hStore, &chainPara,
                                           CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT, nullptr,
                                           &pChainCtx);
    if (!chainOk || !pChainCtx) {
        CertCloseStore(hStore, 0);
        CertFreeCertificateContext(pCert);
        X509_free(leaf);
        error = format_string("ssl: CertGetCertificateChain failed (%lu)", GetLastError());
        return false;
    }

    int wlen = MultiByteToWideChar(CP_UTF8, 0, hostname, -1, nullptr, 0);
    wchar_t* whostname = new wchar_t[wlen];
    MultiByteToWideChar(CP_UTF8, 0, hostname, -1, whostname, wlen);

    SSL_EXTRA_CERT_CHAIN_POLICY_PARA sslPolicy{};
    sslPolicy.cbSize = sizeof(sslPolicy);
    sslPolicy.dwAuthType = AUTHTYPE_SERVER;
    sslPolicy.pwszServerName = whostname;
    CERT_CHAIN_POLICY_PARA policyPara{};
    policyPara.cbSize = sizeof(policyPara);
    policyPara.pvExtraPolicyPara = &sslPolicy;
    CERT_CHAIN_POLICY_STATUS policyStatus{};
    policyStatus.cbSize = sizeof(policyStatus);

    BOOL policyOk = CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, pChainCtx, &policyPara,
                                                     &policyStatus);

    delete[] whostname;
    CertFreeCertificateChain(pChainCtx);
    CertCloseStore(hStore, 0);
    CertFreeCertificateContext(pCert);
    X509_free(leaf);

    if (!policyOk || policyStatus.dwError != 0) {
        error = format_string("ssl: certificate verification failed (Windows error 0x%08lX)",
                              policyStatus.dwError);
        return false;
    }

    return true;
}

static int verify_cert_system(lua_State* L, SSL* ssl, const char* hostname) {
    std::string error;
    if (!verify_cert_system_impl(ssl, hostname, error)) {
        luaL_error(L, "%s", error.c_str());
        return -1;
    }
    return 0;
}

#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

static bool verify_cert_system_impl(SSL* ssl, const char* hostname, std::string& error) {
    X509* leaf = SSL_get1_peer_certificate(ssl);
    if (!leaf) {
        error = "ssl: server sent no certificate";
        return false;
    }

    CFMutableArrayRef certs = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    auto append_cert = [&](X509* cert) {
        int len = i2d_X509(cert, nullptr);
        if (len <= 0) return;
        std::vector<unsigned char> der((size_t)len);
        unsigned char* der_ptr = der.data();
        i2d_X509(cert, &der_ptr);

        CFDataRef data = CFDataCreate(kCFAllocatorDefault, der.data(), (CFIndex)der.size());
        if (!data) return;
        SecCertificateRef sec_cert = SecCertificateCreateWithData(kCFAllocatorDefault, data);
        CFRelease(data);
        if (sec_cert) {
            CFArrayAppendValue(certs, sec_cert);
            CFRelease(sec_cert);
        }
    };

    append_cert(leaf);
    STACK_OF(X509)* chain = ssl_get_peer_chain(ssl);
    if (chain) {
        int count = sk_X509_num(chain);
        for (int i = 0; i < count; i++) {
            X509* cert = sk_X509_value(chain, i);
            if (X509_cmp(cert, leaf) == 0) continue;
            append_cert(cert);
        }
    }

    CFStringRef cfhost =
        CFStringCreateWithCString(kCFAllocatorDefault, hostname, kCFStringEncodingUTF8);
    SecPolicyRef policy = SecPolicyCreateSSL(true, cfhost);
    CFRelease(cfhost);

    SecTrustRef trust = nullptr;
    OSStatus status = SecTrustCreateWithCertificates(certs, policy, &trust);
    CFRelease(policy);
    CFRelease(certs);
    X509_free(leaf);

    if (status != errSecSuccess || !trust) {
        if (trust) CFRelease(trust);
        error = format_string("ssl: SecTrustCreateWithCertificates failed (%d)", (int)status);
        return false;
    }

    CFErrorRef err = nullptr;
    bool trusted = SecTrustEvaluateWithError(trust, &err);
    CFRelease(trust);

    if (!trusted) {
        if (err) {
            CFStringRef desc = CFErrorCopyDescription(err);
            char buf[512];
            CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8);
            CFRelease(desc);
            CFRelease(err);
            error = format_string("ssl: certificate verification failed: %s", buf);
        } else {
            error = "ssl: certificate verification failed";
        }
        return false;
    }

    return true;
}

static int verify_cert_system(lua_State* L, SSL* ssl, const char* hostname) {
    std::string error;
    if (!verify_cert_system_impl(ssl, hostname, error)) {
        luaL_error(L, "%s", error.c_str());
        return -1;
    }
    return 0;
}

#else

static bool verify_cert_system_impl(SSL* ssl, const char* hostname, std::string& error) {
    static const char* const candidates[] = {
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        "/etc/ssl/cert.pem",
        nullptr,
    };

    const char* bundle = nullptr;
    for (int i = 0; candidates[i]; ++i) {
        FILE* f = fopen(candidates[i], "rb");
        if (f) {
            fclose(f);
            bundle = candidates[i];
            break;
        }
    }

    if (!bundle) {
        error = "ssl: no system CA bundle found (install ca-certificates)";
        return false;
    }

    X509* leaf = SSL_get1_peer_certificate(ssl);
    if (!leaf) {
        error = "ssl: server sent no certificate";
        return false;
    }

    X509_STORE* store = X509_STORE_new();
    if (!store) {
        X509_free(leaf);
        error = openssl_error_message("X509_STORE_new");
        return false;
    }

    if (X509_STORE_load_locations(store, bundle, nullptr) != 1) {
        X509_STORE_free(store);
        X509_free(leaf);
        error = openssl_error_message("load system CA bundle");
        return false;
    }

    STACK_OF(X509)* untrusted = sk_X509_new_null();
    if (!untrusted) {
        X509_STORE_free(store);
        X509_free(leaf);
        error = openssl_error_message("sk_X509_new_null");
        return false;
    }

    STACK_OF(X509)* chain = ssl_get_peer_chain(ssl);
    if (chain) {
        int count = sk_X509_num(chain);
        for (int i = 0; i < count; i++) {
            X509* cert = sk_X509_value(chain, i);
            if (X509_cmp(cert, leaf) == 0) continue;
            X509_up_ref(cert);
            sk_X509_push(untrusted, cert);
        }
    }

    X509_STORE_CTX* store_ctx = X509_STORE_CTX_new();
    if (!store_ctx) {
        sk_X509_pop_free(untrusted, X509_free);
        X509_STORE_free(store);
        X509_free(leaf);
        error = openssl_error_message("X509_STORE_CTX_new");
        return false;
    }

    if (X509_STORE_CTX_init(store_ctx, store, leaf, untrusted) != 1) {
        X509_STORE_CTX_free(store_ctx);
        sk_X509_pop_free(untrusted, X509_free);
        X509_STORE_free(store);
        X509_free(leaf);
        error = openssl_error_message("X509_STORE_CTX_init");
        return false;
    }

    X509_VERIFY_PARAM* param = X509_STORE_CTX_get0_param(store_ctx);
    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (X509_VERIFY_PARAM_set1_host(param, hostname, 0) != 1) {
        X509_STORE_CTX_free(store_ctx);
        sk_X509_pop_free(untrusted, X509_free);
        X509_STORE_free(store);
        X509_free(leaf);
        error = openssl_error_message("X509_VERIFY_PARAM_set1_host");
        return false;
    }

    int verify_ok = X509_verify_cert(store_ctx);
    if (verify_ok != 1) {
        int err = X509_STORE_CTX_get_error(store_ctx);
        const char* msg = X509_verify_cert_error_string(err);
        X509_STORE_CTX_free(store_ctx);
        sk_X509_pop_free(untrusted, X509_free);
        X509_STORE_free(store);
        X509_free(leaf);
        error =
            format_string("ssl: certificate verification failed: %s", msg ? msg : "unknown error");
        return false;
    }

    X509_STORE_CTX_free(store_ctx);
    sk_X509_pop_free(untrusted, X509_free);
    X509_STORE_free(store);
    X509_free(leaf);
    return true;
}

static int verify_cert_system(lua_State* L, SSL* ssl, const char* hostname) {
    std::string error;
    if (!verify_cert_system_impl(ssl, hostname, error)) {
        luaL_error(L, "%s", error.c_str());
        return -1;
    }
    return 0;
}

#endif

static int ssl_poll_events_for_error(int ssl_err) {
    return ssl_err == SSL_ERROR_WANT_WRITE ? UV_WRITABLE : UV_READABLE;
}

static void ssl_handle_close_cb(uv_handle_t* handle) {
    SSLPendingOp* op = (SSLPendingOp*)handle->data;
    if (!op) return;
    op->handles_closing--;
    if (op->handles_closing <= 0) delete op;
}

static void cleanup_ssl_pending_op(SSLPendingOp* op) {
    if (op->threadRef != LUA_NOREF) {
        lua_unref(op->runtime->GL, op->threadRef);
        op->threadRef = LUA_NOREF;
    }
    if (op->ctx_ref != LUA_NOREF) {
        lua_unref(op->runtime->GL, op->ctx_ref);
        op->ctx_ref = LUA_NOREF;
    }
    if (!op->socket && op->ssl) {
        SSL_free(op->ssl);
        op->ssl = nullptr;
    }

    op->handles_closing = 0;
    if (!uv_is_closing((uv_handle_t*)&op->poll)) {
        op->handles_closing++;
        uv_poll_stop(&op->poll);
        uv_close((uv_handle_t*)&op->poll, ssl_handle_close_cb);
    }
    if (op->has_timer && !uv_is_closing((uv_handle_t*)&op->timer)) {
        op->handles_closing++;
        uv_timer_stop(&op->timer);
        uv_close((uv_handle_t*)&op->timer, ssl_handle_close_cb);
    }
    if (op->handles_closing <= 0) delete op;

    auto& pending = g_pendingSslOps[op->runtime];
    if (op->threadRef != LUA_NOREF)
        pending.erase(op->threadRef);
    else
        for (auto it = pending.begin(); it != pending.end(); ++it)
            if (it->second == op) {
                pending.erase(it);
                break;
            }
}

static void ssl_resume_failure(SSLPendingOp* op, const std::string& message) {
    lua_pushnil(op->thread);
    lua_pushlstring(op->thread, message.data(), message.size());
    int ref = op->threadRef;
    op->threadRef = LUA_NOREF;
    eryx_push_thread(op->runtime, ref, 2, false);
    cleanup_ssl_pending_op(op);
}

static void ssl_interrupt_all(EryxRuntime* rt, void*) {
    if (!rt) return;
    auto itmap = g_pendingSslOps.find(rt);
    if (itmap == g_pendingSslOps.end()) return;

    std::vector<int> refs;
    for (auto& kv : itmap->second) refs.push_back(kv.first);

    for (int ref : refs) {
        auto it = itmap->second.find(ref);
        if (it == itmap->second.end()) continue;
        SSLPendingOp* op = it->second;
        if (!op || op->finished) {
            itmap->second.erase(it);
            continue;
        }

        op->finished = true;
        if (op->thread && op->threadRef != LUA_NOREF) {
            eryx_exception_push_keyboard_interrupt(op->thread);
            int tref = op->threadRef;
            op->threadRef = LUA_NOREF;
            eryx_push_thread(rt, tref, 1, true);
        }

        cleanup_ssl_pending_op(op);
        itmap->second.erase(ref);
    }
}

static void cancel_sslsocket_pending_ops(lua_State* L, LuaSSLSocket* ss) {
    EryxRuntime* rt = eryx_get_runtime(L);
    auto itmap = g_pendingSslOps.find(rt);
    if (itmap == g_pendingSslOps.end()) return;

    std::vector<int> refs;
    for (auto& kv : itmap->second) {
        if (kv.second->socket == ss) refs.push_back(kv.first);
    }

    for (int ref : refs) {
        auto it = itmap->second.find(ref);
        if (it == itmap->second.end()) continue;
        SSLPendingOp* op = it->second;
        if (!op || op->finished) {
            itmap->second.erase(it);
            continue;
        }

        op->finished = true;
        if (op->thread && op->threadRef != LUA_NOREF) {
            lua_pushstring(op->thread, "ssl socket is closed");
            int tref = op->threadRef;
            op->threadRef = LUA_NOREF;
            eryx_push_thread(rt, tref, 1, true);
        }

        cleanup_ssl_pending_op(op);
        itmap->second.erase(ref);
    }
}

static void ssl_timeout_cb(uv_timer_t* handle);

static void ssl_rearm_poll(SSLPendingOp* op, int events) {
    op->finished = false;
    if (op->has_timer && op->timeout > 0 && !uv_is_closing((uv_handle_t*)&op->timer)) {
        uv_timer_stop(&op->timer);
        uv_timer_start(&op->timer, ssl_timeout_cb, (uint64_t)(op->timeout * 1000.0), 0);
    }
    uv_poll_start(&op->poll, events, [](uv_poll_t* handle, int status, int events) {
        SSLPendingOp* op = (SSLPendingOp*)handle->data;
        if (!op || op->finished) return;
        op->finished = true;

        uv_poll_stop(handle);
        if (op->has_timer && !uv_is_closing((uv_handle_t*)&op->timer)) uv_timer_stop(&op->timer);

        if (status < 0) {
            ssl_resume_failure(op, uv_strerror(status));
            return;
        }

        switch (op->op) {
            case SSLOpType::Handshake: {
                int ret = SSL_do_handshake(op->ssl);
                if (ret == 1) {
                    if (op->verify_system) {
                        std::string verify_error;
                        if (!verify_cert_system_impl(op->ssl, op->hostname.c_str(), verify_error)) {
                            ssl_resume_failure(op, verify_error);
                            return;
                        }
                    }

                    LuaSSLSocket* ss = new_sslsocket_userdata(op->thread);
                    ss->ssl = op->ssl;
                    ss->fd = op->fd;
                    ss->ctx = op->ctx;
                    ss->ctx_ref = op->ctx_ref;
                    ss->connected = true;
                    ss->closed = false;
                    ss->timeout = op->timeout;
                    ss->hostname = op->hostname;

                    op->ssl = nullptr;
                    op->ctx_ref = LUA_NOREF;
                    if (op->raw_socket_ud) *(SOCKET*)op->raw_socket_ud = INVALID_SOCKET;

                    luaL_getmetatable(op->thread, SSLSOCKET_METATABLE);
                    lua_setmetatable(op->thread, -2);

                    int ref = op->threadRef;
                    op->threadRef = LUA_NOREF;
                    eryx_push_thread(op->runtime, ref, 1, false);
                    cleanup_ssl_pending_op(op);
                    return;
                }

                int ssl_err = SSL_get_error(op->ssl, ret);
                if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
                    ssl_rearm_poll(op, ssl_poll_events_for_error(ssl_err));
                    return;
                }

                ssl_resume_failure(op, ssl_error_message("ssl_handshake", ssl_err));
                return;
            }

            case SSLOpType::Read: {
                char stackbuf[8192];
                char* tmp =
                    (op->bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[op->bufsize];
                int ret = SSL_read(op->ssl, tmp, op->bufsize);
                if (ret > 0) {
                    void* out = lua_newbuffer(op->thread, ret);
                    memcpy(out, tmp, ret);
                    if (tmp != stackbuf) delete[] tmp;
                    int ref = op->threadRef;
                    op->threadRef = LUA_NOREF;
                    eryx_push_thread(op->runtime, ref, 1, false);
                    cleanup_ssl_pending_op(op);
                    return;
                }

                int ssl_err = SSL_get_error(op->ssl, ret);
                if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
                    if (tmp != stackbuf) delete[] tmp;
                    ssl_rearm_poll(op, ssl_poll_events_for_error(ssl_err));
                    return;
                }
                if (ssl_err == SSL_ERROR_ZERO_RETURN || ret == 0) {
                    lua_newbuffer(op->thread, 0);
                    if (tmp != stackbuf) delete[] tmp;
                    int ref = op->threadRef;
                    op->threadRef = LUA_NOREF;
                    eryx_push_thread(op->runtime, ref, 1, false);
                    cleanup_ssl_pending_op(op);
                    return;
                }

                if (tmp != stackbuf) delete[] tmp;
                ssl_resume_failure(op, ssl_error_message("ssl_read", ssl_err));
                return;
            }

            case SSLOpType::Write:
            case SSLOpType::WriteAll: {
                while (op->data_sent < op->data.size()) {
                    int chunk_len = (int)std::min((size_t)INT_MAX, op->data.size() - op->data_sent);
                    int ret = SSL_write(op->ssl, op->data.data() + op->data_sent, chunk_len);
                    if (ret > 0) {
                        op->data_sent += (size_t)ret;
                        if (op->op == SSLOpType::Write) {
                            lua_pushinteger(op->thread, ret);
                            int ref = op->threadRef;
                            op->threadRef = LUA_NOREF;
                            eryx_push_thread(op->runtime, ref, 1, false);
                            cleanup_ssl_pending_op(op);
                            return;
                        }
                        continue;
                    }

                    int ssl_err = SSL_get_error(op->ssl, ret);
                    if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
                        ssl_rearm_poll(op, ssl_poll_events_for_error(ssl_err));
                        return;
                    }

                    ssl_resume_failure(op, ssl_error_message("ssl_write", ssl_err));
                    return;
                }

                int ref = op->threadRef;
                op->threadRef = LUA_NOREF;
                eryx_push_thread(op->runtime, ref, 0, false);
                cleanup_ssl_pending_op(op);
                return;
            }
        }
    });
}

static void ssl_timeout_cb(uv_timer_t* handle) {
    SSLPendingOp* op = (SSLPendingOp*)handle->data;
    if (!op || op->finished) return;
    op->finished = true;
    uv_poll_stop(&op->poll);

    const char* opname = "ssl operation";
    switch (op->op) {
        case SSLOpType::Handshake:
            opname = "ssl handshake";
            break;
        case SSLOpType::Read:
            opname = "ssl read";
            break;
        case SSLOpType::Write:
        case SSLOpType::WriteAll:
            opname = "ssl write";
            break;
    }

    ssl_resume_failure(op, format_string("%s timed out", opname));
}

static int schedule_ssl_pending_op(lua_State* L, SSLPendingOp* op, int events) {
    op->runtime = eryx_get_runtime(L);
    lua_pushthread(L);
    op->threadRef = lua_ref(L, -1);
    lua_pop(L, 1);

    int poll_init_rc;
#ifdef _WIN32
    poll_init_rc = uv_poll_init_socket(op->runtime->loop, &op->poll, op->fd);
#else
    poll_init_rc = uv_poll_init(op->runtime->loop, &op->poll, op->fd);
#endif
    if (poll_init_rc < 0) {
        lua_unref(op->runtime->GL, op->threadRef);
        if (op->ctx_ref != LUA_NOREF) lua_unref(op->runtime->GL, op->ctx_ref);
        if (!op->socket && op->ssl) SSL_free(op->ssl);
        delete op;
        luaL_error(L, "uv_poll_init failed: %s", uv_strerror(poll_init_rc));
    }

    op->poll.data = op;
    op->has_timer = false;
    op->finished = false;
    op->handles_closing = 0;

    g_pendingSslOps[op->runtime][op->threadRef] = op;
    if (g_registeredSslRuntimes.find(op->runtime) == g_registeredSslRuntimes.end()) {
        eryx_register_interrupt_callback(op->runtime, ssl_interrupt_all, nullptr);
        g_registeredSslRuntimes.insert(op->runtime);
    }

    if (op->timeout > 0) {
        uv_timer_init(op->runtime->loop, &op->timer);
        op->timer.data = op;
        op->has_timer = true;
        uv_timer_start(&op->timer, ssl_timeout_cb, (uint64_t)(op->timeout * 1000.0), 0);
    }

    ssl_rearm_poll(op, events);
    return lua_yield(L, 0);
}

static void push_wrapped_ssl_socket(lua_State* L, SSL* ssl, SOCKET fd, LuaSSLContext* ctx,
                                    int ctx_ref, const char* hostname, double timeout,
                                    void* raw_socket_ud) {
    LuaSSLSocket* ss = new_sslsocket_userdata(L);
    ss->ssl = ssl;
    ss->fd = fd;
    ss->ctx = ctx;
    ss->ctx_ref = ctx_ref;
    ss->connected = true;
    ss->closed = false;
    ss->timeout = timeout;
    if (hostname) ss->hostname = hostname;

    if (raw_socket_ud) *(SOCKET*)raw_socket_ud = INVALID_SOCKET;

    luaL_getmetatable(L, SSLSOCKET_METATABLE);
    lua_setmetatable(L, -2);
}

static int ssl_do_handshake(lua_State* L, SSL* ssl) {
    while (true) {
        int ret = SSL_do_handshake(ssl);
        if (ret == 1) return 0;

        int ssl_err = SSL_get_error(ssl, ret);
        if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) continue;
        return ssl_lua_error(L, "ssl_handshake", ssl, ret);
    }
}

static void sslsock_close_impl(LuaSSLSocket* ss) {
    if (!ss || ss->closed) return;

    if (ss->L) cancel_sslsocket_pending_ops(ss->L, ss);

    if (ss->ssl) {
        if (ss->connected) {
            int ret = SSL_shutdown(ss->ssl);
            if (ret == 0) SSL_shutdown(ss->ssl);
        }
        SSL_free(ss->ssl);
        ss->ssl = nullptr;
    }

    if (ss->fd != INVALID_SOCKET) {
        sock_fd_close(ss->fd);
        ss->fd = INVALID_SOCKET;
    }

    ss->connected = false;
    ss->closed = true;
}

static int wrap_socket_with_context(lua_State* L, int ctx_idx, int sock_idx, int hostname_idx) {
    ctx_idx = lua_absindex(L, ctx_idx);
    sock_idx = lua_absindex(L, sock_idx);

    LuaSSLContext* ctx = check_sslctx(L, ctx_idx);
    LuaSocket* raw_socket = check_socket(L, sock_idx);
    SOCKET fd = raw_socket->fd;
    if (fd == INVALID_SOCKET) luaL_error(L, "ssl: socket is closed");

    const char* hostname =
        lua_isnoneornil(L, hostname_idx) ? nullptr : luaL_checkstring(L, hostname_idx);
    if (!ctx->is_server && ctx->verify_mode == SSL_VERIFY_REQUIRED_LUA && !hostname) {
        luaL_error(L, "ssl: verified client connections require serverHostname");
    }

    SSL* ssl = SSL_new(ctx->ctx);
    if (!ssl) push_openssl_error(L, "SSL_new");

    if (!ctx->is_server) {
        if (hostname && SSL_set_tlsext_host_name(ssl, hostname) != 1) {
            SSL_free(ssl);
            push_openssl_error(L, "SSL_set_tlsext_host_name");
        }

        if (!ctx->use_system_verify && ctx->verify_mode == SSL_VERIFY_REQUIRED_LUA) {
            if (SSL_set1_host(ssl, hostname) != 1) {
                SSL_free(ssl);
                push_openssl_error(L, "SSL_set1_host");
            }
        }

        SSL_set_connect_state(ssl);
    } else {
        SSL_set_accept_state(ssl);
    }

    SSL_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE);

    if (SSL_set_fd(ssl, (int)(intptr_t)fd) != 1) {
        SSL_free(ssl);
        push_openssl_error(L, "SSL_set_fd");
    }

    int ctx_ref = LUA_NOREF;
    lua_pushvalue(L, ctx_idx);
    ctx_ref = lua_ref(L, -1);
    lua_pop(L, 1);

    int ret = SSL_do_handshake(ssl);
    if (ret != 1) {
        int ssl_err = SSL_get_error(ssl, ret);
        if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
            SSLPendingOp* op = new SSLPendingOp();
            op->thread = L;
            op->op = SSLOpType::Handshake;
            op->ssl = ssl;
            op->fd = fd;
            op->socket = nullptr;
            op->raw_socket_ud = raw_socket;
            op->ctx = ctx;
            op->ctx_ref = ctx_ref;
            op->verify_system = !ctx->is_server && ctx->use_system_verify &&
                                ctx->verify_mode == SSL_VERIFY_REQUIRED_LUA;
            op->timeout = raw_socket->timeout;
            op->bufsize = 0;
            op->data_sent = 0;
            if (hostname) op->hostname = hostname;
            return schedule_ssl_pending_op(L, op, ssl_poll_events_for_error(ssl_err));
        }

        lua_unref(eryx_get_runtime(L)->GL, ctx_ref);
        SSL_free(ssl);
        return ssl_lua_error_code(L, "ssl_handshake", ssl_err);
    }

    if (!ctx->is_server && ctx->use_system_verify && ctx->verify_mode == SSL_VERIFY_REQUIRED_LUA) {
        if (verify_cert_system(L, ssl, hostname) != 0) {
            lua_unref(eryx_get_runtime(L)->GL, ctx_ref);
            SSL_free(ssl);
            return 0;
        }
    }

    push_wrapped_ssl_socket(L, ssl, fd, ctx, ctx_ref, hostname, raw_socket->timeout, raw_socket);
    return 1;
}

// ---------------------------------------------------------------------------
// SSLContext methods
// ---------------------------------------------------------------------------
static int ssl_create_default_context(lua_State* L) {
    create_client_context(L);
    return 1;
}

static int ssl_create_server_context(lua_State* L) {
    std::string certfile = luaL_checkpathlike(L, 1);
    std::string keyfile = luaL_checkpathlike(L, 2);
    const char* password = luaL_optstring(L, 3, nullptr);
    create_server_context_from_files(L, certfile, keyfile, password);
    return 1;
}

static int ssl_create_server_context_pem(lua_State* L) {
    const char* cert_pem = luaL_checkstring(L, 1);
    const char* key_pem = luaL_checkstring(L, 2);
    const char* password = luaL_optstring(L, 3, nullptr);
    create_server_context_from_memory(L, cert_pem, key_pem, password);
    return 1;
}

static int sslctx_load_verify_locations(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);
    std::string cafile = luaL_checkpathlike(L, 2);

    FILE* f = fopen(cafile.c_str(), "rb");
    if (!f) luaL_error(L, "ssl: CA file not found: %s", cafile.c_str());
    fclose(f);

    if (SSL_CTX_load_verify_locations(ctx->ctx, cafile.c_str(), nullptr) != 1) {
        push_openssl_error(L, "load_verify_locations");
    }

    ctx->use_system_verify = false;
    apply_ctx_verify_mode(ctx);
    return 0;
}

static int sslctx_set_verify(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);
    int mode = (int)luaL_checkinteger(L, 2);
    if (mode != SSL_VERIFY_NONE_LUA && mode != SSL_VERIFY_REQUIRED_LUA) {
        luaL_error(L, "ssl: invalid verify mode %d", mode);
        return 0;
    }

    ctx->verify_mode = mode;
    apply_ctx_verify_mode(ctx);
    return 0;
}

static int sslctx_wrap_socket(lua_State* L) { return wrap_socket_with_context(L, 1, 2, 3); }

static int sslctx_tostring(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);
    char buf[128];
    snprintf(buf, sizeof(buf), "SSLContext(%s, verify=%s, ca=%s)",
             ctx->is_server ? "server" : "client",
             ctx->verify_mode == SSL_VERIFY_REQUIRED_LUA ? "REQUIRED" : "NONE",
             ctx->use_system_verify ? "system" : "custom");
    lua_pushstring(L, buf);
    return 1;
}

static void sslctx_dtor(void* ud) {
    LuaSSLContext* ctx = (LuaSSLContext*)ud;
    if (ctx->ctx) {
        SSL_CTX_free(ctx->ctx);
        ctx->ctx = nullptr;
    }
    ctx->~LuaSSLContext();
}

// ---------------------------------------------------------------------------
// SSLSocket methods
// ---------------------------------------------------------------------------
static int sslsock_send(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    if (ss->closed || !ss->ssl) luaL_error(L, "ssl socket is closed");

    size_t len = 0;
    const char* data = sslsock_check_bytes_arg(L, 2, &len);
    check_openssl_input_len(L, len, "data");

    int ret = SSL_write(ss->ssl, data, (int)len);
    if (ret > 0) {
        lua_pushinteger(L, ret);
        return 1;
    }

    int ssl_err = SSL_get_error(ss->ssl, ret);
    if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
        if (ss->timeout == 0) {
            lua_pushnil(L);
            return 1;
        }
        SSLPendingOp* op = new SSLPendingOp();
        op->thread = L;
        op->op = SSLOpType::Write;
        op->ssl = ss->ssl;
        op->fd = ss->fd;
        op->socket = ss;
        op->raw_socket_ud = nullptr;
        op->ctx = nullptr;
        op->ctx_ref = LUA_NOREF;
        op->verify_system = false;
        op->timeout = ss->timeout;
        op->bufsize = 0;
        op->data_sent = 0;
        op->data.assign(data, len);
        return schedule_ssl_pending_op(L, op, ssl_poll_events_for_error(ssl_err));
    }

    return ssl_lua_error(L, "ssl_write", ss->ssl, ret);
}

static int sslsock_sendall(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    if (ss->closed || !ss->ssl) luaL_error(L, "ssl socket is closed");

    size_t len = 0;
    const char* data = sslsock_check_bytes_arg(L, 2, &len);
    check_openssl_input_len(L, len, "data");

    size_t total = 0;
    while (total < len) {
        int chunk_len = (int)((len - total) > (size_t)INT_MAX ? (size_t)INT_MAX : (len - total));
        int ret = SSL_write(ss->ssl, data + total, chunk_len);
        if (ret > 0) {
            total += (size_t)ret;
            continue;
        }

        int ssl_err = SSL_get_error(ss->ssl, ret);
        if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
            if (total == 0 && ss->timeout == 0) {
                lua_pushboolean(L, false);
                return 1;
            }
            SSLPendingOp* op = new SSLPendingOp();
            op->thread = L;
            op->op = SSLOpType::WriteAll;
            op->ssl = ss->ssl;
            op->fd = ss->fd;
            op->socket = ss;
            op->raw_socket_ud = nullptr;
            op->ctx = nullptr;
            op->ctx_ref = LUA_NOREF;
            op->verify_system = false;
            op->timeout = ss->timeout;
            op->bufsize = 0;
            op->data_sent = total;
            op->data.assign(data, len);
            return schedule_ssl_pending_op(L, op, ssl_poll_events_for_error(ssl_err));
        }
        return ssl_lua_error(L, "ssl_write", ss->ssl, ret);
    }

    return 0;
}

static int sslsock_recv(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    if (ss->closed || !ss->ssl) luaL_error(L, "ssl socket is closed");

    int bufsize = (int)luaL_checkinteger(L, 2);
    if (bufsize <= 0) luaL_argerror(L, 2, "bufsize must be > 0");

    char stackbuf[8192];
    char* tmp = (bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[bufsize];

    int ret = SSL_read(ss->ssl, tmp, bufsize);
    if (ret > 0) {
        void* out = lua_newbuffer(L, ret);
        memcpy(out, tmp, ret);
        if (tmp != stackbuf) delete[] tmp;
        return 1;
    }

    int ssl_err = SSL_get_error(ss->ssl, ret);
    if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
        if (tmp != stackbuf) delete[] tmp;
        if (ss->timeout == 0) {
            lua_pushnil(L);
            return 1;
        }
        SSLPendingOp* op = new SSLPendingOp();
        op->thread = L;
        op->op = SSLOpType::Read;
        op->ssl = ss->ssl;
        op->fd = ss->fd;
        op->socket = ss;
        op->raw_socket_ud = nullptr;
        op->ctx = nullptr;
        op->ctx_ref = LUA_NOREF;
        op->verify_system = false;
        op->timeout = ss->timeout;
        op->bufsize = bufsize;
        op->data_sent = 0;
        return schedule_ssl_pending_op(L, op, ssl_poll_events_for_error(ssl_err));
    }
    if (ssl_err == SSL_ERROR_ZERO_RETURN || ret == 0) {
        void* out = lua_newbuffer(L, 0);
        (void)out;
        if (tmp != stackbuf) delete[] tmp;
        return 1;
    }

    if (tmp != stackbuf) delete[] tmp;
    return ssl_lua_error(L, "ssl_read", ss->ssl, ret);
}

static int sslsock_close(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    sslsock_close_impl(ss);
    return 0;
}

static int sslsock_setblocking(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    luaL_checktype(L, 2, LUA_TBOOLEAN);
    bool blocking = lua_toboolean(L, 2);
    ss->timeout = blocking ? -1.0 : 0.0;
    return 0;
}

static int sslsock_settimeout(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    if (lua_isnoneornil(L, 2)) {
        ss->timeout = -1.0;
    } else {
        ss->timeout = luaL_checknumber(L, 2);
    }
    return 0;
}

static int sslsock_getpeername(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    if (getpeername(ss->fd, (struct sockaddr*)&addr, &addrlen) == SOCKET_ERROR) {
        luaL_error(L, "getpeername failed");
        return 0;
    }

    char host[NI_MAXHOST];
    char serv[NI_MAXSERV];
    getnameinfo((struct sockaddr*)&addr, addrlen, host, sizeof(host), serv, sizeof(serv),
                NI_NUMERICHOST | NI_NUMERICSERV);
    lua_pushstring(L, host);
    lua_pushinteger(L, atoi(serv));
    return 2;
}

static int sslsock_getsockname(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    if (getsockname(ss->fd, (struct sockaddr*)&addr, &addrlen) == SOCKET_ERROR) {
        luaL_error(L, "getsockname failed");
        return 0;
    }

    char host[NI_MAXHOST];
    char serv[NI_MAXSERV];
    getnameinfo((struct sockaddr*)&addr, addrlen, host, sizeof(host), serv, sizeof(serv),
                NI_NUMERICHOST | NI_NUMERICSERV);
    lua_pushstring(L, host);
    lua_pushinteger(L, atoi(serv));
    return 2;
}

static int sslsock_fileno(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    lua_pushnumber(L, (double)(uintptr_t)ss->fd);
    return 1;
}

static int sslsock_tostring(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    char buf[128];
    if (ss->closed)
        snprintf(buf, sizeof(buf), "SSLSocket(closed)");
    else
        snprintf(buf, sizeof(buf), "SSLSocket(fd=%d, host=%s)", (int)(intptr_t)ss->fd,
                 ss->hostname.c_str());
    lua_pushstring(L, buf);
    return 1;
}

static void sslsock_dtor(void* ud) {
    LuaSSLSocket* ss = (LuaSSLSocket*)ud;
    sslsock_close_impl(ss);
    if (ss->ctx_ref != LUA_NOREF && ss->L) {
        lua_unref(ss->L, ss->ctx_ref);
        ss->ctx_ref = LUA_NOREF;
    }
    ss->~LuaSSLSocket();
}

// ---------------------------------------------------------------------------
// Module-level convenience: ssl.wrapSocket(sock [, hostname])
// ---------------------------------------------------------------------------
static int ssl_wrap_socket(lua_State* L) {
    create_client_context(L);
    int ctx_idx = lua_gettop(L);
    return wrap_socket_with_context(L, ctx_idx, 1, 2);
}

// ---------------------------------------------------------------------------
// Certificate / Key Generation
// ---------------------------------------------------------------------------
static X509_NAME* parse_subject_name(lua_State* L, const char* subject, const char* op) {
    X509_NAME* name = X509_NAME_new();
    if (!name) push_openssl_error(L, op);

    std::string input(subject ? subject : "");
    size_t pos = 0;
    bool added_any = false;
    while (pos < input.size()) {
        size_t next = input.find(',', pos);
        std::string part = trim_copy(
            input.substr(pos, next == std::string::npos ? std::string::npos : next - pos));
        pos = next == std::string::npos ? input.size() : next + 1;
        if (part.empty()) continue;

        size_t eq = part.find('=');
        if (eq == std::string::npos) {
            X509_NAME_free(name);
            luaL_error(L, "%s: invalid subject component '%s'", op, part.c_str());
            return nullptr;
        }

        std::string key = trim_copy(part.substr(0, eq));
        std::string value = trim_copy(part.substr(eq + 1));
        if (key.empty() || value.empty()) {
            X509_NAME_free(name);
            luaL_error(L, "%s: invalid subject component '%s'", op, part.c_str());
            return nullptr;
        }

        if (X509_NAME_add_entry_by_txt(name, key.c_str(), MBSTRING_ASC,
                                       (const unsigned char*)value.c_str(), -1, -1, 0) != 1) {
            X509_NAME_free(name);
            push_openssl_error(L, op);
        }

        added_any = true;
    }

    if (!added_any) {
        X509_NAME_free(name);
        luaL_error(L, "%s: subject must not be empty", op);
        return nullptr;
    }

    return name;
}

static void add_v3_ext(lua_State* L, X509* cert, int nid, const char* value, const char* op) {
    X509_EXTENSION* ext = X509V3_EXT_conf_nid(nullptr, nullptr, nid, (char*)value);
    if (!ext) push_openssl_error(L, op);

    if (X509_add_ext(cert, ext, -1) != 1) {
        X509_EXTENSION_free(ext);
        push_openssl_error(L, op);
    }

    X509_EXTENSION_free(ext);
}

static int ssl_generate_key(lua_State* L) {
    const char* type = luaL_optstring(L, 1, "rsa");

    EVP_PKEY_CTX* ctx = nullptr;
    if (strcmp(type, "rsa") == 0) {
        int bits = (int)luaL_optinteger(L, 2, 2048);
        ctx = EVP_PKEY_CTX_new_from_name(nullptr, "RSA", nullptr);
        if (!ctx) push_openssl_error(L, "generate_key");
        if (EVP_PKEY_keygen_init(ctx) != 1 || EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) != 1) {
            EVP_PKEY_CTX_free(ctx);
            push_openssl_error(L, "generate_key");
        }
    } else if (strcmp(type, "ec") == 0) {
        int bits = (int)luaL_optinteger(L, 2, 256);
        if (bits != 256) luaL_error(L, "generate_key: only 256-bit EC keys are supported");

        ctx = EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr);
        if (!ctx) push_openssl_error(L, "generate_key");
        if (EVP_PKEY_keygen_init(ctx) != 1) {
            EVP_PKEY_CTX_free(ctx);
            push_openssl_error(L, "generate_key");
        }

        const char* group_name = "prime256v1";
        OSSL_PARAM params[] = {
            OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, (char*)group_name, 0),
            OSSL_PARAM_construct_end(),
        };
        if (EVP_PKEY_CTX_set_params(ctx, params) != 1) {
            EVP_PKEY_CTX_free(ctx);
            push_openssl_error(L, "generate_key");
        }
    } else {
        luaL_error(L, "generate_key: unsupported type '%s' (expected 'rsa' or 'ec')", type);
        return 0;
    }

    EVP_PKEY* pkey = nullptr;
    if (EVP_PKEY_generate(ctx, &pkey) != 1) {
        EVP_PKEY_CTX_free(ctx);
        push_openssl_error(L, "generate_key");
    }
    EVP_PKEY_CTX_free(ctx);

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generate_key");
    }

    if (PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        BIO_free(bio);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generate_key");
    }

    std::string pem = bio_to_string(L, bio, "generate_key");
    BIO_free(bio);
    EVP_PKEY_free(pkey);

    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

static int ssl_generate_self_signed_cert(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "key");
    if (!lua_isstring(L, -1))
        luaL_error(L, "generateSelfSignedCert: 'key' field (PEM string) is required");
    const char* key_pem = lua_tostring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "subject");
    const char* subject = luaL_optstring(L, -1, "CN=localhost");
    lua_pop(L, 1);

    lua_getfield(L, 1, "days");
    int days = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 365;
    lua_pop(L, 1);

    lua_getfield(L, 1, "isCa");
    bool is_ca = lua_isboolean(L, -1) ? (lua_toboolean(L, -1) != 0) : false;
    lua_pop(L, 1);

    EVP_PKEY* pkey = load_private_key_pem(L, "generateSelfSignedCert: parse key", key_pem, nullptr);

    X509* cert = X509_new();
    if (!cert) {
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert");
    }

    if (X509_set_version(cert, 2) != 1) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set version");
    }

    unsigned char serial_bytes[16];
    if (RAND_bytes(serial_bytes, (int)sizeof(serial_bytes)) != 1) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set serial");
    }
    serial_bytes[0] &= 0x7F;

    ASN1_INTEGER* serial = ASN1_INTEGER_new();
    if (!serial) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set serial");
    }
    BIGNUM* serial_bn = BN_bin2bn(serial_bytes, (int)sizeof(serial_bytes), nullptr);
    if (!serial_bn || BN_to_ASN1_INTEGER(serial_bn, serial) == nullptr ||
        X509_set_serialNumber(cert, serial) != 1) {
        ASN1_INTEGER_free(serial);
        BN_free(serial_bn);
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set serial");
    }
    ASN1_INTEGER_free(serial);
    BN_free(serial_bn);

    if (X509_gmtime_adj(X509_get_notBefore(cert), 0) == nullptr ||
        X509_gmtime_adj(X509_get_notAfter(cert), (long)days * 86400L) == nullptr) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set validity");
    }

    if (X509_set_pubkey(cert, pkey) != 1) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set public key");
    }

    X509_NAME* name = parse_subject_name(L, subject, "generateSelfSignedCert: set subject");
    if (X509_set_subject_name(cert, name) != 1 || X509_set_issuer_name(cert, name) != 1) {
        X509_NAME_free(name);
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: set subject");
    }
    X509_NAME_free(name);

    add_v3_ext(L, cert, NID_basic_constraints, is_ca ? "critical,CA:TRUE" : "CA:FALSE",
               "generateSelfSignedCert: basic constraints");

    lua_getfield(L, 1, "san");
    if (lua_istable(L, -1)) {
        int san_count = (int)lua_objlen(L, -1);
        if (san_count > 64) san_count = 64;
        if (san_count > 0) {
            std::string san_value;
            for (int i = 0; i < san_count; i++) {
                lua_rawgeti(L, -1, i + 1);
                const char* name_value = luaL_checkstring(L, -1);
                if (!san_value.empty()) san_value += ',';
                san_value += looks_like_ipv4(name_value) ? "IP:" : "DNS:";
                san_value += name_value;
                lua_pop(L, 1);
            }

            add_v3_ext(L, cert, NID_subject_alt_name, san_value.c_str(),
                       "generateSelfSignedCert: set SAN");
        }
    }
    lua_pop(L, 1);

    if (X509_sign(cert, pkey, EVP_sha256()) <= 0) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: write PEM");
    }

    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio) {
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: write PEM");
    }
    if (PEM_write_bio_X509(bio, cert) != 1) {
        BIO_free(bio);
        X509_free(cert);
        EVP_PKEY_free(pkey);
        push_openssl_error(L, "generateSelfSignedCert: write PEM");
    }

    std::string pem = bio_to_string(L, bio, "generateSelfSignedCert: write PEM");
    BIO_free(bio);
    X509_free(cert);
    EVP_PKEY_free(pkey);

    lua_pushlstring(L, pem.data(), pem.size());
    return 1;
}

static int ssl_parse_certificate(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);

    BIO* bio = BIO_new_mem_buf(pem, -1);
    if (!bio) push_openssl_error(L, "parseCertificate");

    X509* cert = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!cert) push_openssl_error(L, "parseCertificate");

    lua_newtable(L);

    std::string info = format_cert_info(L, cert, "parseCertificate");
    lua_pushlstring(L, info.data(), info.size());
    lua_setfield(L, -2, "info");

    std::string subject = format_x509_name(L, X509_get_subject_name(cert), "parseCertificate");
    lua_pushlstring(L, subject.data(), subject.size());
    lua_setfield(L, -2, "subject");

    std::string issuer = format_x509_name(L, X509_get_issuer_name(cert), "parseCertificate");
    lua_pushlstring(L, issuer.data(), issuer.size());
    lua_setfield(L, -2, "issuer");

    std::string valid_from = format_asn1_time(L, X509_get_notBefore(cert), "parseCertificate");
    lua_pushlstring(L, valid_from.data(), valid_from.size());
    lua_setfield(L, -2, "validFrom");

    std::string valid_to = format_asn1_time(L, X509_get_notAfter(cert), "parseCertificate");
    lua_pushlstring(L, valid_to.data(), valid_to.size());
    lua_setfield(L, -2, "validTo");

    lua_pushinteger(L, (lua_Integer)X509_get_version(cert) + 1);
    lua_setfield(L, -2, "version");

    std::string serial = format_serial_hex(cert);
    lua_pushlstring(L, serial.data(), serial.size());
    lua_setfield(L, -2, "serial");

    X509_free(cert);
    return 1;
}

// ---------------------------------------------------------------------------
// Metatables / registration
// ---------------------------------------------------------------------------
static int sslsocket_index(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    const char* key = luaL_checkstring(L, 2);

    if (strcmp(key, "readable") == 0) {
        lua_pushboolean(L, !ss->closed);
        return 1;
    }
    if (strcmp(key, "writable") == 0) {
        lua_pushboolean(L, !ss->closed);
        return 1;
    }
    if (strcmp(key, "closed") == 0) {
        lua_pushboolean(L, ss->closed);
        return 1;
    }

    lua_pushvalue(L, 2);
    lua_rawget(L, lua_upvalueindex(1));
    return 1;
}

static void register_sslctx_metatable(lua_State* L) {
    luaL_newmetatable(L, SSLCTX_METATABLE);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, sslctx_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, sslctx_wrap_socket, "wrapSocket");
    lua_setfield(L, -2, "wrapSocket");

    lua_pushcfunction(L, sslctx_load_verify_locations, "loadVerifyLocations");
    lua_setfield(L, -2, "loadVerifyLocations");

    lua_pushcfunction(L, sslctx_set_verify, "setVerify");
    lua_setfield(L, -2, "setVerify");

    lua_pop(L, 1);
}

static void register_sslsocket_metatable(lua_State* L) {
    luaL_newmetatable(L, SSLSOCKET_METATABLE);

    lua_newtable(L);
    lua_pushcfunction(L, sslsock_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, sslsock_send, "send");
    lua_setfield(L, -2, "send");
    lua_pushcfunction(L, sslsock_send, "write");
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, sslsock_send, "writeSync");
    lua_setfield(L, -2, "writeSync");
    lua_pushcfunction(L, sslsock_sendall, "sendAll");
    lua_setfield(L, -2, "sendAll");
    lua_pushcfunction(L, sslsock_sendall, "writeAll");
    lua_setfield(L, -2, "writeAll");
    lua_pushcfunction(L, sslsock_recv, "recv");
    lua_setfield(L, -2, "recv");
    lua_pushcfunction(L, sslsock_recv, "read");
    lua_setfield(L, -2, "read");
    lua_pushcfunction(L, sslsock_recv, "readSync");
    lua_setfield(L, -2, "readSync");
    lua_pushcfunction(L, sslsock_recv, "readBuffer");
    lua_setfield(L, -2, "readBuffer");
    lua_pushcfunction(L, sslsock_recv, "readBufferSync");
    lua_setfield(L, -2, "readBufferSync");
    lua_pushcfunction(L, sslsock_close, "close");
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, sslsock_close, "closeSync");
    lua_setfield(L, -2, "closeSync");
    lua_pushcfunction(L, sslsock_setblocking, "setBlocking");
    lua_setfield(L, -2, "setBlocking");
    lua_pushcfunction(L, sslsock_settimeout, "setTimeout");
    lua_setfield(L, -2, "setTimeout");
    lua_pushcfunction(L, sslsock_getpeername, "getPeerName");
    lua_setfield(L, -2, "getPeerName");
    lua_pushcfunction(L, sslsock_getsockname, "getSockName");
    lua_setfield(L, -2, "getSockName");
    lua_pushcfunction(L, sslsock_fileno, "fileNo");
    lua_setfield(L, -2, "fileNo");

    lua_pushcclosure(L, sslsocket_index, "__index", 1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, sslsock_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pop(L, 1);
}

LUAU_MODULE_EXPORT int luauopen__ssl(lua_State* L) {
    register_sslctx_metatable(L);
    register_sslsocket_metatable(L);

    lua_newtable(L);

    lua_pushcfunction(L, ssl_create_default_context, "createDefaultContext");
    lua_setfield(L, -2, "createDefaultContext");

    lua_pushcfunction(L, ssl_wrap_socket, "wrapSocket");
    lua_setfield(L, -2, "wrapSocket");

    lua_pushcfunction(L, ssl_create_server_context, "createServerContext");
    lua_setfield(L, -2, "createServerContext");

    lua_pushcfunction(L, ssl_create_server_context_pem, "createServerContextPem");
    lua_setfield(L, -2, "createServerContextPem");

    lua_pushcfunction(L, ssl_generate_key, "generateKey");
    lua_setfield(L, -2, "generateKey");

    lua_pushcfunction(L, ssl_generate_self_signed_cert, "generateSelfSignedCert");
    lua_setfield(L, -2, "generateSelfSignedCert");

    lua_pushcfunction(L, ssl_parse_certificate, "parseCertificate");
    lua_setfield(L, -2, "parseCertificate");

    lua_pushinteger(L, SSL_VERIFY_NONE_LUA);
    lua_setfield(L, -2, "VERIFY_NONE");

    lua_pushinteger(L, SSL_VERIFY_REQUIRED_LUA);
    lua_setfield(L, -2, "VERIFY_REQUIRED");

    lua_setreadonly(L, -1, true);
    return 1;
}
