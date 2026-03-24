# The Standard Library

## Core language features

- [[luau]]: Access to luau language features (analysis, compiling)
- [[task]]: Concurrency helpers
- [[exception]]: Exception formatting and helpers
- [[_ffi]]: Low-level foreign function interfaces
- _PLANNED_ Marshall

## Development utilities

- [[pprint]]: Data pretty-printer
- [[test]]: Unit testing framework
- [[eryxdoc]]: Documentation generation engine
- [[signal]]: Provides signals that can be subscribed to
- [[date]]: Dates and times with timezone support
- _PLANNED_ Logging
- _PLANNED_ Retry helpers
- _PLANNED_ Caching (LRU)?

## Text processing

- [[regex]]: Regular expression support (PCRE2)
- _PLANNED_ Wrapping
- _PLANNED_ Un-indenting
- _PLANNED_ Diffing

## Command-line interface

- [[stdio]]: Standard input and output interact
- [[argparse]]: Command-line option parser
- _PLANNED_ Curses? Maybe? Or just our own TUI

## I/O and OS operations

- [[os]]: OS interactions
- [[fs]]: Filesystem operations
- [[vfs]]: Virtual filesystem operations
- [[fs_watch]]: High level filesystem water bindings
- [[_fs_watch]]: Low level interface consumed by `fs_watch`
- _PLANNED_ Glob
- _PLANNED_ Temp files
- _PLANNED_ Windows registry

## Networking

- [[http]]: HTTP client and server
- [[net]]: Basic TCP client and server
- [[websocket]]: Websocket client and server
- [[mime]]: MIME format detection **INCOMPLETE**
- [[_socket]]: Low level BSD-style socket interface
- [[_ssl]]: Low level SSL interface to be used with `_socket`
- _PLANNED_ UUID
- _PLANNED_ RPC (RCON, JSON-RPC, XML-RPC)
- _PLANNED_ Email
- _PLANNED_ FTP
- _PLANNED_ IMAP
- _PLANNED_ SMTP

## Databases

- [[sqlite3]]: Bindings for SQLite3 databases

## Encoding

- [[encoding/base64]]: Base64 encoding and decoding
- [[encoding/base85]]: Base85 encoding and decoding
- [[encoding/base32]]: Base32 encoding and decoding
- [[encoding/hex]]: HEX encoding and decoding
- [[encoding/url]]: URL-escape encoding and decoding
- [[encoding/csv]]: CSV parser and writer
- [[encoding/json]]: JSON parser and writer
- [[encoding/xml]]: XML parser and writer
- [[encoding/yaml]]: YAML parser and writer
- _PLANNED_ TOML

## Compression

- [[compression/brotli]]: Brotli compression and decompression
- [[compression/bzip2]]: BZip2 compression and decompression
- [[compression/gzip]]: GZip compression and decompression
- [[compression/zlib]]: Zlib compression and decompression
- [[compression/zstd]]: Brotli compression and decompression
- [[compression/zip]]: Zip file manipulation

## Cryptography

- [[crypto/aes]]: AES ciphers
- [[crypto/camellia]]: Camellia ciphers
- [[crypto/chacha20]]: ChaCha20 ciphers
- [[crypto/des]]: 3DES ciphers
- [[crypto/rsa]]: RSA ciphers
- [[crypto/hash]]: Various hashing functions
- [[crypto/hmac]]: HMAC generation
- [[crypto/kdf]]: Key derivation functions
- [[crypto/pem]]: PEM/DER format support
- [[crypto/random]]: Secure random number and data generator
- [[crypto/asn1]]: ASN1 format support **INCOMPLETE**

## Text file formats

- [[markdown]]: Markdown parser
- [[markdown/html]]: Markdown HTML renderer
- [[template]]: Templating engine

## Multimedia and interfaces

- [[webview]]: Create and manipulate native WebView browsers
- [[webui]]: Wrapper for `webview` proving convenient JS<->Eryx communication
- [[image]]: Support for various image formats
- _PLANNED_ Audio
