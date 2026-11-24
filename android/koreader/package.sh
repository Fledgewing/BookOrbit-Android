#!/usr/bin/env bash
# Builds the release zip of the Orbit KOReader plugin: orbit.koplugin/ with PATCH_VERSION
# stamped into its main.lua, every member under orbit.koplugin/ (the self-update and the
# companion unpack only that folder).
#
#   android/koreader/package.sh <version> <out.zip>
set -euo pipefail
ver=${1:?usage: package.sh <version> <out.zip>}
out=${2:?usage: package.sh <version> <out.zip>}
here=$(cd "$(dirname "$0")" && pwd)
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$here/orbit.koplugin" "$stage/"
cp "$here/LICENSE" "$stage/orbit.koplugin/LICENSE"
# The settings shared with the companion (docs/design/companion-settings.md §4.1): one file for both.
cp "$here/../../shared/settings/schema.json" "$stage/orbit.koplugin/settings_schema.json"
main="$stage/orbit.koplugin/main.lua"
sed -E "s/^local PATCH_VERSION = \"[^\"]*\"$/local PATCH_VERSION = \"$ver\"/" "$here/orbit.koplugin/main.lua" > "$main"
grep -qx "local PATCH_VERSION = \"$ver\"" "$main" || { echo "package.sh: version stamp failed" >&2; exit 1; }
# Fixed times and order: the same source gives the same zip.
find "$stage/orbit.koplugin" -exec touch -t 202601010000 {} +
rm -f "$out"
(cd "$stage" && find orbit.koplugin -type f | LC_ALL=C sort | zip -q -X -D "$out" -@)
echo "$out"
