#!/usr/bin/env bash
# Flash an Xteink test build over USB with esptool, keeping the reader's settings (AGENTS.md
# "Test builds: sideload first, release after"). Test on the device first; release once it works.
#
#   tools/sideload-xteink.sh <run-id|bin|folder> --port /dev/cu.usbmodemXXXX --env x4-pro|x4|x3 [--yes]
#
#   <run-id>  an xteink.yml run (a manual run with test_build on, a pull request or a push):
#             downloads its firmware-<env>-* artifact from this repo
#   <bin>     a firmware .bin with <bin>.sha256 or a SHA256SUMS beside it (a release download)
#   <folder>  a downloaded artifact
#   --yes     don't ask before flashing
#
# It writes only two regions, both read from the reader's own partition table (and checked
# against the table the build used, .parttable in the artifact): the app image to the first OTA
# slot (ota_0, "app0"), and the otadata region reset to blank, so the bootloader starts ota_0.
# The same as a PlatformIO upload. NVS (Wi-Fi, Tailscale keys, settings), the other app slot,
# spiffs, coredump, the bootloader, the partition table and the SD card are not touched.
# It refuses a reader whose chip doesn't match --env (x4-pro, x4: ESP32-S3; x3: ESP32-C3, also
# the C3 X4), an image built for another chip, an image larger than the slot, and a port that
# another program (a serial logger) holds open; it never stops that program.
# Needs: esptool (v4 or v5), gh (for a run id), lsof, od, shasum or sha256sum.
set -euo pipefail

# shellcheck source=SCRIPTDIR/repo-urls.sh
source "$(dirname "${BASH_SOURCE[0]}")/repo-urls.sh"

REPO=$BOOKSYNC_REPO # artifacts come from this repo only
PT_OFFSET=0x8000         # where the bootloader reads the partition table (ESP-IDF's default)
PT_SIZE=0xC00            # the table's sector: 96 entries of 32 bytes

SOURCE="" PORT="" ENV_ARG="" YES=0

say() { printf '%s\n' "$*"; }
die() { printf 'sideload-xteink: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- helpers (pure)

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# --env -> "<pio env> <firmware name> <chip> <esptool chip> <image chip id>" (esp_image_header_t chip_id).
env_info() {
    case "$1" in
        x4-pro) echo "x4-pro firmware-x4-pro ESP32-S3 esp32s3 9" ;;
        x4 | x4-classic) echo "x4-classic firmware-x4-classic ESP32-S3 esp32s3 9" ;;
        x3 | default) echo "default firmware-x3-x4 ESP32-C3 esp32c3 5" ;;
        *) return 1 ;;
    esac
}

# Artifact folder names (stdin) -> the one firmware-<pio env>-* folder; fails on none or several.
pick_artifact() { # pio env
    local names
    names=$(grep -E "^firmware-$1-[0-9]" || true)
    [[ -n $names ]] || { echo "no firmware-$1-* artifact" >&2; return 1; }
    [[ $(wc -l <<<"$names" | tr -d ' ') == 1 ]] || { printf 'several firmware-%s artifacts (one per CrossInk line); pass the folder of the one you want:\n%s\n' "$1" "$names" >&2; return 1; }
    printf '%s\n' "$names"
}

# File names (stdin) -> the one <firmware name>-v*.bin; fails on none or several.
pick_bin() { # firmware name
    local names
    names=$(grep -E "^$1-v.*\.bin$" || true)
    [[ -n $names ]] || { echo "no $1-v*.bin" >&2; return 1; }
    [[ $(wc -l <<<"$names" | tr -d ' ') == 1 ]] || { printf 'several images:\n%s\n' "$names" >&2; return 1; }
    printf '%s\n' "$names"
}

# esptool output (stdin) -> the chip it found, e.g. ESP32-S3 (v4 "Chip is ...", v5 "Chip type: ...").
chip_from_esptool() {
    sed -nE 's/.*(Chip is|Chip type:|Detecting chip type\.\.\.)[[:space:]]+(ESP32(-[A-Z0-9]+)?).*/\2/p' | head -n 1
}

# The chip id in an app image header (esp_image_header_t: magic 0xE9 at 0, chip_id at 12, LE).
# Prints the id, or fails when the file is not an ESP app image.
image_chip_id() {
    local b
    read -r -a b < <(od -An -v -tu1 -N14 "$1")
    [[ ${#b[@]} == 14 && ${b[0]} == 233 ]] || return 1
    echo $((b[12] + 256 * b[13]))
}

# A binary partition table (ESP-IDF esp_partition_info_t, 32-byte entries, magic AA 50) ->
# one line per partition: "<type> <subtype> <offset> <size> <label>" (numbers in decimal).
# Fails when the first entry has no magic (no table there).
parse_parttable() {
    local -a b
    read -r -a b <<<"$(od -An -v -tu1 "$1" | tr -s ' \n' '  ')"
    local i=0 n=0 j label c
    while ((i + 32 <= ${#b[@]})); do
        ((b[i] == 0xAA && b[i + 1] == 0x50)) || break
        label=""
        for ((j = i + 12; j < i + 28; j++)); do
            c=${b[j]}
            ((c == 0)) && break
            label+=$(printf '%b' "\\0$(printf '%03o' "$c")")
        done
        printf '%d %d %d %d %s\n' "${b[i + 2]}" "${b[i + 3]}" \
            $((b[i + 4] + (b[i + 5] << 8) + (b[i + 6] << 16) + (b[i + 7] << 24))) \
            $((b[i + 8] + (b[i + 9] << 8) + (b[i + 10] << 16) + (b[i + 11] << 24))) "$label"
        n=$((n + 1))
        i=$((i + 32))
    done
    ((n > 0))
}

# Parsed table (stdin), type and subtype -> "<offset> <size> <label>" of the first match.
part_find() { awk -v t="$1" -v s="$2" '$1 == t && $2 == s { print $3, $4, $5; exit }'; }

hex() { printf '0x%x' "$1"; }

# The other names of a serial port: macOS lists each USB port as /dev/cu.X and /dev/tty.X.
port_aliases() {
    printf '%s\n' "$1"
    case "$1" in
        /dev/cu.*) printf '/dev/tty.%s\n' "${1#/dev/cu.}" ;;
        /dev/tty.*) printf '/dev/cu.%s\n' "${1#/dev/tty.}" ;;
    esac
}

# ---------------------------------------------------------------- esptool

esptool_init() {
    if command -v esptool >/dev/null 2>&1; then ESPTOOL=esptool
    elif command -v esptool.py >/dev/null 2>&1; then ESPTOOL=esptool.py
    else die "esptool not found (pipx install esptool, or brew install esptool)"; fi
    local v
    v=$("$ESPTOOL" version 2>/dev/null | sed -nE 's/.*v([0-9]+)\..*/\1/p' | head -n 1)
    ESPTOOL_MAJOR=${v:-4}
}

# A command name in the running esptool's spelling (v5 uses hyphens).
ecmd() { if ((ESPTOOL_MAJOR >= 5)); then printf '%s\n' "${1//_/-}"; else printf '%s\n' "$1"; fi; }

port_free() {
    command -v lsof >/dev/null 2>&1 || { say "Note: lsof not found; can't check whether a logger holds $PORT"; return 0; }
    local p holders=""
    while IFS= read -r p; do
        [[ -e $p ]] || continue
        holders+=$(lsof -- "$p" 2>/dev/null | awk 'NR > 1 { printf "  %s (pid %s) holds %s\n", $1, $2, $NF }' || true)
    done < <(port_aliases "$PORT")
    if [[ -n $holders ]]; then
        printf '%s\n' "$holders" >&2
        die "$PORT is in use. Close that program (a serial logger or monitor) and run this again; this script stops nothing"
    fi
}

# ---------------------------------------------------------------- inputs

fetch() {
    local dir sub
    if [[ $SOURCE =~ ^[0-9]+$ ]]; then
        command -v gh >/dev/null 2>&1 || die "gh not found (needed to download run $SOURCE)"
        say "Run $SOURCE in $REPO:"
        booksync_run_info --json workflowName,headBranch,headSha,event,status,conclusion \
            -q '"  workflow \(.workflowName), branch \(.headBranch) \(.headSha[0:12]), \(.event), \(.status) \(.conclusion)"' ||
            die "can't read run $SOURCE in $REPO"
        gh run download "$SOURCE" -R "$REPO" -p "firmware-$PIOENV-*" -D "$WORK/dl" ||
            die "run $SOURCE has no firmware-$PIOENV-* artifact"
        dir="$WORK/dl"
    elif [[ -f $SOURCE ]]; then
        BIN=$SOURCE
        dir=""
    elif [[ -d $SOURCE ]]; then
        dir=$SOURCE
    else
        die "$SOURCE is neither a run id, a .bin nor a folder"
    fi
    if [[ -n $dir ]]; then
        if ! find "$dir" -maxdepth 1 -name "$FWNAME-v*.bin" | grep -q .; then
            sub=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | pick_artifact "$PIOENV") || die "no $FWNAME image in $dir"
            dir="$dir/$sub"
        fi
        BIN="$dir/$(find "$dir" -maxdepth 1 -type f -exec basename {} \; | pick_bin "$FWNAME")" || die "no single $FWNAME image in $dir"
    fi
}

verify_image() {
    local d b want=""
    d=$(dirname "$BIN") b=$(basename "$BIN")
    if [[ -f $BIN.sha256 ]]; then
        want=$(cut -d' ' -f1 <"$BIN.sha256")
    elif [[ -f $d/SHA256SUMS ]]; then
        want=$(awk -v n="$b" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$d/SHA256SUMS")
    fi
    [[ -n $want ]] || die "no checksum for $b ($b.sha256 or SHA256SUMS beside it); not flashing an unchecked image"
    [[ $(sha256 "$BIN") == "$want" ]] || die "$b doesn't match its checksum"
    say "Checked: $b matches its SHA-256"
    local id
    id=$(image_chip_id "$BIN") || die "$b is not an ESP32 app image"
    [[ $id == "$IMG_CHIP_ID" ]] || die "$b is built for chip id $id, not the $CHIP of --env $ENV_ARG"
    say "Checked: $b is an $CHIP app image"
    BUILD_PT="${BIN%.bin}.parttable"
    [[ -f $BUILD_PT ]] || BUILD_PT=""
}

# ---------------------------------------------------------------- device

read_device() {
    port_free
    say "Reading the reader's chip and partition table (read only)"
    local out
    out=$("$ESPTOOL" --port "$PORT" "$(ecmd read_flash)" "$PT_OFFSET" "$PT_SIZE" "$WORK/device.parttable" 2>&1) || {
        printf '%s\n' "$out" >&2
        die "esptool couldn't read the reader on $PORT (hold the boot button while plugging in if it doesn't answer)"
    }
    FOUND=$(printf '%s\n' "$out" | chip_from_esptool)
    [[ -n $FOUND ]] || { printf '%s\n' "$out" >&2; die "esptool didn't say which chip it found"; }
    if [[ $FOUND != "$CHIP" ]]; then
        local hint=""
        [[ $FOUND == ESP32-C3 ]] && hint=" (an ESP32-C3 reader, the X3 or the C3 X4, takes --env x3)"
        [[ $FOUND == ESP32-S3 ]] && hint=" (an ESP32-S3 reader takes --env x4-pro or --env x4)"
        die "the reader on $PORT is an $FOUND, not the $CHIP that --env $ENV_ARG is for$hint; nothing written"
    fi
    say "Checked: the reader is an $FOUND"
    DEVICE_TABLE=$(parse_parttable "$WORK/device.parttable") || die "no partition table at $PT_OFFSET on the reader; flash it fully once instead"
    if [[ -n $BUILD_PT ]]; then
        local built
        built=$(parse_parttable "$BUILD_PT") || die "$(basename "$BUILD_PT") is not a partition table"
        [[ $built == "$DEVICE_TABLE" ]] || {
            printf 'reader:\n%s\nbuild:\n%s\n' "$DEVICE_TABLE" "$built" >&2
            die "the reader's partition table differs from the one this build is for; this script never rewrites it"
        }
        say "Checked: the reader's partition table is the one the build used"
    else
        say "Note: no .parttable beside the image; using the reader's own table"
    fi
    read -r OTA_OFF OTA_SIZE _ < <(part_find 1 0 <<<"$DEVICE_TABLE") || true
    read -r APP0_OFF APP0_SIZE APP0_LABEL < <(part_find 0 16 <<<"$DEVICE_TABLE") || true
    [[ -n ${OTA_OFF:-} && -n ${APP0_OFF:-} ]] || die "the reader's table has no otadata or ota_0 partition"
    local size
    size=$(wc -c <"$BIN" | tr -d ' ')
    ((size <= APP0_SIZE)) || die "$(basename "$BIN") is $size bytes; $APP0_LABEL holds $APP0_SIZE"
    BIN_SIZE=$size
}

plan() {
    say ""
    say "The reader's partition table:"
    awk '{ printf "    %-10s type %d/%d at 0x%x, %d KB\n", $5, $1, $2, $3, $4 / 1024 }' <<<"$DEVICE_TABLE"
    say "Plan for the $FOUND on $PORT:"
    say "  1. Write $(basename "$BIN") ($BIN_SIZE bytes) to $APP0_LABEL at $(hex "$APP0_OFF") (slot $APP0_SIZE bytes)."
    say "  2. Reset otadata at $(hex "$OTA_OFF") ($OTA_SIZE bytes, written blank) so the bootloader starts $APP0_LABEL."
    say "  3. Reset the reader; it starts the new firmware."
    say "  Command: $ESPTOOL --chip $ESPCHIP --port $PORT $(ecmd write_flash) $(hex "$OTA_OFF") <blank otadata> $(hex "$APP0_OFF") $(basename "$BIN")"
    say "  Not touched: NVS (Wi-Fi, Tailscale keys, settings), the other app slot, spiffs, the bootloader,"
    say "  the partition table and the SD card."
}

confirm() {
    [[ $YES == 1 ]] && return 0
    local answer=""
    printf 'Flash? [y/N] '
    read -r answer </dev/tty || answer=""
    [[ $answer == y || $answer == Y ]] || die "stopped; nothing written"
}

flash() {
    port_free
    head -c "$OTA_SIZE" /dev/zero | LC_ALL=C tr '\0' '\377' >"$WORK/otadata-blank.bin"
    "$ESPTOOL" --chip "$ESPCHIP" --port "$PORT" "$(ecmd write_flash)" \
        "$(hex "$OTA_OFF")" "$WORK/otadata-blank.bin" "$(hex "$APP0_OFF")" "$BIN" ||
        die "esptool failed. Run the same command again: the bootloader and NVS are untouched, so USB flashing still works"
    say "Done: $(basename "$BIN") is on the reader. Test it there; release only once it works."
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) PORT=${2:?--port needs a serial port}; shift ;;
            --env) ENV_ARG=${2:?--env needs x4-pro, x4 or x3}; shift ;;
            --yes) YES=1 ;;
            -h | --help) usage; return 0 ;;
            -*) usage >&2; die "unknown option $1" ;;
            *) [[ -z $SOURCE ]] || die "one run id, .bin or folder only"; SOURCE=$1 ;;
        esac
        shift
    done
    [[ -n $SOURCE ]] || { usage >&2; die "give a run id, a .bin or a folder"; }
    [[ -n $PORT ]] || die "give --port (ls /dev/cu.usbmodem* on macOS, /dev/ttyACM* on Linux)"
    [[ -n $ENV_ARG ]] || die "give --env x4-pro, x4 or x3"
    read -r PIOENV FWNAME CHIP ESPCHIP IMG_CHIP_ID < <(env_info "$ENV_ARG") || die "--env is x4-pro, x4 or x3, not $ENV_ARG"
    [[ -e $PORT ]] || die "$PORT doesn't exist (is the reader plugged in and awake?)"
    esptool_init
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    fetch
    verify_image
    read_device
    plan
    confirm
    flash
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
