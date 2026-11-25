#pragma once
// Orbify: is a firmware update signed by Orbify's release key, which the root key certified?
// docs/design/release-signing.md has the formats. The feed gives each signed firmware asset an
// "orbify_signature": a release-key certificate (serial, release public key, root signature)
// followed by the release key's signature over "orbify-artifact-v1\n<tag>\n<asset>\n<sha256>\n".
// The updater checks it after the staged image matched its SHA-256; whether a failure blocks
// the update is the build's enforce switch (shared/release-signing.json).
#include <cstddef>
#include <cstdint>

namespace orbify::update_signature {

constexpr size_t kCertificateBytes = 4 + 32 + 64;
constexpr size_t kSignatureBytes = kCertificateBytes + 64;  // certificate || artifact signature
constexpr size_t kSignatureHex = 2 * kSignatureBytes;       // as the feed carries it

enum class Result {
  Ok,            // signed by a release key the root certified
  NoRoot,        // this build has no root key, so it can't check (logged as unsigned)
  Unsigned,      // the update carries no signature
  Revoked,       // the release key's serial is below this build's minimum
  BadCertificate,  // the release key is not certified by this build's root
  BadSignature,  // the signature does not match this tag, asset and SHA-256
};

struct Trust {
  const uint8_t* root;  // 32-byte root public key, or nullptr when the build has none
  uint32_t minSerial;
};

// Hex (either case) to bytes; false unless `hex` is exactly 2 * n hex digits.
bool decodeHex(const char* hex, uint8_t* out, size_t n);

// Checks `signature` (kSignatureBytes, or nullptr when the update has none) for the asset
// `asset` of release `tag` whose SHA-256 is `sha256Hex` (64 hex digits, either case).
Result check(const uint8_t* signature, const Trust& trust, const char* tag, const char* asset, const char* sha256Hex);

// The updater's check (overlay patch 0050): `rootHex` is the build's root key define ("" when
// none), the asset is the last path segment of the download URL, and `signature` the feed's
// decoded orbify_signature (nullptr when the asset has none). The signed filename must also
// match this reader's expectedDeviceStem (the updater's firmwareAssetStem).
Result checkDownload(const char* rootHex, uint32_t minSerial, const char* tag, const char* url, const char* sha256Hex,
                     const uint8_t* signature, const char* expectedDeviceStem);

// Whether the update may be installed: always when signed; otherwise only while not enforced.
inline bool accepted(Result result, bool enforce) { return result == Result::Ok || !enforce; }

// "signed", "unsigned", "signature invalid: ..." for the log.
const char* describe(Result result);

}  // namespace orbify::update_signature
