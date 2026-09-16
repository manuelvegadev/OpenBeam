# ClipSync Protocol v1

A small LAN protocol for synchronizing clipboards (text and files) between two paired devices. Designed for trivial implementation on macOS (CryptoKit + Network.framework) and Linux (libsodium + Avahi). Inspired by KDE Connect but **not wire-compatible** with it.

> **Source-of-truth rule.** This document is the canonical specification. Both the macOS implementation in OpenBeam and the Linux companion app implement *against this file*. Whenever a decision affects what goes on the wire — packet shapes, crypto primitives, key derivation strings, limits, port numbers — update this file first, then update the implementations to match.

## Goals

- Two-party pairing with explicit user consent on the receiver.
- End-to-end authenticated encryption with forward secrecy.
- Cross-platform: macOS, Linux (and Windows later).
- No TLS, no X.509, no OpenSSL dependency required.
- Implementable from libsodium primitives in <500 lines of code per platform.

## Conventions

- **Endianness**: all multi-byte integers on the wire are **big-endian**.
- **Encoding**: control frames are UTF-8 JSON. Binary data inside JSON is **standard base64** (RFC 4648, no URL variant, no line wrapping). All cryptographic byte strings are sized exactly: keys 32 B, signatures 64 B, MAC tags 16 B, nonces 12 B.
- **Hashes**: SHA-256 throughout. Fingerprints are formatted as colon-separated uppercase hex of the first 16 bytes of `SHA-256(public key raw bytes)`: `AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89`.
- **Time**: `unix-ms` = milliseconds since the Unix epoch as a JSON number. `unix-s` = seconds.
- **JSON keys**: must be present unless marked optional. Unknown keys are ignored (forward-compatible).

## Cryptographic Primitives

| Use | Primitive | libsodium / CryptoKit / RustCrypto |
|---|---|---|
| Long-term identity signing | Ed25519 | `crypto_sign_*` / `Curve25519.Signing` / `ed25519-dalek` |
| Long-term static key exchange | X25519 | `crypto_kx_*` / `Curve25519.KeyAgreement` / `x25519-dalek` |
| Ephemeral session key exchange | X25519 | same |
| Authenticated encryption (per message) | ChaCha20-Poly1305 (IETF, 12-byte nonce) | `crypto_aead_chacha20poly1305_ietf_*` / `ChaChaPoly` / `chacha20poly1305` |
| Key derivation | HKDF-SHA256 | `crypto_kdf_hkdf_sha256_*` (libsodium ≥ 1.0.18) / `HKDF<SHA256>` / `hkdf` |
| Hashing | SHA-256 | `crypto_hash_sha256` / `SHA256` / `sha2` |

## Identity

Each device generates exactly once at first launch (and persists in the OS secret store — Keychain on macOS, libsecret on Linux):

- A stable random **`peerID`** (UUID string, 36 chars, lowercase, e.g. `7c5c8b62-4e0f-4f27-9d4d-5f81e9d3b1aa`).
- An **Ed25519 keypair** `(sigPriv, sigPub)` — used to sign handshake transcripts to bind ephemeral session keys to the long-term identity.
- An **X25519 keypair** `(kxPriv, kxPub)` — used as the long-term static contribution to the session key derivation.

`sigPub` and `kxPub` are 32-byte raw representations. Implementations exchange them at pair time and pin them per peer.

`displayName` is a UTF-8 string up to 64 chars (recommend the system hostname truncated). `os` is one of `"macos" | "linux" | "windows"`. Both are mutable across launches; trust is bound to keys, not to names.

## Discovery

- mDNS service type: **`_clipsync._tcp`**.
- Both sides **advertise and browse** simultaneously.
- TXT records (all values UTF-8 strings):
  - `id` — the device's `peerID`.
  - `name` — the device's `displayName`.
  - `os` — the device's `os` value.
  - `v` — the protocol version, currently `"1"`.
- The advertised port is the TCP port the device is listening on for incoming ClipSync connections (any free port; recommended range 50000–65535 to avoid colliding with well-known services).
- Implementations MUST filter out their own advertisement (match by `id`).
- When the same `peerID` appears on multiple network interfaces, use the lowest-cost endpoint and dedupe.

## Transport

- **TCP** on the port from mDNS.
- Each direction is an independent message stream. Both sides may send at any time after the handshake completes.
- **Frame format**: `UInt32 BE length || JSON bytes`. `length` does not include itself. Maximum frame: **1 MiB** (control + envelopes; payload bytes are inside `share.chunk` envelopes which are themselves capped at 320 KB after base64 encoding).
- A connection serves one peer at a time. To talk to N peers, open N connections.
- Idle timeout: 5 min. Either side MAY send a `ping` to keep alive.

## Handshake

After TCP connect, each side sends **one cleartext `hello` frame**, but not at the same time: the **initiator sends first**, and the **responder answers only after it has verified the initiator's hello**. The responder's signature binds the initiator's `sigPub` (see below), which it does not know until that frame arrives — a responder that sends its hello eagerly can only sign against 32 zero bytes, which is not what the initiator verifies against, and the handshake dies there.

### `hello` frame (cleartext)

```json
{
  "v": 1,
  "type": "hello",
  "peerID": "7c5c8b62-4e0f-4f27-9d4d-5f81e9d3b1aa",
  "displayName": "Manuela's MacBook",
  "os": "macos",
  "sigPub": "<base64 32 B>",
  "kxPub": "<base64 32 B>",
  "ephPub": "<base64 32 B>",
  "sig": "<base64 64 B>"
}
```

`ephPub` is a freshly generated **ephemeral** X25519 public key for this connection only.

`sig` is computed as:

```
domain = b"clipsync-v1\x00hello\x00"             // 18 bytes, with two embedded NUL bytes
peer_sig_pub_expected = per the role rule below: 32 zero bytes from the initiator,
                        the initiator's sigPub from the responder
msg = domain || ephPub || peer_sig_pub_expected   // total length = 18 + 32 + 32 = 82 bytes
sig = Ed25519.sign(sigPriv, msg)                  // 64-byte detached signature
```

**Important:** `ephPub` and `peer_sig_pub_expected` here are the **raw 32-byte** representations of the public keys, *not* their base64-encoded JSON wire form. The signed message is exactly 82 raw bytes. Then the resulting 64-byte `sig` is base64-encoded only when placed into the JSON `sig` field. Do not sign the base64 strings — sign the raw bytes.

The initiator uses 32 zero bytes for `peer_sig_pub_expected` on every `hello` (the initiator may not know who they're connecting to — Bonjour names can change). The responder, having received the initiator's `hello` first, uses the initiator's actual `sigPub` for its own `hello`'s signature. This is what orders the exchange: the responder cannot sign until the initiator has spoken.

### Verification

Each side verifies the peer's `hello`:

- Recompute the signed message using the peer's claimed `sigPub` and the `peer_sig_pub_expected` the peer would have used: the **initiator** expects its own `sigPub` there (the responder signed against it), the **responder** expects 32 zero bytes.
- Verify `sig` with the peer's claimed `sigPub`. **Mismatch ⇒ close the connection.**
- If the peer is in the local paired list, additionally check that the claimed `sigPub` matches the pinned value. Mismatch ⇒ close.
- If the peer is **not** in the local paired list, the connection is now in `unpaired` state. Only the pairing frames — `pair_request`, `pair_accept` and `pair_reject` — are permitted from this peer; everything else, `encrypted` included, is **dropped without closing the connection**. (A peer that still has you pinned while you have forgotten it opens with a clipboard snapshot; closing on that would kill the connection its user is pairing on.)

### Session key derivation

Both sides derive the same 32-byte session key:

```
shared_eph    = X25519(my_ephPriv, peer_ephPub)
shared_static = X25519(my_kxPriv,  peer_kxPub)
ikm           = shared_eph || shared_static                       // 64 bytes
salt          = sortedConcat(my_ephPub, peer_ephPub)              // canonical: lex-min || lex-max, 64 B
session_key   = HKDF-SHA256(ikm = ikm, salt = salt,
                            info = b"clipsync-v1-session", length = 32)
```

`sortedConcat(a, b)` returns `a || b` if `a < b` lexicographically (byte-by-byte compare), else `b || a`. This makes both sides compute the same salt regardless of who started the connection.

## Encrypted Frames

After the handshake, all further frames use the same length-prefix wrapper but the JSON body is always:

```json
{
  "v": 1,
  "type": "encrypted",
  "n": 0,
  "ct": "<base64 (ciphertext || 16-byte Poly1305 tag)>"
}
```

- `n` is a per-direction strictly increasing nonce counter, starting at 0 for each direction. Receivers MUST reject any `n` not strictly greater than the previous accepted `n` for that direction.
- The 12-byte ChaCha20-Poly1305 nonce is constructed as:

  ```
  direction_byte = 0x00 if I am the connection initiator (sender), else 0x01
  nonce = direction_byte (1 B) || n (UInt64 BE, 8 B) || 0x00 0x00 0x00 (3 B padding)
  ```

  Because the two directions use different `direction_byte`s, the nonces never collide even if both sides start at `n = 0`.

- The plaintext is **another JSON object**, one of the payload types defined below.
- The AAD (additional authenticated data) for ChaCha20-Poly1305 is **empty**. (Identity is already bound by the handshake's signed `ephPub`.)

## Payload Types (encrypted plaintext)

Every payload object has a `kind` discriminator. Receivers MUST ignore unknown `kind`s without closing the connection (forward compatibility).

### `clipboard.text` — text clipboard update

```json
{
  "kind": "clipboard.text",
  "body": "the clipboard string",
  "sentAt": 1715515200123,
  "originID": "<sender peerID>",
  "contentHash": "<hex SHA-256 of body UTF-8 bytes>"
}
```

- `body` is UTF-8. Maximum 256 KB after UTF-8 encoding. Senders MUST NOT exceed this; receivers MAY reject.
- `originID` always equals the sender's `peerID`. Receivers MUST drop the payload if `originID` equals their own `peerID` (loop guard for star topologies — not strictly needed for two-party, but required for forward compatibility).
- `contentHash` allows receivers to dedupe: if equal to the receiver's last-applied or last-broadcast hash, drop without reapplying.

### `clipboard.text.snapshot` — initial sync on connect

Same shape as `clipboard.text`. Sent once, by each side, immediately after the handshake completes, if the local clipboard contains text. The receiver applies it the same way as `clipboard.text` *unless* its own current clipboard is newer (compare local `changeCount`/equivalent to `sentAt` heuristically — receivers MAY simply always apply; the protocol does not mandate one policy).

### `share.begin` — multi-file transfer announcement

```json
{
  "kind": "share.begin",
  "transferID": "<UUID v4>",
  "files": [
    { "name": "report.pdf", "size": 482919, "sha256": "<hex>" },
    { "name": "logo.png",   "size": 12450,  "sha256": "<hex>" }
  ],
  "totalBytes": 495369,
  "sentAt": 1715515200123,
  "originID": "<sender peerID>"
}
```

- `name` is the basename only (no path components). `..` and absolute paths MUST be rejected by the receiver.
- Limits: max **10 files**, max **100 MB total**. Senders MUST NOT exceed; receivers MUST reject by sending `share.cancel` with `reason: "limit_exceeded"`.
- `sha256` is the hex SHA-256 of the file's bytes (sender precomputes; receiver verifies on `share.end`).
- `paste` is **optional**. Absent (or any value the receiver does not know) means the transfer is files, to be committed as the platform's equivalent of file references on the clipboard. `"image"` means the transfer is a **single picture the user copied**, to be committed as image data so it pastes as a picture rather than as a file:

  ```json
  { "kind": "share.begin", "transferID": "…", "paste": "image",
    "files": [ { "name": "clipboard.png", "size": 661362, "sha256": "<hex>" } ],
    "totalBytes": 661362, "sentAt": 1715515200123, "originID": "<sender peerID>" }
  ```

  The bytes MUST be **PNG**. A pasteboard usually offers the same picture as an uncompressed bitmap too — on macOS a Retina screenshot is ~660 KB as PNG and ~15 MB as TIFF — so the sender converts to PNG and the receiver rebuilds any other representation locally. `paste: "image"` carries exactly one file. Because unknown keys are ignored, a peer that predates this receives a PNG file on its clipboard instead: a worse paste, not a broken one.

### `share.chunk` — payload chunk

```json
{
  "kind": "share.chunk",
  "transferID": "<same as share.begin>",
  "fileIndex": 0,
  "chunkIndex": 0,
  "totalChunks": 4,
  "data": "<base64 (≤ 256 KiB plaintext bytes)>"
}
```

- Files are sent **sequentially** (file 0, all chunks; then file 1, all chunks; …). Within a file, chunks are sent **in order**.
- Maximum plaintext chunk size: **262 144 bytes** (256 KiB). The base64 expansion plus JSON wrapper plus encryption is bounded by the 1 MiB frame cap.

### `share.end` — commit

```json
{
  "kind": "share.end",
  "transferID": "<...>"
}
```

The receiver verifies each file's SHA-256, then commits (writes URLs to local clipboard / drops files into a configured target directory — implementation-defined). On any verification failure, send `share.cancel` with `reason: "hash_mismatch"` and discard the partial transfer.

### `share.cancel` — abort

```json
{
  "kind": "share.cancel",
  "transferID": "<...>",
  "reason": "user" | "limit_exceeded" | "hash_mismatch" | "io_error" | "timeout" | "other"
}
```

Either side may send. The transfer's partial state is discarded by the receiver.

### `ping` / `pong` — keepalive

```json
{ "kind": "ping", "nonce": "<random 16-char hex>" }
{ "kind": "pong", "nonce": "<echoed>" }
```

Optional. Either side may send. Idle connections SHOULD be pinged once before the 5-min idle timeout fires.

## Pairing

When the initiator's `hello` is verified by the responder and the responder finds **no matching paired peer**, the connection is in `unpaired` state. The initiator may now send:

### `pair_request` (cleartext, only valid in `unpaired` state)

```json
{
  "v": 1,
  "type": "pair_request",
  "peerID": "<initiator peerID>",
  "displayName": "<initiator displayName>",
  "os": "macos",
  "sigPub": "<base64 32 B>",
  "kxPub": "<base64 32 B>"
}
```

(These fields are redundant with the initiator's `hello`. They're repeated to keep this packet self-contained for clarity in future logging / debugging.)

### Verification code derivation

Both sides derive an identical **6-digit decimal code** from the in-flight ECDH:

```
verify = HKDF-SHA256(ikm = shared_eph || shared_static,
                     salt = sortedConcat(my_ephPub, peer_ephPub),
                     info = b"clipsync-v1-pair-verify",
                     length = 4)
code = (BE_UINT32(verify) % 1_000_000)   // formatted with leading zeros: "043812"
```

The responder **also** computes the SHA-256 fingerprint of the initiator's `sigPub` (16-byte truncation, colon-hex format) for display.

### Receiver UX

The responder shows a modal dialog (NSAlert on macOS, GTK/Qt dialog on Linux) on the **main UI thread**. Suggested layout:

```
Pair with "Manuela's MacBook"?

Verification code: 043812
Confirm this code matches what's shown on the other device.

Fingerprint: AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89

[Reject] [Accept]
```

A **30 s timeout** triggers auto-reject. The dialog MUST appear even if the app's window is hidden / it's a tray-only app (activate the app for the duration).

### `pair_accept` (cleartext, sent by responder on Accept)

```json
{
  "v": 1,
  "type": "pair_accept",
  "peerID": "<responder peerID>",
  "displayName": "<responder displayName>",
  "os": "linux",
  "sigPub": "<base64 32 B>",
  "kxPub": "<base64 32 B>"
}
```

After sending, the responder:
1. Persists the initiator as a `PairedPeer` (peerID + displayName + os + sigPub + kxPub + pairedAt).
2. **Closes** the pairing connection. Subsequent communication uses a fresh connection (which will then verify successfully against the now-pinned identity).

The initiator, on receiving `pair_accept`:
1. Verifies the responder's `peerID`/`sigPub`/`kxPub` matches what the responder sent in its `hello`. Mismatch ⇒ abort, do not persist.
2. Persists the responder as a `PairedPeer`.
3. Closes the pairing connection. Re-opens a normal connection on demand.

### `pair_reject` (cleartext, sent by responder on Reject or Timeout)

```json
{
  "v": 1,
  "type": "pair_reject",
  "reason": "user" | "timeout" | "mismatch" | "other"
}
```

After sending, the responder closes the connection. The initiator MUST NOT persist anything.

### Re-pairing

A device may lose its paired-peer list (reinstall, or the user chose Forget) while the other side still has it pinned. The forgetful side pairs again as the initiator; the side that still remembers receives a `pair_request` in `paired` state, where the spec would otherwise not allow one.

A receiver **MAY** accept such a `pair_request` **without asking the user again**, and this is what implementations should do, provided **all** of:

- the request's `peerID`, `sigPub` and `kxPub` match the pinned peer exactly, and
- the connection's `hello` already verified against that pinned `sigPub`.

Those two together mean the request can only come from the holder of the pinned private key — the device the user already confirmed once — so no new trust is being granted and the consent in Goal 1 is not being bypassed, only not re-asked. The receiver then answers `pair_accept` and closes, as with any other accept. A receiver that would rather ask again MAY show the dialog instead; both behaviors interoperate.

### Simultaneous-pair tie-breaker

If both sides attempt to initiate pairing with each other concurrently, the side with the **lexicographically smaller `peerID`** cancels its outbound attempt and waits for the other side's `pair_request` to arrive on the inbound connection. This guarantees only one pairing dialog appears per user.

## Loop Prevention (Convention, not Enforcement)

When a receiver applies an inbound clipboard payload to its local clipboard, it should record `(contentHash, post-write-changeCount-or-equivalent)` and skip rebroadcasting on the next pasteboard-poll tick if both fields match. Senders should also remember the last hash they broadcast and skip identical follow-ups. The wire protocol does not mandate this — it's the only sane behavior, but is left to implementations.

## Limits Summary

| Limit | Value |
|---|---|
| TCP frame max size | 1 MiB |
| `clipboard.text.body` max size | 256 KB UTF-8 |
| `share` files per transfer | 10 |
| `share` total bytes per transfer | 100 MB |
| `share.chunk.data` max plaintext | 256 KiB |
| Idle timeout | 5 min |
| Pair-dialog timeout | 30 s |
| `displayName` max length | 64 chars |

## Versioning and Forward Compatibility

- All control frames carry `"v": 1`. Implementations MUST reject frames with a `v` they don't support, but SHOULD NOT close the connection on a single bad frame — log and ignore.
- Unknown JSON keys are ignored.
- Unknown encrypted-payload `kind` values are ignored.
- New `kind`s may be added freely in v1; new top-level frame `type`s require a version bump.
- A v2 implementation negotiates by including a `vMax` integer in `hello` (optional in v1; defaults to 1 if absent). Both sides use `min(my_vMax, peer_vMax)`.

## Implementation Hints

| Platform | Crypto | Networking | mDNS |
|---|---|---|---|
| macOS (Swift) | CryptoKit (`Curve25519.Signing`, `Curve25519.KeyAgreement`, `ChaChaPoly`, `HKDF<SHA256>`, `SHA256`) | Network.framework (`NWListener`, `NWConnection`) | Network.framework (`NWBrowser`, `NWListener` advertised service) |
| Linux (C / C++) | libsodium (`crypto_sign_*`, `crypto_kx_keypair`, `crypto_scalarmult`, `crypto_aead_chacha20poly1305_ietf_*`, `crypto_kdf_hkdf_sha256_*`) | POSIX sockets or asio | Avahi (`avahi-client`) |
| Linux (Rust) | RustCrypto (`ed25519-dalek`, `x25519-dalek`, `chacha20poly1305`, `hkdf`, `sha2`) | `tokio` | `mdns-sd` or `zeroconf` crate |
| Linux (Python) | `pynacl` (`nacl.signing`, `nacl.public`, `nacl.bindings.crypto_aead_chacha20poly1305_ietf_*`); `cryptography` for HKDF | `asyncio` | `python-zeroconf` |

## Test Vectors

The reference Mac implementation generates test vectors on first run and writes them to `~/Library/Caches/OpenBeam/clipsync/test-vectors.json`. Format:

```json
{
  "vectors": [
    {
      "name": "session-key derivation, role=initiator",
      "input": {
        "my_ephPriv": "<hex 32 B>",
        "peer_ephPub": "<hex 32 B>",
        "my_kxPriv": "<hex 32 B>",
        "peer_kxPub": "<hex 32 B>"
      },
      "expected": {
        "session_key": "<hex 32 B>"
      }
    },
    {
      "name": "ChaCha20-Poly1305 frame, direction=initiator, n=0",
      "input": { "session_key": "<hex>", "plaintext_json": "{\"kind\":\"ping\",\"nonce\":\"abc\"}" },
      "expected": { "ciphertext_b64": "<...>" }
    },
    {
      "name": "pair verification code",
      "input": { "shared_eph": "<hex>", "shared_static": "<hex>", "ephPubs_sorted": "<hex 64 B>" },
      "expected": { "code": "043812" }
    }
  ]
}
```

Cross-implementation interop should be brought up by running both sides against the same vectors before any actual pairing.

## Glossary

- **peer**: another device running a ClipSync v1 implementation.
- **paired peer**: a peer whose long-term `sigPub` and `kxPub` we have persisted after a successful pair flow.
- **handshake**: the initial cleartext `hello` exchange and resulting session-key derivation.
- **session key**: 32-byte symmetric key derived per-connection from ephemeral + static ECDH; lives only as long as the TCP connection.
- **fingerprint**: human-readable identifier of an Ed25519 public key, formatted as colon-hex of `SHA-256(sigPub)[:16]`.

## Change Log

- **v1 (2026-09-16)**: added the optional `paste` field to `share.begin`, so a copied picture can arrive as a picture rather than as a file. Backwards compatible in both directions: an implementation that ignores the key still receives the PNG as a file.
- **v1 (2026-09-16)**: clarified the handshake's ordering and signature binding — the responder sends its `hello` only after verifying the initiator's, because its signature binds the initiator's `sigPub`; removed the contradictory "peer's sigPub if known from a prior pairing" line from the `sig` pseudocode. Added `pair_accept` to the frames an `unpaired` peer may send (an initiator receives one in that state), and said explicitly that disallowed frames are dropped rather than closed. Added "Re-pairing". No wire-format change: same frames, same fields, same crypto.
- **v1 (2026-05-12)**: initial revision.
