#!/usr/bin/env bash
# tools/feed-keys: a root certifies release keys, release keys sign artifacts, and verify accepts
# exactly those (a wrong root, a tampered file, another tag and a revoked serial all fail).
set -euo pipefail
fk="$(cd "$(dirname "$0")/.." && pwd)/feed-keys/feed-keys"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
refuses() { if "$@" >/dev/null 2>&1; then fail "accepted: ${*:2}"; fi; }

root="$("$fk" new-root "$t/keys" 2>/dev/null)"
[[ "$root" =~ ^[0-9a-f]{64}$ ]] || fail "new-root printed '$root'"
[ "$("$fk" public-key "$t/keys/root.pem")" = "$root" ] || fail "public-key disagrees with new-root"
refuses "$fk" new-root "$t/keys"
"$fk" new-release-key --root "$t/keys/root.pem" --serial 1 2>/dev/null
"$fk" new-release-key --root "$t/keys/root.pem" --serial 2 2>/dev/null
[ "$(stat -c %a "$t/keys/release-key-1.bundle" 2>/dev/null || stat -f %Lp "$t/keys/release-key-1.bundle")" = 600 ] \
  || fail "the bundle is readable by others"

printf 'firmware image\n' > "$t/firmware-x4-pro-v2.0.0.150.bin"
printf 'plugin\n' > "$t/orbit.koplugin.zip"
RELEASE_SIGNING_KEY="$(cat "$t/keys/release-key-1.bundle")" \
  "$fk" sign --tag xteink-v2.0.0.150 "$t/firmware-x4-pro-v2.0.0.150.bin" "$t/orbit.koplugin.zip" > "$t/SIGNATURES"
[ "$(wc -l < "$t/SIGNATURES")" -eq 3 ] || fail "SIGNATURES: $(cat "$t/SIGNATURES")"
"$fk" verify --tag xteink-v2.0.0.150 --root "$root" "$t/SIGNATURES" "$t/firmware-x4-pro-v2.0.0.150.bin" "$t/orbit.koplugin.zip" >/dev/null \
  || fail "a valid signature was refused"
field="$("$fk" feed-field "$t/SIGNATURES" firmware-x4-pro-v2.0.0.150.bin)"
if ! [[ "$field" =~ ^[0-9a-f]+$ ]] || [ "${#field}" -ne 328 ]; then fail "feed-field: '$field'"; fi

other="$("$fk" new-root "$t/other" 2>/dev/null)"
refuses "$fk" verify --tag xteink-v2.0.0.150 --root "$other" "$t/SIGNATURES" "$t/orbit.koplugin.zip"
refuses "$fk" verify --tag xteink-v2.0.0.151 --root "$root" "$t/SIGNATURES" "$t/orbit.koplugin.zip"
refuses "$fk" verify --tag xteink-v2.0.0.150 --root "$root" --min-serial 2 "$t/SIGNATURES" "$t/orbit.koplugin.zip"
cp "$t/orbit.koplugin.zip" "$t/keep" && printf 'x' >> "$t/orbit.koplugin.zip"
refuses "$fk" verify --tag xteink-v2.0.0.150 --root "$root" "$t/SIGNATURES" "$t/orbit.koplugin.zip"
mv "$t/keep" "$t/orbit.koplugin.zip"

# Rotation: release key 2, certified by the same root, verifies with no other change.
"$fk" sign --tag v0.9.0 --bundle "$t/keys/release-key-2.bundle" "$t/orbit.koplugin.zip" > "$t/SIGNATURES2"
"$fk" verify --tag v0.9.0 --root "$root" --min-serial 2 "$t/SIGNATURES2" "$t/orbit.koplugin.zip" | grep -q 'release key 2' \
  || fail "the rotated key was refused"
# A key certified by another root is refused.
"$fk" new-release-key --root "$t/other/root.pem" --serial 3 2>/dev/null
"$fk" sign --tag v0.9.0 --bundle "$t/other/release-key-3.bundle" "$t/orbit.koplugin.zip" > "$t/SIGNATURES3"
refuses "$fk" verify --tag v0.9.0 --root "$root" "$t/SIGNATURES3" "$t/orbit.koplugin.zip"

# set-root writes only the key, into a copy of the config.
cp "$(dirname "$fk")/../../shared/release-signing.json" "$t/config.json"
FEED_KEYS_CONFIG="$t/config.json" "$fk" set-root "$t/keys/root.pem" 2>/dev/null
grep -q "\"root_public_key\": \"$root\"" "$t/config.json" || fail "set-root: $(cat "$t/config.json")"
FEED_KEYS_CONFIG="$t/config.json" "$fk" verify --tag v0.9.0 "$t/SIGNATURES2" "$t/orbit.koplugin.zip" >/dev/null \
  || fail "verify did not read the root from the config"
echo "feed-keys: all checks passed"
