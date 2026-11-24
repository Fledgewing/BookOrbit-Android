#!/usr/bin/env bash
# Offline tests for tools/install-usb.sh: its helpers, and the book list against a stand-in
# adb (no device, no network). Run: bash tools/test/test-install-usb.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/../install-usb.sh
source "$here/../install-usb.sh"

passed=0 failed=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fi
}

check "abi arm64" arm64 "$(abi_arch arm64-v8a)"
check "abi arm" arm "$(abi_arch armeabi-v7a)"
check "abi x86_64 uses x86" x86 "$(abi_arch x86_64)"
check "abi unknown" no "$(abi_arch mips || echo no)"
check "orbit tag android-v" 0.7.1 "$(orbit_version android-v0.7.1)"
check "orbit tag v" 0.7.0 "$(orbit_version v0.7.0)"
check "2.2.9 < 2.3.0" yes "$(version_lt 2.2.9 2.3.0 && echo yes || echo no)"
check "2.3.0 !< 2.3.0" no "$(version_lt 2.3.0 2.3.0 && echo yes || echo no)"
check "2.10.0 !< 2.3.0" no "$(version_lt 2.10.0 2.3.0 && echo yes || echo no)"

tmpf=$(mktemp)
printf 'hello\n' >"$tmpf"
check "git blob id" ce013625030ba8dba906f756967f9e9ca394464a "$(git_blob_sha1 "$tmpf")"
rm -f "$tmpf"
check "csv quotes" '"say ""hi"", ok"' "$(csv 'say "hi", ok')"
check "device quoting" "'it'\\''s'" "$(q "it's")"
check "opf path" "OEBPS/content.opf" "$(printf '<container><rootfiles>\n<rootfile full-path="OEBPS/content.opf" media-type="x"/></rootfiles></container>' | opf_path)"
opf='<metadata><dc:title id="t">Pride &amp; Prejudice</dc:title>
<dc:creator opf:role="aut">Jane Austen</dc:creator><dc:creator>Second Author</dc:creator></metadata>'
check "opf title" "Pride & Prejudice" "$(printf '%s' "$opf" | opf_field title)"
check "opf first creator" "Jane Austen" "$(printf '%s' "$opf" | opf_field creator)"
check "opf missing field" "" "$(printf '%s' "$opf" | opf_field publisher)"
check "sidecar status" complete "$(printf 'return {\n ["summary"] = {\n  ["status"] = "complete",\n },\n}' | sidecar_status)"
check "neo row" $'/sdcard/Books/a, b.epub\tA, B\tAnn\t2\t1700000000000' \
    "$(printf 'Row: 0 id=4, nativeAbsolutePath=/sdcard/Books/a, b.epub, title=A, B, authors=Ann, readingStatus=2, lastAccess=1700000000000\n' | neo_rows)"

# ---- the book list against a stand-in adb
fake_adb() {
    [[ $1 == shell ]] || return 1
    shift
    local cmd="$*"
    case "$cmd" in
        "content query --uri $NEO_URI") printf 'Row: 0 nativeAbsolutePath=/sdcard/Books/neo.epub, title=Neo Title, authors=Neo Author, readingStatus=1, lastAccess=1700000000000\n' ;;
        find*) printf '/sdcard/Books/neo.epub\n/sdcard/Books/plain.epub\n/sdcard/Books/doc.pdf\n' ;;
        "unzip -p '/sdcard/Books/plain.epub' META-INF/container.xml") printf '<rootfile full-path="c.opf"/>' ;;
        "unzip -p '/sdcard/Books/plain.epub' 'c.opf'") printf '<dc:title>Plain</dc:title><dc:creator>Writer</dc:creator>' ;;
        "unzip -p '/sdcard/Books/neo.epub' META-INF/container.xml") printf '<rootfile full-path="n.opf"/>' ;;
        "unzip -p '/sdcard/Books/neo.epub' 'n.opf'") printf '<dc:title>Ignored</dc:title>' ;;
        "ls '/sdcard/Books/plain.sdr'/metadata.*.lua 2>/dev/null") printf '/sdcard/Books/plain.sdr/metadata.epub.lua\n' ;;
        "cat '/sdcard/Books/plain.sdr/metadata.epub.lua'") printf '["summary"] = { ["status"] = "reading" }' ;;
        "stat -c %Y '/sdcard/Books/plain.sdr/metadata.epub.lua'") printf '1700000123\n' ;;
        ls*) return 1 ;;
        *) printf 'unexpected: %s\n' "$cmd" >&2; return 1 ;;
    esac
}
ADB=(fake_adb)
out=$(mktemp)
write_books "$out" >/dev/null
check "csv header" "path,title,author,status,last_opened,source" "$(sed -n 1p "$out")"
check "neoreader book" '"/sdcard/Books/neo.epub","Neo Title","Neo Author","1","1700000000000",neoreader+opf' "$(grep neo.epub "$out")"
check "epub via OPF + KOReader sidecar" '"/sdcard/Books/plain.epub","Plain","Writer","reading","1700000123",file+opf+koreader' "$(grep plain.epub "$out")"
check "a pdf: path only" '"/sdcard/Books/doc.pdf","","","","",file' "$(grep doc.pdf "$out")"
rm -f "$out"

# ---- the Orbit plugin: unpack checks, then the push, the swap and the old patch removed
zwork=$(mktemp -d)
mkdir -p "$zwork/src/orbit.koplugin/ko"
printf 'local PATCH_VERSION = "0.8.0"\n' >"$zwork/src/orbit.koplugin/main.lua"
printf -- '-- x\n' >"$zwork/src/orbit.koplugin/ko/x.lua"
(cd "$zwork/src" && zip -q -r "$zwork/ok.zip" orbit.koplugin)
check "unpack: folder" "$zwork/u1/orbit.koplugin" "$(unpack_orbit "$zwork/ok.zip" "$zwork/u1" 0.8.0)"
check "unpack: files" "-- x" "$(cat "$zwork/u1/orbit.koplugin/ko/x.lua")"
check "unpack: wrong version refused" refused "$( (unpack_orbit "$zwork/ok.zip" "$zwork/u2" 0.9.0 >/dev/null 2>&1) && echo ok || echo refused)"
printf 'x\n' >"$zwork/src/stray.lua"
(cd "$zwork/src" && zip -q -r "$zwork/bad.zip" orbit.koplugin stray.lua)
check "unpack: member outside the folder refused" refused "$( (unpack_orbit "$zwork/bad.zip" "$zwork/u3" 0.8.0 >/dev/null 2>&1) && echo ok || echo refused)"
check "unpack: nothing written for a refused zip" no "$([[ -e $zwork/u3 ]] && echo yes || echo no)"

log="$zwork/adb.log"
rec_adb() { printf '%s\n' "$*" >>"$log"; } # dsh runs it in a pipeline (a subshell): log to a file
ADB=(rec_adb)
ORBIT_DIR="$zwork/u1/orbit.koplugin" ORBIT_TAG=v0.8.0
install_orbit_plugin >/dev/null
P="$KO_DIR/plugins/orbit.koplugin"
check "plugin pushed beside the live one" "push $ORBIT_DIR $P.orbit-new" "$(sed -n 3p "$log")"
check "then swapped in" "shell if [ -d $P ]; then mv $P $P.orbit-old; fi && mv $P.orbit-new $P && rm -rf $P.orbit-old" "$(sed -n 4p "$log")"
check "old patch removed" "shell rm -f $KO_DIR/patches/2-orbit-android.lua $KO_DIR/patches/2-orbit-android.lua.new" "$(sed -n 5p "$log")"
# Doze allowlist: only installed apps are added, and a refusal is reported, not fatal.
: >"$log"
batt_adb() {
    printf '%s\n' "$*" >>"$log"
    case "$*" in
        "shell pm path com.tailscale.ipn") ;;
        "shell pm path "*) echo "package:/data/app/x/base.apk" ;;
        "shell dumpsys deviceidle whitelist +org.koreader.launcher") echo "Unknown package: org.koreader.launcher" ;;
        "shell dumpsys deviceidle whitelist +"*) echo "Added: ${4#+}" ;;
    esac
}
ADB=(batt_adb)
out=$(allowlist_battery)
check "allowlist: installed apps only" "shell dumpsys deviceidle whitelist +net.fledgewing.orbitcompanion|shell dumpsys deviceidle whitelist +org.koreader.launcher" \
    "$(grep deviceidle "$log" | paste -sd '|' -)"
check "allowlist: added" yes "$(grep -q 'net.fledgewing.orbitcompanion unrestricted' <<<"$out" && echo yes || echo no)"
check "allowlist: refusal reported" yes "$(grep -q "couldn't add org.koreader.launcher" <<<"$out" && echo yes || echo no)"
rm -rf "$zwork"

printf '%d passed, %d failed\n' "$passed" "$failed"
[[ $failed == 0 ]]
