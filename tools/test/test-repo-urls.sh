#!/usr/bin/env bash
# Offline URL/attestation selection tests; gh and fetch are stubs, no devices.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/../repo-urls.sh
source "$here/../repo-urls.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
check() { [[ $2 == "$3" ]] || { printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; exit 1; }; }
SOURCE=42
mode=new
gh() {
    printf '%s\n' "$5" >>"$tmp/calls"
    case "$1 $2" in
        'run view') [[ $5 == "$BOOKSYNC_REPO" && $mode == new || $5 == "$BOOKSYNC_LEGACY_REPO" && $mode == old ]] ;;
        'attestation verify')
            [[ $mode == new && $5 == "$BOOKSYNC_REPO" || $mode == old && $5 == "$BOOKSYNC_LEGACY_REPO" ||
               $mode == mixed && $3 == apk && $5 == "$BOOKSYNC_REPO" ||
               $mode == mixed && $3 == zip && $5 == "$BOOKSYNC_LEGACY_REPO" ]] ;;
        *) return 1 ;;
    esac
}
REPO=$BOOKSYNC_REPO
booksync_run_info --json status
check 'canonical run lookup' "$BOOKSYNC_REPO" "$REPO"
check 'canonical lookup does not fall back' "$BOOKSYNC_REPO" "$(cat "$tmp/calls")"
: >"$tmp/calls"
mode=old
booksync_run_info --json status
check 'old run lookup selects the download repository' "$BOOKSYNC_LEGACY_REPO" "$REPO"
check 'lookup tries both names' "$BOOKSYNC_REPO"$'\n'"$BOOKSYNC_LEGACY_REPO" "$(cat "$tmp/calls")"
mode=missing
check 'missing old run stops' failed "$(booksync_run_info --json status || echo failed)"

fetch() {
    printf '%s\n' "$1" >>"$tmp/urls"
    if [[ $1 != *"/$BOOKSYNC_LEGACY_REPO/"* ]]; then printf partial; return 1; fi
    printf '{"tag_name":"v1"}'
}
check 'release metadata before rename' '{"tag_name":"v1"}' \
    "$(booksync_release_metadata "https://api.github.com/repos/$BOOKSYNC_REPO/releases/latest")"
check 'metadata lookup tries both names' \
    "https://api.github.com/repos/$BOOKSYNC_REPO/releases/latest"$'\n'"https://api.github.com/repos/$BOOKSYNC_LEGACY_REPO/releases/latest" \
    "$(cat "$tmp/urls")"
mode=new
check 'empty artifact set refused' failed "$(booksync_attested || echo failed)"
booksync_attested apk zip
mode=old
booksync_attested apk zip
mode=mixed
check 'mixed attestation identities refused' failed "$(booksync_attested apk zip || echo failed)"
mode=missing
check 'unverified artifacts refused' failed "$(booksync_attested apk zip || echo failed)"
printf 'repository URL tests passed\n'
