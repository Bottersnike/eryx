# Cryptography in Eryx

Eryx's cryptography libraries are split into two broad layers:

1. **High-level crypto**, for the operations application code usually wants directly.
2. **Hazardous materials**, for low-level cryptographic primitives and formats.

That distinction matters because cryptography is one of the easiest places to write code that appears correct, passes tests, and still fails in production. The higher-level APIs try to make the safe path short and obvious. The hazmat APIs remain available when you genuinely need protocol-level control, interoperability with an external system, or exact algorithm selection.

## The High-Level Layer

The high-level layer is the API most applications should start with. It focuses on complete workflows rather than individual algorithms:

- password hashing for stored credentials
- symmetric authenticated encryption for secrets and sealed payloads
- keyed and unkeyed message authentication helpers
- future convenience wrappers for common signing and token workflows

In practice, if you are trying to answer questions like:

- "How do I store user passwords?"
- "How do I encrypt an API key before writing it to disk?"
- "How do I compute or verify a message digest?"
- "How do I attach an authenticity check to data?"

then you probably want the high-level layer.

Start here: [[High-Level Crypto]]

## The Hazmat Layer

The hazmat layer exposes the raw building blocks:

- Hash functions
- HMAC
- KDFs
- Raw symmetric ciphers and AEAD constructions
- RSA and ECC primitives
- PEM, ASN.1, and related wire formats
- Secure random data generation
- Argon2 in its low-level forms

These modules are powerful, but they assume you know what you are doing. They are the right choice when you are implementing or interoperating with a protocol, reproducing an existing format, or composing several primitives into a scheme of your own.

Start here: [[Hazmat Crypto]]

## A Practical Rule of Thumb

Prefer the highest-level API that solves your problem.

Use `@eryx/crypto/password` instead of calling Argon2 directly when storing passwords.

Use `@eryx/crypto/secretbox` instead of manually juggling ChaCha20-Poly1305 nonces and tags when you just want to encrypt data with a shared secret.

Reach for hazmat only when one of these is true:

- you must match an external specification exactly
- you need an algorithm or format not yet wrapped by the high-level layer
- you are implementing a reusable higher-level cryptographic abstraction
