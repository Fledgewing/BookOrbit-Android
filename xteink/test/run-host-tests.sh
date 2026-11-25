#!/usr/bin/env bash
# Host tests for the overlay's pure firmware logic, against a CrossInk-Bookorbit checkout the
# overlay was applied to (scripts/apply.sh). Uses the system C++ compiler; no device, no PlatformIO.
#   xteink/test/run-host-tests.sh /path/to/CrossInk-Bookorbit
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
up="$(cd "${1:?usage: run-host-tests.sh /path/to/CrossInk-Bookorbit}" && pwd)"
# ORBIFY_TEST_OUT keeps the binaries and the End-of-Book PNGs (CI uploads them); else a temp dir.
if [ -n "${ORBIFY_TEST_OUT:-}" ]; then
  out="$ORBIFY_TEST_OUT"
  mkdir -p "$out"
else
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi

python3 "$repo/tools/test/test-product-names.py"

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
"$out/ota_release_pick_test" "$repo/shared/fixtures/github/orbify-releases.json" "$repo/shared/fixtures/github/xteink-feed.json"

# The actual SD-marker implementation, with storage and version replaced for a reboot test.
"${CXX:-c++}" -std=c++17 -Wall -Wextra -O1 -I"$here/ota_return_stubs" -I"$repo/xteink/orbify" -I"$here" \
  "$here/ota_return_test.cpp" "$repo/xteink/orbify/OtaReturn.cpp" -o "$out/ota_return_test"
"$out/ota_return_test"

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
# Signed updates (docs/design/release-signing.md): the verifier against known answers and the
# release-signing fixtures the companion checks too, then the OTA scenario through the updater's
# own parser (overlay patch 0050).
signing="$repo/shared/fixtures/release-signing"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -O1 -I"$ajson" -I"$core" -I"$here" \
  "$here/update_signature_test.cpp" "$core/Ed25519Verify.cpp" "$core/UpdateSignature.cpp" -o "$out/update_signature_test"
"$out/update_signature_test" "$signing"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -O1 -I"$ajson" -I"$core" -I"$here" -I"$up/lib/JsonParser" -I"$json_inc" \
  "$here/ota_signature_test.cpp" "$up/lib/JsonParser/ReleaseJsonParser.cpp" "$json_src" \
  "$core/Ed25519Verify.cpp" "$core/UpdateSignature.cpp" -o "$out/ota_signature_test"
"$out/ota_signature_test" "$signing"
# shared/fixtures/REGISTRY.json: these tests read every rule table that names "cpp" (registry_test.cpp).
orbify_test registry
orbify_test status_format
orbify_test finish "$core/FinishQueue.cpp"
orbify_test end_of_book "$core/SeriesCard.cpp" "$core/EndPagePlan.cpp" "$core/FinishQueue.cpp" "$core/NextCover.cpp" \
  "$core/CatalogCache.cpp" "$core/LocalFirst.cpp"
orbify_test localfirst "$core/LocalFirst.cpp"
orbify_test reading_quiet "$core/ReadingQuiet.cpp"
# OrbiSmart sync (docs/design/position-sync.md §3): the shared table, as Android runs it.
orbify_test orbismart "$core/OrbiSmart.cpp"
orbify_test cache "$core/CatalogCache.cpp" "$core/LocalFirst.cpp"
orbify_test copy_check "$core/CopyCheck.cpp"
orbify_test copy_queue "$core/CopyQueue.cpp" "$core/CopyCheck.cpp"
orbify_test mirror "$core/Mirror.cpp"
orbify_test sleep_sync_deadline
orbify_test wifi_holds
orbify_test refresh_plan "$core/Mirror.cpp"
orbify_test bulk_refresh
orbify_test wifi_policy
# Battery stats (orbify/core/BatteryStatsCore): CrossInk-style GoogleTest cases through GtestShim.h.
orbify_test battery_stats "$core/BatteryStatsCore.cpp"
orbify_test boot_trail
# The BookOrbit server's TLS trust (orbify/core/ServerTrust): which requests are verified, and the pin.
orbify_test server_trust "$core/ServerTrust.cpp"
# The sleep screen (ROADMAP 11): the rotation and the batch read shared/fixtures/sleep/cases.json, as Android does.
orbify_test sleep_pick "$core/SleepPick.cpp" "$core/SleepLayout.cpp"
# The End-of-Book page (orbify/core/EndPageLayout): touch rules on the X4 Pro and X4 layouts, and
# PNGs drawn with CrossInk's own font sources for review against the mockups (in $out). Needs
# FreeType and libpng; CI sets ORBIFY_REQUIRE_RENDER=1 so a missing library fails there.
if pkg-config --exists freetype2 libpng 2>/dev/null; then
  "${CXX:-c++}" -std=c++17 -Wall -Wextra -O1 -I"$core" $(pkg-config --cflags freetype2 libpng) \
    "$here/eob_render.cpp" "$core/EndPageLayout.cpp" $(pkg-config --libs freetype2 libpng) -o "$out/eob_render"
  "$out/eob_render" "$up" "$out"
elif [ "${ORBIFY_REQUIRE_RENDER:-0}" = 1 ]; then
  echo "eob-render: FreeType and libpng are required (pkg-config freetype2 libpng)" >&2
  exit 1
else
  echo "eob-render: skipped (no FreeType/libpng)"
fi
# The lwIP core-lock wrapper (tailnet/shim/TailnetLwipLock.c) against stand-in lwIP headers.
"${CC:-cc}" -std=c11 -Wall -Wextra -I"$here/stubs" "$here/lwip_lock_test.c" "$repo/xteink/tailnet/shim/TailnetLwipLock.c" \
  -o "$out/lwip_lock_test"
"$out/lwip_lock_test"
