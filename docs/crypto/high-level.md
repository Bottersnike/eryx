# High-Level Crypto

The high-level crypto layer is intended to cover the most common application tasks with APIs that already make the important design choices for you.

Instead of asking you to pick from a menu of primitives, it tries to answer workflow-level questions directly:

- hash a password for storage
- verify a password
- encrypt a secret with authenticated encryption
- decrypt and verify a secret
- compute a digest for application data
- compute a keyed MAC for application data

## What "High-Level" Means Here

In Eryx, "high-level" does not mean "toy" or "less capable". It means the API owns more of the security-sensitive decisions:

- algorithm choice
- parameter defaults
- output format tagging
- nonce generation
- authentication-tag placement
- storage-oriented serialization

That is the part most applications benefit from. The more of that an API can do for you, the fewer opportunities there are to make a subtle mistake.

## Password Hashing

Use [[@eryx/crypto/password]] for stored passwords.

This module currently uses Argon2id under the hood and returns a tagged string format suitable for storing in a database.

```luau
local password = require("@eryx/crypto/password")

local stored = password.hash("hunter2")

if password.verify("hunter2", stored) then
	print("accepted")
end
```

Why use this instead of Argon2 directly:

- it selects Argon2id for you
- it generates a random salt automatically
- it chooses a default work factor
- it stores an algorithm tag for future migration
- it gives you a storage-ready value rather than separate pieces

If you are authenticating humans, this is the right default.

## Secretbox-Style Encryption

Use [[@eryx/crypto/secretbox]] when you want to encrypt data with a symmetric shared secret and you want authentication as well as confidentiality.

This module currently uses ChaCha20-Poly1305 underneath and serializes a self-contained ciphertext format:

- `algorithm || nonce || ciphertext || tag`

```luau
local secretbox = require("@eryx/crypto/secretbox")

local ciphertext, key = secretbox.seal(buffer.fromstring("top secret"))
local opened = secretbox.open(ciphertext, key)

assert(buffer.tostring(opened) == "top secret")
```

Why use this instead of calling the AEAD primitive directly:

- the nonce is generated automatically
- the ciphertext is tagged for future compatibility
- the nonce and tag are serialized consistently
- callers do not need to remember the wire format

This is the right API when your application simply needs to seal and later open data using a shared key.

## Hashing

The high-level crypto surface also includes digest helpers for ordinary application use via [[@eryx/crypto/hash]].

These are intended for cases like:

- content fingerprinting
- deduplication
- stable cache keys
- request-body checksums
- application-level integrity checks where no secret key is involved

```luau
local hash = require("@eryx/crypto/hash")

local digest = hash.digest(buffer.fromstring("hello"))

assert(hash.verify(buffer.fromstring("hello"), digest))
```

The specific underlying algorithm is intentionally hidden behind the API. The digest value is tagged so stored values can remain self-describing if the implementation choice changes later.

Important caveat: plain hashing does **not** authenticate who produced the data. If an attacker can modify the message, use HMAC or authenticated encryption instead.

## HMAC

The high-level crypto surface also includes keyed message authentication via [[@eryx/crypto/hmac]].

Use HMAC when:

- both sides already share a secret key
- you need authenticity and integrity but not encryption
- you are signing requests, webhook payloads, or structured records

```luau
local hmac = require("@eryx/crypto/hmac")

local mac = hmac.digest(
	buffer.fromstring("shared-secret"),
	buffer.fromstring("message")
)

assert(hmac.verify(
	buffer.fromstring("shared-secret"),
	buffer.fromstring("message"),
	mac
))
```

The concrete HMAC algorithm is intentionally hidden from callers. Like the digest API, the returned value is tagged for forward compatibility.

## When To Drop Down To Hazmat

Use the high-level layer unless you specifically need one of these:

- a particular RSA or ECC signature mode
- a specific PEM or DER wire format
- raw cipher modes such as CBC or CTR
- protocol-defined KDF parameter choices
- direct access to Argon2 variant selection
- exact nonce, IV, AAD, or tag placement control

That is when the hazmat layer becomes the right tool.
