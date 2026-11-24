#!/usr/bin/env bash
# Sideload an Android test build over USB (adb): the release-signed Orbit Companion and the
# stamped Orbit KOReader plugin from a release.yml run with publish off (AGENTS.md "Test builds:
# sideload first, release after"). Test on the device first; publish a release once it works.
#
#   tools/sideload-android.sh <run-id>                 download the run's android-test-* artifact
#   tools/sideload-android.sh <artifact-dir>           an artifact already downloaded
#   options: --serial SERIAL   pick the device    --plugin-only   only the plugin, no APK
#            --yes             don't ask before changing the device
#
# Checks before touching the device: SHA256SUMS for the APK and the plugin zip, the APK's
# signing certificate (release.yml EXPECTED_CERT_SHA256, read from the workflow) and the
# version stamped into the plugin. Then: `adb install -r` (keeps the app's data), the plugin
# pushed beside the live one and swapped in (as the companion installs it), and, when KOReader
# runs, the companion's restart (COMMAND=restart: the plugin saves, quits and is started again).
# It deletes no user data: only the plugin folder it replaces and the old Orbit user patch.
# Needs: adb, gh (for a run id), unzip, apksigner (Android SDK build-tools; not with
# --plugin-only), shasum or sha256sum.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/install-usb.sh
source "$here/install-usb.sh" # helpers: sha256, unpack_orbit, push_plugin, dsh, pick_device, q

REPO="Fledgewing/Orbify" # artifacts come from this repo only
ARTIFACT_PREFIX="android-test-"
COMPANION_PKG="net.fledgewing.orbitcompanion"
KO_PKG="org.koreader.launcher"
KO_ACTIVITY="org.koreader.launcher.MainActivity"
EXTRA_COMMAND="$COMPANION_PKG.extra.COMMAND" # companion Contract.EXTRA_COMMAND
RELEASE_YML="$here/../.github/workflows/release.yml"

PLUGIN_ONLY=0
YES=0
SOURCE=""

die() { printf 'sideload-android: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- helpers (pure)

# The release certificate's SHA-256 as release.yml declares it (one source of truth).
expected_cert() { sed -nE 's/^ *EXPECTED_CERT_SHA256: *"([0-9A-F:]+)".*/\1/p' "$RELEASE_YML" | head -n 1; }

# apksigner --print-certs output -> the first certificate's SHA-256 as AA:BB:...
cert_from_apksigner() {
    sed -nE 's/.*[Cc]ertificate SHA-256 digest: ([0-9a-fA-F]+).*/\1/p' | head -n 1 |
        tr 'a-f' 'A-F' | sed -E 's/(..)/\1:/g; s/:$//'
}

# The test build's version from its APK name: orbit-companion-<version>.apk.
apk_version() {
    local n
    n=$(basename "$1")
    n=${n#orbit-companion-}
    printf '%s\n' "${n%.apk}"
}

# Folder names (one per line, stdin) -> the one android-test-* artifact; fails on none or several.
pick_artifact() {
    local names
    names=$(grep -E "^${ARTIFACT_PREFIX}" || true)
    [[ -n $names ]] || { echo "no ${ARTIFACT_PREFIX}* artifact (was the run started with publish off?)" >&2; return 1; }
    [[ $(wc -l <<<"$names" | tr -d ' ') == 1 ]] || { printf 'several test artifacts:\n%s\n' "$names" >&2; return 1; }
    printf '%s\n' "$names"
}

# SHA256SUMS (file $1) lists <name> and its digest matches <dir>/<name>.
sum_ok() { # sums dir name
    local want
    want=$(awk -v n="$3" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$1")
    [[ -n $want ]] || { echo "SHA256SUMS doesn't list $3" >&2; return 1; }
    [[ $(sha256 "$2/$3") == "$want" ]] || { echo "$3 doesn't match SHA256SUMS" >&2; return 1; }
}

# ---------------------------------------------------------------- inputs

find_apksigner() {
    local d c
    if command -v apksigner >/dev/null 2>&1; then command -v apksigner; return 0; fi
    for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
        [[ -n $d && -d $d/build-tools ]] || continue
        c=$(find "$d/build-tools" -maxdepth 2 -name apksigner -type f 2>/dev/null | sort -V | tail -n 1)
        [[ -n $c ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

fetch_artifact() {
    if [[ $SOURCE =~ ^[0-9]+$ ]]; then
        command -v gh >/dev/null 2>&1 || die "gh not found (needed to download run $SOURCE)"
        say "Run $SOURCE in $REPO:"
        gh run view "$SOURCE" -R "$REPO" --json workflowName,headBranch,headSha,event,status,conclusion \
            -q '"  workflow \(.workflowName), branch \(.headBranch) \(.headSha[0:12]), \(.event), \(.status) \(.conclusion)"' ||
            die "can't read run $SOURCE in $REPO"
        gh run download "$SOURCE" -R "$REPO" -p "${ARTIFACT_PREFIX}*" -D "$WORK/dl" ||
            die "run $SOURCE has no ${ARTIFACT_PREFIX}* artifact (start release.yml with publish off)"
        ART="$WORK/dl"
    else
        [[ -d $SOURCE ]] || die "$SOURCE is neither a run id nor a folder"
        ART=$SOURCE
    fi
    # The artifact's files, or a folder holding one android-test-* artifact folder.
    if ! compgen -G "$ART/orbit-companion-*.apk" >/dev/null; then
        local sub
        sub=$(find "$ART" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | pick_artifact) || die "no test build in $ART"
        ART="$ART/$sub"
    fi
}

verify() {
    local apks
    apks=$(compgen -G "$ART/orbit-companion-*.apk" || true)
    [[ -n $apks && $(wc -l <<<"$apks" | tr -d ' ') == 1 ]] || die "$ART needs exactly one orbit-companion-*.apk"
    APK=$apks
    VER=$(apk_version "$APK")
    [[ -f $ART/SHA256SUMS && -f $ART/$ORBIT_ZIP ]] || die "$ART has no SHA256SUMS or $ORBIT_ZIP"
    sum_ok "$ART/SHA256SUMS" "$ART" "$(basename "$APK")" || die "checksum failed"
    sum_ok "$ART/SHA256SUMS" "$ART" "$ORBIT_ZIP" || die "checksum failed"
    say "Checked: $(basename "$APK") and $ORBIT_ZIP match SHA256SUMS"
    case "$VER" in *-0.test.*) ;; *) say "Note: $VER is not a test-build version (<next patch>-0.test.<run>)" ;; esac

    if [[ $PLUGIN_ONLY == 0 ]]; then
        local signer want got
        signer=$(find_apksigner) || die "apksigner not found: install Android SDK build-tools, or set ANDROID_HOME"
        want=$(expected_cert)
        [[ -n $want ]] || die "can't read EXPECTED_CERT_SHA256 from $RELEASE_YML"
        got=$("$signer" verify --print-certs "$APK" | cert_from_apksigner) || die "apksigner rejected $(basename "$APK")"
        [[ $got == "$want" ]] || die "$(basename "$APK") is signed by $got, not the release certificate $want"
        say "Checked: signed with the release certificate ${want:0:11}…${want: -5}"
    fi
    PLUGIN_SRC=$(unpack_orbit "$ART/$ORBIT_ZIP" "$WORK/orbit" "$VER")
    say "Checked: $ORBIT_ZIP holds only $ORBIT_PLUGIN/ and declares $VER"
}

# ---------------------------------------------------------------- device

companion_version() { dsh dumpsys package "$COMPANION_PKG" | sed -nE 's/^ *versionName=(.*)$/\1/p' | head -n 1; }
plugin_version() { dsh cat "$KO_DIR/plugins/$ORBIT_PLUGIN/main.lua" 2>/dev/null | sed -n 's/^local PATCH_VERSION = "\([^"]*\)".*/\1/p' | head -n 1 || true; }
koreader_pid() { dsh pidof "$KO_PKG" 2>/dev/null || true; }
koreader_running() { [[ -n $(koreader_pid) ]]; }

plan() {
    local have_app have_plugin running=no
    have_app=$(companion_version || true)
    have_plugin=$(plugin_version)
    koreader_running && running=yes
    say ""
    say "Plan for $MODEL:"
    local n=1
    say "  $n. Push the Orbit KOReader plugin $VER to $KO_DIR/plugins/$ORBIT_PLUGIN (now: ${have_plugin:-none})."
    say "     Copied to $ORBIT_PLUGIN.orbit-new, then swapped in; the old folder is removed after the swap."
    say "     Removes $KO_DIR/patches/$OLD_PATCH if present (the old Orbit user patch)."
    n=$((n + 1))
    if [[ $PLUGIN_ONLY == 0 ]]; then
        say "  $n. adb install -r $(basename "$APK") (now: ${have_app:-not installed}); the app keeps its settings."
        n=$((n + 1))
    fi
    if [[ $running == yes ]]; then
        say "  $n. Restart KOReader the companion's way (COMMAND=restart): the plugin saves, quits, and the companion starts it again."
        [[ $PLUGIN_ONLY == 1 ]] || say "     Skipped when the updated companion restarts it first (it does after its own update)."
    else
        say "  $n. KOReader isn't running: it loads the new plugin when it next starts."
    fi
    say "Nothing else on the device changes: no books, settings or other folders are touched."
}

confirm() {
    [[ $YES == 1 ]] && return 0
    local answer=""
    printf 'Go ahead? [y/N] '
    read -r answer </dev/tty || answer=""
    [[ $answer == y || $answer == Y ]] || die "stopped; nothing changed"
}

apply() {
    say "Pushing the plugin $VER"
    push_plugin "$PLUGIN_SRC" "$ORBIT_PLUGIN"
    dsh rm -f "$KO_DIR/patches/$OLD_PATCH" "$KO_DIR/patches/$OLD_PATCH.new"
    [[ $(plugin_version) == "$VER" ]] || die "the plugin on the device doesn't declare $VER after the push"
    # Plugin first: the companion's own after-update step then finds its plugin version in place
    # (a test build has no release to fetch one from).
    local pid
    pid=$(koreader_pid)
    if [[ $PLUGIN_ONLY == 0 ]]; then
        say "Installing Orbit Companion $VER"
        "${ADB[@]}" install -r "$APK" ||
            die "the companion didn't install (a debug-signed install must be uninstalled first; that clears its settings, so do it yourself if you want it)"
        [[ $(companion_version) == "$VER" ]] || die "the device reports companion $(companion_version), not $VER"
    fi
    if [[ $PLUGIN_ONLY == 0 && -n $pid ]]; then
        # After its update the companion restarts a KOReader that runs an older plugin than the
        # one on disk; give it 15 s so KOReader isn't restarted twice.
        local i
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            [[ $(koreader_pid) == "$pid" ]] || break
            sleep 1
        done
        if [[ $(koreader_pid) != "$pid" ]]; then
            say "The companion restarted KOReader (it loads plugin $VER)"
            pid=""
        fi
    fi
    if [[ -n $pid ]] && koreader_running; then
        say "Restarting KOReader (COMMAND=restart)"
        dsh am start -n "$KO_PKG/$KO_ACTIVITY" -a android.intent.action.MAIN -f 0x10010000 --es "$EXTRA_COMMAND" restart >/dev/null
    fi
    say "Done: companion ${VER} and plugin ${VER} on $MODEL. Test it there; release only once it works."
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --serial) ADB=(adb -s "${2:?--serial needs a serial}"); shift ;;
            --plugin-only) PLUGIN_ONLY=1 ;;
            --yes) YES=1 ;;
            -h | --help) usage; return 0 ;;
            -*) usage >&2; die "unknown option $1" ;;
            *) [[ -z $SOURCE ]] || die "one run id or folder only"; SOURCE=$1 ;;
        esac
        shift
    done
    [[ -n $SOURCE ]] || { usage >&2; die "give a run id or an artifact folder"; }
    command -v adb >/dev/null 2>&1 || die "adb not found (Android platform-tools)"
    command -v unzip >/dev/null 2>&1 || die "unzip not found"
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    fetch_artifact
    verify
    pick_device
    detect
    plan
    confirm
    apply
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
