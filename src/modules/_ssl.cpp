// _ssl.cpp  –  TLS wrapper for _socket, using mbedTLS (Win32)
//
// Provides a Python ssl-module-like interface:
//
//   ssl.wrap_socket(sock [, options]) -> SSLSocket
//   ssl.create_default_context()      -> SSLContext   (client)
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

// ---------------------------------------------------------------------------
// Platform socket compatibility (mirrors _socket.hpp)
// ---------------------------------------------------------------------------
#ifndef _WIN32
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
using SOCKET = int;
#define INVALID_SOCKET  (-1)
#define SOCKET_ERROR    (-1)
#define sock_fd_close(fd) close(fd)
#else
#define sock_fd_close(fd) closesocket(fd)
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

// mbedTLS headers
#include "mbedtls/debug.h"
#include "mbedtls/error.h"
#include "mbedtls/md.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/x509_csr.h"


// mbedTLS 4.0: RNG is handled internally via PSA Crypto
#include "lua.h"
#include "lualib.h"
#include "module_api.h"
#include "psa/crypto.h"


// ---------------------------------------------------------------------------
// Module metadata
// ---------------------------------------------------------------------------
static const LuauModuleInfo INFO = {
    .abiVersion = 1,
    .luauVersion = LUAU_GIT_HASH,
    .entry = "luauopen__ssl",
};
LUAU_MODULE_INFO()

// ---------------------------------------------------------------------------
// Metatables
// ---------------------------------------------------------------------------
static const char* SSLCTX_METATABLE = "SSLContext";
static const char* SSLSOCKET_METATABLE = "SSLSocket";

// ---------------------------------------------------------------------------
// SSLContext  –  shared configuration (verify mode)
// In mbedTLS 4.0, RNG is handled internally by PSA Crypto.
// Certificate verification is delegated to Windows CryptoAPI.
// ---------------------------------------------------------------------------
struct LuaSSLContext {
    mbedtls_ssl_config conf;
    mbedtls_x509_crt cacert;    // for explicit load_verify_locations
    mbedtls_x509_crt own_cert;  // server certificate chain
    mbedtls_pk_context pk_key;  // server private key
    bool use_system_verify;     // true -> delegate to Win CryptoAPI
    int verify_mode;            // MBEDTLS_SSL_VERIFY_NONE / REQUIRED
    bool is_server;             // true for server contexts
    bool has_own_cert;          // true when own_cert/pk_key are loaded
};

static LuaSSLContext* check_sslctx(lua_State* L, int idx) {
    return (LuaSSLContext*)luaL_checkudata(L, idx, SSLCTX_METATABLE);
}

// ---------------------------------------------------------------------------
// SSLSocket  –  a TLS-wrapped socket
// ---------------------------------------------------------------------------
struct LuaSSLSocket {
    mbedtls_ssl_context ssl;
    mbedtls_net_context net;
    LuaSSLContext* ctx;  // borrowed pointer (kept alive by Lua ref)
    int ctx_ref;         // LUA_REGISTRYINDEX ref to keep ctx alive
    bool connected;
    std::string hostname;
};

static LuaSSLSocket* check_sslsocket(lua_State* L, int idx) {
    return (LuaSSLSocket*)luaL_checkudata(L, idx, SSLSOCKET_METATABLE);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
// Raise a Lua error with an mbedTLS error string.
static int mbedtls_lua_error(lua_State* L, const char* prefix, int ret) {
    char buf[256];
    mbedtls_strerror(ret, buf, sizeof(buf));
    luaL_error(L, "%s: [%d] %s", prefix, ret, buf);
    return 0;
}

// ---------------------------------------------------------------------------
// System certificate verification  (post-handshake, all platforms)
//
// On Windows:  Windows CryptoAPI  (browser-identical trust anchors)
// On macOS:    Security framework (SecTrustEvaluateWithError)
// On Linux:    mbedtls_x509_crt_verify against a probed CA bundle file
// ---------------------------------------------------------------------------

#ifdef _WIN32
#include <wincrypt.h>
#pragma comment(lib, "crypt32.lib")

static int verify_cert_system(lua_State* L, mbedtls_ssl_context* ssl, const char* hostname) {
    const mbedtls_x509_crt* peer = mbedtls_ssl_get_peer_cert(ssl);
    if (!peer) { luaL_error(L, "ssl: server sent no certificate"); return -1; }

    PCCERT_CONTEXT pCert = CertCreateCertificateContext(X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                                                        peer->raw.p, (DWORD)peer->raw.len);
    if (!pCert) {
        luaL_error(L, "ssl: CertCreateCertificateContext failed (%lu)", GetLastError());
        return -1;
    }

    HCERTSTORE hStore =
        CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, nullptr);
    if (!hStore) { CertFreeCertificateContext(pCert); luaL_error(L, "ssl: CertOpenStore failed"); return -1; }

    for (const mbedtls_x509_crt* c = peer; c != nullptr; c = c->next) {
        CertAddEncodedCertificateToStore(hStore, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                                         c->raw.p, (DWORD)c->raw.len,
                                         CERT_STORE_ADD_USE_EXISTING, nullptr);
    }

    CERT_CHAIN_PARA chainPara{};
    chainPara.cbSize = sizeof(chainPara);
    PCCERT_CHAIN_CONTEXT pChainCtx = nullptr;
    BOOL chainOk = CertGetCertificateChain(nullptr, pCert, nullptr, hStore, &chainPara,
                                           CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
                                           nullptr, &pChainCtx);
    if (!chainOk || !pChainCtx) {
        CertCloseStore(hStore, 0); CertFreeCertificateContext(pCert);
        luaL_error(L, "ssl: CertGetCertificateChain failed (%lu)", GetLastError()); return -1;
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

    BOOL policyOk = CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, pChainCtx,
                                                     &policyPara, &policyStatus);
    delete[] whostname;
    CertFreeCertificateChain(pChainCtx);
    CertCloseStore(hStore, 0);
    CertFreeCertificateContext(pCert);

    if (!policyOk || policyStatus.dwError != 0) {
        luaL_error(L, "ssl: certificate verification failed (Windows error 0x%08lX)",
                   policyStatus.dwError);
        return -1;
    }
    return 0;
}

#elif defined(__APPLE__)
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>

static int verify_cert_system(lua_State* L, mbedtls_ssl_context* ssl, const char* hostname) {
    const mbedtls_x509_crt* peer = mbedtls_ssl_get_peer_cert(ssl);
    if (!peer) { luaL_error(L, "ssl: server sent no certificate"); return -1; }

    // Build a CFArray of SecCertificateRef from the DER chain
    CFMutableArrayRef certs =
        CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (const mbedtls_x509_crt* c = peer; c != nullptr; c = c->next) {
        CFDataRef der = CFDataCreate(kCFAllocatorDefault, c->raw.p, (CFIndex)c->raw.len);
        SecCertificateRef cert = SecCertificateCreateWithData(kCFAllocatorDefault, der);
        CFRelease(der);
        if (cert) { CFArrayAppendValue(certs, cert); CFRelease(cert); }
    }

    // Create a trust object with the SSL server policy and hostname
    CFStringRef cfhost =
        CFStringCreateWithCString(kCFAllocatorDefault, hostname, kCFStringEncodingUTF8);
    SecPolicyRef policy = SecPolicyCreateSSL(true, cfhost);
    CFRelease(cfhost);

    SecTrustRef trust = nullptr;
    OSStatus status = SecTrustCreateWithCertificates(certs, policy, &trust);
    CFRelease(policy);
    CFRelease(certs);

    if (status != errSecSuccess || !trust) {
        if (trust) CFRelease(trust);
        luaL_error(L, "ssl: SecTrustCreateWithCertificates failed (%d)", (int)status);
        return -1;
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
            luaL_error(L, "ssl: certificate verification failed: %s", buf);
        } else {
            luaL_error(L, "ssl: certificate verification failed");
        }
        return -1;
    }
    return 0;
}

#else  // Linux and other POSIX

static int verify_cert_system(lua_State* L, mbedtls_ssl_context* ssl, const char* hostname) {
    // Probe well-known CA bundle paths (same set as curl/Python)
    static const char* const candidates[] = {
        "/etc/ssl/certs/ca-certificates.crt",           // Debian, Ubuntu, Arch
        "/etc/pki/tls/certs/ca-bundle.crt",             // RHEL, Fedora, CentOS
        "/etc/ssl/ca-bundle.pem",                       // OpenSUSE
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // RHEL 7+
        "/etc/ssl/cert.pem",                            // Alpine, some others
        nullptr,
    };
    const char* bundle = nullptr;
    for (int i = 0; candidates[i]; ++i) {
        FILE* f = fopen(candidates[i], "rb");
        if (f) { fclose(f); bundle = candidates[i]; break; }
    }
    if (!bundle) {
        luaL_error(L, "ssl: no system CA bundle found (install ca-certificates)");
        return -1;
    }

    const mbedtls_x509_crt* peer = mbedtls_ssl_get_peer_cert(ssl);
    if (!peer) { luaL_error(L, "ssl: server sent no certificate"); return -1; }

    mbedtls_x509_crt ca;
    mbedtls_x509_crt_init(&ca);
    int ret = mbedtls_x509_crt_parse_file(&ca, bundle);
    if (ret < 0) {
        mbedtls_x509_crt_free(&ca);
        char err[256]; mbedtls_strerror(ret, err, sizeof(err));
        luaL_error(L, "ssl: failed to load CA bundle %s: %s", bundle, err);
        return -1;
    }

    uint32_t flags = 0;
    ret = mbedtls_x509_crt_verify((mbedtls_x509_crt*)peer, &ca, nullptr, hostname,
                                   &flags, nullptr, nullptr);
    mbedtls_x509_crt_free(&ca);

    if (ret != 0 || flags != 0) {
        char info[512];
        mbedtls_x509_crt_verify_info(info, sizeof(info), "", flags);
        luaL_error(L, "ssl: certificate verification failed: %s", info);
        return -1;
    }
    return 0;
}

#endif  // platform verify

// ---------------------------------------------------------------------------
// Custom BIO send/recv callbacks that operate on an existing socket fd
// (passed in through mbedtls_net_context.fd).
// ---------------------------------------------------------------------------
static int bio_send(void* ctx, const unsigned char* buf, size_t len) {
    mbedtls_net_context* net = (mbedtls_net_context*)ctx;
    int ret = ::send((SOCKET)net->fd, (const char*)buf, (int)len, 0);
    if (ret < 0) {
#ifdef _WIN32
        if (WSAGetLastError() == WSAEWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
#endif
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return ret;
}

static int bio_recv(void* ctx, unsigned char* buf, size_t len) {
    mbedtls_net_context* net = (mbedtls_net_context*)ctx;
    int ret = ::recv((SOCKET)net->fd, (char*)buf, (int)len, 0);
    if (ret < 0) {
#ifdef _WIN32
        if (WSAGetLastError() == WSAEWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
#endif
        return MBEDTLS_ERR_NET_RECV_FAILED;
    }
    if (ret == 0) return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
    return ret;
}

// ---------------------------------------------------------------------------
// SSLContext methods
// ---------------------------------------------------------------------------

// ssl.create_default_context() -> SSLContext  (client mode)
static int ssl_create_default_context(lua_State* L) {
    LuaSSLContext* ctx = (LuaSSLContext*)lua_newuserdata(L, sizeof(LuaSSLContext));
    new (ctx) LuaSSLContext();

    mbedtls_ssl_config_init(&ctx->conf);
    mbedtls_x509_crt_init(&ctx->cacert);
    mbedtls_x509_crt_init(&ctx->own_cert);
    mbedtls_pk_init(&ctx->pk_key);
    ctx->use_system_verify = true;
    ctx->verify_mode = MBEDTLS_SSL_VERIFY_REQUIRED;
    ctx->is_server = false;
    ctx->has_own_cert = false;

    // Configure as TLS client with default ciphersuites
    // mbedTLS 4.0: RNG is set up internally by PSA Crypto (psa_crypto_init)
    int ret = mbedtls_ssl_config_defaults(&ctx->conf, MBEDTLS_SSL_IS_CLIENT,
                                          MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_config_defaults", ret);

    // System verify: let mbedTLS do the handshake without CA verification
    // (we verify post-handshake via Windows CryptoAPI)
    mbedtls_ssl_conf_authmode(&ctx->conf, MBEDTLS_SSL_VERIFY_NONE);

    luaL_getmetatable(L, SSLCTX_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// ssl.create_server_context(certfile, keyfile [, password]) -> SSLContext  (server mode)
//
// Creates an SSLContext configured for TLS server operation.
// `certfile` is a PEM file containing the server certificate chain.
// `keyfile` is a PEM file containing the server private key.
// Optional `password` for encrypted private keys.
static int ssl_create_server_context(lua_State* L) {
    const char* certfile = luaL_checkstring(L, 1);
    const char* keyfile = luaL_checkstring(L, 2);
    const char* password = luaL_optstring(L, 3, nullptr);

    // Check files exist before calling mbedTLS (which gives cryptic errors)
    { FILE* f = fopen(certfile, "rb"); if (!f) luaL_error(L, "ssl: certificate file not found: %s", certfile); else fclose(f); }
    { FILE* f = fopen(keyfile, "rb"); if (!f) luaL_error(L, "ssl: private key file not found: %s", keyfile); else fclose(f); }

    LuaSSLContext* ctx = (LuaSSLContext*)lua_newuserdata(L, sizeof(LuaSSLContext));
    new (ctx) LuaSSLContext();

    mbedtls_ssl_config_init(&ctx->conf);
    mbedtls_x509_crt_init(&ctx->cacert);
    mbedtls_x509_crt_init(&ctx->own_cert);
    mbedtls_pk_init(&ctx->pk_key);
    ctx->use_system_verify = false;
    ctx->verify_mode = MBEDTLS_SSL_VERIFY_NONE;  // servers don't verify client certs by default
    ctx->is_server = true;
    ctx->has_own_cert = false;

    // Configure as TLS server
    int ret = mbedtls_ssl_config_defaults(&ctx->conf, MBEDTLS_SSL_IS_SERVER,
                                          MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_config_defaults (server)", ret);

    // Server doesn't verify client certificates by default
    mbedtls_ssl_conf_authmode(&ctx->conf, MBEDTLS_SSL_VERIFY_NONE);

    // Load server certificate chain
    ret = mbedtls_x509_crt_parse_file(&ctx->own_cert, certfile);
    if (ret < 0) return mbedtls_lua_error(L, "load server certificate", ret);

    // Load server private key
    ret = mbedtls_pk_parse_keyfile(&ctx->pk_key, keyfile, password);
    if (ret != 0) return mbedtls_lua_error(L, "load server private key", ret);

    // Attach certificate + key to the config
    ret = mbedtls_ssl_conf_own_cert(&ctx->conf, &ctx->own_cert, &ctx->pk_key);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_conf_own_cert", ret);
    ctx->has_own_cert = true;

    luaL_getmetatable(L, SSLCTX_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// SSLContext:load_verify_locations(cafile)
// Switches from system (Windows CryptoAPI) verification to mbedTLS-based
// verification using the supplied CA file.
static int sslctx_load_verify_locations(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);
    const char* cafile = luaL_checkstring(L, 2);

    int ret = mbedtls_x509_crt_parse_file(&ctx->cacert, cafile);
    if (ret < 0) {
        FILE* f = fopen(cafile, "rb");
        if (!f) luaL_error(L, "ssl: CA file not found: %s", cafile);
        else fclose(f);
        return mbedtls_lua_error(L, "load_verify_locations", ret);
    }

    // Switch to mbedTLS verification with the loaded CA chain
    ctx->use_system_verify = false;
    mbedtls_ssl_conf_ca_chain(&ctx->conf, &ctx->cacert, nullptr);
    mbedtls_ssl_conf_authmode(&ctx->conf, ctx->verify_mode);
    return 0;
}

// SSLContext:set_verify(mode)  -- 0 = VERIFY_NONE, 2 = VERIFY_REQUIRED
static int sslctx_set_verify(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);
    int mode = luaL_checkinteger(L, 2);
    ctx->verify_mode = mode;
    // Only change mbedTLS authmode if we're using mbedTLS-based verification
    // (i.e. custom CA via load_verify_locations).  When using system verify,
    // mbedTLS stays at VERIFY_NONE and we do post-handshake verification.
    if (!ctx->use_system_verify) {
        mbedtls_ssl_conf_authmode(&ctx->conf, mode);
    }
    return 0;
}

// SSLContext:wrap_socket(socket_ud [, server_hostname]) -> SSLSocket
//
// Takes ownership of the underlying SOCKET fd.  The original Lua Socket
// userdata should not be used for I/O after wrapping (close is fine).
static int sslctx_wrap_socket(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);

    // The second argument is a Socket userdata – we read its fd field.
    // Socket struct: { SOCKET fd; int family; int type; int proto; double timeout; }
    // We use luaL_checkudata with "Socket" metatable.
    void* raw_socket = luaL_checkudata(L, 2, "Socket");
    SOCKET fd = *(SOCKET*)raw_socket;  // fd is the first field

    // Take ownership: prevent the original Socket's __gc from closing the fd
    *(SOCKET*)raw_socket = INVALID_SOCKET;

    const char* hostname = luaL_optstring(L, 3, nullptr);

    // Allocate SSLSocket userdata
    LuaSSLSocket* ss = (LuaSSLSocket*)lua_newuserdata(L, sizeof(LuaSSLSocket));
    new (ss) LuaSSLSocket();

    mbedtls_ssl_init(&ss->ssl);
    mbedtls_net_init(&ss->net);
    ss->ctx = ctx;
    ss->connected = false;
    if (hostname) ss->hostname = hostname;

    // Keep a strong reference to the SSLContext so it stays alive
    lua_pushvalue(L, 1);
    ss->ctx_ref = lua_ref(L, -1);
    lua_pop(L, 1);

    // Transfer the raw SOCKET fd into mbedtls_net_context
    ss->net.fd = (int)(intptr_t)fd;

    // Setup SSL from the shared config
    int ret = mbedtls_ssl_setup(&ss->ssl, &ctx->conf);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_setup", ret);

    // Set hostname for SNI (client mode only)
    if (!ctx->is_server && hostname) {
        ret = mbedtls_ssl_set_hostname(&ss->ssl, hostname);
        if (ret != 0) return mbedtls_lua_error(L, "ssl_set_hostname", ret);
    }

    // Wire up our custom BIO callbacks
    mbedtls_ssl_set_bio(&ss->ssl, &ss->net, bio_send, bio_recv, nullptr);

    // Perform the TLS handshake
    while ((ret = mbedtls_ssl_handshake(&ss->ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE)
            return mbedtls_lua_error(L, "ssl_handshake", ret);
    }

    // Post-handshake: verify certificate via system trust store (client mode only)
    if (!ctx->is_server && ctx->use_system_verify &&
        ctx->verify_mode == MBEDTLS_SSL_VERIFY_REQUIRED && hostname) {
        verify_cert_system(L, &ss->ssl, hostname);
    }

    ss->connected = true;

    luaL_getmetatable(L, SSLSOCKET_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// __tostring
static int sslctx_tostring(lua_State* L) {
    LuaSSLContext* ctx = check_sslctx(L, 1);
    char buf[128];
    snprintf(buf, sizeof(buf), "SSLContext(%s, verify=%s, ca=%s)",
             ctx->is_server ? "server" : "client",
             ctx->verify_mode == MBEDTLS_SSL_VERIFY_REQUIRED ? "REQUIRED" : "NONE",
             ctx->use_system_verify ? "system" : "custom");
    lua_pushstring(L, buf);
    return 1;
}

// __gc
static int sslctx_gc(lua_State* L) {
    LuaSSLContext* ctx = (LuaSSLContext*)luaL_checkudata(L, 1, SSLCTX_METATABLE);
    if (ctx) {
        if (ctx->has_own_cert) {
            mbedtls_pk_free(&ctx->pk_key);
            mbedtls_x509_crt_free(&ctx->own_cert);
        }
        mbedtls_x509_crt_free(&ctx->cacert);
        mbedtls_ssl_config_free(&ctx->conf);
        ctx->~LuaSSLContext();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// SSLSocket methods
// ---------------------------------------------------------------------------

// SSLSocket:send(buf) -> bytes_sent
static int sslsock_send(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    size_t len = 0;
    const char* data = (const char*)luaL_checkbuffer(L, 2, &len);

    int ret;
    do {
        ret = mbedtls_ssl_write(&ss->ssl, (const unsigned char*)data, len);
    } while (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ ||
             ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);
    if (ret < 0) return mbedtls_lua_error(L, "ssl_write", ret);

    lua_pushinteger(L, ret);
    return 1;
}

// SSLSocket:sendall(buf)
static int sslsock_sendall(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    size_t len = 0;
    const char* data = (const char*)luaL_checkbuffer(L, 2, &len);

    size_t total = 0;
    while (total < len) {
        int ret = mbedtls_ssl_write(&ss->ssl, (const unsigned char*)(data + total), len - total);
        if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ ||
            ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
            continue;
        if (ret < 0) return mbedtls_lua_error(L, "ssl_write", ret);
        total += ret;
    }
    return 0;
}

// SSLSocket:recv(bufsize) -> buffer
static int sslsock_recv(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    int bufsize = luaL_checkinteger(L, 2);
    if (bufsize <= 0) luaL_argerror(L, 2, "bufsize must be > 0");

    char stackbuf[8192];
    char* tmp = (bufsize <= (int)sizeof(stackbuf)) ? stackbuf : new char[bufsize];

    int ret;
    do {
        ret = mbedtls_ssl_read(&ss->ssl, (unsigned char*)tmp, bufsize);
    } while (ret == MBEDTLS_ERR_SSL_WANT_READ ||
             ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);

    if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || ret == 0) {
        // Connection closed cleanly - return empty buffer
        void* out = lua_newbuffer(L, 0);
        if (tmp != stackbuf) delete[] tmp;
        return 1;
    }
    if (ret < 0) {
        if (tmp != stackbuf) delete[] tmp;
        return mbedtls_lua_error(L, "ssl_read", ret);
    }

    void* out = lua_newbuffer(L, ret);
    memcpy(out, tmp, ret);
    if (tmp != stackbuf) delete[] tmp;
    return 1;
}

// SSLSocket:close()
static int sslsock_close(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    if (ss->connected) {
        mbedtls_ssl_close_notify(&ss->ssl);
        ss->connected = false;
    }
    if (ss->net.fd >= 0) {
        sock_fd_close((SOCKET)(intptr_t)ss->net.fd);
        ss->net.fd = -1;
    }
    return 0;
}

// SSLSocket:getpeername() -> host, port
static int sslsock_getpeername(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    if (getpeername((SOCKET)(intptr_t)ss->net.fd, (struct sockaddr*)&addr, &addrlen) ==
        SOCKET_ERROR) {
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

// SSLSocket:getsockname() -> host, port
static int sslsock_getsockname(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    struct sockaddr_storage addr {};
    socklen_t addrlen = sizeof(addr);
    if (getsockname((SOCKET)(intptr_t)ss->net.fd, (struct sockaddr*)&addr, &addrlen) ==
        SOCKET_ERROR) {
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

// SSLSocket:fileno() -> number
static int sslsock_fileno(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    lua_pushnumber(L, (double)(uintptr_t)ss->net.fd);
    return 1;
}

// __tostring
static int sslsock_tostring(lua_State* L) {
    LuaSSLSocket* ss = check_sslsocket(L, 1);
    char buf[128];
    if (!ss->connected)
        snprintf(buf, sizeof(buf), "SSLSocket(closed)");
    else
        snprintf(buf, sizeof(buf), "SSLSocket(fd=%d, host=%s)", ss->net.fd, ss->hostname.c_str());
    lua_pushstring(L, buf);
    return 1;
}

// __gc
static int sslsock_gc(lua_State* L) {
    LuaSSLSocket* ss = (LuaSSLSocket*)luaL_checkudata(L, 1, SSLSOCKET_METATABLE);
    if (ss) {
        if (ss->connected) {
            mbedtls_ssl_close_notify(&ss->ssl);
            ss->connected = false;
        }
        mbedtls_ssl_free(&ss->ssl);
        if (ss->net.fd >= 0) {
            sock_fd_close((SOCKET)(intptr_t)ss->net.fd);
            ss->net.fd = -1;
        }
        // Release the SSLContext reference
        if (ss->ctx_ref != LUA_NOREF) {
            lua_unref(L, ss->ctx_ref);
            ss->ctx_ref = LUA_NOREF;
        }
        ss->~LuaSSLSocket();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Module-level convenience: ssl.wrap_socket(sock [, hostname])
// Creates a default context and wraps in one call.
// ---------------------------------------------------------------------------
static int ssl_wrap_socket(lua_State* L) {
    // arg1 = Socket userdata, arg2 = optional hostname
    void* raw_socket = luaL_checkudata(L, 1, "Socket");
    (void)raw_socket;
    const char* hostname = luaL_optstring(L, 2, nullptr);
    SOCKET fd = *(SOCKET*)raw_socket;

    // Take ownership: prevent the original Socket's __gc from closing the fd
    *(SOCKET*)raw_socket = INVALID_SOCKET;

    // Create a default context (system verify, VERIFY_REQUIRED)
    LuaSSLContext* ctx = (LuaSSLContext*)lua_newuserdata(L, sizeof(LuaSSLContext));
    new (ctx) LuaSSLContext();
    mbedtls_ssl_config_init(&ctx->conf);
    mbedtls_x509_crt_init(&ctx->cacert);
    mbedtls_x509_crt_init(&ctx->own_cert);
    mbedtls_pk_init(&ctx->pk_key);
    ctx->use_system_verify = true;
    ctx->verify_mode = MBEDTLS_SSL_VERIFY_REQUIRED;
    ctx->is_server = false;
    ctx->has_own_cert = false;

    int ret = mbedtls_ssl_config_defaults(&ctx->conf, MBEDTLS_SSL_IS_CLIENT,
                                          MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_config_defaults", ret);

    // System verify: let mbedTLS do the handshake without CA verification
    mbedtls_ssl_conf_authmode(&ctx->conf, MBEDTLS_SSL_VERIFY_NONE);

    luaL_getmetatable(L, SSLCTX_METATABLE);
    lua_setmetatable(L, -2);
    // Stack: sock, [hostname], ctx
    int ctx_idx = lua_gettop(L);

    // Allocate SSLSocket
    LuaSSLSocket* ss = (LuaSSLSocket*)lua_newuserdata(L, sizeof(LuaSSLSocket));
    new (ss) LuaSSLSocket();
    mbedtls_ssl_init(&ss->ssl);
    mbedtls_net_init(&ss->net);
    ss->ctx = ctx;
    ss->connected = false;
    if (hostname) ss->hostname = hostname;

    // Keep context alive via Lua ref
    lua_pushvalue(L, ctx_idx);
    ss->ctx_ref = lua_ref(L, -1);
    lua_pop(L, 1);

    ss->net.fd = (int)(intptr_t)fd;

    ret = mbedtls_ssl_setup(&ss->ssl, &ctx->conf);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_setup", ret);

    // Set hostname for certificate verification (and SNI for DNS names)
    if (hostname) {
        ret = mbedtls_ssl_set_hostname(&ss->ssl, hostname);
        if (ret != 0) return mbedtls_lua_error(L, "ssl_set_hostname", ret);
    }

    mbedtls_ssl_set_bio(&ss->ssl, &ss->net, bio_send, bio_recv, nullptr);

    while ((ret = mbedtls_ssl_handshake(&ss->ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE)
            return mbedtls_lua_error(L, "ssl_handshake", ret);
    }

    // Post-handshake: verify certificate via system trust store
    if (ctx->use_system_verify && ctx->verify_mode == MBEDTLS_SSL_VERIFY_REQUIRED && hostname) {
        verify_cert_system(L, &ss->ssl, hostname);
    }

    ss->connected = true;

    luaL_getmetatable(L, SSLSOCKET_METATABLE);
    lua_setmetatable(L, -2);
    return 1;  // return SSLSocket only
}

// ---------------------------------------------------------------------------
// Certificate / Key Generation
// ---------------------------------------------------------------------------

// Helper: crude check for IPv4 literal ("1.2.3.4")
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

// ssl.generate_key(type?, bits?) -> pem_string
//   type: "rsa" (default) or "ec"
//   bits: 2048 default for RSA, 256 default for EC (secp256r1)
static int ssl_generate_key(lua_State* L) {
    const char* type = luaL_optstring(L, 1, "rsa");

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_SIGN_MESSAGE |
                                        PSA_KEY_USAGE_VERIFY_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_lifetime(&attrs, PSA_KEY_LIFETIME_VOLATILE);

    if (strcmp(type, "rsa") == 0) {
        int bits = (int)luaL_optinteger(L, 2, 2048);
        psa_set_key_type(&attrs, PSA_KEY_TYPE_RSA_KEY_PAIR);
        psa_set_key_bits(&attrs, (size_t)bits);
        psa_set_key_algorithm(&attrs, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_SHA_256));
    } else if (strcmp(type, "ec") == 0) {
        int bits = (int)luaL_optinteger(L, 2, 256);
        psa_set_key_type(&attrs, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
        psa_set_key_bits(&attrs, (size_t)bits);
        psa_set_key_algorithm(&attrs, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    } else {
        luaL_error(L, "generate_key: unsupported type '%s' (expected 'rsa' or 'ec')", type);
        return 0;
    }

    mbedtls_svc_key_id_t key_id;
    psa_status_t status = psa_generate_key(&attrs, &key_id);
    psa_reset_key_attributes(&attrs);
    if (status != PSA_SUCCESS) {
        luaL_error(L, "generate_key: psa_generate_key failed (%d)", (int)status);
        return 0;
    }

    // Copy PSA key into PK context so we can write PEM
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_copy_from_psa(key_id, &pk);
    psa_destroy_key(key_id);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_key", ret);
    }

    unsigned char buf[16384];
    ret = mbedtls_pk_write_key_pem(&pk, buf, sizeof(buf));
    mbedtls_pk_free(&pk);
    if (ret != 0) return mbedtls_lua_error(L, "generate_key", ret);

    lua_pushstring(L, (const char*)buf);
    return 1;
}

// ssl.generate_self_signed_cert({ key, subject?, days?, san?, is_ca? }) -> cert_pem
static int ssl_generate_self_signed_cert(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    // Required: key  (PEM string)
    lua_getfield(L, 1, "key");
    if (!lua_isstring(L, -1))
        luaL_error(L, "generate_self_signed_cert: 'key' field (PEM string) is required");
    const char* key_pem = lua_tostring(L, -1);
    size_t key_pem_len = lua_objlen(L, -1);
    lua_pop(L, 1);

    // Optional fields
    lua_getfield(L, 1, "subject");
    const char* subject = luaL_optstring(L, -1, "CN=localhost");
    lua_pop(L, 1);

    lua_getfield(L, 1, "days");
    int days = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 365;
    lua_pop(L, 1);

    lua_getfield(L, 1, "is_ca");
    bool is_ca = lua_isboolean(L, -1) ? (lua_toboolean(L, -1) != 0) : false;
    lua_pop(L, 1);

    // Parse the private key from PEM
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_key(&pk, (const unsigned char*)key_pem, key_pem_len + 1, nullptr, 0);
    if (ret != 0) {
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_self_signed_cert: parse key", ret);
    }

    // Set up x509write context
    mbedtls_x509write_cert crt;
    mbedtls_x509write_crt_init(&crt);

    mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&crt, &pk);
    mbedtls_x509write_crt_set_issuer_key(&crt, &pk);  // self-signed

    ret = mbedtls_x509write_crt_set_subject_name(&crt, subject);
    if (ret != 0) {
        mbedtls_x509write_crt_free(&crt);
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_self_signed_cert: set subject", ret);
    }
    ret = mbedtls_x509write_crt_set_issuer_name(&crt, subject);  // self-signed
    if (ret != 0) {
        mbedtls_x509write_crt_free(&crt);
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_self_signed_cert: set issuer", ret);
    }

    // Random serial number
    unsigned char serial[16];
    psa_generate_random(serial, sizeof(serial));
    serial[0] &= 0x7F;  // ASN.1 INTEGER must be positive
    ret = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial));
    if (ret != 0) {
        mbedtls_x509write_crt_free(&crt);
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_self_signed_cert: set serial", ret);
    }

    // Validity: not_before = now, not_after = now + days
    time_t now_t = time(nullptr);
    struct tm tb;
#ifdef _WIN32
    gmtime_s(&tb, &now_t);
#else
    gmtime_r(&now_t, &tb);
#endif
    char not_before[16], not_after[16];
    snprintf(not_before, sizeof(not_before), "%04d%02d%02d%02d%02d%02d", tb.tm_year + 1900,
             tb.tm_mon + 1, tb.tm_mday, tb.tm_hour, tb.tm_min, tb.tm_sec);
    time_t later = now_t + (time_t)days * 86400;
#ifdef _WIN32
    gmtime_s(&tb, &later);
#else
    gmtime_r(&later, &tb);
#endif
    snprintf(not_after, sizeof(not_after), "%04d%02d%02d%02d%02d%02d", tb.tm_year + 1900,
             tb.tm_mon + 1, tb.tm_mday, tb.tm_hour, tb.tm_min, tb.tm_sec);
    ret = mbedtls_x509write_crt_set_validity(&crt, not_before, not_after);
    if (ret != 0) {
        mbedtls_x509write_crt_free(&crt);
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_self_signed_cert: set validity", ret);
    }

    // Basic constraints
    ret = mbedtls_x509write_crt_set_basic_constraints(&crt, is_ca ? 1 : 0, is_ca ? -1 : 0);
    if (ret != 0) {
        mbedtls_x509write_crt_free(&crt);
        mbedtls_pk_free(&pk);
        return mbedtls_lua_error(L, "generate_self_signed_cert: basic constraints", ret);
    }

    // Subject Alternative Names (optional)
    lua_getfield(L, 1, "san");
    if (lua_istable(L, -1)) {
        int san_count = (int)lua_objlen(L, -1);
        if (san_count > 64) san_count = 64;
        if (san_count > 0) {
            // Stack-allocate SAN list nodes and IP buffers
            mbedtls_x509_san_list* san_nodes =
                (mbedtls_x509_san_list*)alloca(san_count * sizeof(mbedtls_x509_san_list));
            unsigned char(*ip_bufs)[4] = (unsigned char(*)[4])alloca(san_count * 4);
            memset(san_nodes, 0, san_count * sizeof(mbedtls_x509_san_list));

            // Push each SAN string onto the Lua stack to keep it alive.
            // Stack layout after the loop: [san_table] [str1] [str2] ...
            for (int i = 0; i < san_count; i++) {
                lua_rawgeti(L, -1 - i, i + 1);  // push string
                const char* name = luaL_checkstring(L, -1);

                if (looks_like_ipv4(name)) {
                    san_nodes[i].node.type = MBEDTLS_X509_SAN_IP_ADDRESS;
                    inet_pton(AF_INET, name, ip_bufs[i]);
                    san_nodes[i].node.san.unstructured_name.p = ip_bufs[i];
                    san_nodes[i].node.san.unstructured_name.len = 4;
                } else {
                    san_nodes[i].node.type = MBEDTLS_X509_SAN_DNS_NAME;
                    san_nodes[i].node.san.unstructured_name.p = (unsigned char*)name;
                    san_nodes[i].node.san.unstructured_name.len = strlen(name);
                }
                san_nodes[i].next = (i + 1 < san_count) ? &san_nodes[i + 1] : nullptr;
                // Don't pop – keep string alive on stack
            }

            ret = mbedtls_x509write_crt_set_subject_alternative_name(&crt, &san_nodes[0]);
            // Pop all SAN strings
            lua_pop(L, san_count);
            if (ret != 0) {
                mbedtls_x509write_crt_free(&crt);
                mbedtls_pk_free(&pk);
                lua_pop(L, 1);  // san table
                return mbedtls_lua_error(L, "generate_self_signed_cert: set SAN", ret);
            }
        }
    }
    lua_pop(L, 1);  // san table

    // Write certificate PEM
    unsigned char pem_buf[16384];
    ret = mbedtls_x509write_crt_pem(&crt, pem_buf, sizeof(pem_buf));
    mbedtls_x509write_crt_free(&crt);
    mbedtls_pk_free(&pk);
    if (ret != 0) return mbedtls_lua_error(L, "generate_self_signed_cert: write PEM", ret);

    lua_pushstring(L, (const char*)pem_buf);
    return 1;
}

// ssl.parse_certificate(pem_string) -> { subject, issuer, valid_from, valid_to, serial, version,
// info }
static int ssl_parse_certificate(lua_State* L) {
    const char* pem = luaL_checkstring(L, 1);
    size_t pem_len = lua_objlen(L, -1);

    mbedtls_x509_crt crt;
    mbedtls_x509_crt_init(&crt);

    int ret = mbedtls_x509_crt_parse(&crt, (const unsigned char*)pem, pem_len + 1);
    if (ret != 0) {
        mbedtls_x509_crt_free(&crt);
        return mbedtls_lua_error(L, "parse_certificate", ret);
    }

    lua_newtable(L);

    // Full info string
    char info[4096];
    ret = mbedtls_x509_crt_info(info, sizeof(info), "", &crt);
    if (ret > 0) {
        lua_pushlstring(L, info, ret);
        lua_setfield(L, -2, "info");
    }

    // Subject
    char name_buf[512];
    ret = mbedtls_x509_dn_gets(name_buf, sizeof(name_buf), &crt.subject);
    if (ret > 0) {
        lua_pushlstring(L, name_buf, ret);
        lua_setfield(L, -2, "subject");
    }

    // Issuer
    ret = mbedtls_x509_dn_gets(name_buf, sizeof(name_buf), &crt.issuer);
    if (ret > 0) {
        lua_pushlstring(L, name_buf, ret);
        lua_setfield(L, -2, "issuer");
    }

    // Validity
    char time_buf[32];
    snprintf(time_buf, sizeof(time_buf), "%04d-%02d-%02d %02d:%02d:%02d", crt.valid_from.year,
             crt.valid_from.mon, crt.valid_from.day, crt.valid_from.hour, crt.valid_from.min,
             crt.valid_from.sec);
    lua_pushstring(L, time_buf);
    lua_setfield(L, -2, "valid_from");

    snprintf(time_buf, sizeof(time_buf), "%04d-%02d-%02d %02d:%02d:%02d", crt.valid_to.year,
             crt.valid_to.mon, crt.valid_to.day, crt.valid_to.hour, crt.valid_to.min,
             crt.valid_to.sec);
    lua_pushstring(L, time_buf);
    lua_setfield(L, -2, "valid_to");

    // Version
    lua_pushinteger(L, crt.version);
    lua_setfield(L, -2, "version");

    // Serial (hex string)
    std::string hex;
    for (size_t i = 0; i < crt.serial.len; i++) {
        char h[4];
        snprintf(h, sizeof(h), "%02X", crt.serial.p[i]);
        if (i > 0) hex += ':';
        hex += h;
    }
    lua_pushlstring(L, hex.c_str(), hex.size());
    lua_setfield(L, -2, "serial");

    mbedtls_x509_crt_free(&crt);
    return 1;
}

// ssl.create_server_context_pem(cert_pem, key_pem [, password]) -> SSLContext
// Same as create_server_context but takes PEM strings instead of file paths.
static int ssl_create_server_context_pem(lua_State* L) {
    const char* cert_pem = luaL_checkstring(L, 1);
    size_t cert_len = lua_objlen(L, 1);
    const char* key_pem = luaL_checkstring(L, 2);
    size_t key_len = lua_objlen(L, 2);
    const char* password = luaL_optstring(L, 3, nullptr);

    LuaSSLContext* ctx = (LuaSSLContext*)lua_newuserdata(L, sizeof(LuaSSLContext));
    new (ctx) LuaSSLContext();

    mbedtls_ssl_config_init(&ctx->conf);
    mbedtls_x509_crt_init(&ctx->cacert);
    mbedtls_x509_crt_init(&ctx->own_cert);
    mbedtls_pk_init(&ctx->pk_key);
    ctx->use_system_verify = false;
    ctx->verify_mode = MBEDTLS_SSL_VERIFY_NONE;
    ctx->is_server = true;
    ctx->has_own_cert = false;

    int ret = mbedtls_ssl_config_defaults(&ctx->conf, MBEDTLS_SSL_IS_SERVER,
                                          MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_config_defaults (server)", ret);

    mbedtls_ssl_conf_authmode(&ctx->conf, MBEDTLS_SSL_VERIFY_NONE);

    // Parse certificate from PEM buffer (needs trailing NUL)
    ret = mbedtls_x509_crt_parse(&ctx->own_cert, (const unsigned char*)cert_pem, cert_len + 1);
    if (ret < 0) return mbedtls_lua_error(L, "parse server certificate PEM", ret);

    // Parse private key from PEM buffer
    size_t pwd_len = password ? strlen(password) : 0;
    ret = mbedtls_pk_parse_key(&ctx->pk_key, (const unsigned char*)key_pem, key_len + 1,
                               (const unsigned char*)password, pwd_len);
    if (ret != 0) return mbedtls_lua_error(L, "parse server private key PEM", ret);

    ret = mbedtls_ssl_conf_own_cert(&ctx->conf, &ctx->own_cert, &ctx->pk_key);
    if (ret != 0) return mbedtls_lua_error(L, "ssl_conf_own_cert", ret);
    ctx->has_own_cert = true;

    luaL_getmetatable(L, SSLCTX_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
static void register_sslctx_metatable(lua_State* L) {
    luaL_newmetatable(L, SSLCTX_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, sslctx_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, sslctx_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, sslctx_wrap_socket, "wrap_socket");
    lua_setfield(L, -2, "wrap_socket");

    lua_pushcfunction(L, sslctx_load_verify_locations, "load_verify_locations");
    lua_setfield(L, -2, "load_verify_locations");

    lua_pushcfunction(L, sslctx_set_verify, "set_verify");
    lua_setfield(L, -2, "set_verify");

    lua_pop(L, 1);
}

static void register_sslsocket_metatable(lua_State* L) {
    luaL_newmetatable(L, SSLSOCKET_METATABLE);

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, sslsock_tostring, "tostring");
    lua_setfield(L, -2, "__tostring");

    lua_pushcfunction(L, sslsock_gc, "gc");
    lua_setfield(L, -2, "__gc");

    lua_pushcfunction(L, sslsock_send, "send");
    lua_setfield(L, -2, "send");

    lua_pushcfunction(L, sslsock_sendall, "sendall");
    lua_setfield(L, -2, "sendall");

    lua_pushcfunction(L, sslsock_recv, "recv");
    lua_setfield(L, -2, "recv");

    lua_pushcfunction(L, sslsock_close, "close");
    lua_setfield(L, -2, "close");

    lua_pushcfunction(L, sslsock_getpeername, "getpeername");
    lua_setfield(L, -2, "getpeername");

    lua_pushcfunction(L, sslsock_getsockname, "getsockname");
    lua_setfield(L, -2, "getsockname");

    lua_pushcfunction(L, sslsock_fileno, "fileno");
    lua_setfield(L, -2, "fileno");

    lua_pop(L, 1);
}

LUAU_MODULE_EXPORT int luauopen__ssl(lua_State* L) {
    // Winsock must already be initialised by _socket

    // mbedTLS 4.0: initialise PSA Crypto subsystem (handles RNG internally)
    psa_status_t psa_ret = psa_crypto_init();
    if (psa_ret != PSA_SUCCESS) {
        luaL_error(L, "psa_crypto_init failed: %d", (int)psa_ret);
        return 0;
    }

    register_sslctx_metatable(L);
    register_sslsocket_metatable(L);

    lua_newtable(L);

    // Functions
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

    // Constants
    lua_pushinteger(L, MBEDTLS_SSL_VERIFY_NONE);
    lua_setfield(L, -2, "VERIFY_NONE");

    lua_pushinteger(L, MBEDTLS_SSL_VERIFY_REQUIRED);
    lua_setfield(L, -2, "VERIFY_REQUIRED");

    return 1;
}
