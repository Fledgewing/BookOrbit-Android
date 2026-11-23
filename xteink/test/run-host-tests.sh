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
"$here/upstream_line_test.sh"

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

# Orbify's own logic (xteink/orbify/core): pure C++, tested with ArduinoJson, the JSON library the
# firmware links: the build fetches it, so CI runs these after the build.
ajson="${ARDUINOJSON_DIR:-}"
if [ -z "$ajson" ]; then
  for d in "$up"/.pio/libdeps/*/ArduinoJson/src; do [ -f "$d/ArduinoJson.h" ] && ajson="$d" && break; done
fi
[ -n "$ajson" ] || { echo "ArduinoJson not found: run 'pio pkg install -e <env>' in $up, or set ARDUINOJSON_DIR" >&2; exit 1; }
core="$repo/xteink/orbify/core"
orbify_test() { # name [sources...]: the test reads its tables from shared/fixtures/bookorbit
  local name="$1"
  shift
  "${CXX:-c++}" -std=c++17 -Wall -Wextra -O1 -I"$ajson" -I"$core" -I"$here" \
    "$here/${name}_test.cpp" "$@" -o "$out/${name}_test"
  "$out/${name}_test" "$repo/shared/fixtures/bookorbit"
}
orbify_test finish "$core/FinishQueue.cpp"
orbify_test end_of_book "$core/SeriesCard.cpp" "$core/EndPagePlan.cpp" "$core/FinishQueue.cpp"
orbify_test localfirst "$core/LocalFirst.cpp"
orbify_test cache "$core/CatalogCache.cpp" "$core/LocalFirst.cpp"
