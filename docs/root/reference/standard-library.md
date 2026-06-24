# The Standard Library

The standard library is the core selling point for Eryx. This section of the documentation contains pages discussing many of the built in libraries. Some libraries, or groups of libraries, are too complex to be aptly described in a single page, and instead have their own sections.

The remainder of this page lists out every available library. Each available library is categorised into one of the following statuses:

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
| [[@eryx/luau]]      | Complete              | Access to luau language features (analysis, compiling) |
| [[@eryx/task]]      | Complete              | Concurrency helpers                                    |
| [[@eryx/thread]]    | Complete              | Isolated child runtimes backed by OS threads           |
| [[@eryx/number]]    | Complete              | Arbitrary-precision integers, rationals, and floats    |
| [[@eryx/exception]] | Complete              | Exception formatting and helpers                       |
| [[@eryx/_ffi]]      | Win32, Partial[^_ffi] | Low-level foreign function interfaces                  |
| Marshall            | Planned               | Binary-encoded format of Luau objects                  |

[^_ffi]: Currently only supports Windows, and likely has GC-related problems. A new replacement is being developed.

## Development utilities

| Library              | Status                    | Description                                             |
| -------------------- | ------------------------- | ------------------------------------------------------- |
| [[@eryx/pprint]]     | Complete                  | Data pretty-printer                                     |
| [[@eryx/schema]]     | Complete                  | Runtime type checking, and some more complex checks too |
| [[@eryx/test]]       | Complete                  | Unit testing framework                                  |
| [[@eryx/signal]]     | Complete                  | Provides signals that can be subscribed to              |
| [[@eryx/date]]       | Complete                  | Dates and times with timezone support                   |
| [[@eryx/logging]]    | Complete                  | Structured logging utilities                            |
| [[@eryx/stream]]     | Complete                  | Types for interacting with [[Stream]]s                  |
| [[@eryx/debugger]]   | Complete                  | Breakpoint debugger with stepping and inspection        |
| [[@eryx/iter]]       | Complete                  | Lazy iterator and sequence utilities                    |
| [[@eryx/queue]]      | Complete                  | Queue, deque, and priority queue containers             |
| [[@eryx/semver]]     | Complete                  | Semantic version parsing, comparison, and ranges        |
| [[@eryx/capability]] | Complete                  | Optional-module loading and feature-gating helpers      |
| [[@eryx/caching]]    | Mostly complete[^caching] | In-memory caches (LRU/TTL) and memoization              |
| [[@eryx/project]]    | Mostly complete[^project] | Project manifest and lockfile parsing                   |
| Retry helpers        | Planned                   | Helpers for retrying failed actions                     |

[^caching]: TTL expiry is pruned by a full scan on each access (O(n) per operation), and the default clock is CPU time rather than wall-clock

[^project]: Read/parse-focused; there are no typed mutation helpers, so edits must be made through the raw CST view

## Text processing

| Library           | Status   | Description                                   |
| ----------------- | -------- | --------------------------------------------- |
| [[@eryx/regex]]   | Complete | Regular expression support (PCRE2)            |
| [[@eryx/unicode]] | Complete | Manipulation of Unicode strings               |
| [[@eryx/text]]    | Complete | Text utilities: wrapping, indenting, trimming |

## Command-line interface

| Library                            | Status                  | Description                        |
| ---------------------------------- | ----------------------- | ---------------------------------- |
| [[@eryx/stdio]]                    | Mostly complete[^stdio] | Standard input and output interact |
| [[@eryx/argparse]]                 | Partial[^argparse]      | Command-line option parser         |
| Curses? Maybe? Or just our own TUI | Planned                 | Basic terminal UI functionality    |

[^argparse]: Still lacks some advanced CLI ergonomics, but now supports variadic positionals, multi-value options, mutually exclusive groups, and generated shell completion scripts

[^stdio]: Missing higher-level terminal controls (cursor/screen management, key events), though raw mode and configurable line terminators are supported

## I/O and OS operations

| Library             | Status                   | Description                                            |
| ------------------- | ------------------------ | ------------------------------------------------------ |
| [[@eryx/os]]        | Mostly complete[^os]     | OS interactions                                        |
| [[@eryx/fs]]        | Mostly complete[^fs]     | Filesystem operations                                  |
| [[@eryx/path]]      | Mostly complete          | High level lexical filesystem path parsing and helpers |
| [[@eryx/vfs]]       | Mostly complete[^vfs]    | Virtual filesystem operations                          |
| [[@eryx/fs_watch]]  | Complete                 | High level filesystem watcher bindings                 |
| [[@eryx/_fs_watch]] | Complete                 | Low level interface consumed by `fs_watch`             |
| [[@eryx/glob]]      | Complete                 | Filesystem search using globs                          |
| [[@eryx/tempfile]]  | Complete                 | Creation and management of temporary files and folders |
| [[@eryx/serial]]    | Mostly complete[^serial] | Serial port I/O (RS-232, USB CDC)                      |
| Windows registry    | Planned                  | Access to the Windows registry                         |

[^os]: No OS signals, no users/groups, no resource limits, no forking

[^fs]: No access to permissions, potentially other missing features

[^vfs]: Library not sufficiently tested to be confidently complete

[^serial]: No flow-control configuration, POSIX is limited to the standard baud-rate table, and macOS port enumeration lacks VID/PID metadata

## Networking

| Library             | Status                      | Description                                                 |
| ------------------- | --------------------------- | ----------------------------------------------------------- |
| [[@eryx/http]]      | Mostly complete[^http]      | HTTP client and server                                      |
| [[@eryx/net]]       | Complete                    | Basic TCP client and server                                 |
| [[@eryx/websocket]] | Mostly complete[^websocket] | Websocket client and server                                 |
| [[@eryx/mime]]      | Mostly complete[^mime]      | MIME type detection                                         |
| [[@eryx/_socket]]   | Complete                    | Low level BSD-style socket interface                        |
| [[@eryx/ip]]        | Complete                    | Parsing and manipulation of IP addresses and network ranges |
| [[@eryx/uri]]       | Mostly complete[^uri]       | RFC 3986 URI/URL parsing and validation                     |
| [[@eryx/uuid]]      | Complete                    | RFC 9562 UUID generation, parsing, and formatting           |
| [[@eryx/_ssl]]      | Mostly Complete[^_ssl]      | Low level SSL interface to be used with `_socket`           |
| RPC                 | Planned                     | RCON, JSON-RPC, XML-RPC                                     |
| Email               | Planned                     |                                                             |
| FTP                 | Planned                     | Support for the FTP protocol                                |
| IMAP                | Planned                     | Support for the IMAP protocol                               |
| SMTP                | Planned                     | Support for the SMTP protocol                               |
| JWT                 | Planned                     | Creation and manipulation of JWTs                           |

[^http]: Lacks proxy support

[^websocket]: Full RFC 6455 client and server (`ws://` and `wss://`) with fragmentation, ping/pong, the close handshake, and RFC 7692 permessage-deflate. End-to-end behaviour is thinly tested, it is tightly coupled to the HTTP server internals, and 64-bit payload lengths are truncated to 32 bits

[^mime]: Extension map (~110 types) plus content sniffing with magic-byte signatures. Some heuristics are loose, there is no reverse (mime->extension) lookup, and content-sniffing test coverage is thin

[^uri]: IPv6 host validation is loose, there is no normalization/resolution or serialization back to a string, and the module currently has no test suite

[^_ssl]: No mTLS support, no ALPN, no cipher suite selection, no OCSP

## Databases

| Library           | Status   | Description                    |
| ----------------- | -------- | ------------------------------ |
| [[@eryx/sqlite3]] | Complete | Bindings for SQLite3 databases |

## Encoding

| Library                   | Status   | Description                      |
| ------------------------- | -------- | -------------------------------- |
| [[@eryx/encoding/base64]] | Complete | Base64 encoding and decoding     |
| [[@eryx/encoding/base85]] | Complete | Base85 encoding and decoding     |
| [[@eryx/encoding/base32]] | Complete | Base32 encoding and decoding     |
| [[@eryx/encoding/hex]]    | Complete | HEX encoding and decoding        |
| [[@eryx/encoding/url]]    | Complete | URL-escape encoding and decoding |

## Text-based data formats

| Library             | Status                 | Description                                          |
| ------------------- | ---------------------- | ---------------------------------------------------- |
| [[@eryx/data/csv]]  | Complete               | CSV parser and writer                                |
| [[@eryx/data/json]] | Complete               | JSON parser and writer                               |
| [[@eryx/data/xml]]  | Complete               | XML parser and writer                                |
| [[@eryx/data/yaml]] | Mostly complete[^yaml] | YAML parser and writer                               |
| [[@eryx/data/toml]] | Complete               | TOML parser and writer, with a format-preserving CST |

[^yaml]: Subset of YAML 1.2

## Compression and archives

| Library                      | Status                | Description                             |
| ---------------------------- | --------------------- | --------------------------------------- |
| [[@eryx/compression/brotli]] | Complete              | Brotli compression and decompression    |
| [[@eryx/compression/bzip2]]  | Complete              | BZip2 compression and decompression     |
| [[@eryx/compression/gzip]]   | Complete              | GZip compression and decompression      |
| [[@eryx/compression/zlib]]   | Complete              | Zlib compression and decompression      |
| [[@eryx/compression/zstd]]   | Complete              | Zstandard compression and decompression |
| [[@eryx/archive/zip]]        | Mostly complete[^zip] | Zip file manipulation                   |
| [[@eryx/archive/tar]]        | Partial[^tar]         | Tar archive reading                     |

[^zip]: In-memory only (no streaming or direct file I/O), each write rebuilds the whole archive (no incremental append/update/delete), and there is no password/encryption support

[^tar]: Read-only by design. Supports many variations of tar (ustar, GNU long names, PAX, sparse files, base-256 fields) but not archive creation, and link entries are surfaced as metadata only (no extraction)

## Cryptography

| Library                          | Status          | Description                              |
| -------------------------------- | --------------- | ---------------------------------------- |
| [[@eryx/crypto/password]]        | Complete        | High level password hashing              |
| [[@eryx/crypto/secretbox]]       | Complete        | High level authenticated encryption      |
| [[@eryx/crypto/hmac]]            | Complete        | High level HMACs                         |
| [[@eryx/crypto/hash]]            | Complete        | High level message digests               |
| [[@eryx/crypto/hazmat/aes]]      | Complete        | AES ciphers                              |
| [[@eryx/crypto/hazmat/camellia]] | Complete        | Camellia ciphers                         |
| [[@eryx/crypto/hazmat/chacha20]] | Complete        | ChaCha20 ciphers                         |
| [[@eryx/crypto/hazmat/des]]      | Complete        | 3DES ciphers                             |
| [[@eryx/crypto/hazmat/rsa]]      | Complete        | RSA ciphers                              |
| [[@eryx/crypto/hazmat/hash]]     | Complete        | Various hashing functions                |
| [[@eryx/crypto/hazmat/hmac]]     | Complete        | HMAC generation                          |
| [[@eryx/crypto/hazmat/kdf]]      | Complete        | Key derivation functions                 |
| [[@eryx/crypto/hazmat/pem]]      | Complete        | PEM/DER format support                   |
| [[@eryx/crypto/hazmat/pkcs7]]    | Complete        | PKCS#7 block padding                     |
| [[@eryx/crypto/hazmat/random]]   | Complete        | Secure random number and data generator  |
| [[@eryx/crypto/hazmat/ecc]]      | Partial         | ECC keys, ECDSA signing, ECDH derivation |
| [[@eryx/crypto/hazmat/argon2]]   | Partial         | Argon2d, Argon2i, and Argon2id hashing   |
| [[@eryx/crypto/hazmat/asn1]]     | Unusable[^asn1] | ASN1 format support                      |

[^asn1]: Very patchy hand-written code, lacking almost all important ASN1 features

## Text file formats

| Library            | Status   | Description       |
| ------------------ | -------- | ----------------- |
| [[@eryx/template]] | Complete | Templating engine |

## Multimedia and interfaces

| Library           | Status                    | Description                                                      |
| ----------------- | ------------------------- | ---------------------------------------------------------------- |
| [[@eryx/font]]    | Complete                  | Font loading, shaping (HarfBuzz), and rasterization (FreeType)   |
| [[@eryx/image]]   | Partial[^image]           | Support for various image formats                                |
| [[@eryx/gui]]     | Mostly complete[^gui]     | Native GUI toolkit (wxWidgets)                                   |
| [[@eryx/webview]] | Win32, Unusable[^webview] | Create and manipulate native WebView browsers                    |
| [[@eryx/webui]]   | Unusable[^webui]          | Wrapper for `webview` proving convenient JS<->Eryx communication |
| Audio             | Planned                   | Support for various audio formats                                |

[^webview]: Bare-bones wrapper for WebView2 on windows, but no support for other platforms

[^webui]: Missing most things that make wrapping a webview useful

[^image]: Missing most image manipulation features

[^gui]: Data binding is coarse (full-replace, with no incremental update, sorting, or in-place editing)

## First party packages

These are maintained alongside Eryx but ship as standalone packages rather than as part of the core standard library.

| Package       | Status                     | Description                     |
| ------------- | -------------------------- | ------------------------------- |
| [[@eryxdoc]]  | Complete                   | Documentation generation engine |
| [[@markdown]] | Mostly complete[^markdown] | Markdown parser                 |

[^markdown]: Inline parsing follows CommonMark and is tested against the CommonMark and GFM suites; block extensions (tables, footnotes, admonitions, tabs) are complete, but some inline extensions have rough edges (e.g. inline footnotes don't support spaced labels), and the interface for specifying custom extensions is a little round around the edges.
