# Hazmat Crypto

The hazmat crypto modules expose low-level primitives. They are useful and often necessary, but they do less hand-holding and expect more protocol knowledge from the caller.

In other words: this layer gives you power, not safety rails.

## When Hazmat Is Appropriate

Reach for hazmat when you are:

- implementing a cryptographic protocol
- matching an external wire format
- interoperating with another language or library
- building a new high-level crypto wrapper
- doing key import/export or signature verification work

Avoid it when the job is really just:

- "store a password"
- "encrypt a blob with a shared key"
- "compute a normal application digest"

Those should usually use the high-level APIs instead.

## Hashes and MACs

These are the simplest hazmat modules and often the most useful:

- [[@eryx/crypto/hazmat/hash]]
- [[@eryx/crypto/hazmat/hmac]]

Use `hash` for unkeyed digests.

Use `hmac` for keyed authenticity checks.

These modules expose raw digest bytes and make no decisions about encoding, comparison strategy, truncation, or message framing. That is your job at this layer.

## Randomness

Use [[@eryx/crypto/hazmat/random]] when you need cryptographically secure randomness:

- keys
- salts
- nonces
- tokens

This is the foundation that higher-level crypto wrappers use internally.

## Password KDFs

Eryx currently exposes:

- [[@eryx/crypto/hazmat/argon2]]
- [[@eryx/crypto/hazmat/kdf]]

`argon2` is the lower-level password-hashing and memory-hard KDF surface. It gives you direct control over:

- variant choice
- salt
- time cost
- memory cost
- parallelism
- raw versus encoded output

Use it when you need exact Argon2 control or interoperability with an existing Argon2 storage format.

`kdf` exposes HKDF and PBKDF2. HKDF is usually the right choice for deriving subkeys from already-strong key material. PBKDF2 exists mainly for compatibility with systems that already use it.

## Symmetric Ciphers

The hazmat symmetric modules include:

- [[@eryx/crypto/hazmat/aes]]
- [[@eryx/crypto/hazmat/camellia]]
- [[@eryx/crypto/hazmat/chacha20]]
- [[@eryx/crypto/hazmat/des]]

These expose raw cipher and AEAD operations. That means you are responsible for details like:

- IV and nonce generation
- nonce uniqueness
- authenticated-data handling
- output framing
- algorithm negotiation

For example, ChaCha20-Poly1305 is a strong primitive, but if every caller invents a different `nonce || ciphertext || tag` layout, interoperability becomes fragile. That is exactly the kind of problem a higher-level wrapper such as `secretbox` exists to solve.

## Asymmetric Crypto

The hazmat asymmetric modules include:

- [[@eryx/crypto/hazmat/rsa]]
- [[@eryx/crypto/hazmat/ecc]]

Use them for:

- public-key encryption
- signatures
- ECDSA verification
- ECDH shared-secret derivation
- key generation and conversion

This is the right layer for implementing protocols and key-management flows, but it also means you must understand scheme choice. For example, RSA-PSS and RSA-OAEP are generally the modern options, while legacy modes may still exist for compatibility.

## Formats and Interop

The low-level format modules are:

- [[@eryx/crypto/hazmat/pem]]
- [[@eryx/crypto/hazmat/asn1]]

PEM and DER handling matter whenever you exchange keys or certificates with other tooling.

ASN.1 is particularly sharp-edged. It is powerful, widely used, and easy to get wrong. In Eryx it should be treated as an expert-oriented interop layer rather than something most applications should build on directly.

## A Good Pattern

A good engineering pattern is:

1. implement the tricky protocol-specific work in terms of hazmat primitives
2. wrap that in a small higher-level module with stable defaults
3. make application code call the wrapper rather than the primitives

That keeps the sharp edges concentrated in one place and gives the rest of the codebase a safer API.

