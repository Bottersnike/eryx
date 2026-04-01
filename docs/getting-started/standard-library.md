# The Standard Library

The standard library is the core selling point for Eryx. Each available library is categorised into one of the following statuses:

| Status          | Meaning                                                                               |
| --------------- | ------------------------------------------------------------------------------------- |
| Complete        | The library is complete and fully usable                                              |
| Mostly complete | The library is mature but not complete, but what is present is usable                 |
| Partial         | The library is partially complete, but what is present is usable                      |
| Unusable        | The library is in an early stage of development, and is not expected to work properly |
| Planned         | The library does not exist yet                                                        |

## Core language features

| Library             | Status                | Description                                            |
| ------------------- | --------------------- | ------------------------------------------------------ |
| [[@eryx/luau]]      | Partial[^luau]        | Access to luau language features (analysis, compiling) |
| [[@eryx/task]]      | Complete              | Concurrency helpers                                    |
| [[@eryx/exception]] | Complete              | Exception formatting and helpers                       |
| [[@eryx/_ffi]]      | Win32, Partial[^_ffi] | Low-level foreign function interfaces                  |
| Marshall            | Planned               | Binary-encoded format of Luau objects                  |

[^luau]: Not all AST nodes are fully exposed properly. Some bindings missing

[^_ffi]: Currently only supports Windows, and likely has GC-related problems

## Development utilities

| Library           | Status   | Description                                |
| ----------------- | -------- | ------------------------------------------ |
| [[@eryx/pprint]]  | Complete | Data pretty-printer                        |
| [[@eryx/test]]    | Complete | Unit testing framework                     |
| [[@eryx/eryxdoc]] | Complete | Documentation generation engine            |
| [[@eryx/signal]]  | Complete | Provides signals that can be subscribed to |
| [[@eryx/date]]    | Complete | Dates and times with timezone support      |
| Logging           | Planned  | Structured logging utilities               |
| Retry helpers     | Planned  | Helpers for retrying failed actions        |
| Caching (LRU)?    | Planned  | Function result caching                    |

## Text processing

| Library         | Status   | Description                        |
| --------------- | -------- | ---------------------------------- |
| [[@eryx/regex]] | Complete | Regular expression support (PCRE2) |
| Text utils      | Planned  | Wrapping, un-indenting, diffing    |

## Command-line interface

| Library                            | Status                  | Description                        |
| ---------------------------------- | ----------------------- | ---------------------------------- |
| [[@eryx/stdio]]                    | Mostly complete[^stdio] | Standard input and output interact |
| [[@eryx/argparse]]                 | Partial[^argparse]      | Command-line option parser         |
| Curses? Maybe? Or just our own TUI | Planned                 | Basic terminal UI functionality    |

[^argparse]: Still lacks some advanced CLI ergonomics, but now supports variadic positionals, multi-value options, mutually exclusive groups, and generated shell completion scripts

[^stdio]: Missing raw mode, line terminators, streaming

## I/O and OS operations

| Library             | Status                | Description                                            |
| ------------------- | --------------------- | ------------------------------------------------------ |
| [[@eryx/os]]        | Mostly complete[^os]  | OS interactions                                        |
| [[@eryx/fs]]        | Mostly complete[^fs]  | Filesystem operations                                  |
| [[@eryx/vfs]]       | Mostly complete[^vfs] | Virtual filesystem operations                          |
| [[@eryx/fs_watch]]  | Complete              | High level filesystem water bindings                   |
| [[@eryx/_fs_watch]] | Complete              | Low level interface consumed by `fs_watch`             |
| Glob                | Planned               | Filesystem search using globs                          |
| Temp files          | Planned               | Creation and management of temporary files and folders |
| Windows registry    | Planned               | Access to the Windows registry                         |

[^os]: No OS signals, no users/groups, no resource limits, no forking

[^fs]: No access to permissions, potentially other missing features

[^vfs]: Module not sufficiently tested to be confidently complete

## Networking

| Library             | Status                 | Description                                       |
| ------------------- | ---------------------- | ------------------------------------------------- |
| [[@eryx/http]]      | Mostly complete[^http] | HTTP client and server                            |
| [[@eryx/net]]       | Partial[^net]          | Basic TCP client and server                       |
| [[@eryx/websocket]] | Partial[^websocket]    | Websocket client and server                       |
| [[@eryx/mime]]      | Unusable[^mime]        | MIME format detection                             |
| [[@eryx/_socket]]   | Complete               | Low level BSD-style socket interface              |
| [[@eryx/_ssl]]      | Mostly Complete[^_ssl] | Low level SSL interface to be used with `_socket` |
| UUID                | Planned                | Creation and manipulation of UUIDs                |
| RPC                 | Planned                | RCON, JSON-RPC, XML-RPC                           |
| Email               | Planned                |                                                   |
| FTP                 | Planned                | Support for the FTP protocol                      |
| IMAP                | Planned                | Support for the IMAP protocol                     |
| SMTP                | Planned                | Support for the SMTP protocol                     |
| JWT                 | Planned                | Creation and manipulation of JWTs                 |

[^http]: Lacks proxy support

[^net]: No UDP, no IPv6, no socket options, no concurrent server patterns

[^websocket]: Immature implementation lacking many features. Not sufficient tested

[^mime]: No sufficient tested. Supports only a limited number of features. Some heuristics likely broken

[^_ssl]: No mTLS support, no ALPN, no cipher suite selection, no OCSP

## Databases

| Library           | Status   | Description                    |
| ----------------- | -------- | ------------------------------ |
| [[@eryx/sqlite3]] | Complete | Bindings for SQLite3 databases |

## Encoding

| Library                   | Status                 | Description                      |
| ------------------------- | ---------------------- | -------------------------------- |
| [[@eryx/encoding/base64]] | Complete               | Base64 encoding and decoding     |
| [[@eryx/encoding/base85]] | Complete               | Base85 encoding and decoding     |
| [[@eryx/encoding/base32]] | Complete               | Base32 encoding and decoding     |
| [[@eryx/encoding/hex]]    | Complete               | HEX encoding and decoding        |
| [[@eryx/encoding/url]]    | Complete               | URL-escape encoding and decoding |
| [[@eryx/encoding/csv]]    | Complete               | CSV parser and writer            |
| [[@eryx/encoding/json]]   | Complete               | JSON parser and writer           |
| [[@eryx/encoding/xml]]    | Complete               | XML parser and writer            |
| [[@eryx/encoding/yaml]]   | Mostly complete[^yaml] | YAML parser and writer           |
| TOML                      | Planned                | TOML parser and writer           |

[^yaml]: Subset of YAML 1.2

## Compression

| Library                      | Status                | Description                          |
| ---------------------------- | --------------------- | ------------------------------------ |
| [[@eryx/compression/brotli]] | Complete              | Brotli compression and decompression |
| [[@eryx/compression/bzip2]]  | Complete              | BZip2 compression and decompression  |
| [[@eryx/compression/gzip]]   | Complete              | GZip compression and decompression   |
| [[@eryx/compression/zlib]]   | Complete              | Zlib compression and decompression   |
| [[@eryx/compression/zstd]]   | Complete              | Brotli compression and decompression |
| [[@eryx/compression/zip]]    | Mostly complete[^zip] | Zip file manipulation                |

[^zip]: Limited interface for manipulating ZIP files

## Cryptography

| Library                   | Status          | Description                             |
| ------------------------- | --------------- | --------------------------------------- |
| [[@eryx/crypto/aes]]      | Complete        | AES ciphers                             |
| [[@eryx/crypto/camellia]] | Complete        | Camellia ciphers                        |
| [[@eryx/crypto/chacha20]] | Complete        | ChaCha20 ciphers                        |
| [[@eryx/crypto/des]]      | Complete        | 3DES ciphers                            |
| [[@eryx/crypto/rsa]]      | Complete        | RSA ciphers                             |
| [[@eryx/crypto/hash]]     | Complete        | Various hashing functions               |
| [[@eryx/crypto/hmac]]     | Complete        | HMAC generation                         |
| [[@eryx/crypto/kdf]]      | Complete        | Key derivation functions                |
| [[@eryx/crypto/pem]]      | Complete        | PEM/DER format support                  |
| [[@eryx/crypto/random]]   | Complete        | Secure random number and data generator |
| [[@eryx/crypto/asn1]]     | Unusable[^asn1] | ASN1 format support                     |
| ECC                       | Planned         | ECC ciphers (ECDSA/ECDH/EdDSA)          |
| Argon2                    | Planned         |                                         |

[^asn1]: Very patchy hand-written code, lacking almost all important ASN1 features

## Text file formats

| Library            | Status                     | Description       |
| ------------------ | -------------------------- | ----------------- |
| [[@eryx/markdown]] | Mostly complete[^markdown] | Markdown parser   |
| [[@eryx/template]] | Complete                   | Templating engine |

[^markdown]: Extensions not fully featured yet, and some inline parsing bugs present

## Multimedia and interfaces

| Library           | Status                    | Description                                                      |
| ----------------- | ------------------------- | ---------------------------------------------------------------- |
| [[@eryx/webview]] | Win32, Unusable[^webview] | Create and manipulate native WebView browsers                    |
| [[@eryx/webui]]   | Unusable[^webui]          | Wrapper for `webview` proving convenient JS<->Eryx communication |
| [[@eryx/image]]   | Partial[^image]           | Support for various image formats                                |
| Audio             | Planned                   | Support for various audio formats                                |

[^webview]: Bare-bones wrapper for WebView2 on windows, but no support for other platforms

[^webui]: Missing most things that make wrapping a webview useful

[^image]: Missing must image manipulation features
