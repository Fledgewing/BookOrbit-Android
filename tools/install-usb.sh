#!/usr/bin/env bash
# Set up an Android e-reader over USB (adb): KOReader, the BookOrbit plugin, Orbit Companion
# and the Orbit KOReader plugin, each downloaded from its official GitHub release and verified before
# anything touches the device. macOS and Linux. See android/docs/SETUP.md "Set up over USB".
#
#   tools/install-usb.sh                  install or update everything
#   tools/install-usb.sh --fresh          first clear an old /sdcard/koreader (lists it, asks y/N)
#   tools/install-usb.sh --books out.csv  also write the device's book list (before any change)
#   tools/install-usb.sh --books out.csv --no-install   only the book list
#
# Needs: adb, curl, jq, unzip, and shasum (macOS) or sha256sum/sha1sum (Linux).
# It never deletes anything but an old /sdcard/koreader you confirmed (--fresh), the plugin
# folders it replaces and the old Orbit user patch (koreader/patches/2-orbit-android.lua).
set -euo pipefail

KOREADER_API="https://api.github.com/repos/koreader/koreader/releases/latest"
BOOKORBIT_API="https://api.github.com/repos/bookorbit/bookorbit"
BOOKORBIT_RAW="https://raw.githubusercontent.com/bookorbit/bookorbit"
ORBIT_API="https://api.github.com/repos/Fledgewing/Orbify/releases/latest"
PLUGIN_NAME="bookorbit.koplugin"
PLUGIN_MIN="2.3.0" # the plugin Orbit's hooks are checked against (companion PluginRelease.MIN_VERSION)
ORBIT_ZIP="orbit.koplugin.zip"
ORBIT_PLUGIN="orbit.koplugin"
OLD_PATCH="2-orbit-android.lua" # the user patch the plugin replaced (Orbify 0.7.x and older)
KO_DIR="/sdcard/koreader"
NEO_URI="content://com.onyx.content.database.ContentProvider/Metadata"

FRESH=0
BOOKS=""
INSTALL=1
ADB=(adb)

say() { printf '%s\n' "$*"; }
die() { printf 'install-usb: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- helpers (pure)

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
sha1_stdin() { if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1; else shasum -a 1 | cut -d' ' -f1; fi; }

# Git's blob id of a file: SHA-1 of "blob <size>\0" + content (what GitHub's trees API lists).
git_blob_sha1() {
    local size
    size=$(wc -c <"$1" | tr -d ' ')
    { printf 'blob %s\0' "$size"; cat "$1"; } | sha1_stdin
}

# KOReader's release asset name part for an Android ABI.
abi_arch() {
    case "$1" in
        arm64-v8a) echo arm64 ;;
        armeabi-v7a | armeabi) echo arm ;;
        x86 | x86_64) echo x86 ;;
        *) return 1 ;;
    esac
}

# a.b.c version compare: succeeds when $1 < $2.
version_lt() {
    local a b i x y
    IFS=. read -r -a a <<<"${1%%[-+]*}"
    IFS=. read -r -a b <<<"${2%%[-+]*}"
    for i in 0 1 2; do
        x=${a[i]:-0} y=${b[i]:-0}
        ((10#$x < 10#$y)) && return 0
        ((10#$x > 10#$y)) && return 1
    done
    return 1
}

# Quote one argument for the device's shell.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# One CSV field.
csv() { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }

# The OPF path from META-INF/container.xml on stdin.
opf_path() { tr '\n' ' ' | sed -n 's/.*full-path="\([^"]*\)".*/\1/p'; }

# dc:title / dc:creator from an OPF on stdin (first of each, tags and entities stripped).
opf_field() {
    local tag=$1
    tr '\n' ' ' | { grep -o "<dc:${tag}[^>]*>[^<]*</dc:${tag}>" || true; } | head -n 1 | sed 's/<[^>]*>//g' |
        sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'"'"'/g' | sed 's/^ *//; s/ *$//'
}

# KOReader's sidecar status (summary.status) from metadata.*.lua on stdin.
sidecar_status() { tr '\n' ' ' | sed -n 's/.*\["status"\] *= *"\([a-z_]*\)".*/\1/p'; }

# NeoReader rows ("Row: N key=value, key=value, ...") -> path<TAB>title<TAB>authors<TAB>status<TAB>lastAccess.
# Only these keys are read; a value runs to the next ", <known key>=".
neo_rows() {
    awk '
    BEGIN { n = split("nativeAbsolutePath title authors readingStatus lastAccess", keys, " ") }
    /^Row: / {
        line = $0; sub(/^Row: [0-9]+ /, "", line); line = ", " line
        for (i = 1; i <= n; i++) v[keys[i]] = ""
        for (i = 1; i <= n; i++) {
            k = keys[i]; p = index(line, ", " k "=")
            if (!p) continue
            rest = substr(line, p + length(k) + 3); end = length(rest) + 1
            for (j = 1; j <= n; j++) { e = index(rest, ", " keys[j] "="); if (e && e < end) end = e }
            v[k] = substr(rest, 1, end - 1); if (v[k] == "NULL") v[k] = ""
        }
        if (v["nativeAbsolutePath"] != "") printf "%s\t%s\t%s\t%s\t%s\n", v["nativeAbsolutePath"], v["title"], v["authors"], v["readingStatus"], v["lastAccess"]
    }'
}

# ---------------------------------------------------------------- device

dsh() { "${ADB[@]}" shell "$@" | tr -d '\r'; }

pick_device() {
    local n
    [[ ${#ADB[@]} -gt 1 ]] && return 0 # --serial
    n=$("${ADB[@]}" devices | awk 'NR > 1 && $2 == "device"' | wc -l | tr -d ' ')
    [[ $n == 1 ]] || die "need exactly one device in 'adb devices' (found $n); use --serial SERIAL"
}

detect() {
    MODEL=$(dsh getprop ro.product.model)
    ANDROID=$(dsh getprop ro.build.version.release)
    ABIS=$(dsh getprop ro.product.cpu.abilist)
    [[ -n $ABIS ]] || ABIS=$(dsh getprop ro.product.cpu.abi)
    say "Device: $MODEL, Android $ANDROID, ABIs $ABIS"
}

# ---------------------------------------------------------------- book list

write_books() {
    local out=$1 tmp f status last title author container opf sdr
    tmp=$(mktemp)
    say "Book list -> $out"
    if dsh content query --uri "$NEO_URI" 2>/dev/null | neo_rows >"$tmp.neo" && [[ -s $tmp.neo ]]; then
        say "  NeoReader library: $(wc -l <"$tmp.neo" | tr -d ' ') book(s)"
    else
        : >"$tmp.neo"
        say "  no NeoReader library on this device"
    fi
    {
        printf 'path,title,author,status,last_opened,source\n'
        dsh "find /sdcard -type f \\( -iname '*.epub' -o -iname '*.pdf' -o -iname '*.mobi' -o -iname '*.azw3' -o -iname '*.fb2' -o -iname '*.cbz' \\) -not -path '/sdcard/Android/*' 2>/dev/null" | sort >"$tmp.files"
        cut -f1 "$tmp.neo" | sort -u >"$tmp.neopaths"
        while IFS= read -r f; do
            [[ -n $f ]] || continue
            title="" author="" status="" last="" source="file"
            local row
            row=$(awk -F'\t' -v p="$f" '$1 == p { print; exit }' "$tmp.neo")
            if [[ -n $row ]]; then
                IFS=$'\t' read -r _ title author status last <<<"$row"
                source="neoreader"
            fi
            if [[ $f == *.[eE][pP][uU][bB] ]]; then
                container=$(dsh unzip -p "$(q "$f")" META-INF/container.xml 2>/dev/null || true)
                opf=$(printf '%s' "$container" | opf_path)
                if [[ -n $opf ]]; then
                    local xml
                    xml=$(dsh unzip -p "$(q "$f")" "$(q "$opf")" 2>/dev/null || true)
                    [[ -n $title ]] || title=$(printf '%s' "$xml" | opf_field title)
                    [[ -n $author ]] || author=$(printf '%s' "$xml" | opf_field creator)
                    source="$source+opf"
                fi
            fi
            # KOReader: the sidecar's status, and when it was last written (last opened).
            sdr="${f%.*}.sdr"
            local meta
            meta=$(dsh "ls $(q "$sdr")/metadata.*.lua 2>/dev/null" | head -n 1 || true)
            if [[ -n $meta ]]; then
                [[ -n $status ]] || status=$(dsh cat "$(q "$meta")" | sidecar_status || true)
                [[ -n $last ]] || last=$(dsh stat -c %Y "$(q "$meta")" 2>/dev/null || true)
                source="$source+koreader"
            fi
            printf '%s,%s,%s,%s,%s,%s\n' "$(csv "$f")" "$(csv "$title")" "$(csv "$author")" "$(csv "$status")" "$(csv "$last")" "$source"
        done <"$tmp.files"
    } >"$out"
    say "  $(($(wc -l <"$out") - 1)) book(s) written"
    rm -f "$tmp" "$tmp.neo" "$tmp.files" "$tmp.neopaths"
}

# ---------------------------------------------------------------- --fresh

fresh() {
    if ! dsh "[ -d $KO_DIR ] && echo yes" | grep -q yes; then
        say "No $KO_DIR on the device: nothing to clear."
        return 0
    fi
    say "--fresh clears $KO_DIR on the device. It holds:"
    dsh ls -la "$KO_DIR"
    local answer=""
    printf 'Delete %s and everything in it? [y/N] ' "$KO_DIR"
    read -r answer </dev/tty || answer=""
    if [[ $answer == y || $answer == Y ]]; then
        dsh rm -rf "$KO_DIR"
        say "Cleared $KO_DIR."
    else
        say "Kept $KO_DIR."
    fi
}

# ---------------------------------------------------------------- downloads (verified)

fetch() { curl -fsSL --retry 2 --connect-timeout 8 -H "User-Agent: orbit-install-usb" "$@"; }

download_koreader() {
    local json abi arch name url digest got
    json=$(fetch "$KOREADER_API")
    KO_TAG=$(jq -r .tag_name <<<"$json")
    for abi in ${ABIS//,/ }; do
        arch=$(abi_arch "$abi") || continue
        name=$(jq -r --arg a "$arch" '.assets[].name | select(test("^koreader-android-" + $a + "-v[0-9].*\\.apk$"))' <<<"$json" | head -n 1)
        [[ -n $name ]] && break
    done
    [[ -n ${name:-} ]] || die "KOReader $KO_TAG has no APK for $ABIS"
    url=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$json")
    digest=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest // ""' <<<"$json")
    KO_APK="$WORK/$name"
    fetch -o "$KO_APK" "$url"
    got=$(sha256 "$KO_APK")
    if [[ -n $digest ]]; then
        [[ "sha256:$got" == "$digest" ]] || die "KOReader download failed its checksum"
        say "KOReader $KO_TAG: $name, $(wc -c <"$KO_APK" | tr -d ' ') bytes, sha256 matches GitHub's digest"
    else
        say "KOReader $KO_TAG: $name, $(wc -c <"$KO_APK" | tr -d ' ') bytes (GitHub published no digest; sha256 $got)"
    fi
}

download_plugin() {
    local tag tree_sha tree path sha f n=0
    tag=$(fetch "$BOOKORBIT_API/releases/latest" | jq -r .tag_name)
    tree_sha=$(fetch "$BOOKORBIT_API/contents/koreader-plugin?ref=$tag" | jq -r --arg n "$PLUGIN_NAME" '.[] | select(.name == $n and .type == "dir") | .sha')
    [[ -n $tree_sha ]] || die "BookOrbit $tag has no $PLUGIN_NAME"
    tree=$(fetch "$BOOKORBIT_API/git/trees/$tree_sha?recursive=1")
    [[ $(jq -r .truncated <<<"$tree") == false ]] || die "BookOrbit $tag: plugin file list cut short"
    PLUGIN_DIR="$WORK/$PLUGIN_NAME"
    mkdir -p "$PLUGIN_DIR"
    while IFS=$'\t' read -r path sha; do
        case "/$path/" in */../* | */./* | *//*) die "unexpected plugin path $path" ;; esac
        f="$PLUGIN_DIR/$path"
        mkdir -p "$(dirname "$f")"
        fetch -o "$f" "$BOOKORBIT_RAW/$tag/koreader-plugin/$PLUGIN_NAME/$path"
        [[ $(git_blob_sha1 "$f") == "$sha" ]] || die "plugin file $path failed its checksum"
        n=$((n + 1))
    done < <(jq -r '.tree[] | select(.type == "blob") | [.path, .sha] | @tsv' <<<"$tree")
    PLUGIN_VER=$(sed -n 's/^local PLUGIN_VERSION = "\([^"]*\)".*/\1/p' "$PLUGIN_DIR/main.lua")
    [[ -n $PLUGIN_VER ]] || die "BookOrbit $tag: no plugin main.lua"
    say "BookOrbit plugin $PLUGIN_VER (release $tag): $n files, $(du -sk "$PLUGIN_DIR" | cut -f1) KB, git blob ids match"
}

# The version in an Android release tag: android-v0.7.1 (Orbify) or v0.7.0 (before it).
orbit_version() {
    local t=${1#android-}
    printf '%s' "${t#v}"
}

download_orbit() {
    local json name url ver
    json=$(fetch "$ORBIT_API")
    ORBIT_TAG=$(jq -r .tag_name <<<"$json")
    ver=$(orbit_version "$ORBIT_TAG")
    for name in SHA256SUMS "$ORBIT_ZIP" "orbit-companion-$ver.apk"; do
        url=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$json")
        [[ -n $url ]] || die "$ORBIT_TAG has no $name"
        fetch -o "$WORK/$name" "$url"
    done
    local sum file checked=0
    while read -r sum file; do
        file=${file#\*}
        case "$file" in "$ORBIT_ZIP" | orbit-companion-*.apk) ;; *) continue ;; esac
        [[ $(sha256 "$WORK/$file") == "$sum" ]] || die "$file failed SHA256SUMS"
        checked=$((checked + 1))
    done <"$WORK/SHA256SUMS"
    [[ $checked == 2 ]] || die "SHA256SUMS doesn't list the companion and the plugin"
    COMPANION_APK="$WORK/orbit-companion-$ver.apk"
    if command -v gh >/dev/null 2>&1 && gh attestation verify "$COMPANION_APK" -R Fledgewing/Orbify >/dev/null 2>&1 &&
        gh attestation verify "$WORK/$ORBIT_ZIP" -R Fledgewing/Orbify >/dev/null 2>&1; then
        say "Orbit $ORBIT_TAG: companion and plugin match SHA256SUMS and their build attestations"
    else
        say "Orbit $ORBIT_TAG: companion and plugin match SHA256SUMS (install the gh CLI to also check build attestations)"
    fi
    ORBIT_DIR=$(unpack_orbit "$WORK/$ORBIT_ZIP" "$WORK/orbit" "$ver")
}

# The release zip unpacked into <dest>/orbit.koplugin; prints that folder. Every member must sit
# inside orbit.koplugin/ and its main.lua must declare <version>.
unpack_orbit() { # zip dest version
    local zip=$1 dest=$2 ver=$3 member
    while IFS= read -r member; do
        case "$member" in
            "$ORBIT_PLUGIN"/*) ;;
            *) die "$ORBIT_ZIP holds $member, outside $ORBIT_PLUGIN/" ;;
        esac
        case "/$member/" in */../* | */./*) die "$ORBIT_ZIP holds $member" ;; esac
    done < <(unzip -Z1 "$zip")
    mkdir -p "$dest"
    unzip -q -o "$zip" -d "$dest"
    local stamped
    stamped=$(sed -n 's/^local PATCH_VERSION = "\([^"]*\)"$/\1/p' "$dest/$ORBIT_PLUGIN/main.lua" 2>/dev/null | head -n 1)
    [[ $stamped == "$ver" ]] || die "$ORBIT_ZIP declares ${stamped:-no version}, not $ver"
    printf '%s\n' "$dest/$ORBIT_PLUGIN"
}

# Pushes a plugin folder in beside the live one, then swaps it in: the live folder is never
# half-written.
push_plugin() { # local dir, plugin folder name
    local live="$KO_DIR/plugins/$2" new="$KO_DIR/plugins/$2.orbit-new" old="$KO_DIR/plugins/$2.orbit-old"
    dsh mkdir -p "$KO_DIR/plugins"
    dsh rm -rf "$new" "$old"
    "${ADB[@]}" push "$1" "$new" >/dev/null
    dsh "if [ -d $live ]; then mv $live $old; fi && mv $new $live && rm -rf $old"
}

install_orbit_plugin() {
    say "Pushing the Orbit KOReader plugin $ORBIT_TAG"
    push_plugin "$ORBIT_DIR" "$ORBIT_PLUGIN"
    # The plugin replaces the user patch; with both present the plugin stays off.
    dsh rm -f "$KO_DIR/patches/$OLD_PATCH" "$KO_DIR/patches/$OLD_PATCH.new"
}

# ---------------------------------------------------------------- installs

# Puts Orbit, KOReader and Tailscale (each if installed) on Android's Doze allowlist: what the
# setup row "Battery: Unrestricted" checks. Some readers (the Boox Page) show Orbit, a device
# admin, as "Battery optimization not available" with no switch, yet Doze still applies. Android
# keeps the list across reboots (deviceidle.xml). Undo: dumpsys deviceidle whitelist -<package>.
BATTERY_PKGS=(net.fledgewing.orbitcompanion org.koreader.launcher com.tailscale.ipn)
allowlist_battery() {
    local pkg
    for pkg in "${BATTERY_PKGS[@]}"; do
        [[ -n $(dsh pm path "$pkg" 2>/dev/null || true) ]] || continue
        if dsh dumpsys deviceidle whitelist "+$pkg" | grep -q "^Added"; then
            say "Battery: $pkg unrestricted (Doze allowlist)"
        else
            say "Battery: couldn't add $pkg to the Doze allowlist; set it in Settings › Apps › Battery"
        fi
    done
}

install_all() {
    say "Installing KOReader $KO_TAG"
    "${ADB[@]}" install -r "$KO_APK" ||
        die "KOReader didn't install. An unofficial KOReader (another signature) must be uninstalled first; your books and $KO_DIR stay."
    say "Installing Orbit Companion $ORBIT_TAG"
    "${ADB[@]}" install -r "$COMPANION_APK" || die "Orbit Companion didn't install"

    local have
    have=$(dsh cat "$KO_DIR/plugins/$PLUGIN_NAME/main.lua" 2>/dev/null | sed -n 's/^local PLUGIN_VERSION = "\([^"]*\)".*/\1/p' || true)
    if [[ -n $have ]] && ! version_lt "$have" "$PLUGIN_MIN"; then
        say "BookOrbit plugin $have already installed (it updates itself from your BookOrbit server): kept"
    else
        say "Pushing the BookOrbit plugin $PLUGIN_VER"
        push_plugin "$PLUGIN_DIR" "$PLUGIN_NAME"
    fi

    install_orbit_plugin
    allowlist_battery
    say "Done. Open Orbit Companion on the device and follow Setup (Fix next)."
}

# ---------------------------------------------------------------- main

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fresh) FRESH=1 ;;
            --books) BOOKS=${2:?--books needs a file name}; shift ;;
            --no-install) INSTALL=0 ;;
            --serial) ADB=(adb -s "${2:?--serial needs a serial}"); shift ;;
            -h | --help) usage; return 0 ;;
            *) usage >&2; die "unknown option $1" ;;
        esac
        shift
    done
    command -v adb >/dev/null 2>&1 || die "adb not found (Android platform-tools)"
    if [[ $INSTALL == 1 ]]; then
        command -v curl >/dev/null 2>&1 || die "curl not found"
        command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq / apt install jq)"
        command -v unzip >/dev/null 2>&1 || die "unzip not found"
    fi
    pick_device
    detect
    # The list first: --fresh may remove KOReader's sidecars.
    [[ -n $BOOKS ]] && write_books "$BOOKS"
    [[ $INSTALL == 1 ]] || return 0
    [[ $FRESH == 1 ]] && fresh
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    download_koreader
    download_plugin
    download_orbit
    install_all
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
