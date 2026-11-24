#!/usr/bin/env bash
# Offline tests for the test-build tools: tools/android-test-version.sh, and the pure helpers of
# tools/sideload-android.sh and tools/sideload-xteink.sh (no device, no network).
# Run: bash tools/test/test-sideload.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tools="$here/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/fails"
: >"$tmp/passes"

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo . >>"$tmp/passes"; else printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3" | tee -a "$tmp/fails"; fi
}

# ---- the Android test-build version
tv() { printf '%s\n' "$@" | "$tools/android-test-version.sh" 42 2>/dev/null || echo error; }
check "next patch after the newest release" 0.11.3-0.test.42 "$(tv v0.9.0 v0.11.2 v0.11.1 v0.10.9)"
check "numeric, not text, order" 0.10.1-0.test.42 "$(tv v0.9.9 v0.10.0 v0.2.0)"
check "android-v tags count" 0.7.2-0.test.42 "$(tv android-v0.7.1 v0.7.0)"
check "pre-releases and firmware tags don't" 0.11.3-0.test.42 "$(tv v0.11.2 v0.12.0-rc.1 xteink-v2.0.0.167+bookorbit.1-rc3 v0.11.3-0.test.9)"
check "no release tag" error "$(tv xteink-v2.0.0.1 nightly)"
check "run number must be a number" error "$(printf 'v0.1.0\n' | "$tools/android-test-version.sh" abc 2>/dev/null || echo error)"

# ---- sideload-android.sh
(
    # shellcheck source=SCRIPTDIR/../sideload-android.sh
    source "$tools/sideload-android.sh"
    want="F5:07:8C:85:F8:23:18:30:C1:F1:8D:93:FE:30:D7:1F:87:93:6C:1D:94:24:F2:D8:15:98:3D:1D:21:A9:0A:15"
    check "release certificate read from release.yml" "$want" "$(expected_cert)"
    check "apksigner output -> certificate" "AB:CD:01" \
        "$(printf 'Signer #1 certificate DN: CN=x\nSigner #1 certificate SHA-256 digest: abcd01\nSigner #1 certificate SHA-1 digest: ff\n' | cert_from_apksigner)"
    check "version from the APK name" 0.11.3-0.test.42 "$(apk_version /x/orbit-companion-0.11.3-0.test.42.apk)"
    check "one test artifact" android-test-0.11.3-0.test.42 "$(printf 'other\nandroid-test-0.11.3-0.test.42\n' | pick_artifact)"
    check "no test artifact" none "$(printf 'firmware-x4-pro-1\n' | pick_artifact 2>/dev/null || echo none)"
    check "two test artifacts" none "$(printf 'android-test-a\nandroid-test-b\n' | pick_artifact 2>/dev/null || echo none)"
    mkdir -p "$tmp/art"
    printf 'apk' >"$tmp/art/orbit-companion-1.0.0.apk"
    printf 'zip' >"$tmp/art/orbit.koplugin.zip"
    (cd "$tmp/art" && { sha256 orbit-companion-1.0.0.apk | sed 's/$/  orbit-companion-1.0.0.apk/'; echo "0000000000000000000000000000000000000000000000000000000000000000 *orbit.koplugin.zip"; } >SHA256SUMS)
    check "listed and matching" ok "$(sum_ok "$tmp/art/SHA256SUMS" "$tmp/art" orbit-companion-1.0.0.apk && echo ok)"
    check "listed, not matching" bad "$(sum_ok "$tmp/art/SHA256SUMS" "$tmp/art" orbit.koplugin.zip 2>/dev/null || echo bad)"
    check "not listed" bad "$(sum_ok "$tmp/art/SHA256SUMS" "$tmp/art" LICENSE 2>/dev/null || echo bad)"
)

# ---- sideload-xteink.sh
(
    # shellcheck source=SCRIPTDIR/../sideload-xteink.sh
    source "$tools/sideload-xteink.sh"
    check "env x4-pro" "x4-pro firmware-x4-pro ESP32-S3 esp32s3 9" "$(env_info x4-pro)"
    check "env x4" "x4-classic firmware-x4-classic ESP32-S3 esp32s3 9" "$(env_info x4)"
    check "env x3" "default firmware-x3-x4 ESP32-C3 esp32c3 5" "$(env_info x3)"
    check "env unknown" none "$(env_info x5 || echo none)"

    arts=$'firmware-x4-pro-2.0.0.270-bookorbit.1-rc3\nfirmware-x4-classic-2.0.0.270-bookorbit.1-rc3\nfirmware-default-2.0.0.270-bookorbit.1-rc3\neob-page-2.0.0.270-bookorbit.1-rc3'
    check "artifact x4-pro" firmware-x4-pro-2.0.0.270-bookorbit.1-rc3 "$(pick_artifact x4-pro <<<"$arts")"
    check "artifact x3" firmware-default-2.0.0.270-bookorbit.1-rc3 "$(pick_artifact default <<<"$arts")"
    check "artifact missing" none "$(pick_artifact x4-pro <<<"eob-page-1" 2>/dev/null || echo none)"
    check "two CrossInk lines" none "$(printf 'firmware-x4-pro-2.0.0.1\nfirmware-x4-pro-2.1.0.1\n' | pick_artifact x4-pro 2>/dev/null || echo none)"
    files=$'firmware-x3-x4-v2.0.0.270-bookorbit.1-rc3.bin\nfirmware-x3-x4-v2.0.0.270-bookorbit.1-rc3.bin.sha256\nfirmware-x3-x4-v2.0.0.270-bookorbit.1-rc3.parttable'
    check "image, not its checksum or table" firmware-x3-x4-v2.0.0.270-bookorbit.1-rc3.bin "$(pick_bin firmware-x3-x4 <<<"$files")"
    check "image of another reader" none "$(pick_bin firmware-x4-pro <<<"$files" 2>/dev/null || echo none)"

    check "esptool v4 chip" ESP32-S3 "$(printf 'Connecting....\nChip is ESP32-S3 (QFN56) (revision v0.2)\nFeatures: WiFi\n' | chip_from_esptool)"
    check "esptool v5 chip" ESP32-C3 "$(printf 'Connecting...\nChip type:          ESP32-C3 (QFN32) (revision v0.4)\n' | chip_from_esptool)"
    check "esptool detection line" ESP32-S3 "$(printf 'Detecting chip type... ESP32-S3\n' | chip_from_esptool)"
    check "no chip" "" "$(printf 'A fatal error occurred: Failed to connect\n' | chip_from_esptool)"

    # An app image header: magic E9, then chip_id (LE) at byte 12.
    printf '\351\006\002\057\000\000\000\000\356\000\000\000\011\000\000\000' >"$tmp/s3.bin"
    printf '\351\006\002\057\000\000\000\000\356\000\000\000\005\000\000\000' >"$tmp/c3.bin"
    printf 'PK\003\004 not an image..' >"$tmp/zip.bin"
    check "S3 image" 9 "$(image_chip_id "$tmp/s3.bin")"
    check "C3 image" 5 "$(image_chip_id "$tmp/c3.bin")"
    check "not an image" none "$(image_chip_id "$tmp/zip.bin" || echo none)"

    # The binary table PlatformIO builds from CrossInk's partitions.csv: nvs 0x9000, otadata
    # 0xe000, app0 0x10000, app1 0x650000, spiffs 0xc90000, coredump 0xff0000.
    byte() { printf '%b' "\\0$(printf '%03o' $(($1 & 255)))"; }
    le32() { byte "$1"; byte $(($1 >> 8)); byte $(($1 >> 16)); byte $(($1 >> 24)); }
    entry() { # type subtype offset size label
        printf '\252\120'
        byte "$1"
        byte "$2"
        le32 "$3"
        le32 "$4"
        printf '%s' "$5"
        head -c $((16 - ${#5})) /dev/zero
        head -c 4 /dev/zero
    }
    {
        entry 1 2 $((0x9000)) $((0x5000)) nvs
        entry 1 0 $((0xe000)) $((0x2000)) otadata
        entry 0 16 $((0x10000)) $((0x640000)) app0
        entry 0 17 $((0x650000)) $((0x640000)) app1
        entry 1 130 $((0xc90000)) $((0x360000)) spiffs
        entry 1 3 $((0xff0000)) $((0x10000)) coredump
        printf '\353\353'
        head -c 30 /dev/zero | LC_ALL=C tr '\0' '\377'
        head -c $((0xC00 - 7 * 32)) /dev/zero | LC_ALL=C tr '\0' '\377'
    } >"$tmp/table.bin"
    table=$(parse_parttable "$tmp/table.bin")
    check "table: six partitions, stops at the MD5 entry" 6 "$(wc -l <<<"$table" | tr -d ' ')"
    check "table: nvs" "1 2 36864 20480 nvs" "$(sed -n 1p <<<"$table")"
    check "otadata from the table" "57344 8192 otadata" "$(part_find 1 0 <<<"$table")"
    check "ota_0 from the table" "65536 6553600 app0" "$(part_find 0 16 <<<"$table")"
    check "ota_1 from the table" "6619136 6553600 app1" "$(part_find 0 17 <<<"$table")"
    head -c 3072 /dev/zero | LC_ALL=C tr '\0' '\377' >"$tmp/blank.bin"
    check "blank flash: no table" none "$(parse_parttable "$tmp/blank.bin" || echo none)"
    check "hex" 0x10000 "$(hex 65536)"
    check "macOS port aliases" $'/dev/cu.usbmodem101\n/dev/tty.usbmodem101' "$(port_aliases /dev/cu.usbmodem101)"
    check "Linux port" /dev/ttyACM0 "$(port_aliases /dev/ttyACM0)"
)

passed=$(wc -l <"$tmp/passes" | tr -d ' ')
failed=$(wc -l <"$tmp/fails" | tr -d ' ')
printf '%s passed, %s failed\n' "$passed" "$failed"
[[ $failed == 0 ]]
