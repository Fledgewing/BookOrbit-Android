# Signed updates

Readers and the companion install firmware and the KOReader plugin that they download from
GitHub. A SHA-256 from the same release only catches corruption. This design adds an offline
signature, so an update is accepted only if the maintainer's key vouched for it.

The APK is not covered here: Android and the companion's updater already require the
release signing certificate.

## Keys

| Key | Where it lives | Signs | Replaced by |
|---|---|---|---|
| **Root** (Ed25519) | Offline: the maintainer's password manager plus a backup. Its public key is in `shared/release-signing.json`, compiled into the firmware and the companion | Release-key certificates only | A reflash over USB of every reader (and a companion update) |
| **Release key** (Ed25519) | The Actions secret `RELEASE_SIGNING_KEY` | Each release's firmware images, the plugin zip and the firmware feed | A new certificate from the root; no reflash |

Each release key has a serial number. `min_release_key_serial` in `shared/release-signing.json`
revokes older keys in every build made after it changes.

## Formats

All binary values are written as lowercase hex.

- **Certificate** (100 bytes): serial (4 bytes, big-endian) ‖ release public key (32) ‖ root
  signature (64). The root signs `"orbify-release-key-v1\n"` ‖ serial ‖ release public key.
- **Artifact signature** (64 bytes): the release key signs the text
  `"orbify-artifact-v1\n<tag>\n<asset name>\n<sha256 hex>\n"`. The tag binds the version, so
  an old image can't be offered as a newer one.
- **`SIGNATURES`** (a release asset): the line `release-key <certificate>`, then one
  `<signature>  <asset name>` line per signed asset.
- **Feed** (`xteink/releases.json` on `xteink-feed`): each signed firmware asset carries
  `"orbify_signature": "<certificate><signature>"` (328 hex characters). The feed file itself
  is signed too, as `xteink/releases.json.sig`: a `SIGNATURES` file whose asset is
  `releases.json` and whose tag is `xteink-feed`.

`tools/feed-keys/feed-keys` makes and checks all of these with openssl.
`tools/test/test-feed-keys.sh` is its test.

## Checks

- **Firmware**: after the staged image passes its SHA-256 check, the updater verifies:
  1. the certificate against the compiled-in root, with a serial at or above the minimum;
  2. the signature over (tag, asset name, SHA-256).
- **Companion**: before unpacking the plugin zip, it runs the same two checks, using the
  release's `SIGNATURES`.
- **CI**: the publish jobs sign, then verify their own signatures with `feed-keys verify`
  before anything is uploaded.

## Rollout: built in, then enforced

`enforce` in `shared/release-signing.json` decides what a failed check does:

- `false` (the default until the keys exist): an unsigned or badly signed update is logged
  (`unsigned`, `signature invalid`) and still installed.
- `true`: it is refused.

Turning enforcement on is the one-line change `"enforce": true`. Do it only once the root key
is committed and a signed release has gone out. Readers that still run a build without the
root key keep accepting unsigned updates until they take the first signed one.

## Setting up the keys (maintainer, once)

1. `tools/feed-keys/feed-keys new-root ~/orbify-release-keys` creates the root key, then
   `tools/feed-keys/feed-keys new-release-key --root ~/orbify-release-keys/root.pem --serial 1`
   creates the first release key.
2. Store `~/orbify-release-keys/root.pem` in the password manager, plus a backup copy offline.
3. `gh secret set RELEASE_SIGNING_KEY -R Fledgewing/Orbify < ~/orbify-release-keys/release-key-1.bundle`,
   then delete the bundle. The root key never goes to CI.
4. `tools/feed-keys/feed-keys set-root ~/orbify-release-keys/root.pem`, then commit
   `shared/release-signing.json` in a pull request.

To rotate the release key: run `new-release-key` with the next serial and set the secret again.
If the old key may have leaked, also raise `min_release_key_serial`.

To verify a release by hand: `tools/feed-keys/feed-keys verify --tag <tag> SIGNATURES <files>`.
