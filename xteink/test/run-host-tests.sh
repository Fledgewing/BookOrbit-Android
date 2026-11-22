#!/usr/bin/env bash
# Host tests for the overlay's pure firmware logic, against a CrossInk-Bookorbit checkout the
# overlay was applied to (scripts/apply.sh). Uses the system C++ compiler; no device, no PlatformIO.
#   xteink/test/run-host-tests.sh /path/to/CrossInk-Bookorbit
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
up="$(cd "${1:?usage: run-host-tests.sh /path/to/CrossInk-Bookorbit}" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# The streaming JSON parser moved into the FreeInk SDK in CrossInk 2.x.
json_inc="$up/lib/JsonParser"
json_src="$up/lib/JsonParser/StreamingJsonParser.cpp"
if [ ! -f "$json_src" ]; then
  json_inc="$up/freeink-sdk/libs/network/JsonSax/include"
  json_src="$up/freeink-sdk/libs/network/JsonSax/src/StreamingJsonParser.cpp"
fi

"${CXX:-c++}" -std=c++17 -Wall -Wextra -O1 \
  -I"$up/lib/JsonParser" -I"$json_inc" -I"$up/src/network" \
  "$here/ota_release_pick_test.cpp" \
  "$up/lib/JsonParser/ReleaseJsonParser.cpp" "$json_src" \
  "$up/src/network/FirmwareVersion.cpp" "$up/src/network/OtaReleasePick.cpp" \
  -o "$out/ota_release_pick_test"
"$out/ota_release_pick_test" "$repo/shared/fixtures/github/orbify-releases.json"
